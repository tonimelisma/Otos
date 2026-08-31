import Foundation
@testable import OtosKit
import Testing

/// Snapshot-based proof for the product's filesystem promise. The snapshot is
/// deliberately independent of catalog rows: it records every path below the
/// user root, including inode and content digest, so a catalog operation cannot
/// hide an in-place rewrite behind unchanged metadata.
struct FilesystemTreeSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let relativePath: String
        let isDirectory: Bool
        let size: Int64
        let modificationDate: Date?
        let mode: UInt16?
        let inode: UInt64?
        let digest: XXH3Digest128?
    }

    let entries: [String: Entry]

    static func capture(root: URL) throws -> Self {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var entries: [String: Entry] = [:]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return Self(entries: entries) }

        while let url = enumerator.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let isDirectory = type == .typeDirectory
            let digest: XXH3Digest128?
            if type == .typeRegular {
                guard case let .complete(value) = ContentHasher().hashMaterializedFile(at: url) else {
                    throw SnapshotError.digestFailed(url.path)
                }
                digest = value
            } else {
                digest = nil
            }
            entries[relative] = Entry(
                relativePath: relative,
                isDirectory: isDirectory,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modificationDate: attributes[.modificationDate] as? Date,
                mode: (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                digest: digest
            )
        }
        return Self(entries: entries)
    }

    func difference(from other: Self) -> String {
        let keys = Set(entries.keys).union(other.entries.keys).sorted()
        return keys.compactMap { key in
            guard entries[key] != other.entries[key] else { return nil }
            return key
        }.joined(separator: ", ")
    }
}

private enum SnapshotError: Error {
    case digestFailed(String)
}

struct OriginalsReadOnlyTests {
    @Test func addLibraryAndFullScanLeaveOriginalTreeUnchanged() async throws {
        let root = try makeFixtureRoot(named: "scan")
        let before = try FilesystemTreeSnapshot.capture(root: root)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try assertUnchanged(before, root: root)
    }

    @Test func companionInventoryAndRemoveLibraryLeaveOriginalTreeUnchanged() async throws {
        let root = try makeFixtureRoot(named: "companions")
        try Data("sidecar".utf8).write(to: root.appending(path: "photo.xmp"))
        try Data("captions".utf8).write(to: root.appending(path: "photo.srt"))
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let beforeRemove = try FilesystemTreeSnapshot.capture(root: root)
        let path = try CatalogPath.normalizedDirectoryPath(for: root)
        try await store.removeLibrary(path: path)
        try assertUnchanged(beforeRemove, root: root)
    }

    @Test func previewDecodeLeavesOriginalTreeUnchanged() async throws {
        let root = try makeFixtureRoot(named: "preview")
        let before = try FilesystemTreeSnapshot.capture(root: root)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: root.path),
            relativePath: MediaRelativePath(rawValue: "original.jpg")
        )
        let loader = PreviewImageLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester { _ in .testMaterialized }
        )
        _ = await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: 256))
        try assertUnchanged(before, root: root)
    }

    @Test func enrichmentAndThumbnailStagingLeaveOriginalTreeUnchanged() async throws {
        let root = try makeMediaFixtureRoot(
            named: "enrichment",
            fixtureName: "jpeg-exif-offset-date.jpg",
            fileName: "photo.jpg"
        )
        let before = try FilesystemTreeSnapshot.capture(root: root)
        let thumbnailDirectory = root.deletingLastPathComponent().appending(
            path: "enrichment-thumbnails",
            directoryHint: .isDirectory
        )
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: root.path),
            relativePath: MediaRelativePath(rawValue: "photo.jpg")
        )

        let outcome = await MediaEnricher.live(thumbnailDirectory: thumbnailDirectory).enrich(
            id,
            .localFile(root.appending(path: "photo.jpg")),
            100,
            1000,
            true
        )
        guard case .complete = outcome else {
            Issue.record("Expected enrichment to complete, got \(outcome)")
            return
        }
        try assertUnchanged(before, root: root)
    }

    @Test func materializationCoordinatorLeavesOriginalTreeUnchanged() async throws {
        let root = try makeFixtureRoot(named: "materialization")
        let before = try FilesystemTreeSnapshot.capture(root: root)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let coordinator = MaterializationCoordinator(
            store: store,
            executor: { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: root.path),
            relativePath: MediaRelativePath(rawValue: "original.jpg")
        )
        let result = await coordinator.materialize(
            .init(id: id, sourceSize: 14, isVideo: false, priority: .background)
        )
        await coordinator.shutdown()

        #expect(result.isMaterialized)
        try assertUnchanged(before, root: root)
    }

    @Test @MainActor func videoPreviewLeavesOriginalTreeUnchanged() async throws {
        let root = try makeMediaFixtureRoot(
            named: "video-preview",
            fixtureName: "mp4-no-embedded-capture-date.mp4",
            fileName: "clip.mp4"
        )
        let before = try FilesystemTreeSnapshot.capture(root: root)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: root.path),
            relativePath: MediaRelativePath(rawValue: "clip.mp4")
        )
        let detail = MediaTileDetail(
            libraryRootPath: LibraryRootPath(rawValue: root.path),
            relativePath: MediaRelativePath(rawValue: "clip.mp4"),
            thumbnailPath: nil,
            bestKind: .video,
            durationSeconds: nil,
            enrichedSourceSize: 1024,
            enrichedSourceMTimeSeconds: nil
        )
        let loader = VideoPreviewLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )
        if let state = await loader.preparePlayer(id: id, detail: detail) {
            loader.cleanup(state)
        }
        try assertUnchanged(before, root: root)
    }

    @Test func externalChangeRescanWindowDoesNotRewriteExistingOriginals() async throws {
        let root = try makeFixtureRoot(named: "rescan")
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let before = try FilesystemTreeSnapshot.capture(root: root)
        try Data("new external file".utf8).write(to: root.appending(path: "external.jpg"))
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let afterExternalChange = try FilesystemTreeSnapshot.capture(root: root)
        #expect(afterExternalChange.entries["original.jpg"] == before.entries["original.jpg"])
    }

    private func makeFixtureRoot(named name: String) throws -> URL {
        let root = try makeCatalogStoreTemporaryDirectory().appending(
            path: "\(name)-root",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original bytes".utf8).write(to: root.appending(path: "original.jpg"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "nested"),
            withIntermediateDirectories: true
        )
        try Data("nested bytes".utf8).write(to: root.appending(path: "nested/other.jpg"))
        return root
    }

    private func makeMediaFixtureRoot(named name: String, fixtureName: String, fileName: String) throws -> URL {
        let root = try makeCatalogStoreTemporaryDirectory().appending(
            path: "\(name)-root",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Media/\(fixtureName)")
        try FileManager.default.copyItem(at: fixture, to: root.appending(path: fileName))
        return root
    }

    private func assertUnchanged(_ before: FilesystemTreeSnapshot, root: URL) throws {
        let after = try FilesystemTreeSnapshot.capture(root: root)
        #expect(after == before, "Original tree changed at: \(after.difference(from: before))")
    }
}
