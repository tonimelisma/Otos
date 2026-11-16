import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// An account's sync stream as the catalog sync sees it. `ImmichSessionSyncSource` is
/// the server; a test scripts one.
nonisolated protocol ImmichSyncSource: Sendable {
    /// One pass of the stream: from the session's cursor, or, `fromZero`, from a cursor the
    /// server discards first, so it lists everything the account holds.
    func events(fromZero: Bool) async throws -> any AsyncSequence<ImmichSyncEvent, any Error>
    /// Moves the cursor past `acks`.
    func acknowledge(_ acks: [String]) async throws
    /// The server's own preview of an asset.
    func preview(assetID: String) async throws -> Data
    /// One asset's own facts, for a Live Photo's motion part not in this pass's stream.
    func asset(id: String) async throws -> ImmichAssetDetail
}

/// The server, through one logged-in session.
nonisolated struct ImmichSessionSyncSource: ImmichSyncSource {
    let client: ImmichClient
    let token: String

    func events(fromZero: Bool) async throws -> any AsyncSequence<ImmichSyncEvent, any Error> {
        try await client.syncEvents(token: token, fromZero: fromZero)
    }

    func acknowledge(_ acks: [String]) async throws {
        try await client.acknowledge(acks, token: token)
    }

    func preview(assetID: String) async throws -> Data {
        try await client.preview(assetID: assetID, token: token)
    }

    func asset(id: String) async throws -> ImmichAssetDetail {
        try await client.asset(id: id, token: token)
    }
}

/// What a pass reports to its account's owner as it goes, in this order: its server
/// answered (once, as soon as its first batch is applied and acknowledged), its listing was
/// applied to the stream's end (before the server's images are fetched, which on a first
/// sync takes far longer), and its outcome.
nonisolated enum ImmichSyncReport: Equatable, Sendable {
    case answered
    case listed
    case ended(ImmichSyncPassOutcome)
}

/// What one sync pass did.
nonisolated enum ImmichSyncPassOutcome: Equatable, Sendable {
    /// The stream was applied to its end (`SyncCompleteV1`). `full` is a resync the account
    /// owed, read from zero, whose completion proved every unlisted row deleted.
    case synced(listed: Int, deleted: Int, full: Bool)
    /// The server could not be read; nothing past the last applied batch was acknowledged,
    /// so the next pass replays it.
    case serverFailed(ImmichClientError)
    /// The Store could not apply a batch; it was not acknowledged.
    case catalogFailed
    /// The server reset the cursor again during the resync its first reset started.
    case resetLoop
    /// The root could not get or keep a listing lease: it was not available, or another
    /// owner took its listing. Nothing says when it can again, so the pass is retried.
    case noLease
    /// The pass's loop was cancelled: it is being torn down, and no pass follows.
    case stopped
}

