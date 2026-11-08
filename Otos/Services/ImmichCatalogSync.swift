import Foundation
import OSLog
import UniformTypeIdentifiers

/// An account's sync stream as the catalog sync sees it. `ImmichSessionSyncSource` is
/// the server; a test scripts one.
nonisolated protocol ImmichSyncSource: Sendable {
    /// One pass of the stream, from the session's cursor.
    func events() async throws -> any AsyncSequence<ImmichSyncEvent, any Error>
    /// Moves the cursor past `acks`.
    func acknowledge(_ acks: [String]) async throws
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
/// - a Live Photo's motion part (`hidden`) is not listed yet (plan 0112, increment 9);
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
    private let doorbell: AsyncStream<Void>
    private let ring: AsyncStream<Void>.Continuation

    init(rootPath: LibraryRootPath, source: any ImmichSyncSource, store: CatalogStore) {
        self.rootPath = rootPath
        self.source = source
        self.store = store
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

    /// The loop: one pass per doorbell ring, until `finish()` or cancellation.
    func run() async {
        for await _ in doorbell {
            guard !Task.isCancelled else {
                return
            }
            _ = await pass()
        }
    }

    /// One pass, applied to its end. A reset turns it into one full resync.
    func pass() async -> ImmichSyncPassOutcome {
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
                try await apply(&batch, scan: scan, into: &tally)
            }
        }
        try await apply(&batch, scan: scan, into: &tally)
        return false
    }

    /// Applies the batch to the Store, then acknowledges its lines, then empties it.
    private func apply(_ batch: inout Batch, scan: CatalogStore.ActiveScan, into tally: inout Tally) async throws {
        let changes = batch.changes
        if !changes.isEmpty {
            try await store.applySourceListingChanges(changes, scan: scan)
        }
        try await source.acknowledge(batch.acks)
        tally.observed.formUnion(changes.listed.map(\.file.relativePath))
        tally.deleted += changes.deletedItemFolders.count
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

    /// Lines read since the last apply, folded per asset: the newest line about an asset
    /// decides what it is, and an asset's size joins its row when both are in the batch.
    private struct Batch {
        private var listedByAsset: [String: SourceListedItem] = [:]
        private var sizes: [String: Int64] = [:]
        private var deletedAssets: Set<String> = []
        /// The newest ack of each line type: the cursor moves per type.
        private var acksByType: [String: String] = [:]
        private(set) var lineCount = 0

        var acks: [String] {
            acksByType.keys.sorted().compactMap { acksByType[$0] }
        }

        var changes: SourceListingChanges {
            SourceListingChanges(
                listed: listedByAsset.keys.sorted().compactMap { listedByAsset[$0] },
                sizesByItemFolder: sizes,
                deletedItemFolders: deletedAssets.sorted()
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
                sizes[assetID] = nil
                deletedAssets.insert(assetID)
            case let .exif(assetID, fileSize, ack):
                acknowledge(ack, type: "AssetExifV1")
                guard let fileSize else {
                    return
                }
                if let item = listedByAsset[assetID] {
                    listedByAsset[assetID] = item.withSize(fileSize)
                } else {
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
                // The locked folder is never synced: a row an earlier pass made goes.
                listedByAsset[asset.id] = nil
                sizes[asset.id] = nil
                deletedAssets.insert(asset.id)
            case (.image, .timeline), (.image, .archive), (.video, .timeline), (.video, .archive):
                deletedAssets.remove(asset.id)
                let item = ImmichCatalogSync.listedItem(for: asset, size: sizes.removeValue(forKey: asset.id))
                listedByAsset[asset.id] = item
            case (.image, .hidden), (.video, .hidden), (.audio, _), (.other, _):
                // A Live Photo's motion part comes with increment 9; audio and other
                // types are never Otos media (product rule).
                break
            }
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
            isHiddenBySource: asset.deletedAt != nil
        )
    }

    /// A file name that is one path component.
    static func fileName(_ original: String, fallback: String) -> String {
        let component = original.replacingOccurrences(of: "/", with: ":")
        return component.isEmpty || component == "." || component == ".." ? fallback : component
    }
}

private extension SourceListedItem {
    nonisolated func withSize(_ size: Int64) -> SourceListedItem {
        SourceListedItem(
            file: ScannedMediaFile(
                relativePath: file.relativePath,
                name: file.name,
                contentTypeIdentifier: file.contentTypeIdentifier,
                byteSize: size,
                createdAt: file.createdAt,
                contentModifiedAt: file.contentModifiedAt,
                kind: file.kind,
                format: file.format,
                fileIdentifier: file.fileIdentifier
            ),
            isHiddenBySource: isHiddenBySource
        )
    }
}
