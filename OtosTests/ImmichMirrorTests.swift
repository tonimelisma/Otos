import CryptoKit
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0054: an Immich external library that mirrors a library lists each file with the
/// SHA-1 of its server path, never of its bytes. Otos learns the server path a library's
/// files follow from one asset's own path, confirmed by its checksum, and pairs each library
/// file with the asset its path names, from the listing alone: no byte is read, nothing is
/// downloaded and no digest is needed. The pair's rows are one photo while their versions
/// agree (schema v79).
@Suite(.testScope)
struct ImmichMirrorTests {
    private static let server = URL(string: "https://photos.example.com")!
    private static let serverPrefix = "/mnt/onedrive/Pictures/Camera Roll/"

    /// One pass per stream asked for, then empty complete streams; each asset's own facts.
    private final class MirrorServer: ImmichSyncSource, Sendable {
        private let passes: Mutex<[[ImmichSyncEvent]]>
        private let details: [String: ImmichAssetDetail]
        private let detailRequests = Mutex<[String]>([])
        private let previewRequests = Mutex<[String]>([])

        init(_ passes: [[ImmichSyncEvent]], details: [String: ImmichAssetDetail]) {
            self.passes = Mutex(passes)
            self.details = details
        }

        var requestedDetails: [String] {
            detailRequests.withLock { $0 }
        }

        var requestedPreviews: [String] {
            previewRequests.withLock { $0 }
        }

        func events(fromZero _: Bool) async throws -> any AsyncSequence<ImmichSyncEvent, any Error> {
            let lines = passes.withLock { $0.isEmpty ? [ImmichMirrorTests.complete] : $0.removeFirst() }
            return AsyncThrowingStream<ImmichSyncEvent, any Error> { continuation in
                lines.forEach { continuation.yield($0) }
                continuation.finish()
            }
        }

        func acknowledge(_: [String]) async throws {}

        func preview(assetID: String) async throws -> Data {
            previewRequests.withLock { $0.append(assetID) }
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
        let library: LibraryRootPath
        let account: LibraryRootPath
        /// The library file `2024/IMG_1.JPG`, which the server mirrors.
        let file: PlanningFileFacts

        var asset: MediaAssetID {
            MediaAssetID(libraryRootPath: account, relativePath: MediaRelativePath(rawValue: "a/IMG_1.JPG"))
        }
    }

