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
        let digest: ContentDigest?
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
        ) else { throw SnapshotError.unreadableRoot(root.path) }

        // The enumerator may report the root's real path (`/private/var/…` for `/var/…`)
        // or its given spelling; a key is the path below whichever prefix it carries, and
        // an entry under neither is a capture error, never a key. `realpath(3)` is used
        // because `resolvingSymlinksInPath` strips `/private` back off.
        let prefixes = try [Self.realPath(of: root), root.path].map { $0 + "/" }
        while let url = enumerator.nextObject() as? URL {
            guard let prefix = prefixes.first(where: { url.path.hasPrefix($0) }) else {
                throw SnapshotError.entryOutsideRoot(url.path)
            }
            let relative = String(url.path.dropFirst(prefix.count))
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let isDirectory = type == .typeDirectory
            let digest: ContentDigest?
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

    private static func realPath(of url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else {
            throw SnapshotError.unreadableRoot(url.path)
        }
        defer { free(resolved) }
        return String(cString: resolved)
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
    case unreadableRoot(String)
    case entryOutsideRoot(String)
    case digestFailed(String)
}

@Suite(.testScope)
struct OriginalsReadOnlyTests {
    @Test func addLibraryAndFullScanLeaveOriginalTreeUnchanged() async throws {
        let root = try makeFixtureRoot(named: "scan")
        let before = try FilesystemTreeSnapshot.capture(root: root)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try assertUnchanged(before, root: root)
    }

    @Test func companionInventoryAndRemoveLibraryLeaveOriginalTreeUnchanged() async throws {
        let root = try makeFixtureRoot(named: "companions")
        try Data("sidecar".utf8).write(to: root.appending(path: "photo.xmp"))
        try Data("captions".utf8).write(to: root.appending(path: "photo.srt"))
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let beforeRemove = try FilesystemTreeSnapshot.capture(root: root)
        let path = try CatalogPath.normalizedDirectoryPath(for: root)
        #expect(try await store.removeLibrary(path: path) == .removed)
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
            materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in .testMaterialized }
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
            [.metadata, .rendering, .hash], nil
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let coordinator = MaterializationCoordinator(
            store: store,
            executor: { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            },
            volumeCapacity: ampleVolumeCapacity
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
            byteSize: 1024,
            thumbnailPath: nil,
            bestKind: .video,
            durationSeconds: nil
        )
        let loader = VideoPreviewLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )
        if let state = await loader.preparePlayer(id: id, detail: detail) {
            loader.cleanup(state)
        }
        try assertUnchanged(before, root: root)
    }

    /// The reconcile an external change schedules must read the root and leave the
    /// originals already there untouched. The event is delivered by the test, so the
    /// rescan is known to have happened: the catalog lists the new file only after it.
    @Test func externalChangeRescanWindowDoesNotRewriteExistingOriginals() async throws {
        let root = try makeFixtureRoot(named: "rescan")
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = makeTestStore(location: .inMemory, filesystemWatcher: watcher, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning }
        #expect(Set(scanned.testAssets.map(\.relativePath.rawValue)) == ["original.jpg", "nested/other.jpg"])
        let before = try FilesystemTreeSnapshot.capture(root: root)
        let external = root.appending(path: "external.jpg")
        try Data("new external file".utf8).write(to: external)
        emit(FilesystemEvent(path: external.path, flags: 0))
        let rescanned = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.testAssets.contains { $0.relativePath.rawValue == "external.jpg" }
        }
        let rescannedPaths = Set(rescanned.testAssets.map(\.relativePath.rawValue))
        #expect(rescannedPaths == ["original.jpg", "nested/other.jpg", "external.jpg"])
        let afterExternalChange = try FilesystemTreeSnapshot.capture(root: root)
        let original = try #require(before.entries["original.jpg"])
        #expect(afterExternalChange.entries["original.jpg"] == original)
    }

    private func makeFixtureRoot(named name: String) throws -> URL {
        let root = try makeTestDirectory().appending(
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
        let root = try makeTestDirectory().appending(
            path: "\(name)-root",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = SourceTree.mediaFixtures.appending(path: fixtureName)
        try FileManager.default.copyItem(at: fixture, to: root.appending(path: fileName))
        return root
    }

    private func assertUnchanged(_ before: FilesystemTreeSnapshot, root: URL) throws {
        try #require(!before.entries.isEmpty, "An empty snapshot proves nothing about the originals")
        let after = try FilesystemTreeSnapshot.capture(root: root)
        #expect(after == before, "Original tree changed at: \(after.difference(from: before))")
    }
}
