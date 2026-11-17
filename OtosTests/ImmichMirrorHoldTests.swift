import CoreServices
import CryptoKit
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0054, ADR 0032 rule 8: an account's mirror walk (probe every library, page every
/// digested file against the account) is owed only by what it reads moving: the account's
/// listing bringing something, or a library's paths, sizes or dates changing
/// (`CatalogStore.libraryNamespaceRevision`). A file's digest pairs in its own write, so a
/// poll that listed nothing and found no library changed reads no mirror and asks the server
/// nothing; a file renamed on disk pairs at the next pass, though no listing says so.
@Suite(.testScope)
struct ImmichMirrorHoldTests {
    private static let server = URL(string: "https://photos.example.com")!
    private static let serverPrefix = "/mnt/onedrive/Pictures/Camera Roll/"
    private static let contentDigest = ContentDigest(bytes: Array(Insecure.SHA1.hash(data: Data("same".utf8))))!
    private static let complete = ImmichSyncEvent.complete(ack: "SyncCompleteV1|1")

    /// One pass per stream asked for, then empty complete streams; each asset's own facts.
    private final class Server: ImmichSyncSource, Sendable {
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
            let lines = passes.withLock { $0.isEmpty ? [ImmichMirrorHoldTests.complete] : $0.removeFirst() }
            return AsyncThrowingStream<ImmichSyncEvent, any Error> { continuation in
                lines.forEach { continuation.yield($0) }
                continuation.finish()
            }
        }

        func acknowledge(_: [String]) async throws {}

        func preview(assetID _: String) async throws -> Data {
            throw ImmichClientError.refused(status: 404)
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
        let folder: URL
        let account: LibraryRootPath
        let file: PlanningFileFacts
        let emit: @Sendable (FilesystemEvent) -> Void
    }

    /// A library holding `2024/IMG_1.JPG`, digested, whose events the test delivers, and an
    /// account.
    private func fixture() async throws -> Fixture {
        let temp = try makeTestDirectory()
        let folder = temp.appending(path: "Camera Roll", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "2024"), withIntermediateDirectories: true)
        try writeCatalogStoreFile(folder.appending(path: "2024/IMG_1.JPG"), contents: "same")
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        // File-backed: its connections account their transactions (`CatalogStore.use()`).
        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "catalog.sqlite")), filesystemWatcher: watcher, scanCadence: .milliseconds(10),
            stagingContainers: StagingContainers(base: temp)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: folder)
        let library = try CatalogPath.normalizedDirectoryPath(for: folder)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let file = try #require(await store.windowReads.planningMedia(for: library)?.first)
        _ = try await store.applyContentHash(ContentHashResult(
            id: file.id,
            contentHash: Self.contentDigest,
            sourceSize: file.byteSize,
            sourceMTimeSeconds: file.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
        ))
        let account = try await store.addImmichAccount(server: Self.server, userID: "user-1", displayName: "Family")
        return Fixture(store: store, folder: folder, account: account, file: file, emit: emit)
    }

    /// The external library's asset `id`, named `name` at `serverPath`, with `file`'s size and
    /// modification time.
    private static func listing(
        _ id: String,
        named name: String,
        of file: PlanningFileFacts,
        at serverPath: String
    ) throws -> (events: [ImmichSyncEvent], detail: ImmichAssetDetail) {
        let modifiedAt = try #require(file.contentModifiedAt)
        let checksum = ImmichPathChecksum(serverPath: serverPath)
        let asset = ImmichAsset(
            id: id, originalFileName: name, type: .image, visibility: .timeline, deletedAt: nil,
            fileCreatedAt: modifiedAt, fileModifiedAt: modifiedAt, hasPreview: false, pathChecksum: checksum
        )
        let detail = ImmichAssetDetail(
            id: id, originalFileName: name, type: .image, fileCreatedAt: modifiedAt, fileModifiedAt: modifiedAt,
            fileSize: file.byteSize, hasPreview: false, pathChecksum: checksum, originalPath: serverPath
        )
        return ([
            .asset(asset, ack: "AssetV2|\(id)"),
            .exif(assetID: id, fileSize: file.byteSize, ack: "AssetExifV1|\(id)"),
        ], detail)
    }

    /// Transactions the mirror walk ran: its probe and its pages of digested files.
    private static func mirrorReads(_ store: CatalogStore) -> Int {
        store.use().connections.holds.filter { $0.operation.hasPrefix("mirror") }.reduce(0) { $0 + $1.count }
    }

    private func digest(of path: String, in root: LibraryRootPath, _ store: CatalogStore) async throws -> ContentDigest? {
        let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path))
        return try await store.windowReads.mediaAssets(for: [id])[id]?.contentHash
    }

    /// The first pass pairs; a pass after it that listed nothing, with no library changed,
    /// reads no mirror and asks the server nothing, however often it is rung.
    @Test func aPassThatBroughtNothingWalksNoMirror() async throws {
        let fixture = try await fixture()
        let listing = try Self.listing("a", named: "IMG_1.JPG", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = Server([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity)

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await digest(of: "a/IMG_1.JPG", in: fixture.account, fixture.store) == Self.contentDigest)
        let walked = Self.mirrorReads(fixture.store)
        #expect(walked > 0)

        for _ in 0 ..< 3 {
            #expect(await sync.pass() == .synced(listed: 0, deleted: 0, full: false))
        }
        #expect(Self.mirrorReads(fixture.store) == walked)
        #expect(server.requestedDetails == ["a"])
        await fixture.store.shutdown()
    }

    /// The server lists the file under the name it has since been given on disk. The first
    /// pass finds no library file of that name, so it learns no mirror; once the rename reaches
    /// the catalog, the next pass, which lists nothing, walks again, learns the mirror and pairs.
    @Test func aFileRenamedOnDiskPairsAtTheNextPass() async throws {
        let fixture = try await fixture()
        let listing = try Self.listing("a", named: "IMG_2.JPG", of: fixture.file, at: Self.serverPrefix + "2024/IMG_2.JPG")
        let server = Server([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity)

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await digest(of: "a/IMG_2.JPG", in: fixture.account, fixture.store) == nil)
        #expect(server.requestedDetails.isEmpty)

        let original = fixture.folder.appending(path: "2024/IMG_1.JPG")
        let renamed = fixture.folder.appending(path: "2024/IMG_2.JPG")
        try FileManager.default.moveItem(at: original, to: renamed)
        let flags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
        fixture.emit(FilesystemEvent(path: original.path, flags: flags))
        fixture.emit(FilesystemEvent(path: renamed.path, flags: flags))
        _ = try await waitForCatalogStoreState(fixture.store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue).contains("2024/IMG_2.JPG")
        }

        #expect(await sync.pass() == .synced(listed: 0, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a"])
        #expect(try await digest(of: "a/IMG_2.JPG", in: fixture.account, fixture.store) == Self.contentDigest)
        await fixture.store.shutdown()
    }
}