/// Immich catalog sync guide
///
/// One owner per account keeps its root in step with its server's sync stream (ADR 0046
/// §5), the counterpart of `CameraCatalogSync`. A pass reads the stream from the
/// session's cursor and applies it to the Store in batches under a listing lease; each
/// batch's lines are acknowledged only after the Store has applied it, so a crash or a
/// dropped connection replays a batch rather than losing one.
///
/// What a line means for the catalog:
/// - an image or video asset in the timeline or the archive is a row at
///   `<asset id>/<original file name>`;
/// - one in Immich's trash is the same row, hidden by its source, with its overlay kept;
/// - one in the locked folder is never synced: a row it had is purged;
/// - a Live Photo's motion part (`hidden`) is a row in its still's folder, listed with the
///   still that links it and named by its own asset ID; a row the video had in a folder of
///   its own, before it was a motion part, goes;
/// - `AssetDeleteV1` purges the asset's rows: proof of deletion;
/// - `SyncResetV1` means the server lost this cursor's history: a full resync is recorded
///   as owed in the catalog before the reset is acknowledged (as it is when a new session
///   begins, `ImmichAccounts`). While one is owed, every pass asks the server to discard
///   the cursor (`reset: true`) and reads the stream from zero, so a resync that dropped
///   after acknowledging some batches is never resumed from them. The pass that reaches the
///   end purges every row it did not list and settles the debt in one Store transaction.
///
/// `run()` is the one loop, woken by `requestSync()` (a newest-wins doorbell, ADR 0032):
/// passes never overlap, and a request during a pass is one more pass.
actor ImmichCatalogSync {
    /// Lines applied per Store transaction, and acknowledged together after it.
    static let batchSize = 500

    let rootPath: LibraryRootPath
    private let source: any ImmichSyncSource
    private let store: CatalogStore
    /// Reads a volume's free space for the floor its products keep (ADR 0027).
    private let volumeCapacity: VolumeCapacityReader
    /// Runs the mirror pairing's write walk one heavy load at a time with the other owners'.
    private let admission: LoadAdmission
    private let doorbell: AsyncStream<Void>
    private let ring: AsyncStream<Void>.Continuation

    init(
        rootPath: LibraryRootPath,
        source: any ImmichSyncSource,
        store: CatalogStore,
        volumeCapacity: @escaping VolumeCapacityReader,
        admission: LoadAdmission = LoadAdmission(isOpen: true)
    ) {
        self.admission = admission
        self.rootPath = rootPath
        self.source = source
        self.store = store
        self.volumeCapacity = volumeCapacity
        (doorbell, ring) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Asks for a pass. A request made while one runs is one more pass after it.
    nonisolated func requestSync() {
        ring.yield()
    }

    /// Ends the loop after its current pass.
    nonisolated func finish() {
        ring.finish()
    }

    /// The loop: one pass per doorbell ring, until `finish()` or cancellation. `onReport`
    /// hears each pass's reports (`ImmichSyncReport`), its outcome last, before the next ring
    /// is read. A first sync of a large library takes minutes to list and hours to fetch its
    /// images, and its server has answered long before it ends.
    func run(onReport: @escaping @Sendable (ImmichSyncReport) async -> Void = { _ in }) async {
        for await _ in doorbell {
            guard !Task.isCancelled else {
                return
            }
            await onReport(.ended(pass(onReport: onReport)))
        }
    }

    /// One pass: the stream applied to its end, then the server's own images fetched for
    /// every row still owed them (ADR 0046 §7). The pass's outcome is the stream's; a
    /// product that could not be fetched stays owed and is asked for again next pass, and
    /// one the server says it does not have is not.
    /// `onReport` hears `answered` and `listed`; the caller reports the outcome.
    func pass(onReport: @escaping @Sendable (ImmichSyncReport) async -> Void = { _ in }) async -> ImmichSyncPassOutcome {
        var answered = Answered(report: { await onReport(.answered) })
        let outcome = await syncListing(answered: &answered)
        if case .synced = outcome {
            await onReport(.listed)
            await pairMirrors()
            _ = await fetchProducts()
        }
        return outcome
    }

    // MARK: - Mirrors (ADR 0054)

    /// Learns where the server holds each library it mirrors, then gives every mirrored
    /// asset its library file's digest. It runs once the stream is applied, so every asset
    /// the pass listed is there to pair. A read that fails pairs nothing new, is logged, and
    /// is asked again next pass.
    private func pairMirrors() async {
        let probes: [MirrorGateway.Probe]
        do {
            probes = try await store.mirrorProbes(account: rootPath)
        } catch {
            OtosLog.catalog.errorOperation("immich.mirror", phase: "probeFailed", fields: [
                "rootPath": rootPath.rawValue, "error": String(describing: error),
            ])
            return
        }
        for probe in probes {
            await learnMirror(probe)
        }
        do {
            // A write walk over every mirrored library: one heavy load at a time.
            _ = try await admission.run(.immichMirror) {
                try await store.pairMirroredCopies(account: rootPath)
            }
        } catch is CancellationError {
            return
        } catch {
            OtosLog.catalog.errorOperation("immich.mirror", phase: "pairFailed", fields: [
                "rootPath": rootPath.rawValue, "error": String(describing: error),
            ])
        }
    }

    /// A library's mirror: kept while one of its files still names its asset under the
    /// prefix, else learned from the server's path of a candidate asset, which its own
    /// checksum must confirm. A same-named file from another folder confirms nothing, and the
    /// next candidate is asked.
    private func learnMirror(_ probe: MirrorGateway.Probe) async {
        let fields = ["accountRootPath": rootPath.rawValue, "libraryRootPath": probe.libraryRootPath.rawValue]
        if let prefix = probe.serverPrefix, probe.candidates.contains(where: {
            ImmichPathChecksum(serverPath: prefix + $0.relativePath.rawValue) == $0.pathChecksum
        }) {
            OtosLog.catalog.noticeOperation("immich.mirror", phase: "kept", fields: fields)
            return
        }
        for candidate in probe.candidates {
            let detail: ImmichAssetDetail
            do {
                detail = try await source.asset(id: candidate.assetID)
            } catch {
                OtosLog.catalog.errorOperation("immich.mirror", phase: "pathReadFailed", fields: fields.merging([
                    "assetID": candidate.assetID, "error": String(describing: error),
                ]) { current, _ in current })
                return
            }
            guard let originalPath = detail.originalPath,
                  let prefix = MirrorGateway.serverPrefix(of: originalPath, relativePath: candidate.relativePath),
                  ImmichPathChecksum(serverPath: prefix + candidate.relativePath.rawValue) == candidate.pathChecksum
            else {
                continue
            }
            do {
                try await store.recordMirror(account: rootPath, library: probe.libraryRootPath, serverPrefix: prefix)
            } catch {
                OtosLog.catalog.errorOperation("immich.mirror", phase: "recordFailed", fields: fields.merging([
                    "error": String(describing: error),
                ]) { current, _ in current })
            }
            return
        }
        OtosLog.catalog.noticeOperation("immich.mirror", phase: "notMirrored", fields: fields.merging([
            "candidates": "\(probe.candidates.count)", "known": "\(probe.serverPrefix != nil)",
        ]) { current, _ in current })
    }

    /// The stream applied to its end: from zero while a resync is owed, else from the
    /// cursor, which a reset the server sends turns into one resync from zero.
    private func syncListing(answered: inout Answered) async -> ImmichSyncPassOutcome {
        let owed: SourceResyncDebt?
        do {
            owed = try await store.sourceResyncOwed(rootPath: rootPath)
        } catch {
            OtosLog.catalog.errorOperation("catalog.immich.sync", phase: "resyncReadFailed", fields: [
                "rootPath": rootPath.rawValue, "error": String(describing: error),
            ])
            return .catalogFailed
        }
        switch await stream(resyncing: owed, answered: &answered) {
        case let .done(outcome):
            return outcome
        case let .resetRequested(debt):
            // The server's reset is acknowledged, so the cursor is gone already; a resync
            // that was owed and asked for `reset: true` is never answered with one.
            guard owed == nil else {
                return resetLoop()
            }
            switch await stream(resyncing: debt, answered: &answered) {
            case let .done(outcome):
                return outcome
            case .resetRequested:
                return resetLoop()
            }
        }
    }

    private func resetLoop() -> ImmichSyncPassOutcome {
        OtosLog.catalog.errorOperation("catalog.immich.sync", phase: "resetLoop", fields: [
            "rootPath": rootPath.rawValue,
        ])
        return .resetLoop
    }

    private enum StreamResult {
        case done(ImmichSyncPassOutcome)
        /// The server reset the cursor; the resync it owes is recorded and the reset
        /// acknowledged.
        case resetRequested(SourceResyncDebt)
    }

    /// One stream under one listing lease. `resyncing` reads it from zero, and its end
    /// purges every row it did not list and settles that debt.
    private func stream(resyncing debt: SourceResyncDebt?, answered: inout Answered) async -> StreamResult {
        let scan: CatalogStore.ActiveScan
        do {
            scan = try await store.beginSourceListing(rootPath: rootPath)
        } catch {
            let outcome: ImmichSyncPassOutcome = Task.isCancelled ? .stopped : .noLease
            OtosLog.catalog.noticeOperation("catalog.immich.sync", phase: "noLease", fields: [
                "rootPath": rootPath.rawValue, "outcome": String(describing: outcome),
            ])
            return .done(outcome)
        }
        var tally = Tally()
        do {
            if let reset = try await read(fromZero: debt != nil, scan: scan, into: &tally, answered: &answered) {
                await store.endSourceListing(scan: scan)
                OtosLog.catalog.noticeOperation("catalog.immich.sync", phase: "reset", fields: [
                    "rootPath": rootPath.rawValue, "revision": "\(reset.revision)",
                ])
                return .resetRequested(reset)
            }
            if let debt, tally.completed {
                try await store.completeSourceResync(scan: scan, observedPaths: tally.observed, settling: debt)
            } else {
                await store.endSourceListing(scan: scan)
            }
        } catch {
            await store.endSourceListing(scan: scan)
            let outcome = Self.outcome(of: error)
            OtosLog.catalog.noticeOperation("catalog.immich.sync", phase: "failed", fields: [
                "rootPath": rootPath.rawValue,
                "outcome": String(describing: outcome),
                "error": String(describing: error),
            ])
            return .done(outcome)
        }
        OtosLog.catalog.noticeOperation("catalog.immich.sync", phase: "pass", fields: [
            "rootPath": rootPath.rawValue,
            "listed": "\(tally.observed.count)",
            "deleted": "\(tally.deleted)",
            "full": "\(debt != nil)",
            "completed": "\(tally.completed)",
        ])
        // A stream that ended before `SyncCompleteV1` was cut short: what it applied stays
        // applied and acknowledged, but the catalog is not current with the server.
        guard tally.completed else {
            return .done(.serverFailed(.malformedResponse))
        }
        return .done(.synced(listed: tally.observed.count, deleted: tally.deleted, full: debt != nil))
    }

    /// What a stream's applied batches established.
    private struct Tally {
        var observed: Set<MediaRelativePath> = []
        var deleted = 0
        var completed = false
    }

    /// Reads one stream to its end, applying it batch by batch. The resync the server owes
    /// when it reset the cursor: it is recorded as owed, then the reset is acknowledged, and
    /// nothing of the stream is applied after it. Nil when the stream had no reset.
    private func read(
        fromZero: Bool,
        scan: CatalogStore.ActiveScan,
        into tally: inout Tally,
        answered: inout Answered
    ) async throws -> SourceResyncDebt? {
        var batch = Batch()
        var pass = PassMemory()
        for try await event in try await source.events(fromZero: fromZero) {
            switch event {
            case let .reset(ack):
                guard let debt = try await store.requestSourceResync(rootPath: rootPath) else {
                    // The root is gone from the catalog: nothing is left to resync.
                    throw CancellationError()
                }
                try await source.acknowledge([ack])
                return debt
            case .complete:
                batch.add(event)
                tally.completed = true
            default:
                batch.add(event)
            }
            if batch.lineCount >= Self.batchSize {
                try await apply(&batch, pass: &pass, scan: scan, into: &tally)
                await answered.reportOnce()
            }
        }
        try await apply(&batch, pass: &pass, scan: scan, into: &tally)
        await answered.reportOnce()
        return nil
    }

    /// A pass's one report that its server answered: its stream was read and a batch of it
    /// applied and acknowledged.
    private struct Answered {
        let report: @Sendable () async -> Void
        private var reported = false

        init(report: @escaping @Sendable () async -> Void) {
            self.report = report
        }

        mutating func reportOnce() async {
            guard !reported else {
                return
            }
            reported = true
            await report()
        }
    }

    /// Applies the batch to the Store, then acknowledges its lines, then empties it. A
    /// still that links a motion part lists it in the still's folder, from the motion's
    /// own line in this pass, or else from the server (ADR 0046 §2). A motion part the
    /// server refuses to describe leaves its still listed alone, so one asset never holds
    /// back every pass.
    private func apply(
        _ batch: inout Batch,
        pass: inout PassMemory,
        scan: CatalogStore.ActiveScan,
        into tally: inout Tally
    ) async throws {
        pass.remember(batch)
        var motions: [String: ImmichAssetDetail] = [:]
        for motionID in batch.linkedMotions.sorted() {
            if let known = pass.motionDetail(motionID) {
                motions[motionID] = known
                continue
            }
            do {
                motions[motionID] = try await source.asset(id: motionID)
            } catch let ImmichClientError.refused(status) where status == 400 || status == 404 {
                // The server will not give this asset (Immich answers 400 for an asset the
                // session cannot read): the still is listed without it, and its next line
                // asks again.
                OtosLog.catalog.noticeOperation("catalog.immich.sync", phase: "motionRefused", fields: [
                    "rootPath": rootPath.rawValue, "assetID": motionID, "status": "\(status)",
                ])
            }
        }
        // A motion part's own line without its still in the batch refreshes the row it
        // already has in its still's folder, hidden as its still is. One the catalog does
        // not hold there yet is listed when its still is.
        let alone = Set(batch.motionLines.keys).subtracting(batch.linkedMotions)
        let existing = try await store.sourceItemRows(alone, in: rootPath)
        let changes = batch.changes(motions: motions, existingMotions: existing)
        if !changes.isEmpty {
            try await store.applySourceListingChanges(changes, scan: scan)
        }
        try await source.acknowledge(batch.acks)
        tally.observed.formUnion(changes.listed.map(\.file.relativePath))
        tally.deleted += changes.deletedSourceItems.count
        batch = Batch()
    }

    /// A server failure is reported as the server's; anything else the Store refused. A
    /// cancellation is the loop's teardown only when its task was cancelled: the Store
    /// refuses a lease the root can no longer keep with one too.
    private static func outcome(of error: any Error) -> ImmichSyncPassOutcome {
        switch error {
        case let error as ImmichClientError: .serverFailed(error)
        case let error as URLError: .serverFailed(.unreachable(error.code))
        case is CancellationError: Task.isCancelled ? .stopped : .noLease
        default: .catalogFailed
        }
    }

    /// What a pass has read of motion parts and sizes across its batches, so a still in
    /// a later batch than its motion's own lines lists the motion without asking the
    /// server again.
    private struct PassMemory {
        private var motionLines: [String: ImmichAsset] = [:]
        private var sizes: [String: Int64] = [:]

        mutating func remember(_ batch: Batch) {
            motionLines.merge(batch.motionLines) { _, newer in newer }
            sizes.merge(batch.sizes) { _, newer in newer }
        }

        /// The motion part's facts from its own line in this pass, with its size when that
        /// is here too; a size reported later reaches its row by its ID.
        func motionDetail(_ id: String) -> ImmichAssetDetail? {
            guard let line = motionLines[id], let created = line.fileCreatedAt, let modified = line.fileModifiedAt
            else {
                return nil
            }
            return ImmichAssetDetail(
                id: id, originalFileName: line.originalFileName, type: line.type,
                fileCreatedAt: created, fileModifiedAt: modified, fileSize: sizes[id],
                hasPreview: line.hasPreview, contentDigest: line.contentDigest, pathChecksum: line.pathChecksum
            )
        }
    }

    /// Lines read since the last apply, folded per asset: the newest line about an asset
    /// decides what it is, and an asset's size joins its row when both are in the batch.
    private struct Batch {
        /// Assets listed in a folder of their own: a still, or a video that is no motion part.
        private var listedByAsset: [String: ImmichAsset] = [:]
        /// Live Photo motion parts' own lines (`hidden`), by the motion's ID.
        private(set) var motionLines: [String: ImmichAsset] = [:]
        private(set) var sizes: [String: Int64] = [:]
        private var deletedAssets: Set<String> = []
        /// The newest ack of each line type: the cursor moves per type.
        private var acksByType: [String: String] = [:]
        private(set) var lineCount = 0

        var acks: [String] {
            acksByType.keys.sorted().compactMap { acksByType[$0] }
        }

        /// The motion parts the batch's stills link.
        var linkedMotions: Set<String> {
            Set(listedByAsset.values.compactMap(\.livePhotoVideoID))
        }

        /// The batch as catalog changes. Each listed still's folder is listed in full: the
        /// still, and the motion part it links (from `motions`), under its own name and ID.
        /// A still whose motion part the server would not describe is listed alone, its folder
        /// not in full, so the motion's row there keeps its overlay. A motion part's own
        /// folder is listed empty: a row the video had there, before it was a motion part,
        /// goes, and its row in its still's folder is the one that stays.
        func changes(
            motions: [String: ImmichAssetDetail],
            existingMotions: [String: SourceItemRow]
        ) -> SourceListingChanges {
            var listed: [SourceListedItem] = []
            var joined: Set<String> = []
            var completeFolders = Set(motionLines.keys)
            for id in existingMotions.keys.sorted() {
                // Only a row in its still's folder is refreshed in place; one in the motion's
                // own folder is the stray standalone row this batch removes.
                guard let row = existingMotions[id], let line = motionLines[id],
                      !row.relativePath.rawValue.hasPrefix("\(id)/")
                else {
                    continue
                }
                listed.append(ImmichCatalogSync.refreshedItem(line, at: row, size: sizes[id]))
                joined.insert(id)
            }
            for id in listedByAsset.keys.sorted() {
                guard let asset = listedByAsset[id] else {
                    continue
                }
                listed.append(ImmichCatalogSync.listedItem(for: asset, size: sizes[id]))
                joined.insert(id)
                guard let motionID = asset.livePhotoVideoID else {
                    completeFolders.insert(id)
                    continue
                }
                if let motion = motions[motionID] {
                    listed.append(ImmichCatalogSync.motionItem(
                        motion, in: asset, size: sizes[motionID] ?? motion.fileSize
                    ))
                    joined.insert(motionID)
                    completeFolders.insert(id)
                }
            }
            return SourceListingChanges(
                listed: listed,
                completeFolders: completeFolders.sorted(),
                sizesBySourceItem: sizes.filter { !joined.contains($0.key) },
                deletedSourceItems: deletedAssets.sorted()
            )
        }

        /// Folds one line in; its ack moves its type's cursor when the batch is applied.
        mutating func add(_ event: ImmichSyncEvent) {
            acksByType[event.lineType] = event.ack
            lineCount += 1
            switch event {
            case let .asset(asset, _):
                listAsset(asset)
            case let .assetDeleted(assetID, _):
                listedByAsset[assetID] = nil
                motionLines[assetID] = nil
                deletedAssets.insert(assetID)
            case let .exif(assetID, fileSize, _):
                if let fileSize {
                    sizes[assetID] = fileSize
                }
            case .reset, .complete, .ignored:
                // Nothing in the catalog: only the cursor moves.
                break
            }
        }

        private mutating func listAsset(_ asset: ImmichAsset) {
            switch (asset.type, asset.visibility) {
            case (.image, .locked), (.video, .locked):
                // The locked folder is never synced: a row an earlier pass made goes, and
                // with a still, its motion part.
                listedByAsset[asset.id] = nil
                motionLines[asset.id] = nil
                deletedAssets.insert(asset.id)
            case (.image, .timeline), (.image, .archive), (.video, .timeline), (.video, .archive):
                deletedAssets.remove(asset.id)
                listedByAsset[asset.id] = asset
                motionLines[asset.id] = nil
            case (.video, .hidden):
                // A Live Photo's motion part: listed in its still's folder when the still
                // is listed (ADR 0046 §2), never in a folder of its own, even one an earlier
                // line of this batch gave it.
                listedByAsset[asset.id] = nil
                motionLines[asset.id] = asset
            case (.image, .hidden), (.audio, _), (.other, _):
                // Only a motion part is hidden; audio and other types are never Otos
                // media (product rule).
                break
            }
        }
    }

    // MARK: - Source products (ADR 0046 §7)

    /// What a product pass did.
    enum ProductPassOutcome: Equatable, Sendable {
        /// Every owed row was tried; `made` got images, `unreadable` did not decode.
        case finished(made: Int, unreadable: Int)
        /// The server stopped answering; the rest stay owed.
        case serverFailed(made: Int)
        /// The images' volume is at its free-space floor (ADR 0027); the rest stay owed.
        case floorHeld(made: Int)
        /// The Store could not read the rows owed images or write a page of them; the
        /// rest stay owed.
        case catalogFailed(made: Int)
    }

    /// Rows read from the Store per page.
    static let productPageSize = 64

    /// Fetches Immich's preview for every row owed the server's own images and writes
    /// Otos's two products from it, unstamped as a rendering (ADR 0035): the preview at
    /// the server's size, for a still, and the grid thumbnail drawn from it. One request
    /// per asset; Immich's separate thumbnail is never needed.
    func fetchProducts() async -> ProductPassOutcome {
        guard let directory = store.thumbnailDirectory else {
            return .finished(made: 0, unreadable: 0)
        }
        var tally = ProductTally()
        var cursor: MediaRelativePath?
        while true {
            let page: [SourceProductCandidate]
            do {
                page = try await store.sourceProductCandidates(
                    rootPath: rootPath, after: cursor, limit: Self.productPageSize
                )
            } catch {
                OtosLog.thumbnails.errorOperation("immich.products", phase: "readFailed", fields: [
                    "rootPath": rootPath.rawValue, "made": "\(tally.made)", "error": String(describing: error),
                ])
                return .catalogFailed(made: tally.made)
            }
            guard let last = page.last else {
                break
            }
            cursor = last.id.relativePath
            if let stop = await fetch(page, into: directory, tally: &tally) {
                return stop
            }
        }
        OtosLog.thumbnails.noticeOperation("immich.products", phase: "finished", fields: [
            "rootPath": rootPath.rawValue, "made": "\(tally.made)", "unreadable": "\(tally.unreadable)",
            "refused": "\(tally.refused)",
        ])
        return .finished(made: tally.made, unreadable: tally.unreadable)
    }

    private struct ProductTally {
        /// Rows whose images the Store stored.
        var made = 0
        var unreadable = 0
        /// Assets whose preview the server answered it does not have.
        var refused = 0
    }

    /// What one page fetched, kept until it is applied.
    private struct ProductPage {
        var results: [EnrichmentResult] = []
        /// Rows the server answered it has no preview of.
        var absent: [MediaRelativePath] = []
    }

    /// One page of owed rows: each preview fetched and staged, then the page applied in
    /// one batch. A stop — the floor, or the server not answering — applies what was
    /// fetched and ends the pass.
    private func fetch(
        _ candidates: [SourceProductCandidate],
        into directory: URL,
        tally: inout ProductTally
    ) async -> ProductPassOutcome? {
        var page = ProductPage()
        // The volume's figure is read once a page and each image counted against it through a
        // ledger (ADR 0027): the figure is CacheDelete's, about 15 ms of CPU a read, and a read
        // an image was one a megabyte.
        var ledger = FreeSpaceLedger()
        var reported = await Self.reportedCapacity(of: directory, volumeCapacity)
        for candidate in candidates {
            defer { reported = nil }
            guard ledger.admit(Self.productBytes, reported: reported) else {
                if let failed = await applyProducts(page, tally: &tally) {
                    return failed
                }
                OtosLog.thumbnails.noticeOperation("immich.products", phase: "floorHeld", fields: [
                    "rootPath": rootPath.rawValue, "made": "\(tally.made)",
                ])
                return .floorHeld(made: tally.made)
            }
            let data: Data
            do {
                data = try await source.preview(assetID: candidate.sourceItemID)
            } catch ImmichClientError.refused(status: 404) {
                // The server answered that it has no preview of this asset: recorded, so no
                // pass asks again until a listing says the server has made one, and the
                // rest are still fetched. Any other refusal (a 5xx, a 429) is the server
                // failing now, not an answer about the asset, and ends the pass below.
                page.absent.append(candidate.id.relativePath)
                tally.refused += 1
                OtosLog.thumbnails.noticeOperation("immich.products", phase: "refused", fields: [
                    "relativePath": candidate.id.relativePath.rawValue, "status": "404",
                ])
                continue
            } catch {
                if let failed = await applyProducts(page, tally: &tally) {
                    return failed
                }
                OtosLog.thumbnails.noticeOperation("immich.products", phase: "serverFailed", fields: [
                    "rootPath": rootPath.rawValue, "made": "\(tally.made)", "error": String(describing: error),
                ])
                return .serverFailed(made: tally.made)
            }
            if let result = await Self.products(from: data, for: candidate, in: directory) {
                page.results.append(result)
            } else {
                tally.unreadable += 1
            }
        }
        return await applyProducts(page, tally: &tally)
    }

    /// Applies a page's images and records the rows the server has none of. Nil when both
    /// were written; a failed write is logged and ends the pass, its rows still owed.
    private func applyProducts(_ page: ProductPage, tally: inout ProductTally) async -> ProductPassOutcome? {
        if !page.results.isEmpty {
            switch await store.applyEnrichmentBatch(page.results) {
            case let .applied(count):
                tally.made += count
            case .writeFailed:
                OtosLog.thumbnails.errorOperation("immich.products", phase: "writeFailed", fields: [
                    "rootPath": rootPath.rawValue, "count": "\(page.results.count)",
                ])
                return .catalogFailed(made: tally.made)
            }
        }
        do {
            try await store.recordSourceProductsAbsent(page.absent, rootPath: rootPath)
        } catch {
            OtosLog.thumbnails.errorOperation("immich.products", phase: "absentWriteFailed", fields: [
                "rootPath": rootPath.rawValue, "count": "\(page.absent.count)", "error": String(describing: error),
            ])
            return .catalogFailed(made: tally.made)
        }
        return nil
    }

    /// What one asset's images are counted as against the free-space floor every background
    /// download keeps (ADR 0027).
    private static let productBytes: Int64 = 1_000_000

    /// The images' volume's free space, read off the actor: CacheDelete answers it over XPC.
    @concurrent
    private static func reportedCapacity(of directory: URL, _ volumeCapacity: VolumeCapacityReader) async -> Int64? {
        volumeCapacity(directory)
    }

    /// Decodes the server's preview and stages Otos's products from it, off the actor: a
    /// still gets the preview at the server's size and the thumbnail drawn from it; a
    /// video, whose preview is one frame, gets only the thumbnail (ADR 0035: videos have no
    /// stored preview). Nil, logged, when the data is no image.
    @concurrent
    static func products(
        from data: Data,
        for candidate: SourceProductCandidate,
        in directory: URL
    ) async -> EnrichmentResult? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            OtosLog.thumbnails.noticeOperation("immich.products", phase: "unreadable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "bytes": "\(data.count)",
            ])
            return nil
        }
        do {
            let preview = candidate.kind == .video ? nil : try ThumbnailStore.stagePreview(
                image, finalRelativeName: ThumbnailStore.previewRelativeName(for: candidate.id), in: directory
            )
            let thumbnail = try ThumbnailStore.stage(
                ThumbnailStore.scaled(image, toLongEdge: ThumbnailStore.maxPixelSize),
                finalRelativeName: ThumbnailStore.relativeName(for: candidate.id),
                in: directory
            )
            return EnrichmentResult(
                id: candidate.id,
                metadata: nil,
                rendering: EnrichedRendering(generatedThumbnail: thumbnail, generatedPreview: preview, origin: .source),
                sourceSize: candidate.byteSize,
                sourceMTimeSeconds: candidate.contentModifiedAtSeconds,
                contentHash: nil
            )
        } catch {
            OtosLog.thumbnails.errorOperation("immich.products", phase: "stageFailed", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    /// The row an asset is: `<asset id>/<original file name>` (ADR 0046 §2), so the folder
    /// is Immich's own name for it and the file name keeps export and drag naming right.
    static func listedItem(for asset: ImmichAsset, size: Int64?) -> SourceListedItem {
        let name = fileName(asset.originalFileName, fallback: asset.id)
        return SourceListedItem(
            file: ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: "\(asset.id)/\(name)"),
                name: name,
                contentTypeIdentifier: UTType(filenameExtension: (name as NSString).pathExtension)?.identifier,
                byteSize: size,
                createdAt: asset.fileCreatedAt,
                contentModifiedAt: asset.fileModifiedAt
            ),
            sourceItemID: asset.id,
            isHiddenBySource: asset.deletedAt != nil,
            sourceHasProducts: asset.hasPreview,
            sourceDigest: asset.contentDigest,
            sourcePathChecksum: asset.pathChecksum
        )
    }

    /// A Live Photo's motion part: `<still id>/<motion original file name>` (ADR 0046 §2),
    /// in its still's folder so the pairing rule (ADR 0041) pairs them, named by its own
    /// asset ID, and hidden with its still.
    static func motionItem(_ motion: ImmichAssetDetail, in still: ImmichAsset, size: Int64?) -> SourceListedItem {
        let name = fileName(motion.originalFileName, fallback: motion.id)
        return SourceListedItem(
            file: ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: "\(still.id)/\(name)"),
                name: name,
                contentTypeIdentifier: UTType(filenameExtension: (name as NSString).pathExtension)?.identifier,
                byteSize: size,
                createdAt: motion.fileCreatedAt,
                contentModifiedAt: motion.fileModifiedAt
            ),
            sourceItemID: motion.id,
            isHiddenBySource: still.deletedAt != nil,
            sourceHasProducts: motion.hasPreview,
            sourceDigest: motion.contentDigest,
            sourcePathChecksum: motion.pathChecksum
        )
    }

    /// A row the catalog already holds, refreshed from its asset's own line where it lives:
    /// a motion part whose line came without its still's. It keeps its name and its source's
    /// hidden state, which its still's line decides.
    static func refreshedItem(_ asset: ImmichAsset, at row: SourceItemRow, size: Int64?) -> SourceListedItem {
        let name = row.relativePath.fileName
        return SourceListedItem(
            file: ScannedMediaFile(
                relativePath: row.relativePath,
                name: name,
                contentTypeIdentifier: UTType(filenameExtension: (name as NSString).pathExtension)?.identifier,
                byteSize: size,
                createdAt: asset.fileCreatedAt,
                contentModifiedAt: asset.fileModifiedAt
            ),
            sourceItemID: asset.id,
            isHiddenBySource: row.isHiddenBySource,
            sourceHasProducts: asset.hasPreview,
            sourceDigest: asset.contentDigest,
            sourcePathChecksum: asset.pathChecksum
        )
    }

    /// A file name that is one path component.
    static func fileName(_ original: String, fallback: String) -> String {
        let component = original.replacingOccurrences(of: "/", with: ":")
        return component.isEmpty || component == "." || component == ".." ? fallback : component
    }
}
