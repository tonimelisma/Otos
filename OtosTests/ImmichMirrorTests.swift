import CryptoKit
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0054: an Immich external library that mirrors a library lists each file with the
/// SHA-1 of its server path, never of its bytes. Otos learns the server path a library's
/// files follow from one asset's own path, confirmed by its checksum, and an asset listed
/// at a library file's path with the size and modification time its digest was read at
/// takes that digest, so the two are one photo with no download.
@Suite(.testDirectory)
struct ImmichMirrorTests {
    private static let server = URL(string: "https://photos.example.com")!
    private static let serverPrefix = "/mnt/onedrive/Pictures/Camera Roll/"

    /// One pass per stream asked for, and each asset's own facts.
    private final class MirrorServer: ImmichSyncSource, Sendable {
        private let passes: Mutex<[[ImmichSyncEvent]]>
        private let details: [String: ImmichAssetDetail]
        private let detailRequests = Mutex<[String]>([])

        init(_ passes: [[ImmichSyncEvent]], details: [String: ImmichAssetDetail]) {
            self.passes = Mutex(passes)
            self.details = details
        }

        var requestedDetails: [String] {
            detailRequests.withLock { $0 }
        }

        func events(fromZero _: Bool) async throws -> any AsyncSequence<ImmichSyncEvent, any Error> {
            let lines = passes.withLock { $0.isEmpty ? [] : $0.removeFirst() }
            return AsyncThrowingStream<ImmichSyncEvent, any Error> { continuation in
                lines.forEach { continuation.yield($0) }
                continuation.finish()
            }
        }

        func acknowledge(_: [String]) async throws {}

        func preview(assetID _: String) async throws -> Data {
            throw URLError(.badServerResponse)
        }

        func asset(id: String) async throws -> ImmichAssetDetail {
            detailRequests.withLock { $0.append(id) }
            guard let detail = details[id] else {
                throw ImmichClientError.refused(status: 404)
            }
            return detail
        }
    }

    private struct Fixture {
        let store: CatalogStore
        let library: LibraryRootPath
        let account: LibraryRootPath
        /// The library file `2024/IMG_1.JPG`, which the server mirrors.
        let file: PlanningFileFacts
    }

