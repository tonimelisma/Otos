import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0046 §5: an account's rows follow its server's sync stream. A scripted stream
/// stands in for the server: each pass hands out the next script, and every
/// acknowledgement is recorded with what the catalog held when it was sent.
@Suite(.testDirectory)
struct ImmichCatalogSyncTests {
    private static let server = URL(string: "https://photos.example.com")!

    /// A server whose passes are scripted. `failAfter` throws a transport error after that
    /// many lines of a pass, as a dropped connection would.
    private final class ScriptedServer: ImmichSyncSource, Sendable {
        private let passes: Mutex<[[ImmichSyncEvent]]>
        private let failures: Mutex<[Int?]>
        private let acked = Mutex<[[String]]>([])
        private let onAck: @Sendable ([String]) async -> Void

        init(
            _ passes: [[ImmichSyncEvent]],
            failAfter: [Int?] = [],
            onAck: @escaping @Sendable ([String]) async -> Void = { _ in }
        ) {
            self.passes = Mutex(passes)
            failures = Mutex(failAfter)
            self.onAck = onAck
        }

        var acknowledgements: [[String]] {
            acked.withLock { $0 }
        }

        func events() async throws -> any AsyncSequence<ImmichSyncEvent, any Error> {
            let lines = passes.withLock { $0.isEmpty ? [] : $0.removeFirst() }
            let failAfter = failures.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            return AsyncThrowingStream<ImmichSyncEvent, any Error> { continuation in
                for (index, line) in lines.enumerated() {
                    if let failAfter, index == failAfter {
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                        return
                    }
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }

        func acknowledge(_ acks: [String]) async throws {
            await onAck(acks)
            acked.withLock { $0.append(acks) }
        }
    }

    private struct Fixture {
        let store: CatalogStore
        let rootPath: LibraryRootPath

        static func make() async throws -> Fixture {
            let staging = try makeTestDirectory().appending(path: "RemoteStaging", directoryHint: .isDirectory)
            let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(
                server: ImmichCatalogSyncTests.server, userID: "user-1", displayName: "Family",
                stagingContainer: staging
            )
            return Fixture(store: store, rootPath: rootPath)
        }

        func visible() async throws -> [String] {
            let ids = try await store.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .library(rootPath)), availableLibraryPaths: [rootPath]
            ).ids
            return ids.map(\.relativePath.rawValue).sorted()
        }

