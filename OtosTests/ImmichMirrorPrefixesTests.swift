import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0054, schema v80: a library an account mirrors has a set of server prefixes, since a
/// server can hold one library under several paths. The probe learns one prefix per request,
/// confirmed by the asset's own path checksum, while a file no known prefix explains has a
/// same-named, same-sized asset, and remembers a candidate whose path taught nothing so it is
/// never asked again while that path stands. A server path matches the file whichever Unicode
/// normal form either side holds it in, and a pair's copy key is its own, so two servers
/// with one path for two different files keep them two photos.
@Suite(.testScope)
struct ImmichMirrorPrefixesTests {
    private static let complete = ImmichSyncEvent.complete(ack: "SyncCompleteV1|1")
    private static let firstPrefix = "/srv/a/Camera Roll/"
    private static let secondPrefix = "/srv/b/Camera Roll/"

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
            let lines = passes.withLock { $0.isEmpty ? [ImmichMirrorPrefixesTests.complete] : $0.removeFirst() }
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

    /// A store with one library per entry of `libraries`, each holding its files (relative
    /// path to contents), scanned, and no account yet.
    private func store(
        _ libraries: [[String: String]]
    ) async throws -> (store: CatalogStore, libraries: [LibraryRootPath], files: [String: PlanningFileFacts]) {
        let temp = try makeTestDirectory()
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        var roots: [LibraryRootPath] = []
        var files: [String: PlanningFileFacts] = [:]
        for (index, contents) in libraries.enumerated() {
            let folder = temp.appending(path: "Library \(index)", directoryHint: .isDirectory)
            for (path, text) in contents {
                let url = folder.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writeCatalogStoreFile(url, contents: text)
            }
            try await store.addLibrary(url: folder)
            let root = try CatalogPath.normalizedDirectoryPath(for: folder)
            roots.append(root)
            let total = libraries.prefix(index + 1).reduce(0) { $0 + $1.count }
            _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == total }
            for file in try #require(await store.windowReads.planningMedia(for: root)) {
                // Keyed by the path as the test wrote it, whatever form the scanner reports.
                let written = try #require(contents.keys.first { $0 == file.relativePath.rawValue })
                files[libraries.count == 1 ? written : "\(index):\(written)"] = file
            }
        }
        return (store, roots, files)
    }

    /// The external library's asset `id`, listed at `serverPath` with `file`'s size and
    /// modification time, and its name unless `named` gives another.
    private static func listing(
        _ id: String,
        of file: PlanningFileFacts,
        at serverPath: String,
        named: String? = nil
    ) throws -> (events: [ImmichSyncEvent], detail: ImmichAssetDetail) {
        let modifiedAt = try #require(file.contentModifiedAt)
        let checksum = ImmichPathChecksum(serverPath: serverPath)
        let name = try named ?? #require(file.relativePath.rawValue.split(separator: "/").last.map(String.init))
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

    private func allMedia(_ store: CatalogStore) async throws -> Int {
        let paths = await CatalogWindowPolicy.availablePaths(from: store.currentLibraries())
        return try await store.windowReads.orderedAssetIDs(for: CatalogQueryDescriptor(scope: .allMedia), availableLibraryPaths: paths).ids.count
    }

    private func sync(_ account: LibraryRootPath, _ server: Server, _ store: CatalogStore) -> ImmichCatalogSync {
        ImmichCatalogSync(rootPath: account, source: server, store: store, volumeCapacity: ampleVolumeCapacity)
    }

    /// The server holds one folder of the library under one path and another folder under a
    /// second: one pass learns both prefixes, one request each, and every file is one photo
    /// with its asset.
    @Test func aLibraryUnderTwoServerPrefixesPairsEveryFile() async throws {
        let catalog = try await store([["2024/IMG_1.JPG": "one", "2025/IMG_2.JPG": "two!"]])
        let first = try Self.listing("a", of: #require(catalog.files["2024/IMG_1.JPG"]), at: Self.firstPrefix + "2024/IMG_1.JPG")
        let second = try Self.listing("b", of: #require(catalog.files["2025/IMG_2.JPG"]), at: Self.secondPrefix + "2025/IMG_2.JPG")
        let server = Server([first.events + second.events + [Self.complete]], details: ["a": first.detail, "b": second.detail])
        let account = try await catalog.store.addImmichAccount(server: #require(URL(string: "https://a.example.com")), userID: "u", displayName: "A")

        #expect(await sync(account, server, catalog.store).pass() == .synced(listed: 2, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a", "b"])
        #expect(try await allMedia(catalog.store) == 2)
        let probes = try await catalog.store.backgroundReads.mirrorProbes(account: account)
        #expect(probes.map(\.serverPrefixes) == [[Self.firstPrefix, Self.secondPrefix]])
        #expect(probes.map(\.candidate) == [nil])
        await catalog.store.shutdown()
    }

    /// A prefix the library already has pairs the files it names; when the server lists files
    /// under a second prefix later, the pass that lists them learns it with one request and
    /// pairs them all, and a pass after it asks nothing.
    @Test func aPrefixLearnedLaterPairsTheRestWithOneRequest() async throws {
        let catalog = try await store([["2024/IMG_1.JPG": "one", "2025/IMG_2.JPG": "two!", "2025/IMG_3.JPG": "three"]])
        let first = try Self.listing("a", of: #require(catalog.files["2024/IMG_1.JPG"]), at: Self.firstPrefix + "2024/IMG_1.JPG")
        let second = try Self.listing("b", of: #require(catalog.files["2025/IMG_2.JPG"]), at: Self.secondPrefix + "2025/IMG_2.JPG")
        let third = try Self.listing("c", of: #require(catalog.files["2025/IMG_3.JPG"]), at: Self.secondPrefix + "2025/IMG_3.JPG")
        let server = Server(
            [first.events + [Self.complete], second.events + third.events + [Self.complete]],
            details: ["a": first.detail, "b": second.detail, "c": third.detail]
        )
        let account = try await catalog.store.addImmichAccount(server: #require(URL(string: "https://a.example.com")), userID: "u", displayName: "A")
        let sync = sync(account, server, catalog.store)

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a"])
        #expect(try await allMedia(catalog.store) == 3)

        #expect(await sync.pass() == .synced(listed: 2, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a", "b"])
        #expect(try await allMedia(catalog.store) == 3)
        #expect(try await catalog.store.backgroundReads.mirrorProbes(account: account).map(\.serverPrefixes) == [[Self.firstPrefix, Self.secondPrefix]])

        #expect(await sync.pass() == .synced(listed: 0, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a", "b"])
        await catalog.store.shutdown()
    }

    /// A same-named, same-sized asset from a folder the library does not have teaches no
    /// prefix. The next pass that owes the walk does not ask about it again: the candidate
    /// was remembered as asked at the asset's path.
    @Test func aCandidateThatTaughtNothingIsNotAskedAgain() async throws {
        let catalog = try await store([["2024/IMG_1.JPG": "one"]])
        let file = try #require(catalog.files["2024/IMG_1.JPG"])
        let elsewhere = try Self.listing("a", of: file, at: Self.firstPrefix + "2023/IMG_1.JPG")
        let other = try Self.listing("z", of: file, at: Self.firstPrefix + "1999/IMG_9.JPG", named: "IMG_9.JPG")
        let server = Server(
            [elsewhere.events + [Self.complete], other.events + [Self.complete]],
            details: ["a": elsewhere.detail, "z": other.detail]
        )
        let account = try await catalog.store.addImmichAccount(server: #require(URL(string: "https://a.example.com")), userID: "u", displayName: "A")
        let sync = sync(account, server, catalog.store)

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a"])
        #expect(try await catalog.store.backgroundReads.mirrorProbes(account: account).map(\.candidate) == [nil])

        // A listing that changes the catalog owes the walk again; the one candidate it could
        // offer was asked already, and the new asset has another name.
        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a"])
        #expect(try await allMedia(catalog.store) == 3)
        await catalog.store.shutdown()
    }

    /// The server's path for a file holds an accented folder name in one Unicode normal form
    /// and the Mac's library in the other, or the same one: the prefix learned from an ASCII
    /// file pairs it either way, from the listing alone.
    @Test(arguments: [false, true])
    func eitherNormalFormOfAPathPairs(decomposedOnTheServer: Bool) async throws {
        let accented = "P\u{00E4}iv\u{00E4}/IMG_2.JPG"
        let catalog = try await store([["2024/IMG_1.JPG": "one", accented: "two!"]])
        let serverName = decomposedOnTheServer ? accented.decomposedStringWithCanonicalMapping : accented.precomposedStringWithCanonicalMapping
        let first = try Self.listing("a", of: #require(catalog.files["2024/IMG_1.JPG"]), at: Self.firstPrefix + "2024/IMG_1.JPG")
        let second = try Self.listing("b", of: #require(catalog.files[accented]), at: Self.firstPrefix + serverName)
        let server = Server([first.events + second.events + [Self.complete]], details: ["a": first.detail, "b": second.detail])
        let account = try await catalog.store.addImmichAccount(server: #require(URL(string: "https://a.example.com")), userID: "u", displayName: "A")

        #expect(await sync(account, server, catalog.store).pass() == .synced(listed: 2, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a"])
        #expect(try await allMedia(catalog.store) == 2)
        await catalog.store.shutdown()
    }

    /// Two accounts on two servers each mirror a library, and each server holds a different
    /// file at the same path, so their assets have one path checksum. Neither file has a
    /// digest, so each pair's key is the pair's own: All Media shows two photos, not one.
    @Test func twoServersWithOnePathForDifferentFilesKeepTwoPhotos() async throws {
        let catalog = try await store([["2024/IMG_1.JPG": "one"], ["2024/IMG_1.JPG": "a longer file"]])
        let firstFile = try #require(catalog.files["0:2024/IMG_1.JPG"])
        let secondFile = try #require(catalog.files["1:2024/IMG_1.JPG"])
        let first = try Self.listing("a", of: firstFile, at: Self.firstPrefix + "2024/IMG_1.JPG")
        let second = try Self.listing("b", of: secondFile, at: Self.firstPrefix + "2024/IMG_1.JPG")
        let firstServer = Server([first.events + [Self.complete]], details: ["a": first.detail])
        let secondServer = Server([second.events + [Self.complete]], details: ["b": second.detail])
        let firstAccount = try await catalog.store.addImmichAccount(server: #require(URL(string: "https://a.example.com")), userID: "u", displayName: "A")
        let secondAccount = try await catalog.store.addImmichAccount(server: #require(URL(string: "https://b.example.com")), userID: "u", displayName: "B")

        #expect(await sync(firstAccount, firstServer, catalog.store).pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(await sync(secondAccount, secondServer, catalog.store).pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(firstServer.requestedDetails == ["a"])
        #expect(secondServer.requestedDetails == ["b"])
        // Each account's server holds one of the libraries.
        let firstProbes = try await catalog.store.backgroundReads.mirrorProbes(account: firstAccount)
        let prefixes = Dictionary(uniqueKeysWithValues: firstProbes.map { ($0.libraryRootPath, $0.serverPrefixes) })
        #expect(prefixes == [catalog.libraries[0]: [Self.firstPrefix], catalog.libraries[1]: []])
        #expect(try await allMedia(catalog.store) == 2)
        let shown = try await catalog.store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia),
            availableLibraryPaths: CatalogWindowPolicy.availablePaths(from: catalog.store.currentLibraries())
        ).ids
        #expect(Set(shown) == [firstFile.id, secondFile.id])
        await catalog.store.shutdown()
    }
}
