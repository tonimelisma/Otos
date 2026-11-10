import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// An account's sync stream as the catalog sync sees it. `ImmichSessionSyncSource` is
/// the server; a test scripts one.
nonisolated protocol ImmichSyncSource: Sendable {
    /// One pass of the stream, from the session's cursor.
    func events() async throws -> any AsyncSequence<ImmichSyncEvent, any Error>
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

    func events() async throws -> any AsyncSequence<ImmichSyncEvent, any Error> {
        try await client.syncEvents(token: token)
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

/// What one sync pass did.
nonisolated enum ImmichSyncPassOutcome: Equatable, Sendable {
    /// The stream was applied to its end. `full` is a resync after the server reset the
    /// cursor, whose completion proved every unlisted row deleted.
    case synced(listed: Int, deleted: Int, full: Bool)
    /// The server could not be read; nothing past the last applied batch was acknowledged,
    /// so the next pass replays it.
    case serverFailed(ImmichClientError)
    /// The Store could not apply a batch; it was not acknowledged.
    case catalogFailed
    /// The server reset the cursor again during the resync its first reset started.
    case resetLoop
    /// The account's root could not take a listing lease (it is being removed).
    case noLease
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
///   still that links it and named by its own asset ID;
/// - `AssetDeleteV1` purges the asset's rows: proof of deletion;
/// - `SyncResetV1` means the server lost this cursor's history: the reset is acknowledged
///   and the stream read again in full, and its completion purges every row it no longer
///   lists.
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
    private let doorbell: AsyncStream<Void>
    private let ring: AsyncStream<Void>.Continuation

    init(
        rootPath: LibraryRootPath,
        source: any ImmichSyncSource,
        store: CatalogStore,
        volumeCapacity: @escaping VolumeCapacityReader
    ) {
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

    /// The loop: one pass per doorbell ring, until `finish()` or cancellation. `onPass`
    /// hears each pass's outcome before the next ring is read.
    func run(onPass: @Sendable (ImmichSyncPassOutcome) async -> Void = { _ in }) async {
        for await _ in doorbell {
            guard !Task.isCancelled else {
                return
            }
            await onPass(pass())
        }
    }

    /// One pass: the stream applied to its end, then the server's own images fetched for
    /// every row still owed them (ADR 0046 §7). The pass's outcome is the stream's; a
    /// product that could not be fetched stays owed and is asked for again next pass.
    func pass() async -> ImmichSyncPassOutcome {
        let outcome = await syncListing()
        if case .synced = outcome {
            _ = await fetchProducts()
        }
        return outcome
    }

    /// The stream applied to its end. A reset turns it into one full resync.
    private func syncListing() async -> ImmichSyncPassOutcome {
        switch await stream(full: false) {
        case let .done(outcome):
            return outcome
        case .resetRequested:
            switch await stream(full: true) {
            case let .done(outcome):
                return outcome
            case .resetRequested:
                OtosLog.catalog.errorOperation("catalog.immich.sync", phase: "resetLoop", fields: [
                    "rootPath": rootPath.rawValue,
                ])
                return .resetLoop
            }
        }
    }

    private enum StreamResult {
        case done(ImmichSyncPassOutcome)
        case resetRequested
    }

    private func stream(full: Bool) async -> StreamResult {
        let scan: CatalogStore.ActiveScan
        do {
            scan = try await store.beginSourceListing(rootPath: rootPath)
        } catch {
            OtosLog.catalog.noticeOperation("catalog.immich.sync", phase: "noLease", fields: [
                "rootPath": rootPath.rawValue,
            ])
            return .done(.noLease)
        }
        var tally = Tally()
        do {
            if try await read(scan: scan, into: &tally) {
                await store.endSourceListing(scan: scan)
                OtosLog.catalog.noticeOperation("catalog.immich.sync", phase: "reset", fields: [
                    "rootPath": rootPath.rawValue,
                ])
                return .resetRequested
            }
            if full, tally.completed {
                try await store.completeSourceListing(scan: scan, observedPaths: tally.observed)
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
            "full": "\(full)",
            "completed": "\(tally.completed)",
        ])
        return .done(.synced(listed: tally.observed.count, deleted: tally.deleted, full: full))
    }

    /// What a stream's applied batches established.
    private struct Tally {
        var observed: Set<MediaRelativePath> = []
        var deleted = 0
        var completed = false
    }

    /// Reads one stream to its end, applying it batch by batch. True when the server
    /// reset the cursor: the reset is acknowledged, and nothing of the stream is applied
    /// after it.
    private func read(scan: CatalogStore.ActiveScan, into tally: inout Tally) async throws -> Bool {
        var batch = Batch()
        var pass = PassMemory()
        for try await event in try await source.events() {
            switch event {
            case let .reset(ack):
                try await source.acknowledge([ack])
                return true
            case .complete:
                batch.add(event)
                tally.completed = true
            default:
                batch.add(event)
            }
            if batch.lineCount >= Self.batchSize {
                try await apply(&batch, pass: &pass, scan: scan, into: &tally)
            }
        }
        try await apply(&batch, pass: &pass, scan: scan, into: &tally)
        return false
    }

    /// Applies the batch to the Store, then acknowledges its lines, then empties it. A
    /// still that links a motion part lists it in the still's folder, from the motion's
    /// own line and size in this pass, or else from the server (ADR 0046 §2).
    private func apply(
        _ batch: inout Batch,
        pass: inout PassMemory,
        scan: CatalogStore.ActiveScan,
        into tally: inout Tally
    ) async throws {
        pass.remember(batch)
        var motions: [String: ImmichAssetDetail] = [:]
        for motionID in batch.linkedMotions {
            if let known = pass.motionDetail(motionID) {
                motions[motionID] = known
            } else {
                motions[motionID] = try await source.asset(id: motionID)
            }
        }
        let changes = batch.changes(motions: motions)
        if !changes.isEmpty {
            try await store.applySourceListingChanges(changes, scan: scan)
        }
        try await source.acknowledge(batch.acks)
        tally.observed.formUnion(changes.listed.map(\.file.relativePath))
        tally.deleted += changes.deletedSourceItems.count
        batch = Batch()
    }

    /// A server failure is reported as the server's; anything else the Store refused.
    private static func outcome(of error: any Error) -> ImmichSyncPassOutcome {
        switch error {
        case let error as ImmichClientError: .serverFailed(error)
        case let error as URLError: .serverFailed(.unreachable(error.code))
        case is CancellationError: .noLease
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

        /// The motion part's facts from this pass, when its line and its size are both here.
        func motionDetail(_ id: String) -> ImmichAssetDetail? {
            guard let line = motionLines[id], let size = sizes[id],
                  let created = line.fileCreatedAt, let modified = line.fileModifiedAt
            else {
                return nil
            }
            return ImmichAssetDetail(
                id: id, originalFileName: line.originalFileName, type: line.type,
                fileCreatedAt: created, fileModifiedAt: modified, fileSize: size
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
        func changes(motions: [String: ImmichAssetDetail]) -> SourceListingChanges {
            var listed: [SourceListedItem] = []
            var joined: Set<String> = []
            for id in listedByAsset.keys.sorted() {
                guard let asset = listedByAsset[id] else {
                    continue
                }
                listed.append(ImmichCatalogSync.listedItem(for: asset, size: sizes[id]))
                joined.insert(id)
                if let motionID = asset.livePhotoVideoID, let motion = motions[motionID] {
                    listed.append(ImmichCatalogSync.motionItem(
                        motion, in: asset, size: sizes[motionID] ?? motion.fileSize
                    ))
                    joined.insert(motionID)
                }
            }
            return SourceListingChanges(
                listed: listed,
                completeFolders: listedByAsset.keys.sorted(),
                sizesBySourceItem: sizes.filter { !joined.contains($0.key) },
                deletedSourceItems: deletedAssets.sorted()
            )
        }

        mutating func acknowledge(_ ack: String, type: String) {
            acksByType[type] = ack
            lineCount += 1
        }

        mutating func add(_ event: ImmichSyncEvent) {
            switch event {
            case let .asset(asset, ack):
                acknowledge(ack, type: "AssetV2")
                listAsset(asset)
            case let .assetDeleted(assetID, ack):
                acknowledge(ack, type: "AssetDeleteV1")
                listedByAsset[assetID] = nil
                motionLines[assetID] = nil
                deletedAssets.insert(assetID)
            case let .exif(assetID, fileSize, ack):
                acknowledge(ack, type: "AssetExifV1")
                if let fileSize {
                    sizes[assetID] = fileSize
                }
            case let .unrequested(type, ack):
                acknowledge(ack, type: type)
            case let .reset(ack):
                acknowledge(ack, type: "SyncResetV1")
            case let .complete(ack):
                acknowledge(ack, type: "SyncCompleteV1")
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
            case (.video, .hidden):
                // A Live Photo's motion part: listed in its still's folder when the still
                // is listed (ADR 0046 §2), never in a folder of its own.
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
                    "rootPath": rootPath.rawValue, "error": String(describing: error),
                ])
                break
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
        ])
        return .finished(made: tally.made, unreadable: tally.unreadable)
    }

    private struct ProductTally {
        var made = 0
        var unreadable = 0
    }

    /// One page of owed rows: each preview fetched and staged, then the page applied in
    /// one batch. A stop — the floor, or the server not answering — applies what was made
    /// and ends the pass.
    private func fetch(
        _ page: [SourceProductCandidate],
        into directory: URL,
        tally: inout ProductTally
    ) async -> ProductPassOutcome? {
        var results: [EnrichmentResult] = []
        for candidate in page {
            guard await Self.admitsProducts(onVolumeOf: directory, volumeCapacity) else {
                await apply(results)
                OtosLog.thumbnails.noticeOperation("immich.products", phase: "floorHeld", fields: [
                    "rootPath": rootPath.rawValue, "made": "\(tally.made)",
                ])
                return .floorHeld(made: tally.made)
            }
            let data: Data
            do {
                data = try await source.preview(assetID: candidate.sourceItemID)
            } catch {
                await apply(results)
                OtosLog.thumbnails.noticeOperation("immich.products", phase: "serverFailed", fields: [
                    "rootPath": rootPath.rawValue, "made": "\(tally.made)", "error": String(describing: error),
                ])
                return .serverFailed(made: tally.made)
            }
            if let result = await Self.products(from: data, for: candidate, in: directory) {
                results.append(result)
                tally.made += 1
            } else {
                tally.unreadable += 1
            }
        }
        await apply(results)
        return nil
    }

    private func apply(_ results: [EnrichmentResult]) async {
        guard !results.isEmpty else {
            return
        }
        _ = await store.applyEnrichmentBatch(results)
    }

    /// The free-space floor every background download keeps (ADR 0027), with a megabyte
    /// for the images about to be written.
    @concurrent
    private static func admitsProducts(
        onVolumeOf directory: URL, _ volumeCapacity: VolumeCapacityReader
    ) async -> Bool {
        FreeSpaceFloor.admits(1_000_000, available: volumeCapacity(directory))
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
            isHiddenBySource: asset.deletedAt != nil
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
            isHiddenBySource: still.deletedAt != nil
        )
    }

    /// A file name that is one path component.
    static func fileName(_ original: String, fallback: String) -> String {
        let component = original.replacingOccurrences(of: "/", with: ":")
        return component.isEmpty || component == "." || component == ".." ? fallback : component
    }
}