    /// `secondCopy` also puts `2024/IMG_1 copy.JPG`, the same bytes, in the library.
    private func fixture(digested: Bool, secondCopy: Bool = false) async throws -> Fixture {
        let temp = try makeTestDirectory()
        let folder = temp.appending(path: "Camera Roll", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "2024"), withIntermediateDirectories: true)
        try writeCatalogStoreFile(folder.appending(path: "2024/IMG_1.JPG"), contents: "same")
        if secondCopy {
            try writeCatalogStoreFile(folder.appending(path: "2024/IMG_1 copy.JPG"), contents: "same")
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: folder)
        let library = try CatalogPath.normalizedDirectoryPath(for: folder)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == (secondCopy ? 2 : 1) }
        let file = try #require(await store.windowReads.planningMedia(for: library)?.first { $0.id.relativePath.rawValue == "2024/IMG_1.JPG" })
        if digested {
            try await digest(file, store: store)
        }
        let account = try await store.addImmichAccount(server: Self.server, userID: "user-1", displayName: "Family")
        return Fixture(store: store, library: library, account: account, file: file)
    }

    private func digest(_ file: PlanningFileFacts, store: CatalogStore, as digest: ContentDigest = contentDigest) async throws {
        _ = try await store.applyContentHash(ContentHashResult(
            id: file.id,
            contentHash: digest,
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
        let name = try #require(file.relativePath.rawValue.split(separator: "/").last.map(String.init))
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

    fileprivate static let complete = ImmichSyncEvent.complete(ack: "SyncCompleteV1|1")

    private func ids(
        _ scope: SidebarSelection,
        _ store: CatalogStore,
        available: Set<LibraryRootPath>? = nil
    ) async throws -> Set<MediaAssetID> {
        let paths = if let available {
            available
        } else {
            await CatalogWindowPolicy.availablePaths(from: store.currentLibraries())
        }
        return try await Set(store.windowReads.orderedAssetIDs(for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: paths).ids)
    }

    private func asset(_ id: MediaAssetID, _ store: CatalogStore) async throws -> MediaAsset? {
        try await store.windowReads.mediaAssets(for: [id])[id]
    }

    /// A pass that lists the asset learns the mirror from the asset's path and pairs it with
    /// the library file its path names, though neither has a digest — a cloud-only file whose
    /// bytes Otos never read: All Media shows the library's file alone, the library shows its
    /// file and the account its asset. Nothing is downloaded and no digest is written. A later
    /// pass keeps the mirror without asking the server again.
    @Test func aMirroredFileWithNoDigestAndItsExternalAssetAreOnePhoto() async throws {
        let fixture = try await fixture(digested: false)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await ids(.allMedia, fixture.store) == [fixture.file.id])
        #expect(try await ids(.library(fixture.library), fixture.store) == [fixture.file.id])
        #expect(try await ids(.library(fixture.account), fixture.store) == [fixture.asset])
        #expect(try await asset(fixture.asset, fixture.store)?.contentHash == nil)
        #expect(try await asset(fixture.file.id, fixture.store)?.contentHash == nil)
        #expect(server.requestedPreviews.isEmpty || server.requestedPreviews == ["a"])
        #expect(try await fixture.store.windowReads.visibleAssetCount(
            for: .allMedia, availableLibraryPaths: [fixture.library, fixture.account]
        ) == 1)

        #expect(await sync.pass() == .synced(listed: 0, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a"])
        await fixture.store.shutdown()
    }

    /// A file's digest read after the pair agrees with it: the pair stays one photo, and the
    /// asset is given no digest of its own.
    @Test func aDigestReadAfterThePairKeepsItOnePhoto() async throws {
        let fixture = try await fixture(digested: false)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))

        try await digest(fixture.file, store: fixture.store)
        #expect(try await asset(fixture.file.id, fixture.store)?.contentHash == Self.contentDigest)
        #expect(try await asset(fixture.asset, fixture.store)?.contentHash == nil)
        #expect(try await ids(.allMedia, fixture.store) == [fixture.file.id])
        await fixture.store.shutdown()
    }

    /// A Like or a Dislike on either row of a pair is the photo's (owner, 2026-11-15): it is
    /// written on both, whichever the user chose it on.
    @Test func aChoiceOnEitherRowOfAPairIsThePhotos() async throws {
        let fixture = try await fixture(digested: false)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))

        _ = try await fixture.store.setMediaChoice(.liked, for: [fixture.asset])
        #expect(try await asset(fixture.file.id, fixture.store)?.mediaChoice == .liked)
        _ = try await fixture.store.setMediaChoice(.disliked, for: [fixture.file.id])
        #expect(try await asset(fixture.asset, fixture.store)?.mediaChoice == .disliked)
        await fixture.store.shutdown()
    }

    /// With the library not available, the account's asset is the photo's reachable copy and
    /// shows in All Media; with the account not available, the library's file does.
    @Test func eitherCopyShowsWhenTheOtherIsNotAvailable() async throws {
        let fixture = try await fixture(digested: false)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))

        #expect(try await ids(.allMedia, fixture.store, available: [fixture.account]) == [fixture.asset])
        #expect(try await ids(.allMedia, fixture.store, available: [fixture.library]) == [fixture.file.id])
        await fixture.store.shutdown()
    }

    /// A file and its mirror are one photo, never duplicates (owner, 2026-11-15): with
    /// Duplicates across libraries and accounts, the pair is no group, before the pairing is
    /// learned and after; a second copy of the file in its library makes a group of the two
    /// files alone; and with the library not available the mirror is no copy of anything. So
    /// no click, folder rule or default can keep the mirror and move the file it mirrors.
    @Test(arguments: [false, true])
    func aFileAndItsMirrorAreNeverDuplicates(secondCopy: Bool) async throws {
        let fixture = try await fixture(digested: true, secondCopy: secondCopy)
        let store = fixture.store
        var files: Set<MediaAssetID> = []
        if secondCopy {
            let second = try #require(await store.windowReads.planningMedia(for: fixture.library)?.first { $0.id != fixture.file.id })
            try await digest(second, store: store)
            files = [fixture.file.id, second.id]
        }
        await store.setDuplicatesReach(.acrossLibraries)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(rootPath: fixture.account, source: server, store: store, volumeCapacity: ampleVolumeCapacity)
        func duplicates(_ available: Set<LibraryRootPath>? = nil) async throws -> (copies: Set<MediaAssetID>, scope: Set<MediaAssetID>) {
            let paths = if let available {
                available
            } else {
                await CatalogWindowPolicy.availablePaths(from: store.currentLibraries())
            }
            let copies = try await store.backgroundReads.duplicateCopies(availableLibraryPaths: paths).copies.map(\.copy.id)
            let scope = try await store.windowReads.orderedAssetIDs(for: CatalogQueryDescriptor(scope: .duplicates), availableLibraryPaths: paths).ids
            return (Set(copies), Set(scope))
        }

        #expect(try await duplicates().copies == files)
        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await ids(.allMedia, store).count == 1)
        #expect(try await duplicates().copies == files)
        #expect(try await duplicates().scope == files)
        #expect(try await store.windowReads.visibleAssetCount(for: .duplicates, availableLibraryPaths: [fixture.library, fixture.account]) == files.count)
        #expect(try await duplicates([fixture.account]).copies.isEmpty)
        #expect(try await duplicates([fixture.account]).scope.isEmpty)
        await store.shutdown()
    }

    /// An asset at the file's path but listed with another modification time is another
    /// version: the file was changed and the server has not read it again. The pair stands,
    /// by path, but the two are two photos until their versions agree.
    @Test func aPairWhoseVersionsDifferIsTwoPhotos() async throws {
        let fixture = try await fixture(digested: true)
        let modified = try #require(fixture.file.contentModifiedAt).addingTimeInterval(60)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG", modified: modified)
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await asset(fixture.asset, fixture.store)?.contentHash == nil)
        #expect(try await ids(.allMedia, fixture.store).count == 2)
        await fixture.store.shutdown()
    }

    /// The server lists a new asset before it has read the file's size (an external library's
    /// scan finds the file; its metadata job comes later): the pair is made by path, and the
    /// two are one photo at once (v83), since the modification time the scan read is the
    /// file's, so a Like on the file is the asset's too. The next pass lists the asset again
    /// with its size, an upsert of a row whose pair's key holds, and the pair stays one photo.
    /// The upsert's own conflict policy reaches the copy triggers, so it once aborted there,
    /// the batch was never acknowledged, and every pass after failed on it (owner's catalog,
    /// 2026-11-19).
    @Test func anAssetTheServerHasNotReadIsOnePhotoWithItsFileByTime() async throws {
        let fixture = try await fixture(digested: true, secondCopy: true)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        // The library's other file, which the server has read, teaches the mirror's prefix: the
        // probe asks only about an asset with a size.
        let other = try #require(await fixture.store.windowReads.planningMedia(for: fixture.library)?.first {
            $0.id.relativePath.rawValue == "2024/IMG_1 copy.JPG"
        })
        let read = try Self.listing("b", of: other, at: Self.serverPrefix + "2024/IMG_1 copy.JPG")
        let unsized = listing.events.filter {
            if case .asset = $0 {
                true
            } else {
                false
            }
        }
        let server = MirrorServer(
            [read.events + unsized + [Self.complete], listing.events + [Self.complete]],
            details: ["a": listing.detail, "b": read.detail]
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 2, deleted: 0, full: false))
        _ = try await fixture.store.setMediaChoice(.liked, for: [fixture.file.id])
        #expect(try await asset(fixture.asset, fixture.store)?.mediaChoice == .liked, "one photo, so one choice")

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await ids(.allMedia, fixture.store).contains(fixture.asset) == false)
        #expect(try await asset(fixture.asset, fixture.store)?.mediaChoice == .liked)
        await fixture.store.shutdown()
    }

    /// An asset the server has not read, listed with another modification time than the file's,
    /// is another version: with no size to compare, the time alone tells them apart, so a Like
    /// on the file is not the asset's.
    @Test func anAssetTheServerHasNotReadOfAnotherVersionIsTwoPhotos() async throws {
        let fixture = try await fixture(digested: true, secondCopy: true)
        let modified = try #require(fixture.file.contentModifiedAt).addingTimeInterval(60)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG", modified: modified)
        let other = try #require(await fixture.store.windowReads.planningMedia(for: fixture.library)?.first {
            $0.id.relativePath.rawValue == "2024/IMG_1 copy.JPG"
        })
        let read = try Self.listing("b", of: other, at: Self.serverPrefix + "2024/IMG_1 copy.JPG")
        let unsized = listing.events.filter {
            if case .asset = $0 {
                true
            } else {
                false
            }
        }
        let server = MirrorServer(
            [read.events + unsized + [Self.complete]], details: ["a": listing.detail, "b": read.detail]
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 2, deleted: 0, full: false))
        _ = try await fixture.store.setMediaChoice(.liked, for: [fixture.file.id])
        #expect(try await asset(fixture.asset, fixture.store)?.mediaChoice != .liked)
        await fixture.store.shutdown()
    }

    /// An asset the server has not read yet, with no library file it is one photo with, is
    /// hidden by its source until the server reads it, as the server's own timeline hides it
    /// (v84), and the account counts it; the size the server reports once it has read it
    /// shows it.
    @Test func anAssetTheServerHasNotReadIsHiddenUntilItHas() async throws {
        let fixture = try await fixture(digested: true)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2023/IMG_1.JPG")
        let unsized = listing.events.filter {
            if case .asset = $0 {
                true
            } else {
                false
            }
        }
        let server = MirrorServer(
            [unsized + [Self.complete], listing.events + [Self.complete]],
            details: ["a": listing.detail]
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await ids(.allMedia, fixture.store) == [fixture.file.id], "the unread asset is not shown")
        #expect(try await fixture.store.backgroundReads.unreadSourceItemCount(rootPath: fixture.account) == 1)

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await ids(.allMedia, fixture.store).count == 2, "read, it is shown")
        #expect(try await fixture.store.backgroundReads.unreadSourceItemCount(rootPath: fixture.account) == 0)
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
        #expect(try await fixture.store.backgroundReads.mirrorProbes(account: fixture.account).map(\.serverPrefixes) == [[]])
        #expect(try await ids(.allMedia, fixture.store).count == 2)
        await fixture.store.shutdown()
    }

    /// A prefix that pairs every file is kept, and the probe has no candidate left to ask
    /// about: the pass asks the server one path and no more.
    @Test func aPrefixThatPairsAFileIsKeptWithNoRequest() async throws {
        let fixture = try await fixture(digested: false)
        let listing = try Self.listing("a", of: fixture.file, at: Self.serverPrefix + "2024/IMG_1.JPG")
        let server = MirrorServer([listing.events + [Self.complete]], details: ["a": listing.detail])
        let sync = ImmichCatalogSync(
            rootPath: fixture.account, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(server.requestedDetails == ["a"])
        let probes = try await fixture.store.backgroundReads.mirrorProbes(account: fixture.account)
        #expect(probes.map(\.serverPrefixes) == [[Self.serverPrefix]])
        #expect(probes.map(\.candidate) == [nil])
        await fixture.store.shutdown()
    }

    /// Immich's path checksum is the SHA-1 of `path:` and the server path's bytes; the prefix
    /// is the server path before the relative path, compared as characters, so a name in the
    /// other Unicode normal form is the same path, and a server path that teaches none says why.
    @Test func thePathChecksumAndServerPrefixAreImmichs() throws {
        let checksum = try #require(ImmichAsset.pathChecksum(checksum: "YSh/w9kgVtWGbzD5f2uUP5/HYag=", libraryID: "lib"))
        #expect(ImmichPathChecksum(serverPath: "/mnt/onedrive/Pictures/Camera Roll/2024/IMG_1.JPG") == checksum)
        #expect(ImmichAsset.pathChecksum(checksum: "YSh/w9kgVtWGbzD5f2uUP5/HYag=", libraryID: nil) == nil)
        #expect(ImmichAsset.contentDigest(checksum: "YSh/w9kgVtWGbzD5f2uUP5/HYag=", libraryID: "lib", assetID: "a") == nil)

        let relative = MediaRelativePath(rawValue: "2024/IMG_1.JPG")
        #expect(MirrorGateway.serverPrefix(of: "/mnt/od/2024/IMG_1.JPG", relativePath: relative) == "/mnt/od/")
        #expect(MirrorGateway.serverPrefix(of: "/mnt/od/x2024/IMG_1.JPG", relativePath: relative) == nil)
        #expect(MirrorGateway.serverPrefix(of: "/2024/IMG_1.JPG", relativePath: relative) == nil)
        // The same name in its decomposed form is the same path, and the prefix is the server's.
        let composed = MediaRelativePath(rawValue: "P\u{00E4}iv\u{00E4}/IMG_1.JPG")
        let decomposedServerPath = "/od/Sa\u{0308}ilo\u{0308}/Pa\u{0308}iva\u{0308}/IMG_1.JPG"
        #expect(MirrorGateway.serverPrefix(of: decomposedServerPath, relativePath: composed) == "/od/Sa\u{0308}ilo\u{0308}/")
        let mixed = MirrorGateway.Candidate(
            relativePath: composed, assetPath: MediaRelativePath(rawValue: "b/IMG_1.JPG"), assetID: "b",
            pathChecksum: ImmichPathChecksum(serverPath: decomposedServerPath)
        )
        #expect(MirrorGateway.prefix(of: decomposedServerPath, for: mixed) == .success("/od/Sa\u{0308}ilo\u{0308}/"))
        // Either form of a path names its checksum, and an ASCII path has one form.
        let decomposed = ImmichPathChecksum(serverPath: decomposedServerPath)
        #expect(decomposed.names(serverPath: "/od/S\u{00E4}il\u{00F6}/P\u{00E4}iv\u{00E4}/IMG_1.JPG"))
        #expect(!decomposed.names(serverPath: "/od/Saila/Paiva/IMG_1.JPG"))
        #expect(ImmichPathChecksum.everyForm(ofServerPath: "/od/2024/IMG_1.JPG").count == 1)
        #expect(ImmichPathChecksum.everyForm(ofServerPath: decomposedServerPath).count == 2)
        #expect(MirrorGateway.folder(of: "/od/2024/IMG_1.JPG") == "/od/2024")

        let candidate = MirrorGateway.Candidate(
            relativePath: relative, assetPath: MediaRelativePath(rawValue: "a/IMG_1.JPG"), assetID: "a",
            pathChecksum: ImmichPathChecksum(serverPath: "/mnt/od/2024/IMG_1.JPG")
        )
        #expect(MirrorGateway.prefix(of: "/mnt/od/2024/IMG_1.JPG", for: candidate) == .success("/mnt/od/"))
        #expect(MirrorGateway.prefix(of: nil, for: candidate) == .failure(.noPath))
        #expect(MirrorGateway.prefix(of: "/mnt/od/2023/IMG_1.JPG", for: candidate) == .failure(.tailMismatch(sharedComponents: 1)))
        #expect(MirrorGateway.prefix(of: "/other/2024/IMG_1.JPG", for: candidate) == .failure(.checksumMismatch))
    }
}
