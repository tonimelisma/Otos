import Foundation
import OSLog

/// The camera as the catalog sync sees it: its item list, its change reports, and the
/// two reads the sync makes. `DeviceCameraSession` is the production camera; a test
/// scripts one, because a session cannot be made without a connected `ICCameraDevice`.
@MainActor
protocol CameraCatalogSource: AnyObject {
    var identity: String { get }
    var displayName: String { get }
    var stagingRootURL: URL { get }
    /// Rings when the camera reports items added or removed after its catalog is
    /// complete. Newest-wins: rings during a pass become one more pass. Ends when the
    /// session closes.
    var catalogChanges: AsyncStream<Void> { get }
    func catalogSnapshot() async throws -> DeviceCameraCatalogSnapshot
    func thumbnailData(for relativePath: MediaRelativePath, maxPixelSize: Int) async throws -> Data?
    /// Whether this camera answers a ranged read of `relativePath`.
    func answersRangedReads(relativePath: MediaRelativePath, size: UInt64) async -> Bool
}

/// Camera catalog sync guide
///
/// One owner per attached camera keeps its catalog root in step with the camera for as
/// long as it is connected. A pass reads the camera's list, records every item under a
/// fresh enumeration lease, proves deletions only when the list held still
/// (`DeviceCameraCatalogSnapshot.isStable`, ADR 0008: a missing item is not a deleted
/// one), and stages and thumbnails only the items no earlier pass saw. The first pass
/// runs at attach; every later one is rung by the camera's own add/remove reports, so a
/// shot taken or deleted while connected reaches the catalog without a reconnect.
///
/// `run()` is the one loop. Its pass state is local to it, and passes never overlap.
/// It ends when its task is cancelled (detach) or the camera's change stream finishes.
@MainActor
final class CameraCatalogSync {
    /// What the sync asks of enrichment. Closures over `EnrichmentCoordinator` in the app;
    /// a test records them.
    struct Enrichment {
        let markRangeCapable: @Sendable (LibraryRootPath) async -> Void
        let stage: @Sendable ([EnrichmentCoordinator.DeviceStagingSeed]) async -> Void
    }

    private let source: any CameraCatalogSource
    private let store: CatalogStore
    private let enrichment: Enrichment
    private let thumbnailDirectory: URL?

    init(
        source: any CameraCatalogSource,
        store: CatalogStore,
        enrichment: Enrichment,
        thumbnailDirectory: URL?
    ) {
        self.source = source
        self.store = store
        self.enrichment = enrichment
        self.thumbnailDirectory = thumbnailDirectory
    }

    func run() async {
        let rootPath: LibraryRootPath
        do {
            rootPath = try await store.attachDeviceMTP(
                stagingRootURL: source.stagingRootURL,
                identity: source.identity,
                displayName: source.displayName
            )
        } catch {
            OtosLog.catalog.errorOperation("catalog.device.scan", phase: "attachFailed", fields: [
                "identity": source.identity,
                "error": String(describing: error),
            ])
            return
        }
        var progress = Progress()
        await pass(rootPath: rootPath, progress: &progress)
        for await _ in source.catalogChanges {
            guard !Task.isCancelled else {
                return
            }
            await pass(rootPath: rootPath, progress: &progress)
        }
    }

    /// What earlier passes established for this attach.
    private struct Progress {
        var number = 0
        /// Every item any pass has seen. An item leaving and returning is not staged twice.
        var seen: Set<MediaRelativePath> = []
        /// Whether the ranged-read probe has run; it runs once per attach.
        var probedRangedReads = false
    }

