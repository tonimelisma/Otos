import Foundation
import OSLog
import UniformTypeIdentifiers

/// System-Trash queue guide.
///
/// Move to Trash is a durable intent, not a blocking command. The ViewModel hides the
/// requested items by marking them pending in the Store (`markPendingTrash`) and kicks
/// this actor, which drains the Store's pending rows until each item is in the system
/// Trash, has vanished on disk, or the user withdraws the request. Pending rows survive
/// relaunch; `start()` resumes them. One drain task runs passes serially; answers to
/// decisions and withdrawals arrive between its suspensions and only change the sets the
/// next pass reads.
///
/// A dataless cloud placeholder cannot leave its File Provider domain, so `trashItem`
/// refuses it (`NSFeatureUnsupportedError`). Each dataless member is deliberately
/// materialized through the shared `MaterializationCoordinator` at `command` priority
/// first. Downloads run without the root namespace lease; the lease is held only around
/// the moves themselves, and every member's local status is rechecked under it because
/// a provider may evict again. Companions move before the primary. Nothing is ever
/// deleted permanently except through `deleteImmediately(_:)`, which only an explicit
/// user answer to a published `Decision` reaches.
///
/// Download outcomes split three ways. Transient ones (timeout, provider unavailable,
/// cancellation) leave the item pending and retry with backoff. A definitive one (the
/// provider rejects the request) publishes `.downloadFailed`. A download that would leave
/// the volume below `FreeSpaceFloor` is not started and publishes `.diskFloor` once per
/// pause; declining keeps the items pending until a later pass finds room.
///
/// The injected status, requester, capacity, and executors are the test boundary for
/// fault injection; production uses system Trash, `FileManager.removeItem`, and the
/// volume's important-usage capacity.
actor MediaTrashCoordinator {
    typealias TrashExecutor = @Sendable (URL) throws -> URL?
    typealias RemoveExecutor = @Sendable (URL) throws -> Void
    typealias StatusReader = @Sendable (URL) -> FileMaterializationStatus
    typealias CapacityReader = @Sendable (URL) -> Int64?

    /// A question only the user can answer. Until it is answered the items stay pending
    /// and hidden, and the queue does not retry them.
    enum Decision: Equatable, Sendable {
        /// The provider definitively refused to download these, so they cannot reach the
        /// Trash. Answers: `deleteImmediately` or `restore`.
        case downloadFailed([MediaAssetID])
        /// Downloading these would leave less than `FreeSpaceFloor` free. Answers:
        /// `deleteImmediately` or `keepWaitingForSpace`.
        case diskFloor([MediaAssetID])
    }

    /// What the status bar reports (DES-030/031). `movedCount` counts items moved since
    /// the queue last became non-empty and resets when it drains.
    struct QueueState: Equatable, Sendable {
        enum Attention: Equatable, Sendable {
            case waitingForSpace
            case waitingForDownload
        }

        var pendingCount: Int
        var movedCount: Int
        var bytesToDownload: Int64
        var attention: Attention?

        var runTotal: Int {
            pendingCount + movedCount
        }

        static let idle = QueueState(pendingCount: 0, movedCount: 0, bytesToDownload: 0, attention: nil)
    }

    enum Event: Equatable, Sendable {
        case state(QueueState)
        case decision(Decision)
        /// Items whose move failed after they were local. They have been un-hidden.
        case moveFailed([MediaAssetID])
    }

    struct RetryPolicy: Sendable {
        var delays: [Duration]

        static let production = RetryPolicy(
            delays: [.seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300)]
        )

        func delay(afterAttempt attempt: Int) -> Duration {
            delays[min(max(attempt - 1, 0), delays.count - 1)]
        }
    }

    private let store: CatalogStore
    private let materializationRequester: (any MaterializationRequesting)?
    private let status: StatusReader
    private let capacity: CapacityReader
    private let trashExecutor: TrashExecutor
    private let removeExecutor: RemoveExecutor
    private let retryPolicy: RetryPolicy
    private let clock = ContinuousClock()

    nonisolated let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    private var drainTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var isShuttingDown = false

    /// One download task per item whose dataless members are being fetched.
    private var downloads: [MediaAssetID: Task<Void, Never>] = [:]
    /// Bytes requested by in-flight downloads, counted against the free-space floor.
    private var downloadBytes: [MediaAssetID: Int64] = [:]
    private var attempts: [MediaAssetID: Int] = [:]
    private var retryAt: [MediaAssetID: ContinuousClock.Instant] = [:]
    /// Items waiting on the user's answer to a published decision.
    private var awaitingDecision: Set<MediaAssetID> = []
    /// Items the user chose to keep waiting at the floor; not asked again this pause.
    private var waitingForSpace: Set<MediaAssetID> = []
    private var movedInRun = 0
    private var lastState = QueueState.idle

    init(
        store: CatalogStore,
        materializationRequester: (any MaterializationRequesting)?,
        status: @escaping StatusReader = { FileMaterialization.status(of: $0) },
        capacity: @escaping CapacityReader = { url in
            (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        },
        trashExecutor: @escaping TrashExecutor = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        },
        removeExecutor: @escaping RemoveExecutor = { url in
            try FileManager.default.removeItem(at: url)
        },
        retryPolicy: RetryPolicy = .production
    ) {
        self.store = store
        self.materializationRequester = materializationRequester
        self.status = status
        self.capacity = capacity
        self.trashExecutor = trashExecutor
        self.removeExecutor = removeExecutor
        self.retryPolicy = retryPolicy
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (wakeStream, wakeContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Lifecycle

    /// Starts draining, which also resumes pending items left by an earlier run.
    func start() {
        guard drainTask == nil, !isShuttingDown else { return }
        let wakes = wakeStream
        wakeContinuation.yield()
        drainTask = Task { [weak self] in
            for await _ in wakes {
                guard let self else { return }
                await drain()
            }
        }
    }

    func shutdown() async {
        isShuttingDown = true
        wakeContinuation.finish()
        timerTask?.cancel()
        let inFlight = Array(downloads.values)
        inFlight.forEach { $0.cancel() }
        for task in inFlight {
            await task.value
        }
        await drainTask?.value
        eventContinuation.finish()
    }

    /// New pending items exist, or something they wait on changed. Coalesced.
    nonisolated func kick() {
        wakeContinuation.yield()
    }

    // MARK: - Answers to decisions

    /// Permanently deletes the items' members. Reachable only from an explicit user
    /// answer to a published `Decision`; never automatic.
    func deleteImmediately(_ ids: [MediaAssetID]) async {
        let set = Set(ids)
        awaitingDecision.subtract(set)
        waitingForSpace.subtract(set)
        let items = await pendingItems().filter { set.contains($0.item.id) }
        var deleted = 0
        for pending in items {
            downloads[pending.item.id]?.cancel()
            if await remove(pending.item) {
                deleted += 1
            }
        }
        OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "deletedImmediately", fields: [
            "requested": "\(ids.count)", "deleted": "\(deleted)",
        ])
        kick()
    }

    /// The download failed and the user chose not to delete: the items reappear.
    func restore(_ ids: [MediaAssetID]) async {
        let set = Set(ids)
        awaitingDecision.subtract(set)
        forget(set)
        let restored = await (try? store.clearPendingTrash(ids)) ?? []
        OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "restored", fields: [
            "requested": "\(ids.count)", "restored": "\(restored.count)",
        ])
        kick()
    }

    /// At the floor the user chose to wait: the items stay pending and hidden, and the
    /// queue starts their downloads once a later pass finds room, without asking again.
    func keepWaitingForSpace(_ ids: [MediaAssetID]) {
        let set = Set(ids)
        awaitingDecision.subtract(set)
        waitingForSpace.formUnion(set)
        scheduleWake(after: retryPolicy.delays.last ?? .seconds(300))
        kick()
    }

    /// Withdraws a pending request (undo of a batch not yet in the Trash): cancels any
    /// download in flight and un-hides the items. Returns the items un-hidden.
    func withdraw(_ ids: [MediaAssetID]) async -> [MediaAssetID] {
        let set = Set(ids)
        awaitingDecision.subtract(set)
        waitingForSpace.subtract(set)
        for id in set {
            downloads[id]?.cancel()
        }
        forget(set)
        let restored = await (try? store.clearPendingTrash(ids)) ?? []
        kick()
        return restored
    }

    // MARK: - Drain

    private func drain() async {
        guard !isShuttingDown else { return }
        let items = await pendingItems()
        let now = clock.now
        var floorBlocked: [MediaAssetID] = []
        var waitingOnRetry = false

        for pending in items {
            let item = pending.item
            if awaitingDecision.contains(item.id) || downloads[item.id] != nil {
                continue
            }
            let dataless = datalessMembers(of: item)
            if dataless.isEmpty {
                await moveToTrash(item)
                continue
            }
            if let at = retryAt[item.id], at > now {
                waitingOnRetry = true
                continue
            }
            let bytes = dataless.reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }
            guard fitsAboveFloor(bytes, root: item.root.path) else {
                if !waitingForSpace.contains(item.id) {
                    floorBlocked.append(item.id)
                }
                continue
            }
            waitingForSpace.remove(item.id)
            startDownload(item, members: dataless, bytes: bytes)
        }

        if !floorBlocked.isEmpty {
            awaitingDecision.formUnion(floorBlocked)
            OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "diskFloor", fields: [
                "items": "\(floorBlocked.count)",
            ])
            eventContinuation.yield(.decision(.diskFloor(floorBlocked)))
        }
        await publishState(
            attention: !waitingForSpace.isEmpty || !floorBlocked.isEmpty
                ? .waitingForSpace
                : (waitingOnRetry && downloads.isEmpty ? .waitingForDownload : nil)
        )
        // One timer serves both waits: the earliest download retry, and a periodic
        // free-space recheck while items wait at the floor (nothing else would wake the
        // queue when space is freed outside Otos).
        let spaceRecheck = waitingForSpace.isEmpty
            ? nil
            : clock.now.advanced(by: retryPolicy.delays.last ?? .seconds(300))
        if let next = ([retryAt.values.min(), spaceRecheck].compactMap(\.self)).min() {
            scheduleWake(at: next)
        }
    }

    private func publishState(attention: QueueState.Attention?) async {
        let remaining = await pendingItems()
        if remaining.isEmpty {
            movedInRun = 0
        }
        let state = QueueState(
            pendingCount: remaining.count,
            movedCount: movedInRun,
            bytesToDownload: remaining.reduce(Int64(0)) { $0 + datalessBytes(of: $1.item) },
            attention: remaining.isEmpty ? nil : attention
        )
        guard state != lastState else { return }
        lastState = state
        eventContinuation.yield(.state(state))
    }

    private func pendingItems() async -> [PendingTrashItem] {
        do {
            return try await store.pendingTrashItems()
        } catch {
            OtosLog.catalog.error(
                "op=mediaTrash.queue phase=readFailed error=\(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Downloads

    private func datalessMembers(of item: MediaTrashItem) -> [MediaTrashMember] {
        item.members.filter { status(url(of: $0, in: item)) == .dataless }
    }

    private func datalessBytes(of item: MediaTrashItem) -> Int64 {
        datalessMembers(of: item).reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }
    }

    private func fitsAboveFloor(_ bytes: Int64, root: LibraryRootPath) -> Bool {
        guard let available = capacity(root.url) else {
            // Unknown capacity is not evidence of room, but neither is it evidence of
            // none; ENOSPC from the provider is the backstop and stays transient.
            return true
        }
        let committed = downloadBytes.values.reduce(0, +)
        return available - committed - bytes >= FreeSpaceFloor.bytes
    }

    private func startDownload(_ item: MediaTrashItem, members: [MediaTrashMember], bytes: Int64) {
        guard let materializationRequester else {
            OtosLog.catalog.error(
                "op=mediaTrash.path failed reason=noMaterializer path=\(item.id.relativePath.rawValue, privacy: .public)"
            )
            awaitingDecision.insert(item.id)
            eventContinuation.yield(.decision(.downloadFailed([item.id])))
            return
        }
        downloadBytes[item.id] = bytes
        OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "download", fields: [
            "path": item.id.relativePath.rawValue, "members": "\(members.count)", "bytes": "\(bytes)",
        ])
        let requests = members.map { member in
            MaterializationCoordinator.Request(
                id: MediaAssetID(libraryRootPath: item.root.path, relativePath: member.relativePath),
                sourceSize: member.byteSize,
                isVideo: UTType(filenameExtension: url(of: member, in: item).pathExtension)?
                    .conforms(to: .movie) == true,
                priority: .command
            )
        }
        let id = item.id
        downloads[id] = Task { [weak self] in
            var outcome: MaterializationOutcome = .alreadyMaterialized
            for request in requests {
                let result = await materializationRequester.materialize(request)
                if !result.isMaterialized {
                    outcome = result.outcome
                    break
                }
            }
            await self?.finishDownload(id, outcome: outcome)
        }
    }

    private func finishDownload(_ id: MediaAssetID, outcome: MaterializationOutcome) {
        downloads[id] = nil
        downloadBytes[id] = nil
        guard !isShuttingDown else { return }
        switch outcome {
        case .alreadyMaterialized, .materialized:
            attempts[id] = nil
            retryAt[id] = nil
        case .requestFailed:
            OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "downloadFailed", fields: [
                "path": id.relativePath.rawValue, "outcome": outcome.diagnosticDescription,
            ])
            awaitingDecision.insert(id)
            eventContinuation.yield(.decision(.downloadFailed([id])))
        case .statusUnavailable where !FileManager.default.fileExists(atPath: id.fileURL.path):
            // The file left the root by other means; the scan reconciles its row, and the
            // user's intent (that it be gone) is already met.
            OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "vanished", fields: [
                "path": id.relativePath.rawValue,
            ])
            forget([id])
        case .timedOut, .providerUnavailable, .cancelled, .insufficientLocalSpace, .statusUnavailable,
             .deviceUnavailable:
            let attempt = (attempts[id] ?? 0) + 1
            attempts[id] = attempt
            let delay = retryPolicy.delay(afterAttempt: attempt)
            retryAt[id] = clock.now.advanced(by: delay)
            OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "retry", fields: [
                "path": id.relativePath.rawValue, "outcome": outcome.diagnosticDescription,
                "attempt": "\(attempt)", "delayMs": "\(DiagnosticsTiming.milliseconds(delay))",
            ])
        }
        kick()
    }

    private func forget(_ ids: Set<MediaAssetID>) {
        for id in ids {
            attempts[id] = nil
            retryAt[id] = nil
            downloadBytes[id] = nil
        }
    }

    private func scheduleWake(after delay: Duration) {
        scheduleWake(at: clock.now.advanced(by: delay))
    }

    private func scheduleWake(at instant: ContinuousClock.Instant) {
        timerTask?.cancel()
        let clock = clock
        timerTask = Task { [weak self] in
            try? await clock.sleep(until: instant)
            guard !Task.isCancelled else { return }
            self?.kick()
        }
    }

    // MARK: - Moves

    /// Moves one item whose members are all local. Rows for moved members are
    /// reconciled; if any member fails, the item is un-hidden and reported.
    private func moveToTrash(_ item: MediaTrashItem) async {
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
            for: item.root.path,
            owner: .mediaTrash
        ) else {
            scheduleWake(after: retryPolicy.delays.first ?? .seconds(15))
            return
        }
        var results: [MediaTrashPathResult] = []
        var evicted = false
        for member in item.members.sorted(by: Self.memberOrder) {
            let memberURL = url(of: member, in: item)
            guard await store.ownsNamespaceMutationLease(lease) else {
                results.append(result(item, member, succeeded: false))
                OtosLog.catalog.error(
                    "op=mediaTrash.path failed reason=leaseLost path=\(member.relativePath.rawValue, privacy: .public)"
                )
                continue
            }
            // A provider may evict between download and move; trashItem would refuse.
            guard status(memberURL) != .dataless else {
                evicted = true
                break
            }
            do {
                _ = try trashExecutor(memberURL)
                results.append(result(item, member, succeeded: true))
            } catch {
                results.append(result(item, member, succeeded: false))
                logFailure(error, operation: "trashItem", member: member)
            }
        }
        _ = await store.releaseNamespaceMutationLease(lease)
        await store.reconcileTrashedPaths(results.filter(\.succeeded))
        if evicted {
            OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "evictedBeforeMove", fields: [
                "path": item.id.relativePath.rawValue,
            ])
            kick()
            return
        }
        if results.contains(where: { !$0.succeeded }) {
            _ = try? await store.clearPendingTrash([item.id])
            eventContinuation.yield(.moveFailed([item.id]))
            return
        }
        movedInRun += 1
        forget([item.id])
        OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "trashed", fields: [
            "path": item.id.relativePath.rawValue, "members": "\(results.count)",
        ])
    }

    private func remove(_ item: MediaTrashItem) async -> Bool {
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
            for: item.root.path,
            owner: .mediaTrash
        ) else {
            return false
        }
        var results: [MediaTrashPathResult] = []
        for member in item.members.sorted(by: Self.memberOrder) {
            do {
                try removeExecutor(url(of: member, in: item))
                results.append(result(item, member, succeeded: true))
            } catch {
                results.append(result(item, member, succeeded: false))
                logFailure(error, operation: "removeItem", member: member)
            }
        }
        _ = await store.releaseNamespaceMutationLease(lease)
        await store.reconcileTrashedPaths(results.filter(\.succeeded))
        forget([item.id])
        if results.contains(where: { !$0.succeeded }) {
            _ = try? await store.clearPendingTrash([item.id])
            eventContinuation.yield(.moveFailed([item.id]))
            return false
        }
        return true
    }

    private func result(
        _ item: MediaTrashItem,
        _ member: MediaTrashMember,
        succeeded: Bool
    ) -> MediaTrashPathResult {
        MediaTrashPathResult(
            id: item.id,
            rootPath: item.root.path,
            relativePath: member.relativePath,
            role: member.role,
            succeeded: succeeded
        )
    }

    private nonisolated func url(of member: MediaTrashMember, in item: MediaTrashItem) -> URL {
        item.root.path.url.appending(path: member.relativePath.rawValue)
    }

    private func logFailure(_ error: any Error, operation: String, member: MediaTrashMember) {
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
            .map { "\($0.domain)/\($0.code)" } ?? "none"
        OtosLog.catalog.error(
            """
            op=mediaTrash.path failed reason=\(operation, privacy: .public) \
            errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) \
            underlying=\(underlying, privacy: .public) \
            role=\(String(describing: member.role), privacy: .public) \
            path=\(member.relativePath.rawValue, privacy: .public)
            """
        )
    }

    private static func memberOrder(
        _ left: MediaTrashMember,
        _ right: MediaTrashMember
    ) -> Bool {
        switch (left.role, right.role) {
        case (.companion, .primary): true
        case (.primary, .companion): false
        case (.companion, .companion), (.primary, .primary):
            left.relativePath.rawValue < right.relativePath.rawValue
        }
    }
}
