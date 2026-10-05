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
    /// Moves a file back from the Trash: `(from, to)`. Never overwrites.
    typealias PutBackExecutor = @Sendable (URL, URL) throws -> Void
    typealias StatusReader = @Sendable (URL) -> FileMaterializationStatus
    typealias CapacityReader = @Sendable (URL) -> Int64?

    /// A question only the user can answer. Until it is answered the items stay pending
    /// and hidden, and the queue does not retry them.
    nonisolated enum Decision: Equatable, Sendable {
        /// The provider definitively refused to download these, so they cannot reach the
        /// Trash. Answers: `deleteImmediately` or `restore`.
        case downloadFailed([MediaAssetID])
        /// Downloading these would leave less than `FreeSpaceFloor` free. Answers:
        /// `deleteImmediately` or `keepWaitingForSpace`.
        case diskFloor([MediaAssetID])

        var ids: [MediaAssetID] {
            switch self {
            case let .downloadFailed(ids), let .diskFloor(ids): ids
            }
        }

        var kindName: String {
            switch self {
            case .downloadFailed: "downloadFailed"
            case .diskFloor: "diskFloor"
            }
        }

        func isSameKind(as other: Self) -> Bool {
            kindName == other.kindName
        }

        /// The union of two same-kind questions, keeping first-asked order.
        func merging(_ other: Self) -> Self {
            let merged = ids + other.ids.filter { !ids.contains($0) }
            switch self {
            case .downloadFailed: return .downloadFailed(merged)
            case .diskFloor: return .diskFloor(merged)
            }
        }
    }

    /// What the status bar reports (DES-030/031). `movedCount` counts items moved since
    /// the queue last became non-empty and resets when it drains.
    nonisolated struct QueueState: Equatable, Sendable {
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

    nonisolated enum Event: Equatable, Sendable {
        case state(QueueState)
        case decision(Decision)
        /// Items whose move failed after they were local. They have been un-hidden.
        case moveFailed([MediaAssetID])
    }

    /// What undo achieved for one Move to Trash: items back in the library, and items
    /// that could not be put back (no longer in the Trash, or their path is taken).
    nonisolated struct UndoResult: Equatable, Sendable {
        var restored: [MediaAssetID] = []
        var failed: [MediaAssetID] = []
    }

    nonisolated struct RetryPolicy: Sendable {
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
    private let putBackExecutor: PutBackExecutor
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
    /// Items this session moved to the Trash, per command, for undo. In memory like
    /// every other undo entry; after relaunch only Finder's Put Back remains.
    private var trashed: [MediaTrashBatchID: [TrashedItem]] = [:]
    /// Undo requests run inside the drain task, between passes, so an undo never
    /// interleaves with a move that is part-way through.
    private var undoRequests: [UndoRequest] = []

    private struct UndoRequest {
        let batch: MediaTrashBatchID
        let ids: Set<MediaAssetID>
        let continuation: CheckedContinuation<UndoResult, Never>
    }

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
        putBackExecutor: @escaping PutBackExecutor = { from, to in
            try FileManager.default.moveItem(at: from, to: to)
        },
        retryPolicy: RetryPolicy = .production
    ) {
        self.store = store
        self.materializationRequester = materializationRequester
        self.status = status
        self.capacity = capacity
        self.trashExecutor = trashExecutor
        self.removeExecutor = removeExecutor
        self.putBackExecutor = putBackExecutor
        self.retryPolicy = retryPolicy
        let (events, eventContinuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        self.events = events
        self.eventContinuation = eventContinuation
        let (wakeStream, wakeContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wakeStream = wakeStream
        self.wakeContinuation = wakeContinuation
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
        let unanswered = undoRequests
        undoRequests.removeAll()
        for request in unanswered {
            request.continuation.resume(returning: UndoResult(failed: Array(request.ids)))
        }
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

    /// Undoes one Move to Trash: items still pending reappear without any filesystem
    /// call; items already in the Trash move back to their original paths (never over
    /// an existing file) and are re-cataloged with their authored overlay.
    func undo(batch: MediaTrashBatchID, ids: [MediaAssetID]) async -> UndoResult {
        guard !isShuttingDown else {
            return UndoResult(failed: ids)
        }
        start()
        return await withCheckedContinuation { continuation in
            undoRequests.append(UndoRequest(batch: batch, ids: Set(ids), continuation: continuation))
            kick()
        }
    }

    /// Bytes the requested items still need downloaded before they can be trashed:
    /// catalog sizes of members that are cloud-only right now. Reads no file bytes.
    func downloadBytes(for ids: [MediaAssetID]) async -> Int64 {
        let items = await (try? store.mediaTrashItems(for: ids)) ?? []
        return items.reduce(Int64(0)) { $0 + datalessBytes(of: $1) }
    }

    // MARK: - Drain

    private func drain() async {
        guard !isShuttingDown else { return }
        await answerUndoRequests()
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
                await moveToTrash(item, batch: pending.batch)
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

    private func answerUndoRequests() async {
        while !undoRequests.isEmpty {
            let request = undoRequests.removeFirst()
            await request.continuation.resume(returning: performUndo(batch: request.batch, ids: request.ids))
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
            OtosLog.catalog.errorOperation("mediaTrash.path", phase: "failed", fields: [
                "reason": "noMaterializer", "path": item.id.relativePath.rawValue,
            ])
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
    private func moveToTrash(_ item: MediaTrashItem, batch: MediaTrashBatchID) async {
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
            for: item.root.path,
            owner: .mediaTrash
        ) else {
            scheduleWake(after: retryPolicy.delays.first ?? .seconds(15))
            return
        }
        let overlay = await (try? store.trashedOverlay(for: [item.id]))?[item.id]
        var results: [MediaTrashPathResult] = []
        var moved: [TrashedMember] = []
        var evicted = false
        for member in item.members.sorted(by: Self.memberOrder) {
            let memberURL = url(of: member, in: item)
            guard await store.ownsNamespaceMutationLease(lease) else {
                results.append(result(item, member, succeeded: false))
                OtosLog.catalog.errorOperation("mediaTrash.path", phase: "failed", fields: [
                    "reason": "leaseLost", "path": member.relativePath.rawValue,
                ])
                continue
            }
            // A provider may evict between download and move; trashItem would refuse.
            guard status(memberURL) != .dataless else {
                evicted = true
                break
            }
            do {
                let trashURL = try trashExecutor(memberURL)
                results.append(result(item, member, succeeded: true))
                moved.append(TrashedMember(member: member, trashURL: trashURL))
            } catch {
                results.append(result(item, member, succeeded: false))
                logFailure(error, operation: "trashItem", member: member)
            }
        }
        _ = await store.releaseNamespaceMutationLease(lease)
        await store.reconcileTrashedPaths(results.filter(\.succeeded))
        await settleMove(
            TrashedItem(item: item, members: moved, overlay: overlay),
            batch: batch,
            evicted: evicted,
            allSucceeded: !results.contains { !$0.succeeded }
        )
    }

    /// Records the outcome of one move: re-download an item evicted mid-move, re-show a
    /// failed one, or keep a moved one for undo.
    private func settleMove(
        _ trashedItem: TrashedItem,
        batch: MediaTrashBatchID,
        evicted: Bool,
        allSucceeded: Bool
    ) async {
        let id = trashedItem.item.id
        if evicted {
            OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "evictedBeforeMove", fields: [
                "path": id.relativePath.rawValue,
            ])
            kick()
            return
        }
        guard allSucceeded else {
            _ = try? await store.clearPendingTrash([id])
            eventContinuation.yield(.moveFailed([id]))
            return
        }
        movedInRun += 1
        trashed[batch, default: []].append(trashedItem)
        forget([id])
        OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "trashed", fields: [
            "path": id.relativePath.rawValue, "members": "\(trashedItem.members.count)",
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
        var fields = ErrorDiagnostics.fields(for: error)
        fields["reason"] = operation
        fields["role"] = String(describing: member.role)
        fields["path"] = member.relativePath.rawValue
        OtosLog.catalog.errorOperation("mediaTrash.path", phase: "failed", fields: fields)
    }

    private func performUndo(batch: MediaTrashBatchID, ids: Set<MediaAssetID>) async -> UndoResult {
        var outcome = UndoResult()
        let pendingIDs = await Set(pendingItems().map(\.item.id)).intersection(ids)
        if !pendingIDs.isEmpty {
            awaitingDecision.subtract(pendingIDs)
            waitingForSpace.subtract(pendingIDs)
            for id in pendingIDs {
                downloads[id]?.cancel()
            }
            forget(pendingIDs)
            outcome.restored += await (try? store.clearPendingTrash(Array(pendingIDs))) ?? []
        }
        var remaining: [TrashedItem] = []
        for trashedItem in trashed[batch] ?? [] {
            guard ids.contains(trashedItem.item.id) else {
                remaining.append(trashedItem)
                continue
            }
            if await putBack(trashedItem) {
                outcome.restored.append(trashedItem.item.id)
            } else {
                outcome.failed.append(trashedItem.item.id)
            }
        }
        trashed[batch] = remaining.isEmpty ? nil : remaining
        let accounted = Set(outcome.restored + outcome.failed)
        // Items deleted immediately or vanished on disk have nothing to put back.
        outcome.failed += ids.subtracting(accounted).sorted { $0.relativePath.rawValue < $1.relativePath.rawValue }
        OtosLog.catalog.noticeOperation("mediaTrash.undo", phase: "finish", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "restored": "\(outcome.restored.count)",
            "failed": "\(outcome.failed.count)",
        ])
        kick()
        return outcome
    }

    /// Moves an item's members back from the Trash, primary first, and re-catalogs it.
    /// Succeeds when the primary is back; a companion that cannot return stays in the
    /// Trash and is logged.
    private func putBack(_ trashedItem: TrashedItem) async -> Bool {
        let item = trashedItem.item
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
            for: item.root.path,
            owner: .mediaTrash
        ) else {
            return false
        }
        var returned: [TrashedMember] = []
        var primaryBack = false
        for moved in trashedItem.members.sorted(by: { Self.memberOrder($1.member, $0.member) }) {
            let destination = url(of: moved.member, in: item)
            guard let trashURL = moved.trashURL,
                  FileManager.default.fileExists(atPath: trashURL.path),
                  !FileManager.default.fileExists(atPath: destination.path)
            else {
                OtosLog.catalog.notice(
                    """
                    op=mediaTrash.undo failed reason=notInTrashOrPathTaken \
                    role=\(String(describing: moved.member.role), privacy: .public) \
                    path=\(moved.member.relativePath.rawValue, privacy: .public)
                    """
                )
                if moved.member.role == .primary {
                    break
                }
                continue
            }
            do {
                try putBackExecutor(trashURL, destination)
                returned.append(moved)
                if moved.member.role == .primary {
                    primaryBack = true
                }
            } catch {
                logFailure(error, operation: "putBack", member: moved.member)
                if moved.member.role == .primary {
                    break
                }
            }
        }
        _ = await store.releaseNamespaceMutationLease(lease)
        guard primaryBack else {
            return false
        }
        _ = await store.restoreTrashedItem(
            TrashedItem(item: item, members: returned, overlay: trashedItem.overlay)
        )
        return true
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