    private func pass(rootPath: LibraryRootPath, progress: inout Progress) async {
        progress.number += 1
        let identity = source.identity
        var activeScan: CatalogStore.ActiveScan?
        do {
            let scan = try await store.beginDeviceCatalogEnumeration(rootPath: rootPath)
            activeScan = scan
            let snapshot = try await source.catalogSnapshot()
            try Task.checkCancellation()
            let items = snapshot.items
            try await store.recordDeviceCatalogBatch(Self.scannedFiles(for: items), scan: scan)
            // Decide once per attach whether this device answers ranged reads, before any
            // seeding, because the answer decides whether seeding happens at all. One
            // 12-byte read against one item: cheap enough to always do, and the only honest
            // way to know — `GetPartialObject` is optional in MTP and devices that advertise
            // it are documented failing it.
            if !progress.probedRangedReads,
               let probe = items.first(where: { ($0.byteSize ?? 0) > 0 }),
               let size = probe.byteSize
            {
                progress.probedRangedReads = true
                if await source.answersRangedReads(relativePath: probe.relativePath, size: UInt64(size)) {
                    await enrichment.markRangeCapable(rootPath)
                }
            }
            let added = items.filter { !progress.seen.contains($0.relativePath) }
            progress.seen.formUnion(added.map(\.relativePath))
            if !added.isEmpty {
                await enrichment.stage(Self.stagingSeeds(for: added, rootPath: rootPath))
            }
            if snapshot.isStable {
                try await store.completeDeviceCatalogEnumeration(
                    scan: scan,
                    observedPaths: Set(items.map(\.relativePath)),
                    companions: Self.mediaCompanions(for: snapshot.companions)
                )
            } else {
                OtosLog.catalog.notice(
                    "op=catalog.device.scan phase=unstable identity=\(identity, privacy: .public) count=\(items.count, privacy: .public)"
                )
            }
            OtosLog.catalog.noticeOperation("catalog.device.sync", phase: "pass", fields: [
                "identity": identity,
                "pass": "\(progress.number)",
                "count": "\(items.count)",
                "added": "\(added.count)",
                "isStable": "\(snapshot.isStable)",
            ])
            await applyProvisionalThumbnails(for: added, rootPath: rootPath)
        } catch is CancellationError {
            // The cleanup below ends the current enumeration lease if this pass still
            // owns it; detach or reconnect may already have superseded it.
        } catch {
            OtosLog.catalog.error(
                "op=catalog.device.scan phase=error identity=\(identity, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
        if let activeScan {
            await store.endDeviceCatalogEnumeration(scan: activeScan)
        }
    }

    private static func scannedFiles(for items: [DeviceCameraCatalogItem]) -> [ScannedMediaFile] {
        items.map { item in
            ScannedMediaFile(
                relativePath: item.relativePath,
                name: item.name,
                contentTypeIdentifier: item.contentTypeIdentifier,
                byteSize: item.byteSize,
                createdAt: item.captureDate,
                // Creation-first, not modification-first. `contentModifiedAt` is what
                // import naming falls back to, and `CameraFileDate.modificationDate`
                // prefers the modification dates — which for video is when recording
                // *stopped*, misnaming every clip by its own length. `captureDate`
                // answers the question naming actually asks; the modification date is
                // the fallback of last resort (ARC-057).
                contentModifiedAt: item.captureDate ?? item.modificationDate
            )
        }
    }

    private static func mediaCompanions(for items: [DeviceCameraCompanionItem]) -> [MediaCompanion] {
        items.map { item in
            MediaCompanion(
                relativePath: item.relativePath,
                primaryRelativePath: item.primaryRelativePath,
                kind: item.kind,
                byteSize: item.byteSize,
                contentModifiedAt: item.contentModifiedAt
            )
        }
    }

    private static func stagingSeeds(
        for items: [DeviceCameraCatalogItem],
        rootPath: LibraryRootPath
    ) -> [EnrichmentCoordinator.DeviceStagingSeed] {
        items.map { item in
            EnrichmentCoordinator.DeviceStagingSeed(
                id: MediaAssetID(libraryRootPath: rootPath, relativePath: item.relativePath),
                sourceSize: item.byteSize,
                captureDate: item.captureDate,
                isVideo: MediaEligibility.isVideo(contentTypeIdentifier: item.contentTypeIdentifier)
            )
        }
    }

    private func applyProvisionalThumbnails(
        for items: [DeviceCameraCatalogItem],
        rootPath: LibraryRootPath
    ) async {
        guard let thumbnailDirectory, !items.isEmpty else {
            return
        }
        let batchSize = 24
        var thumbnailsByID: [MediaAssetID: String] = [:]
        for item in items {
            if Task.isCancelled {
                break
            }
            if let relativeName = await writeProvisionalThumbnail(
                item,
                rootPath: rootPath,
                thumbnailDirectory: thumbnailDirectory
            ) {
                thumbnailsByID[MediaAssetID(libraryRootPath: rootPath, relativePath: item.relativePath)] = relativeName
            }
            if thumbnailsByID.count >= batchSize {
                await recordProvisionalThumbnails(thumbnailsByID)
                thumbnailsByID.removeAll(keepingCapacity: true)
            }
        }
        await recordProvisionalThumbnails(thumbnailsByID)
    }

    private func recordProvisionalThumbnails(_ thumbnailsByID: [MediaAssetID: String]) async {
        do {
            try await store.applyProvisionalThumbnails(thumbnailsByID)
        } catch {
            OtosLog.thumbnails.errorOperation("camera.thumbnail", phase: "recordFailed", fields: [
                "identity": source.identity,
                "count": "\(thumbnailsByID.count)",
                "error": String(describing: error),
            ])
        }
    }

    /// The thumbnail's relative name once its file is written, or `nil` when the camera
    /// had none or the write failed — the row then waits for enrichment's thumbnail.
    private func writeProvisionalThumbnail(
        _ item: DeviceCameraCatalogItem,
        rootPath: LibraryRootPath,
        thumbnailDirectory: URL
    ) async -> String? {
        let relativeName = ThumbnailStore.relativeName(
            for: MediaAssetID(libraryRootPath: rootPath, relativePath: item.relativePath)
        )
        do {
            guard let data = try await source.thumbnailData(
                for: item.relativePath,
                maxPixelSize: ThumbnailStore.maxPixelSize
            ) else {
                return nil
            }
            try ThumbnailStore.writeProvisionalJPEG(data, finalRelativeName: relativeName, in: thumbnailDirectory)
            return relativeName
        } catch {
            OtosLog.thumbnails.debug(
                "Camera provisional thumbnail failed path=\(item.relativePath.rawValue, privacy: .public)"
            )
            return nil
        }
    }
}