    private func fixture(digested: Bool) async throws -> Fixture {
        let temp = try makeTestDirectory()
        let folder = temp.appending(path: "Camera Roll", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "2024"), withIntermediateDirectories: true)
        try writeCatalogStoreFile(folder.appending(path: "2024/IMG_1.JPG"), contents: "same")
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: folder)
        let library = try CatalogPath.normalizedDirectoryPath(for: folder)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let file = try #require(await store.planningMedia(for: library)?.first)
        if digested {
            try await digest(file, store: store)
        }
        let account = try await store.addImmichAccount(server: Self.server, userID: "user-1", displayName: "Family")
        return Fixture(store: store, library: library, account: account, file: file)
    }

    private func digest(_ file: PlanningFileFacts, store: CatalogStore) async throws {
        _ = try await store.applyContentHash(ContentHashResult(
            id: file.id,
            contentHash: Self.contentDigest,
            sourceSize: file.byteSize,
            sourceMTimeSeconds: file.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
        ))
    }

    private static let contentDigest = ContentDigest(bytes: Array(Insecure.SHA1.hash(data: Data("same".utf8))))!

    /// The external library's asset `id`, listed at `serverPath` with `file`'s size and,
    /// unless `modified` says otherwise, its modification time.
    private static func listing(
        _ id: String,
        of file: PlanningFileFacts,
        at serverPath: String,
        modified: Date? = nil
    ) throws -> (events: [ImmichSyncEvent], detail: ImmichAssetDetail) {
        let modifiedAt = try modified ?? #require(file.contentModifiedAt)
        let checksum = ImmichPathChecksum(serverPath: serverPath)
        let asset = ImmichAsset(
            id: id, originalFileName: "IMG_1.JPG", type: .image, visibility: .timeline, deletedAt: nil,
            fileCreatedAt: modifiedAt, fileModifiedAt: modifiedAt, hasPreview: false, pathChecksum: checksum
        )
        let detail = ImmichAssetDetail(
            id: id, originalFileName: "IMG_1.JPG", type: .image, fileCreatedAt: modifiedAt, fileModifiedAt: modifiedAt,
            fileSize: file.byteSize, hasPreview: false, pathChecksum: checksum, originalPath: serverPath
        )
        return ([
            .asset(asset, ack: "AssetV2|\(id)"),
            .exif(assetID: id, fileSize: file.byteSize, ack: "AssetExifV1|\(id)"),
        ], detail)
    }

    private static let complete = ImmichSyncEvent.complete(ack: "SyncCompleteV1|1")

    private func ids(_ scope: SidebarSelection, _ store: CatalogStore) async throws -> Set<MediaAssetID> {
        let paths = await CatalogWindowPolicy.availablePaths(from: store.currentLibraries())
        return try await Set(store.orderedAssetIDs(for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: paths).ids)
    }

    private func digest(of path: String, in root: LibraryRootPath, _ store: CatalogStore) async throws -> ContentDigest? {
        let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path))
        return try await store.mediaAssets(for: [id])[id]?.contentHash
    }

    /// A pass that lists the asset after the file's digest was read learns the mirror from
    /// the asset's path and pairs them: All Media shows the library's file alone, and the
    /// account still shows its asset. A later pass keeps the mirror without asking again.
    @Test func aMirroredFileAndItsExternalAssetAreOnePhoto() async throws {
        let fixture = try await fixture(digested: true)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete], [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await digest(of: "a/IMG_1.JPG", in: fixture.account, fixture.store) == Self.contentDigest)
        #expect(try await ids(.allMedia, fixture.store) == [fixture.file.id])
        #expect(try await ids(.library(fixture.account), fixture.store).map(\.relativePath.rawValue) == ["a/IMG_1.JPG"])

        #expect(await sync.pass() == .synced(listed: 0, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a"])
        await fixture.store.shutdown()
    }

    /// A file whose digest is read after the pass learned its mirror pairs in that digest's
    /// own write, with no pass between.
    @Test func aFileDigestedAfterThePassPairsInItsOwnWrite() async throws {
        let fixture = try await fixture(digested: false)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await digest(of: "a/IMG_1.JPG", in: fixture.account, fixture.store) == nil)

        try await digest(fixture.file, store: fixture.store)
        #expect(try await digest(of: "a/IMG_1.JPG", in: fixture.account, fixture.store) == Self.contentDigest)
        #expect(try await ids(.allMedia, fixture.store) == [fixture.file.id])
        await fixture.store.shutdown()
    }

    /// An asset at the file's path but listed with another modification time holds other
    /// bytes: it keeps no digest and shows beside the file.
    @Test func anAssetListedWithOtherFactsIsNotTheFilesCopy() async throws {
        let fixture = try await fixture(digested: true)
        let modified = try #require(fixture.file.contentModifiedAt).addingTimeInterval(60)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG", modified: modified)
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await digest(of: "a/IMG_1.JPG", in: fixture.account, fixture.store) == nil)
        #expect(try await ids(.allMedia, fixture.store).count == 2)
        await fixture.store.shutdown()
    }

    /// A same-named file of the same size in a folder the library does not have teaches no
    /// mirror: its path does not end with the library file's, so nothing pairs.
    @Test func aSameNamedFileFromAnotherFolderTeachesNoMirror() async throws {
        let fixture = try await fixture(digested: true)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2023/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await fixture.store.mirrorProbes(account: fixture.account).map(\.serverPrefix) == [nil])
        #expect(try await digest(of: "a/IMG_1.JPG", in: fixture.account, fixture.store) == nil)
        #expect(try await ids(.allMedia, fixture.store).count == 2)
        await fixture.store.shutdown()
    }

    /// Immich's path checksum is the SHA-1 of `path:` and the server path; the prefix is the
    /// server path before the relative path, compared as bytes.
    @Test func thePathChecksumAndServerPrefixAreImmichs() throws {
        let checksum = try #require(ImmichAsset.pathChecksum(checksum: "YSh/w9kgVtWGbzD5f2uUP5/HYag=", libraryID: "lib"))
        #expect(ImmichPathChecksum(serverPath: "/mnt/onedrive/Pictures/Camera Roll/2024/IMG_1.JPG") == checksum)
        #expect(ImmichAsset.pathChecksum(checksum: "YSh/w9kgVtWGbzD5f2uUP5/HYag=", libraryID: nil) == nil)
        #expect(ImmichAsset.contentDigest(checksum: "YSh/w9kgVtWGbzD5f2uUP5/HYag=", libraryID: "lib", assetID: "a") == nil)

        let relative = MediaRelativePath(rawValue: "2024/IMG_1.JPG")
        #expect(MirrorGateway.serverPrefix(of: "/mnt/od/2024/IMG_1.JPG", relativePath: relative) == "/mnt/od/")
        #expect(MirrorGateway.serverPrefix(of: "/mnt/od/x2024/IMG_1.JPG", relativePath: relative) == nil)
        #expect(MirrorGateway.serverPrefix(of: "/2024/IMG_1.JPG", relativePath: relative) == nil)
        // The same name in its decomposed form is another path.
        let composed = MediaRelativePath(rawValue: "P\u{00E4}iv\u{00E4}.JPG")
        #expect(MirrorGateway.serverPrefix(of: "/od/Pa\u{0308}iva\u{0308}.JPG", relativePath: composed) == nil)
    }
}