        func size(of path: String) async throws -> Int64? {
            let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: path))
            return try await store.mediaAssets(for: [id])[id]?.byteSize
        }
    }

    private static func asset(
        _ id: String,
        name: String = "IMG.JPG",
        type: ImmichAsset.AssetType = .image,
        visibility: ImmichAsset.Visibility = .timeline,
        trashed: Bool = false
    ) -> ImmichSyncEvent {
        .asset(ImmichAsset(
            id: id,
            originalFileName: name,
            type: type,
            visibility: visibility,
            deletedAt: trashed ? Date(timeIntervalSince1970: 1_700_000_500) : nil,
            fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ), ack: "AssetV2|\(id)")
    }

    private static func exif(_ id: String, size: Int64) -> ImmichSyncEvent {
        .exif(assetID: id, fileSize: size, ack: "AssetExifV1|\(id)")
    }

    private static let complete = ImmichSyncEvent.complete(ack: "SyncCompleteV1|1")

    @Test func aPassListsImagesAndVideosWithTheirSizesAndSkipsWhatIsNotOtosMedia() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([[
            Self.asset("a", name: "IMG_1.JPG"),
            Self.asset("b", name: "CLIP.MOV", type: .video, visibility: .archive),
            Self.asset("c", name: "VOICE.M4A", type: .audio),
            Self.asset("d", name: "MOTION.MOV", type: .video, visibility: .hidden),
            Self.asset("e", name: "SECRET.JPG", visibility: .locked),
            Self.exif("a", size: 5_099_275),
            Self.exif("b", size: 2_414_759),
            Self.complete,
        ]])
        let sync = ImmichCatalogSync(rootPath: fixture.rootPath, source: server, store: fixture.store)

        #expect(await sync.pass() == .synced(listed: 2, deleted: 1, full: false))
        #expect(try await fixture.visible() == ["a/IMG_1.JPG", "b/CLIP.MOV"])
        #expect(try await fixture.size(of: "a/IMG_1.JPG") == 5_099_275)
        #expect(try await fixture.size(of: "b/CLIP.MOV") == 2_414_759)
        // The newest ack of each type, once, after the Store applied the batch.
        #expect(server.acknowledgements == [["AssetExifV1|b", "AssetV2|e", "SyncCompleteV1|1"]])
        await fixture.store.shutdown()
    }

    /// An asset Immich trashes is hidden and keeps its overlay; restoring it shows it with
    /// that overlay. A permanent deletion purges it.
    @Test func trashHidesAndKeepsOverlayAndAPermanentDeletionPurges() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([
            [Self.asset("a"), Self.exif("a", size: 10), Self.complete],
            [Self.asset("a", trashed: true), Self.complete],
            [Self.asset("a"), Self.complete],
            [.assetDeleted(assetID: "a", ack: "AssetDeleteV1|a"), Self.complete],
        ])
        let sync = ImmichCatalogSync(rootPath: fixture.rootPath, source: server, store: fixture.store)
        let id = MediaAssetID(libraryRootPath: fixture.rootPath, relativePath: MediaRelativePath(rawValue: "a/IMG.JPG"))

        _ = await sync.pass()
        _ = try await fixture.store.setMediaChoices([id: .liked])
        _ = await sync.pass()
        #expect(try await fixture.visible().isEmpty)
        #expect(try await fixture.store.mediaAssets(for: [id])[id]?.mediaChoice == .liked)

        _ = await sync.pass()
        #expect(try await fixture.visible() == ["a/IMG.JPG"])
        #expect(try await fixture.store.mediaAssets(for: [id])[id]?.mediaChoice == .liked)
        // A line about the asset without its EXIF keeps the size the catalog holds.
        #expect(try await fixture.size(of: "a/IMG.JPG") == 10)

        #expect(await sync.pass() == .synced(listed: 0, deleted: 1, full: false))
        #expect(try await fixture.store.mediaAssets(for: [id])[id] == nil)
        await fixture.store.shutdown()
    }

    @Test func aSizeReportedInALaterPassReachesItsRow() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([
            [Self.asset("a"), Self.complete],
            [Self.exif("a", size: 42), Self.complete],
        ])
        let sync = ImmichCatalogSync(rootPath: fixture.rootPath, source: server, store: fixture.store)
        _ = await sync.pass()
        #expect(try await fixture.size(of: "a/IMG.JPG") == nil)
        _ = await sync.pass()
        #expect(try await fixture.size(of: "a/IMG.JPG") == 42)
        await fixture.store.shutdown()
    }

    /// A reset discards the cursor: the reset is acknowledged, the stream read again in
    /// full, and a row the full listing no longer names is purged.
    @Test func aResetResyncsInFullAndPurgesWhatItNoLongerLists() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([
            [Self.asset("a"), Self.asset("b"), Self.complete],
            [.reset(ack: "SyncResetV1|1")],
            [Self.asset("a"), Self.complete],
        ])
        let sync = ImmichCatalogSync(rootPath: fixture.rootPath, source: server, store: fixture.store)
        _ = await sync.pass()
        #expect(try await fixture.visible() == ["a/IMG.JPG", "b/IMG.JPG"])

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: true))
        #expect(try await fixture.visible() == ["a/IMG.JPG"])
        #expect(server.acknowledgements.contains(["SyncResetV1|1"]))
        await fixture.store.shutdown()
    }

    /// Every acknowledgement follows the Store's apply of its lines: a batch the
    /// connection dropped inside is never acknowledged, and the next pass replays it.
    @Test func aDroppedConnectionAcknowledgesOnlyAppliedBatches() async throws {
        let fixture = try await Fixture.make()
        let store = fixture.store
        let rootPath = fixture.rootPath
        let heldAtAck = Mutex<[[String]]>([])
        var first = (0 ..< ImmichCatalogSync.batchSize).map { Self.asset("x\($0)") }
        first += [Self.asset("late")]
        let server = ScriptedServer(
            [first, [Self.asset("late"), Self.complete]],
            failAfter: [ImmichCatalogSync.batchSize],
            onAck: { _ in
                let ids = await (try? store.orderedAssetIDs(
                    for: CatalogQueryDescriptor(scope: .library(rootPath)), availableLibraryPaths: [rootPath]
                ).ids) ?? []
                heldAtAck.withLock { $0.append(ids.map(\.relativePath.rawValue)) }
            }
        )
        let sync = ImmichCatalogSync(rootPath: rootPath, source: server, store: store)

        #expect(await sync.pass() == .serverFailed(.unreachable(.networkConnectionLost)))
        #expect(server.acknowledgements.count == 1)
        #expect(heldAtAck.withLock { $0.first?.count } == ImmichCatalogSync.batchSize)
        #expect(try await !(fixture.visible().contains("late/IMG.JPG")))

        _ = await sync.pass()
        #expect(try await fixture.visible().contains("late/IMG.JPG"))
        await store.shutdown()
    }

    /// `run()` is the one loop: a request rings a pass, and passes never overlap.
    @Test func eachRequestedSyncRunsOnePass() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([[Self.asset("a"), Self.complete], [Self.asset("b"), Self.complete]])
        let sync = ImmichCatalogSync(rootPath: fixture.rootPath, source: server, store: fixture.store)
        let loop = Task { await sync.run() }
        sync.requestSync()
        try await waitUntil { await (try? fixture.visible()) == ["a/IMG.JPG"] }
        sync.requestSync()
        try await waitUntil { await (try? fixture.visible()) == ["a/IMG.JPG", "b/IMG.JPG"] }
        sync.finish()
        await loop.value
        await fixture.store.shutdown()
    }

    @Test func aFileNameIsOnePathComponent() {
        #expect(ImmichCatalogSync.fileName("IMG_1.JPG", fallback: "id") == "IMG_1.JPG")
        #expect(ImmichCatalogSync.fileName("a/b.jpg", fallback: "id") == "a:b.jpg")
        #expect(ImmichCatalogSync.fileName("", fallback: "id") == "id")
        #expect(ImmichCatalogSync.fileName("..", fallback: "id") == "id")
    }
}
