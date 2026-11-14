import CoreGraphics
import Foundation
import ImageIO
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
    /// A fact a test turns on while the code under test reads it.
    private final class Flag: Sendable {
        private let value = Mutex(false)

        var isSet: Bool {
            value.withLock { $0 }
        }

        func set() {
            value.withLock { $0 = true }
        }
    }

    private final class ScriptedServer: ImmichSyncSource, Sendable {
        private let passes: Mutex<[[ImmichSyncEvent]]>
        private let failures: Mutex<[Int?]>
        private let acked = Mutex<[[String]]>([])
        private let onAck: @Sendable ([String]) async -> Void
        private let previews: @Sendable (String) throws -> Data
        private let previewRequests = Mutex<[String]>([])
        private let details: [String: ImmichAssetDetail]
        private let detailRequests = Mutex<[String]>([])
        private let fromZero = Mutex<[Bool]>([])

        init(
            _ passes: [[ImmichSyncEvent]],
            failAfter: [Int?] = [],
            onAck: @escaping @Sendable ([String]) async -> Void = { _ in },
            previews: @escaping @Sendable (String) throws -> Data = { _ in throw URLError(.badServerResponse) },
            details: [String: ImmichAssetDetail] = [:]
        ) {
            self.passes = Mutex(passes)
            failures = Mutex(failAfter)
            self.onAck = onAck
            self.previews = previews
            self.details = details
        }

        var requestedDetails: [String] {
            detailRequests.withLock { $0 }
        }

        func asset(id: String) async throws -> ImmichAssetDetail {
            detailRequests.withLock { $0.append(id) }
            guard let detail = details[id] else {
                throw ImmichClientError.refused(status: 404)
            }
            return detail
        }

        var requestedPreviews: [String] {
            previewRequests.withLock { $0 }
        }

        func preview(assetID: String) async throws -> Data {
            previewRequests.withLock { $0.append(assetID) }
            return try previews(assetID)
        }

        var acknowledgements: [[String]] {
            acked.withLock { $0 }
        }

        /// Whether each stream asked for was asked from zero, in order.
        var streamsFromZero: [Bool] {
            fromZero.withLock { $0 }
        }

        func events(fromZero: Bool) async throws -> any AsyncSequence<ImmichSyncEvent, any Error> {
            self.fromZero.withLock { $0.append(fromZero) }
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

    /// A server that keeps a cursor, as Immich does: a stream resumes after the newest line
    /// acknowledged, `fromZero` (`reset: true`) discards the cursor first, and a pending reset
    /// answers a plain stream with `SyncResetV1` until it is acknowledged
    /// (`docs/research/2026-11-13-immich-sync-reset.md`). `failAfter` drops each stream in
    /// turn after that many lines.
    private final class ResumingServer: ImmichSyncSource, Sendable {
        private struct State {
            var listing: [ImmichSyncEvent]
            var cursor = 0
            var pendingReset = false
            var failures: [Int?] = []
            var fromZero: [Bool] = []
        }

        private static let resetAck = "SyncResetV1|1"
        private let state: Mutex<State>

        init(_ listing: [ImmichSyncEvent]) {
            state = Mutex(State(listing: listing))
        }

        /// What the account holds from now on, and whether the server has lost the
        /// session's history; `failAfter` scripts the next streams' drops.
        func serve(_ listing: [ImmichSyncEvent], pendingReset: Bool, failAfter: [Int?] = []) {
            state.withLock {
                $0.listing = listing
                $0.pendingReset = pendingReset
                $0.failures = failAfter
            }
        }

        var streamsFromZero: [Bool] {
            state.withLock(\.fromZero)
        }

        func events(fromZero: Bool) async throws -> any AsyncSequence<ImmichSyncEvent, any Error> {
            let (lines, failAfter) = state.withLock { state in
                state.fromZero.append(fromZero)
                if fromZero {
                    state.cursor = 0
                    state.pendingReset = false
                }
                let failAfter = state.failures.isEmpty ? nil : state.failures.removeFirst()
                guard !state.pendingReset else {
                    return ([ImmichSyncEvent.reset(ack: Self.resetAck)], failAfter)
                }
                return (Array(state.listing[state.cursor...]) + [ImmichCatalogSyncTests.complete], failAfter)
            }
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
            state.withLock { state in
                for ack in acks {
                    if ack == Self.resetAck {
                        state.cursor = 0
                        state.pendingReset = false
                    } else if let index = state.listing.firstIndex(where: { $0.ack == ack }) {
                        state.cursor = max(state.cursor, index + 1)
                    }
                }
            }
        }

        func preview(assetID _: String) async throws -> Data {
            throw URLError(.badServerResponse)
        }

        func asset(id _: String) async throws -> ImmichAssetDetail {
            throw ImmichClientError.refused(status: 404)
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
        trashed: Bool = false,
        modified: TimeInterval = 1_700_000_000,
        hasPreview: Bool = true,
        motion: String? = nil
    ) -> ImmichSyncEvent {
        .asset(ImmichAsset(
            id: id,
            originalFileName: name,
            type: type,
            visibility: visibility,
            deletedAt: trashed ? Date(timeIntervalSince1970: 1_700_000_500) : nil,
            fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileModifiedAt: Date(timeIntervalSince1970: modified),
            hasPreview: hasPreview,
            livePhotoVideoID: motion
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
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

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
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
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
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
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
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        _ = await sync.pass()
        #expect(try await fixture.visible() == ["a/IMG.JPG", "b/IMG.JPG"])

        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: true))
        #expect(try await fixture.visible() == ["a/IMG.JPG"])
        #expect(server.acknowledgements.contains(["SyncResetV1|1"]))
        // The resync after the reset asked the server to read from zero.
        #expect(server.streamsFromZero == [false, false, true])
        #expect(try await fixture.store.sourceResyncOwed(rootPath: fixture.rootPath) == nil)
        await fixture.store.shutdown()
    }

    /// The resync a reset owes outlives a stream that drops after some of its batches were
    /// acknowledged. The server resumes a plain stream after those batches, so the next pass
    /// asks it to read from zero again: only a stream that lists everything and reaches its
    /// end purges what it no longer lists, and never a row an acknowledged batch carried.
    @Test func aResyncThatDropsAfterAcknowledgingABatchIsReadFromZeroAgain() async throws {
        let fixture = try await Fixture.make()
        let kept = (0 ..< ImmichCatalogSync.batchSize).map { Self.asset("x\($0)") }
        let server = ResumingServer(kept + [Self.asset("gone")])
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        #expect(await sync.pass() == .synced(listed: ImmichCatalogSync.batchSize + 1, deleted: 0, full: false))

        // `gone` was deleted past the server's audit retention: the server lost the cursor's
        // history, and the resync drops after its first batch was applied and acknowledged.
        server.serve(kept + [Self.asset("late")], pendingReset: true, failAfter: [nil, ImmichCatalogSync.batchSize])
        #expect(await sync.pass() == .serverFailed(.unreachable(.networkConnectionLost)))
        #expect(try await fixture.store.sourceResyncOwed(rootPath: fixture.rootPath) != nil)
        #expect(try await fixture.visible().contains("gone/IMG.JPG"))

        #expect(await sync.pass() == .synced(listed: ImmichCatalogSync.batchSize + 1, deleted: 0, full: true))
        let visible = try await fixture.visible()
        #expect(visible.count == ImmichCatalogSync.batchSize + 1)
        #expect(visible.contains("x0/IMG.JPG"))
        #expect(visible.contains("late/IMG.JPG"))
        #expect(!visible.contains("gone/IMG.JPG"))
        #expect(try await fixture.store.sourceResyncOwed(rootPath: fixture.rootPath) == nil)
        #expect(server.streamsFromZero == [false, false, true, true])

        // Settled: the next pass resumes from the cursor.
        #expect(await sync.pass() == .synced(listed: 0, deleted: 0, full: false))
        await fixture.store.shutdown()
    }

    /// A resync settles only the request it started from: one recorded while it ran (a new
    /// session, another reset) stays owed after it completes.
    @Test func aResyncRequestedWhileOneRunsStaysOwed() async throws {
        let fixture = try await Fixture.make()
        let store = fixture.store
        let first = try #require(try await store.requestSourceResync(rootPath: fixture.rootPath))
        let scan = try await store.beginSourceListing(rootPath: fixture.rootPath)
        let second = try #require(try await store.requestSourceResync(rootPath: fixture.rootPath))
        try await store.completeSourceResync(scan: scan, observedPaths: [], settling: first)
        #expect(try await store.sourceResyncOwed(rootPath: fixture.rootPath) == second)

        let next = try await store.beginSourceListing(rootPath: fixture.rootPath)
        try await store.completeSourceResync(scan: next, observedPaths: [], settling: second)
        #expect(try await store.sourceResyncOwed(rootPath: fixture.rootPath) == nil)
        await store.shutdown()
    }

    /// A root that cannot get a listing lease is not a teardown: the pass says so, and its
    /// owner tries again.
    @Test func aPassWithoutALeaseIsNotStopped() async throws {
        let fixture = try await Fixture.make()
        let sync = ImmichCatalogSync(
            rootPath: LibraryRootPath(rawValue: "/nowhere/"), source: ScriptedServer([[Self.complete]]),
            store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        #expect(await sync.pass() == .noLease)
        await fixture.store.shutdown()
    }

    /// A stream that ends before `SyncCompleteV1` was cut short: what it applied stays, but
    /// the pass is not a sync, so no one is told the catalog is current.
    @Test func aStreamCutShortIsNotASync() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([[Self.asset("a")]])
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        let reports = Mutex<[ImmichSyncReport]>([])
        let outcome = await sync.pass { report in reports.withLock { $0.append(report) } }
        #expect(outcome == .serverFailed(.malformedResponse))
        #expect(!reports.withLock { $0 }.contains(.listed))
        #expect(try await fixture.visible() == ["a/IMG.JPG"])
        await fixture.store.shutdown()
    }

    /// A pass reports that its server answered as soon as its first batch is applied and
    /// acknowledged, once, and before the pass ends, so a first sync that takes minutes is
    /// online while it runs. A stream that fails before any batch reports nothing.
    @Test func aPassReportsItsServerAnsweredBeforeItEnds() async throws {
        let fixture = try await Fixture.make()
        let lines = (0 ..< ImmichCatalogSync.batchSize * 2 + 1).map { Self.asset("x\($0)") }
        let server = ScriptedServer([lines, lines], failAfter: [ImmichCatalogSync.batchSize * 2, 0])
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        let acksWhenAnswered = Mutex<[Int]>([])
        let record: @Sendable (ImmichSyncReport) async -> Void = { report in
            if report == .answered {
                acksWhenAnswered.withLock { $0.append(server.acknowledgements.count) }
            }
        }

        let outcome = await sync.pass(onReport: record)
        #expect(outcome == .serverFailed(.unreachable(.networkConnectionLost)))
        #expect(acksWhenAnswered.withLock { $0 } == [1])

        _ = await sync.pass(onReport: record)
        #expect(acksWhenAnswered.withLock { $0 } == [1])
        await fixture.store.shutdown()
    }

    /// A pass reports its listing applied once the stream reaches its end and before any of
    /// the server's images is fetched, which on a first sync takes far longer; a pass whose
    /// stream fails reports no listing.
    @Test func aPassReportsItsListingBeforeItFetchesImages() async throws {
        let fixture = try await FileFixture.make()
        let preview = try Self.jpeg(width: 300, height: 200)
        let server = ScriptedServer(
            [[Self.asset("a"), Self.exif("a", size: 1), Self.complete], [Self.asset("b"), Self.complete]],
            failAfter: [nil, 1],
            previews: { _ in preview }
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        let previewsWhenListed = Mutex<[Int]>([])
        let record: @Sendable (ImmichSyncReport) async -> Void = { report in
            if report == .listed {
                previewsWhenListed.withLock { $0.append(server.requestedPreviews.count) }
            }
        }

        #expect(await sync.pass(onReport: record) == .synced(listed: 1, deleted: 0, full: false))
        #expect(previewsWhenListed.withLock { $0 } == [0])
        #expect(server.requestedPreviews == ["a"])
        _ = await sync.pass(onReport: record)
        #expect(previewsWhenListed.withLock { $0 } == [0])
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
        let sync = ImmichCatalogSync(
            rootPath: rootPath, source: server, store: store, volumeCapacity: ampleVolumeCapacity
        )

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
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
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

    // MARK: - Source products (ADR 0046 §7)

    /// A JPEG of `width` × `height`, as Immich's preview endpoint serves.
    private static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private struct FileFixture {
        let store: CatalogStore
        let rootPath: LibraryRootPath
        let directory: URL

        static func make() async throws -> FileFixture {
            let temp = try makeTestDirectory()
            let store = CatalogStore(location: .databaseFile(temp.appending(path: "Catalog.sqlite")))
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(
                server: ImmichCatalogSyncTests.server, userID: "user-1", displayName: "Family",
                stagingContainer: temp.appending(path: "RemoteStaging")
            )
            return try FileFixture(store: store, rootPath: rootPath, directory: #require(store.thumbnailDirectory))
        }

        func id(_ path: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: path))
        }

        func image(_ name: String) -> CGImage? {
            ThumbnailStore.load(name, in: directory)
        }
    }

    /// A pass fetches the server's preview once for each row owed one: a still gets the
    /// preview at the server's size and a thumbnail drawn from it, a video only the
    /// thumbnail. A file that changes is owed new ones; nothing else is asked for again.
    @Test func aPassFetchesTheServersPreviewForEveryRowOwedOne() async throws {
        let fixture = try await FileFixture.make()
        let preview = try Self.jpeg(width: 600, height: 400)
        let server = ScriptedServer(
            [
                [
                    Self.asset("a", name: "IMG_1.JPG"), Self.asset("v", name: "CLIP.MOV", type: .video),
                    Self.exif("a", size: 10), Self.exif("v", size: 20), Self.complete,
                ],
                [Self.complete],
                [Self.asset("a", name: "IMG_1.JPG", modified: 1_700_000_900), Self.complete],
            ],
            previews: { _ in preview }
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        _ = await sync.pass()
        #expect(server.requestedPreviews.sorted() == ["a", "v"])
        let still = fixture.id("a/IMG_1.JPG")
        let video = fixture.id("v/CLIP.MOV")
        let assets = try await fixture.store.mediaAssets(for: [still, video])
        #expect(assets[still]?.thumbnailPath == ThumbnailStore.relativeName(for: still))
        #expect(assets[video]?.thumbnailPath == ThumbnailStore.relativeName(for: video))
        // The server's size, not upscaled to Otos's 2560 px; the thumbnail Otos's 256 px.
        #expect(fixture.image(ThumbnailStore.previewRelativeName(for: still))?.width == 600)
        #expect(fixture.image(ThumbnailStore.relativeName(for: still))?.width == 256)
        #expect(fixture.image(ThumbnailStore.previewRelativeName(for: video)) == nil)
        // Not a rendering: the row still owes Otos's own.
        #expect(assets[still]?.renderedSourceSize == nil)

        _ = await sync.pass()
        #expect(server.requestedPreviews.count == 2)
        _ = await sync.pass()
        #expect(server.requestedPreviews.sorted() == ["a", "a", "v"])
        await fixture.store.shutdown()
    }

    /// An edited still shows Otos's rendering, never the server's (ADR 0046 §7): once it
    /// has an edit, a changed file does not ask for the server's preview again, on this
    /// pass or any later one.
    @Test func anEditedStillIsNeverOwedTheServersPreview() async throws {
        let fixture = try await FileFixture.make()
        let preview = try Self.jpeg(width: 600, height: 400)
        let server = ScriptedServer(
            [
                [Self.asset("a", name: "IMG_1.JPG"), Self.exif("a", size: 10), Self.complete],
                [Self.asset("a", name: "IMG_1.JPG", modified: 1_700_000_900), Self.complete],
                [Self.complete],
            ],
            previews: { _ in preview }
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        let still = fixture.id("a/IMG_1.JPG")

        _ = await sync.pass()
        #expect(server.requestedPreviews == ["a"])
        _ = try await fixture.store.setEditRecipe(EditRecipe(exposure: 1), for: still)

        _ = await sync.pass()
        _ = await sync.pass()
        #expect(server.requestedPreviews == ["a"])
        #expect(try await fixture.store.sourceProductCandidates(rootPath: fixture.rootPath, after: nil, limit: 10)
            .isEmpty)
        await fixture.store.shutdown()
    }

    /// A preview the server answers it does not have is skipped, not an end to the pass,
    /// and is not asked for again: not by the next pass, only once a later listing of the
    /// asset says the server has made its previews. Any other refusal still ends the pass.
    @Test func aPreviewTheServerDoesNotHaveIsNotAskedForAgain() async throws {
        let fixture = try await FileFixture.make()
        let preview = try Self.jpeg(width: 300, height: 200)
        let previewMade = Flag()
        let server = ScriptedServer(
            [
                [Self.asset("a"), Self.asset("b"), Self.asset("c"), Self.exif("a", size: 1), Self.exif("b", size: 1),
                 Self.exif("c", size: 1), Self.complete],
                [Self.complete],
                [Self.asset("a"), Self.complete],
            ],
            previews: { id in
                guard id != "a" || previewMade.isSet else {
                    throw ImmichClientError.refused(status: 404)
                }
                return preview
            }
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        _ = await sync.pass()
        #expect(server.requestedPreviews.sorted() == ["a", "b", "c"])
        #expect(try await fixture.store.sourceProductCandidates(rootPath: fixture.rootPath, after: nil, limit: 10)
            .isEmpty)

        _ = await sync.pass()
        #expect(server.requestedPreviews.sorted() == ["a", "b", "c"])

        previewMade.set()
        _ = await sync.pass()
        #expect(server.requestedPreviews.sorted() == ["a", "a", "b", "c"])
        #expect(try await fixture.store.sourceProductCandidates(rootPath: fixture.rootPath, after: nil, limit: 10)
            .isEmpty)

        await fixture.store.shutdown()

        let signedOutFixture = try await FileFixture.make()
        let signedOut = ScriptedServer(
            [[Self.asset("d"), Self.exif("d", size: 1), Self.complete]],
            previews: { _ in throw ImmichClientError.unauthorized }
        )
        let refusedSession = ImmichCatalogSync(
            rootPath: signedOutFixture.rootPath, source: signedOut, store: signedOutFixture.store,
            volumeCapacity: ampleVolumeCapacity
        )
        _ = await refusedSession.pass()
        #expect(await refusedSession.fetchProducts() == .serverFailed(made: 0))
        #expect(try await signedOutFixture.store.sourceProductCandidates(
            rootPath: signedOutFixture.rootPath, after: nil, limit: 10
        ).map(\.sourceItemID) == ["d"])
        await signedOutFixture.store.shutdown()

        // A server failing now (a 5xx, a 429) says nothing about the asset: the preview it
        // had already given is kept, and the failed one stays owed, never recorded absent.
        for status in [429, 500, 503] {
            let failingFixture = try await FileFixture.make()
            let failing = ScriptedServer(
                [[Self.asset("e"), Self.asset("f"), Self.exif("e", size: 1), Self.exif("f", size: 1), Self.complete]],
                previews: { id in
                    guard id == "e" else {
                        throw ImmichClientError.refused(status: status)
                    }
                    return preview
                }
            )
            let failingSync = ImmichCatalogSync(
                rootPath: failingFixture.rootPath, source: failing, store: failingFixture.store,
                volumeCapacity: ampleVolumeCapacity
            )
            _ = await failingSync.pass()
            #expect(try await failingFixture.store.sourceProductCandidates(
                rootPath: failingFixture.rootPath, after: nil, limit: 10
            ).map(\.sourceItemID) == ["f"])
            #expect(await failingSync.fetchProducts() == .serverFailed(made: 0))
            await failingFixture.store.shutdown()
        }
    }

    /// An asset the server lists without a thumbhash has no previews yet, and a Live
    /// Photo's motion part never has any (Immich makes none for a hidden asset): neither is
    /// asked for its images, so a pass asks for only the still's.
    @Test func anAssetListedWithoutPreviewsIsNotAskedForThem() async throws {
        let fixture = try await FileFixture.make()
        let preview = try Self.jpeg(width: 300, height: 200)
        let server = ScriptedServer(
            [[
                Self.motion("m"), Self.exif("m", size: 2000),
                Self.asset("s", motion: "m"), Self.exif("s", size: 1000),
                Self.asset("n", hasPreview: false), Self.exif("n", size: 1),
                Self.complete,
            ]],
            previews: { _ in preview }
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        _ = await sync.pass()
        #expect(server.requestedPreviews == ["s"])
        #expect(try await fixture.store.sourceProductCandidates(rootPath: fixture.rootPath, after: nil, limit: 10)
            .isEmpty)
        await fixture.store.shutdown()
    }

    /// A preview that is no image is skipped and asked for again next pass; a server that
    /// stops answering ends the product pass, and the rest stay owed.
    @Test func productsTheServerCannotGiveStayOwed() async throws {
        let fixture = try await FileFixture.make()
        let preview = try Self.jpeg(width: 300, height: 200)
        let server = ScriptedServer(
            [[Self.asset("a"), Self.asset("b"), Self.asset("c"), Self.exif("a", size: 1), Self.exif("b", size: 1),
              Self.exif("c", size: 1), Self.complete]],
            previews: { id in
                switch id {
                case "a": Data("not an image".utf8)
                case "b": preview
                default: throw URLError(.networkConnectionLost)
                }
            }
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        _ = await sync.pass()
        #expect(await sync.fetchProducts() == .serverFailed(made: 0))
        let owed = try await fixture.store.sourceProductCandidates(rootPath: fixture.rootPath, after: nil, limit: 10)
        #expect(owed.map(\.sourceItemID) == ["a", "c"])
        await fixture.store.shutdown()
    }

    /// A folder listed in full purges the rows inside it that the batch does not list, and
    /// never a sibling: not one whose name sorts inside the folder's range (`a-b`, `a.jpg`),
    /// nor one after it (`a2`).
    @Test func aCompleteFolderPurgesOnlyTheRowsInsideIt() async throws {
        let fixture = try await FileFixture.make()
        let store = fixture.store
        func item(_ path: String) -> SourceListedItem {
            SourceListedItem(
                file: ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: path),
                    name: MediaRelativePath(rawValue: path).fileName,
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 10,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                sourceItemID: path,
                isHiddenBySource: false,
                sourceHasProducts: true
            )
        }
        let paths = ["a-b/IMG.JPG", "a.jpg", "a/IMG.JPG", "a/IMG.MOV", "a/sub/IMG.JPG", "a2/IMG.JPG"]
        let scan = try await store.beginSourceListing(rootPath: fixture.rootPath)
        try await store.applySourceListingChanges(SourceListingChanges(listed: paths.map(item)), scan: scan)
        try await store.applySourceListingChanges(
            SourceListingChanges(listed: [item("a/IMG.JPG")], completeFolders: ["a"]), scan: scan
        )
        await store.endSourceListing(scan: scan)

        let ids = paths.map(fixture.id)
        let kept = try await store.mediaAssets(for: ids).keys.map(\.relativePath.rawValue).sorted()
        #expect(kept == ["a-b/IMG.JPG", "a.jpg", "a/IMG.JPG", "a2/IMG.JPG"])
        await store.shutdown()
    }

    /// A batch that only adds rows is announced as added, which the owners of derived facts
    /// do not read; a batch that changes, hides or deletes a row the catalog holds is a
    /// catalog change everyone hears.
    @Test func aBatchOfNewRowsIsAnnouncedAsAddedAndAChangeToAHeldRowIsNot() async throws {
        let fixture = try await FileFixture.make()
        let store = fixture.store
        func item(_ id: String, size: Int64 = 10, hidden: Bool = false) -> SourceListedItem {
            SourceListedItem(
                file: ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: "\(id)/IMG.JPG"),
                    name: "IMG.JPG",
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: size,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                sourceItemID: id,
                isHiddenBySource: hidden,
                sourceHasProducts: true
            )
        }
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let stream = await store.changeNotifications()
        let recording = Task {
            for await change in stream {
                await changes.append(change)
            }
        }
        defer { recording.cancel() }
        let scan = try await store.beginSourceListing(rootPath: fixture.rootPath)
        // The lease announces itself; each batch after it is one change of its own.
        #expect(await changes.waitForValues { $0.count == 1 } == [.catalogChanged])
        func apply(_ batch: SourceListingChanges) async throws -> CatalogStoreChange? {
            let before = await changes.count()
            try await store.applySourceListingChanges(batch, scan: scan)
            return await changes.waitForValues { $0.count > before }.last
        }

        #expect(try await apply(SourceListingChanges(listed: [item("a"), item("b", hidden: true)])) == .assetsAdded)
        #expect(try await apply(SourceListingChanges(listed: [item("a", size: 20), item("c")])) == .catalogChanged)
        #expect(try await apply(SourceListingChanges(listed: [item("c", hidden: true)])) == .catalogChanged)
        #expect(try await apply(SourceListingChanges(sizesBySourceItem: ["b": 30])) == .catalogChanged)
        #expect(try await apply(SourceListingChanges(deletedSourceItems: ["a"])) == .catalogChanged)
        await store.endSourceListing(scan: scan)
        await store.shutdown()
    }

    /// A bulk write leaves the WAL file no larger than the Store's budget: past it, the
    /// Store checkpoints the log empty before the write returns.
    @Test func aListingBatchLeavesTheWALWithinItsBudget() async throws {
        for budget in [CatalogStore.defaultWALByteBudget, 0] {
            let temp = try makeTestDirectory()
            let file = temp.appending(path: "Catalog.sqlite")
            let wal = file.path(percentEncoded: false) + "-wal"
            func walBytes() throws -> Int {
                try #require(FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int)
            }
            let store = CatalogStore(location: .databaseFile(file), walByteBudget: budget)
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(
                server: Self.server, userID: "user-1", displayName: "Family",
                stagingContainer: temp.appending(path: "RemoteStaging")
            )
            let scan = try await store.beginSourceListing(rootPath: rootPath)
            let items = (0 ..< 200).map { index in
                SourceListedItem(
                    file: ScannedMediaFile(
                        relativePath: MediaRelativePath(rawValue: "asset-\(index)/IMG.JPG"),
                        name: "IMG.JPG",
                        contentTypeIdentifier: "public.jpeg",
                        byteSize: 10,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                    ),
                    sourceItemID: "asset-\(index)",
                    isHiddenBySource: false,
                    sourceHasProducts: true
                )
            }
            try await store.applySourceListingChanges(SourceListingChanges(listed: items), scan: scan)
            if budget == 0 {
                #expect(try walBytes() == 0)
            } else {
                #expect(try walBytes() > 0)
            }
            await store.endSourceListing(scan: scan)
            await store.shutdown()
        }
    }

    // MARK: - Live Photos (ADR 0046 §2)

    private static func motion(_ id: String, name: String = "IMG_1.MOV") -> ImmichSyncEvent {
        asset(id, name: name, type: .video, visibility: .hidden, hasPreview: false)
    }

    private static func detail(_ id: String, name: String = "IMG_1.MOV", size: Int64) -> ImmichAssetDetail {
        ImmichAssetDetail(
            id: id, originalFileName: name, type: .video,
            fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileSize: size,
            hasPreview: false
        )
    }

    /// A motion part is listed in its still's folder under its own name, with its own
    /// size: the still's size never lands on it, nor its size on the still.
    @Test func aLivePhotosMotionPartIsListedInItsStillsFolder() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([[
            Self.motion("m"),
            Self.exif("m", size: 2000),
            Self.asset("s", name: "IMG_1.HEIC", motion: "m"),
            Self.exif("s", size: 1000),
            Self.complete,
        ]])
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        #expect(await sync.pass() == .synced(listed: 2, deleted: 0, full: false))
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC", "s/IMG_1.MOV"])
        #expect(try await fixture.size(of: "s/IMG_1.HEIC") == 1000)
        #expect(try await fixture.size(of: "s/IMG_1.MOV") == 2000)
        #expect(server.requestedDetails.isEmpty)
        let motionRow = MediaAssetID(libraryRootPath: fixture.rootPath, relativePath: MediaRelativePath(rawValue: "s/IMG_1.MOV"))
        #expect(try await fixture.store.sourceItemID(for: motionRow) == "m")
        await fixture.store.shutdown()
    }

    /// A still whose motion part's own lines were acknowledged in an earlier pass lists it
    /// from the server's facts. A later size for the motion reaches its row by its own ID.
    /// A still that no longer links it takes it out; deleting the still takes the rest.
    @Test func aStillListsAMotionPartFromAnEarlierPassAndDropsItWhenUnlinked() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer(
            [
                [Self.motion("m"), Self.exif("m", size: 2000), Self.complete],
                [Self.asset("s", name: "IMG_1.HEIC", motion: "m"), Self.exif("s", size: 1000), Self.complete],
                [Self.exif("m", size: 2500), Self.complete],
                [Self.asset("s", name: "IMG_1.HEIC"), Self.complete],
                [.assetDeleted(assetID: "s", ack: "AssetDeleteV1|s"), Self.complete],
            ],
            details: ["m": Self.detail("m", size: 2000)]
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        _ = await sync.pass()
        #expect(try await fixture.visible().isEmpty)
        _ = await sync.pass()
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC", "s/IMG_1.MOV"])
        #expect(server.requestedDetails == ["m"])
        #expect(try await fixture.size(of: "s/IMG_1.MOV") == 2000)
        _ = await sync.pass()
        #expect(try await fixture.size(of: "s/IMG_1.MOV") == 2500)
        #expect(try await fixture.size(of: "s/IMG_1.HEIC") == 1000)
        _ = await sync.pass()
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC"])
        _ = await sync.pass()
        #expect(try await fixture.visible().isEmpty)
        await fixture.store.shutdown()
    }

    /// A trashed still hides its motion part with it; a motion part deleted on its own
    /// leaves the still.
    @Test func aMotionPartFollowsItsStillIntoTheTrashAndGoesAloneWhenDeletedAlone() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([
            [Self.motion("m"), Self.exif("m", size: 2), Self.asset("s", name: "IMG_1.HEIC", motion: "m"), Self.complete],
            [Self.asset("s", name: "IMG_1.HEIC", trashed: true, motion: "m"), Self.complete],
            [Self.asset("s", name: "IMG_1.HEIC", motion: "m"), Self.complete],
            [.assetDeleted(assetID: "m", ack: "AssetDeleteV1|m"), Self.complete],
        ], details: ["m": Self.detail("m", size: 2)])
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        _ = await sync.pass()
        _ = await sync.pass()
        #expect(try await fixture.visible().isEmpty)
        _ = await sync.pass()
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC", "s/IMG_1.MOV"])
        _ = await sync.pass()
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC"])
        await fixture.store.shutdown()
    }

    /// A motion part's own line, arriving without its still's, refreshes the row it already
    /// has: its modification time and size, in its still's folder, hidden as the still is.
    @Test func aMotionPartsOwnLineRefreshesItsRowWhereItLives() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([
            [Self.motion("m"), Self.exif("m", size: 2), Self.asset("s", name: "IMG_1.HEIC", trashed: true, motion: "m"),
             Self.complete],
            [Self.asset("m", name: "IMG_1.MOV", type: .video, visibility: .hidden, modified: 1_700_000_900),
             Self.exif("m", size: 3), Self.complete],
        ])
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        _ = await sync.pass()
        _ = await sync.pass()
        let motion = MediaAssetID(libraryRootPath: fixture.rootPath, relativePath: MediaRelativePath(rawValue: "s/IMG_1.MOV"))
        let row = try #require(try await fixture.store.mediaAssets(for: [motion])[motion])
        #expect(row.byteSize == 3)
        #expect(row.contentModifiedAt == Date(timeIntervalSince1970: 1_700_000_900))
        #expect(try await fixture.store.sourceItemRows(["m"], in: fixture.rootPath)["m"]?.isHiddenBySource == true)
        #expect(server.requestedDetails.isEmpty)
        await fixture.store.shutdown()
    }

    /// A video listed on its own that becomes a Live Photo's motion part leaves its own
    /// folder: its `hidden` line removes the row it had there, whether the still comes in
    /// a later pass or the line follows the timeline line in the same batch, and the motion
    /// part is then one row, in its still's folder.
    @Test func aVideoThatBecomesAMotionPartLeavesItsOwnFolder() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer(
            [
                [Self.asset("m", name: "IMG_1.MOV", type: .video), Self.exif("m", size: 2), Self.complete],
                [Self.motion("m"), Self.complete],
                [Self.asset("s", name: "IMG_1.HEIC", motion: "m"), Self.complete],
                [Self.asset("v", name: "CLIP.MOV", type: .video), Self.motion("v", name: "CLIP.MOV"), Self.complete],
            ],
            details: ["m": Self.detail("m", size: 2)]
        )
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        _ = await sync.pass()
        #expect(try await fixture.visible() == ["m/IMG_1.MOV"])
        _ = await sync.pass()
        #expect(try await fixture.visible().isEmpty)
        _ = await sync.pass()
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC", "s/IMG_1.MOV"])
        let rows = try await fixture.store.sourceItemRows(["m"], in: fixture.rootPath)
        #expect(rows["m"]?.relativePath.rawValue == "s/IMG_1.MOV")

        _ = await sync.pass()
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC", "s/IMG_1.MOV"])
        await fixture.store.shutdown()
    }

    /// A motion part whose own line came earlier in the pass is listed from it when its
    /// still arrives, with no request to the server, even before the server has reported its
    /// size; the size reaches its row by its own ID when it comes.
    @Test func aMotionPartIsListedFromItsOwnLineBeforeItsSizeIsKnown() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([
            [Self.motion("m"), Self.asset("s", name: "IMG_1.HEIC", motion: "m"), Self.complete],
            [Self.exif("m", size: 2000), Self.complete],
        ])
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )

        _ = await sync.pass()
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC", "s/IMG_1.MOV"])
        #expect(server.requestedDetails.isEmpty)
        #expect(try await fixture.size(of: "s/IMG_1.MOV") == nil)
        _ = await sync.pass()
        #expect(try await fixture.size(of: "s/IMG_1.MOV") == 2000)
        await fixture.store.shutdown()
    }

    /// A motion part the server refuses to describe never holds back the pass: its still is
    /// listed, the batch acknowledged, and a motion row the still's folder already has keeps
    /// its overlay. A server failure still fails the pass.
    @Test func aRefusedMotionPartLeavesItsStillListed() async throws {
        let fixture = try await Fixture.make()
        let server = ScriptedServer([
            [Self.asset("s", name: "IMG_1.HEIC", motion: "gone"), Self.complete],
        ])
        let sync = ImmichCatalogSync(
            rootPath: fixture.rootPath, source: server, store: fixture.store, volumeCapacity: ampleVolumeCapacity
        )
        #expect(await sync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await fixture.visible() == ["s/IMG_1.HEIC"])
        #expect(server.requestedDetails == ["gone"])
        #expect(server.acknowledgements == [["AssetV2|s", "SyncCompleteV1|1"]])
        await fixture.store.shutdown()

        let heldFixture = try await Fixture.make()
        let held = ScriptedServer([
            [Self.motion("m"), Self.asset("s", name: "IMG_1.HEIC", motion: "m"), Self.complete],
            [Self.asset("s", name: "IMG_1.HEIC", modified: 1_700_000_900, motion: "m"), Self.complete],
        ])
        let heldSync = ImmichCatalogSync(
            rootPath: heldFixture.rootPath, source: held, store: heldFixture.store, volumeCapacity: ampleVolumeCapacity
        )
        _ = await heldSync.pass()
        let motion = MediaAssetID(
            libraryRootPath: heldFixture.rootPath, relativePath: MediaRelativePath(rawValue: "s/IMG_1.MOV")
        )
        _ = try await heldFixture.store.setMediaChoices([motion: .liked])
        #expect(await heldSync.pass() == .synced(listed: 1, deleted: 0, full: false))
        #expect(try await heldFixture.store.mediaAssets(for: [motion])[motion]?.mediaChoice == .liked)
        await heldFixture.store.shutdown()
    }
}
