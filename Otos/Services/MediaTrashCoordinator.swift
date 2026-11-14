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
/// A moved item's row stays in the catalog, hidden, with the place the Trash put its file
/// (ADR 0022): everything Otos held for it waits there, so undo, or Finder's Put Back after a
/// relaunch, shows it again when the file returns to its path.
///
/// A failed Store read is not a fact. A pass whose pending-item read fails publishes
/// nothing — the queue state the user last saw stands — and retries on a timer.
///
/// A pass works from a snapshot of the pending items taken before its awaits, and the
/// user can answer a prompt or undo while it runs. Every such answer records the items it
/// withdrew in `revoked` *before* it touches the Store, and the pass checks that set before
/// it acts on each item and again once it holds the root lease, so an item the user took
/// back is never moved afterwards.
///
/// The injected status, requester, capacity, file operations and Store reads are the test
/// boundary for fault injection; production uses system Trash, `FileManager.removeItem`, and the
/// volume's important-usage capacity.
actor MediaTrashCoordinator {
    typealias TrashExecutor = @Sendable (URL) throws -> URL?
    typealias RemoveExecutor = @Sendable (URL) throws -> Void
    /// Moves a file back from the Trash: `(from, to)`. Never overwrites.
    typealias PutBackExecutor = @Sendable (URL, URL) throws -> Void
    typealias StatusReader = @Sendable (URL) -> FileMaterializationStatus

    /// The filesystem acts the queue performs, as one value: the app passes `.live`, the
    /// system Trash, and a test passes a Trash of its own. There is no default, so nothing
    /// the coordinator does reaches the user's Trash unless its owner chose that.
    nonisolated struct FileOperations: Sendable {
        /// Moves a file to the Trash and returns where it went, when the Trash says.
        var trash: TrashExecutor
        /// Deletes a file the user chose to delete immediately.
        var remove: RemoveExecutor
        /// Moves a file back from the Trash: `(from, to)`. Never overwrites.
        var putBack: PutBackExecutor

        static let live = FileOperations(
            trash: { url in
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return resulting as URL?
            },
            remove: { url in
                try FileManager.default.removeItem(at: url)
            },
            putBack: { from, to in
                try FileManager.default.moveItem(at: from, to: to)
            }
        )

        /// Refuses every act, so the queue moves nothing: for a window that must never
        /// touch a file, such as a preview or a test that does not trash.
        static let refusing = FileOperations(
            trash: { _ in throw CocoaError(.featureUnsupported) },
            remove: { _ in throw CocoaError(.featureUnsupported) },
            putBack: { _, _ in throw CocoaError(.featureUnsupported) }
        )
    }

    /// The Store reads the queue depends on, injectable so a test can make one fail.
    nonisolated struct StoreReads: Sendable {
        var pendingItems: @Sendable () async throws -> [PendingTrashItem]
        var trashItems: @Sendable ([MediaAssetID]) async throws -> [MediaTrashItem]

        static func live(_ store: CatalogStore) -> StoreReads {
            StoreReads(
                pendingItems: { try await store.pendingTrashItems() },
                trashItems: { try await store.mediaTrashItems(for: $0) }
            )
        }
    }

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
        var bytesToDownload: PartialByteCount
        var attention: Attention?

        var runTotal: Int {
            pendingCount + movedCount
        }

        static let idle = QueueState(pendingCount: 0, movedCount: 0, bytesToDownload: .zero, attention: nil)
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
    private let reads: StoreReads
    /// Awaited before each pending item is handled in a pass; a test uses it to deliver an
    /// answer at exactly the suspension a real user answer could land in.
    private let willHandleItem: (@Sendable (MediaAssetID) async -> Void)?
    private let materializationRequester: (any MaterializationRequesting)?
    private let status: StatusReader
    private let volumeCapacity: VolumeCapacityReader
    private let files: FileOperations
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
    /// What each in-flight download committed against the floor, and on which volume's
    /// ledger. Settled by `finishDownload`, which every download task ends in.
    private var downloadCommits: [MediaAssetID: (volume: URL, bytes: Int64)] = [:]
    /// One `FreeSpaceLedger` per volume with a download in flight, dropped when its last
    /// download settles, so the next stretch of downloads reads the figure afresh.
    private var ledgers: [URL: FreeSpaceLedger] = [:]
    private var attempts: [MediaAssetID: Int] = [:]
    private var retryAt: [MediaAssetID: ContinuousClock.Instant] = [:]
    /// Items waiting on the user's answer to a published decision.
    private var awaitingDecision: Set<MediaAssetID> = []
    /// Items the user chose to keep waiting at the floor; not asked again this pause.
    private var waitingForSpace: Set<MediaAssetID> = []
    private var movedInRun = 0
    /// Items the user took back (restore, withdraw, immediate delete, undo of a pending
    /// request) while a pass may still hold them in its snapshot. Added before the Store is
    /// touched, dropped once a read no longer lists the item.
    private var revoked: Set<MediaAssetID> = []
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
        files: FileOperations,
        status: @escaping StatusReader = { FileMaterialization.status(of: $0) },
        volumeCapacity: @escaping VolumeCapacityReader,
        retryPolicy: RetryPolicy = .production,
        reads: StoreReads? = nil,
        willHandleItem: (@Sendable (MediaAssetID) async -> Void)? = nil
    ) {
        self.store = store
        self.reads = reads ?? .live(store)
        self.willHandleItem = willHandleItem
        self.materializationRequester = materializationRequester
        self.status = status
        self.volumeCapacity = volumeCapacity
        self.files = files
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

    /// Ends the queue. The flag is set before the first await, and the two places that spawn
    /// work — `startDownload` from a pass, `scheduleWake` — refuse once it is set, so the
    /// downloads snapshotted here are every download there will ever be: a pass suspended
    /// in a read when this lands resumes into a stopped queue, not into a fresh download.
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
        revoked.formUnion(set)
        let items: [PendingTrashItem]
        do {
            items = try await pendingItems().filter { set.contains($0.item.id) }
        } catch {
            // Nothing was deleted: the items stay pending and the user can answer again.
            logReadFailure(error, read: "deleteImmediately")
            revoked.subtract(set)
            kick()
            return
        }
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
        revoked.formUnion(set)
        let restored = await clearPending(ids, operation: "restore")
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
        revoked.formUnion(set)
        for id in set {
            downloads[id]?.cancel()
        }
        forget(set)
        let restored = await clearPending(ids, operation: "withdraw")
        kick()
        return restored
    }

    /// Withdraws every item still waiting to move — the trash bar's Cancel. The items come
    /// from the Store's pending rows, so a request made in an earlier run is withdrawn the
    /// same way. A failed read withdraws nothing and is logged (ADR 0032 rule 4).
    func withdrawAllPending() async -> [MediaAssetID] {
        let ids: [MediaAssetID]
        do {
            ids = try await reads.pendingItems().map(\.item.id)
        } catch {
            logReadFailure(error, read: "withdrawAllPending")
            return []
        }
        let withdrawn = await withdraw(ids)
        OtosLog.catalog.noticeOperation("mediaTrash.queue", phase: "cancelled", fields: [
            "requested": "\(ids.count)", "withdrawn": "\(withdrawn.count)",
        ])
        return withdrawn
    }

    /// Undoes one Move to Trash: items still pending reappear without any filesystem
    /// call; items already in the Trash move back to their original paths (never over
    /// an existing file) and show again with everything their rows kept.
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
    /// catalog sizes of members that are cloud-only right now. Reads no file bytes. `nil`
    /// means the catalog could not be read — unknown, not zero.
    func downloadBytes(for ids: [MediaAssetID]) async -> PartialByteCount? {
        do {
            let items = try await reads.trashItems(ids)
            return items.reduce(PartialByteCount.zero) { $0 + datalessBytes(of: $1) }
        } catch {
            logReadFailure(error, read: "downloadBytes")
            return nil
        }
    }

    // MARK: - Drain

    private func drain() async {
        guard !isShuttingDown else { return }
        await answerUndoRequests()
        let items: [PendingTrashItem]
        do {
            items = try await pendingItems()
        } catch {
            // Not a fact about the queue: publish nothing, keep the state the user last saw,
            // and look again shortly.
            logReadFailure(error, read: "drain")
            scheduleWake(after: retryPolicy.delays.first ?? .seconds(15))
            return
        }
        revoked.formIntersection(Set(items.map(\.item.id)))
        let now = clock.now
        var floorBlocked: [MediaAssetID] = []
        var waitingOnRetry = false

        for pending in items {
            let item = pending.item
            await willHandleItem?(item.id)
            // Shutdown can land at any suspension of this pass (the reads above, the hook,
            // the previous item's move). It cancelled only the downloads it saw, so a pass
            // that finds it begun stops here and starts nothing it would never cancel.
            guard !isShuttingDown else { return }
            if awaitingDecision.contains(item.id) || downloads[item.id] != nil || revoked.contains(item.id) {
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
            // The floor is judged on the sizes that are known. An unknown size is not
            // evidence of room, but neither is it evidence of none; ENOSPC from the provider
            // is the backstop and stays transient, as for an unknown capacity.
            let bytes = PartialByteCount(sizes: dataless.map(\.byteSize)).knownBytes
            guard let volume = admitDownload(bytes, root: item.root.path) else {
                if !waitingForSpace.contains(item.id) {
                    floorBlocked.append(item.id)
                }
                continue
            }
            waitingForSpace.remove(item.id)
            startDownload(item, members: dataless, bytes: bytes, volume: volume)
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
        let remaining: [PendingTrashItem]
        do {
            remaining = try await pendingItems()
        } catch {
            logReadFailure(error, read: "publishState")
            scheduleWake(after: retryPolicy.delays.first ?? .seconds(15))
            return
        }
        if remaining.isEmpty {
            movedInRun = 0
        }
        let state = QueueState(
            pendingCount: remaining.count,
            movedCount: movedInRun,
            bytesToDownload: remaining.reduce(PartialByteCount.zero) { $0 + datalessBytes(of: $1.item) },
            attention: remaining.isEmpty ? nil : attention
        )
        guard state != lastState else { return }
        lastState = state
        eventContinuation.yield(.state(state))
    }

    private func pendingItems() async throws -> [PendingTrashItem] {
        try await reads.pendingItems()
    }

    private func logReadFailure(_ error: any Error, read: String) {
        OtosLog.catalog.errorOperation("mediaTrash.queue", phase: "readFailed", fields: [
            "read": read, "error": String(describing: error),
        ])
    }

    /// Un-hides items in the Store. A failure leaves them hidden and pending, which the
    /// caller reports as nothing restored, and lets the queue handle them again.
    private func clearPending(_ ids: [MediaAssetID], operation: String) async -> [MediaAssetID] {
        do {
            return try await store.clearPendingTrash(ids)
        } catch {
            logReadFailure(error, read: operation)
            revoked.subtract(ids)
            return []
        }
    }

    // MARK: - Downloads

    private func datalessMembers(of item: MediaTrashItem) -> [MediaTrashMember] {
        item.members.filter { status(url(of: $0, in: item)) == .dataless }
    }

    private func datalessBytes(of item: MediaTrashItem) -> PartialByteCount {
        PartialByteCount(sizes: datalessMembers(of: item).map(\.byteSize))
    }

    /// Admits a download of `bytes` into `root` against its volume's ledger and commits
    /// it, returning that volume; `nil` when the download would take it below the floor.
    private func admitDownload(_ bytes: Int64, root: LibraryRootPath) -> URL? {
        let volume = FreeSpaceFloor.volume(of: root.url)
        var ledger = ledgers[volume] ?? FreeSpaceLedger()
        guard ledger.admit(bytes, reported: volumeCapacity(root.url)) else {
            return nil
        }
        ledgers[volume] = ledger
        return volume
    }

    /// Settles a download's commitment with the bytes its members' downloads landed (none
    /// for a member already local), and drops the volume's ledger once nothing of Otos's is in
    /// flight there.
    private func settleCommitment(of id: MediaAssetID, landedBytes: Int64) {
        guard let commit = downloadCommits.removeValue(forKey: id) else { return }
        ledgers[commit.volume]?.settle(committed: commit.bytes, landed: min(landedBytes, commit.bytes))
        if !downloadCommits.values.contains(where: { $0.volume == commit.volume }) {
            ledgers[commit.volume] = nil
        }
    }

    /// Called only from a pass, synchronously after its shutdown check.
    private func startDownload(_ item: MediaTrashItem, members: [MediaTrashMember], bytes: Int64, volume: URL) {
        precondition(!isShuttingDown, "a download started after shutdown would outlive it")
        downloadCommits[item.id] = (volume, bytes)
        guard let materializationRequester else {
            settleCommitment(of: item.id, landedBytes: 0)
            OtosLog.catalog.errorOperation("mediaTrash.path", phase: "failed", fields: [
                "reason": "noMaterializer", "path": item.id.relativePath.rawValue,
            ])
            awaitingDecision.insert(item.id)
            eventContinuation.yield(.decision(.downloadFailed([item.id])))
            return
        }
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
            var landed: Int64 = 0
            for request in requests {
                let result = await materializationRequester.materialize(request)
                landed += result.outcome.landedBytes(of: request.sourceSize ?? 0)
                if !result.isMaterialized {
                    outcome = result.outcome
                    break
                }
            }
            await self?.finishDownload(id, outcome: outcome, landedBytes: landed)
        }
    }

    private func finishDownload(_ id: MediaAssetID, outcome: MaterializationOutcome, landedBytes: Int64) {
        downloads[id] = nil
        settleCommitment(of: id, landedBytes: landedBytes)
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
             .deviceUnavailable, .serverUnreachable:
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
        }
    }

    private func scheduleWake(after delay: Duration) {
        scheduleWake(at: clock.now.advanced(by: delay))
    }

    private func scheduleWake(at instant: ContinuousClock.Instant) {
        // Shutdown cancelled the timer it saw; a pass or answer finishing after it must not
        // arm another that nobody cancels.
        guard !isShuttingDown else { return }
        timerTask?.cancel()
        let clock = clock
        timerTask = Task { [weak self] in
            // time: backoff — a Move to Trash the system refused, or a download that failed
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
        // The user may have taken the item back while this pass waited for the lease.
        guard !revoked.contains(item.id) else {
            _ = await store.releaseNamespaceMutationLease(lease)
            return
        }
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
                let trashURL = try files.trash(memberURL)
                results.append(result(item, member, succeeded: true, trashURL: trashURL))
                moved.append(TrashedMember(member: member, trashURL: trashURL))
            } catch {
                results.append(result(item, member, succeeded: false))
                logFailure(error, operation: "trashItem", member: member)
            }
        }
        // The catalog follows the moves while the lease that covers them is still held,
        // so no scan or reconcile of this root can run between the two.
        await store.reconcileTrashedPaths(results.filter(\.succeeded), batch: batch)
        _ = await store.releaseNamespaceMutationLease(lease)
        await settleMove(
            TrashedItem(item: item, members: moved),
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
            _ = await clearPending([id], operation: "moveFailed")
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
                try files.remove(url(of: member, in: item))
                results.append(result(item, member, succeeded: true))
            } catch {
                results.append(result(item, member, succeeded: false))
                logFailure(error, operation: "removeItem", member: member)
            }
        }
        // Deleted, not in the Trash: no location is passed, so the rows leave the catalog.
        await store.reconcileTrashedPaths(results.filter(\.succeeded), batch: MediaTrashBatchID())
        _ = await store.releaseNamespaceMutationLease(lease)
        forget([item.id])
        if results.contains(where: { !$0.succeeded }) {
            _ = await clearPending([item.id], operation: "removeFailed")
            eventContinuation.yield(.moveFailed([item.id]))
            return false
        }
        return true
    }

    private func result(
        _ item: MediaTrashItem,
        _ member: MediaTrashMember,
        succeeded: Bool,
        trashURL: URL? = nil
    ) -> MediaTrashPathResult {
        MediaTrashPathResult(
            id: item.id,
            rootPath: item.root.path,
            relativePath: member.relativePath,
            role: member.role,
            succeeded: succeeded,
            trashURL: trashURL
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
        // If pending items cannot be listed, they are not claimed restored: they fall into
        // `failed` below, which is what the user is told — nothing was put back.
        var pendingIDs: Set<MediaAssetID> = []
        do {
            pendingIDs = try await Set(pendingItems().map(\.item.id)).intersection(ids)
        } catch {
            logReadFailure(error, read: "undoPending")
        }
        if !pendingIDs.isEmpty {
            awaitingDecision.subtract(pendingIDs)
            waitingForSpace.subtract(pendingIDs)
            revoked.formUnion(pendingIDs)
            for id in pendingIDs {
                downloads[id]?.cancel()
            }
            forget(pendingIDs)
            outcome.restored += await clearPending(Array(pendingIDs), operation: "undo")
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
                try files.putBack(trashURL, destination)
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
        guard primaryBack else {
            _ = await store.releaseNamespaceMutationLease(lease)
            return false
        }
        // Shown again under the same lease that put the files back; the row kept everything.
        let restored = await store.restoreTrashedItem(TrashedItem(item: item, members: returned))
        _ = await store.releaseNamespaceMutationLease(lease)
        if !restored {
            OtosLog.catalog.errorOperation("mediaTrash.undo", phase: "catalogRestoreFailed", fields: [
                "path": item.id.relativePath.rawValue,
            ])
        }
        return restored
    }

    private static func memberOrder(
        _ left: MediaTrashMember,
        _ right: MediaTrashMember
    ) -> Bool {
        // Members first and the primary last: an item whose primary failed to move is
        // still in the catalog to be retried, and undo puts the primary back first.
        switch (left.role == .primary, right.role == .primary) {
        case (false, true): true
        case (true, false): false
        default: left.relativePath.rawValue < right.relativePath.rawValue
        }
    }
}
