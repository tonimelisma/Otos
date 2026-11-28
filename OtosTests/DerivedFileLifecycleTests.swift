import CoreGraphics
import Foundation
import GRDB
@testable import OtosKit
import Testing

/// The overlay's one lifecycle for derived files (ADR 0008): after renders, a re-render, a
/// file moved outside Otos and rendered again under its new path, a deleted file, a
/// camera's thumbnail, and the files a crash or an older build left behind, the derived
/// folder holds exactly the files the catalog's rows name; its stored counters equal a census
/// of it after every step; and a launch lists it only when a fact says leftovers can exist.
@Suite(.testScope)
struct DerivedFileLifecycleTests {
    // Validates: ENR-004
    @Test func theDerivedFolderHoldsExactlyWhatTheRowsNameAndItsCountersMatch() async throws {
        let library = try await GeneratedLibrary.make(["a.jpg", "b.jpg", "c.jpg"])
        let store = library.store
        let directory = library.directory
        let id = library.id
        // A new catalog's counters are unknown until its first census.
        #expect(try await store.backgroundReads.derivedFolderCounters() == nil)
        let first = try #require(try await store.backgroundReads.reconcileDerivedFilesIfOwed())
        #expect(first.reason == "countersUnknown")
        try await expectCountersMatchCensus(directory, store)

        // Renders, then a re-render of one: the same deterministic names, overwritten.
        try await render(["a.jpg", "b.jpg", "c.jpg"].map(id), store: store, directory: directory)
        try await render([id("a.jpg")], store: store, directory: directory)
        try await expectFolderMatchesRows(directory, store)
        try await expectCountersMatchCensus(directory, store)

        // A file moved outside Otos keeps its row and its images; rendered again under its
        // new path, its images take the new names and the old ones go.
        try library.move("b.jpg", to: "b-moved.jpg")
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.testAssets.contains { $0.id == id("b-moved.jpg") }
        }
        try await render([id("b-moved.jpg")], store: store, directory: directory)
        try await expectFolderMatchesRows(directory, store)
        try await expectCountersMatchCensus(directory, store)

        // A deleted file's row is purged with its images.
        try library.delete("c.jpg")
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        try await expectFolderMatchesRows(directory, store)
        try await expectCountersMatchCensus(directory, store)

        // A camera's thumbnail is taken only by a row with none, in the write that names it.
        let staged = try ThumbnailStore.stageProvisionalJPEG(
            Data("camera".utf8), finalRelativeName: ThumbnailStore.relativeName(for: id("a.jpg")), in: directory
        )
        try await store.applyProvisionalThumbnails([id("a.jpg"): staged])
        #expect(try Data(contentsOf: ThumbnailStore.url(for: ThumbnailStore.relativeName(for: id("a.jpg")), in: directory))
            != Data("camera".utf8), "a rendered thumbnail is never replaced by the camera's")
        try await expectFolderMatchesRows(directory, store)
        try await expectCountersMatchCensus(directory, store)
        await store.shutdown()
    }

    // Validates: ENR-004
    /// What a crash between a promotion and its row, or an older build, left: removed by the
    /// next launch's reconciliation, which the unclean exit owes; a present row's own unnamed
    /// name is kept. A clean quit owes nothing, and the next launch lists nothing.
    @Test func anUncleanExitOwesOneReconciliationAndACleanOneOwesNone() async throws {
        let library = try await GeneratedLibrary.make(["a.jpg", "c.jpg"])
        let directory = library.directory
        let id = library.id
        var store = library.store
        _ = try await store.backgroundReads.reconcileDerivedFilesIfOwed()
        try await render([id("a.jpg"), id("c.jpg")], store: store, directory: directory)
        try library.delete("c.jpg")
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        await store.derivedFolder?.untilSettled()
        #expect(store.derivedFolder?.closeSession() == true)
        await store.shutdown()

        // A clean relaunch reads the counters and lists nothing.
        store = try await library.relaunch()
        guard case .counted = try #require(try await store.backgroundReads.reconcileDerivedFilesIfOwed()) else {
            Issue.record("a clean relaunch reconciled")
            return
        }
        // This session ends without closing, as a crash would, leaving files no row names.
        let purged = [
            ThumbnailStore.relativeName(for: id("c.jpg")), ThumbnailStore.previewRelativeName(for: id("c.jpg")),
        ]
        for leftover in ["0123abcd.jpg", "0123abcd.heic", "thumb.jpg.tmp-1"] + purged {
            try Data("left".utf8).write(to: directory.appending(path: leftover))
        }
        // A file of a present row's own identity that its column does not name (yet): the row
        // writes exactly this name when it renders, so it is never removed.
        let unnamedOwn = ThumbnailStore.faceFramesRelativeName(for: id("a.jpg"))
        try Data("frames".utf8).write(to: directory.appending(path: unnamedOwn))
        await store.shutdown()

        store = try await library.relaunch()
        let outcome = try #require(try await store.backgroundReads.reconcileDerivedFilesIfOwed())
        #expect(outcome.reason == "uncleanExit")
        #expect(outcome.removed?.files[.thumbnail] == 2)
        #expect(outcome.removed?.files[.preview] == 2)
        #expect(outcome.removed?.files[.other] == 1)
        let namedNow = try await named(store)
        #expect(try listed(directory) == namedNow.union([unnamedOwn]))
        try await expectCountersMatchCensus(directory, store)
        await store.derivedFolder?.untilSettled()
        #expect(store.derivedFolder?.closeSession() == true)
        await store.shutdown()

        // One reconciliation: the next clean launch lists nothing.
        store = try await library.relaunch()
        guard case .counted = try #require(try await store.backgroundReads.reconcileDerivedFilesIfOwed()) else {
            Issue.record("a launch after a reconciliation and a clean quit reconciled again")
            return
        }
        await store.shutdown()
    }

    // Validates: ENR-004
    /// The counters equal a census after a seeded random run of renders, re-renders, moves,
    /// deletions, new files and camera thumbnails.
    @Test func theCountersEqualACensusAfterRandomOperations() async throws {
        let library = try await GeneratedLibrary.make((0 ..< 6).map { "p\($0).jpg" })
        let store = library.store
        let directory = library.directory
        _ = try await store.backgroundReads.reconcileDerivedFilesIfOwed()
        var random = SeededRandom(seed: 0x0715)
        var next = 6
        for _ in 0 ..< 24 {
            let present = try await catalogStoreTestState(store).testAssets.map(\.id)
            guard let target = present.randomElement(using: &random) else {
                break
            }
            switch random.next() % 5 {
            case 0:
                try await render(Array(present.shuffled(using: &random).prefix(3)), store: store, directory: directory)
            case 1:
                let newName = "p\(next).jpg"
                next += 1
                try library.move(target.relativePath.rawValue, to: newName)
                _ = try await waitForCatalogStoreState(store) { state in
                    !state.isScanning && state.testAssets.contains { $0.id == library.id(newName) }
                }
            case 2 where present.count > 2:
                try library.delete(target.relativePath.rawValue)
                _ = try await waitForCatalogStoreState(store) { state in
                    !state.isScanning && !state.testAssets.contains { $0.id == target }
                }
            case 3:
                let newName = "p\(next).jpg"
                next += 1
                try library.add(newName)
                _ = try await waitForCatalogStoreState(store) { state in
                    !state.isScanning && state.testAssets.contains { $0.id == library.id(newName) }
                }
            default:
                let staged = try ThumbnailStore.stageProvisionalJPEG(
                    Data("camera".utf8), finalRelativeName: ThumbnailStore.relativeName(for: target), in: directory
                )
                try await store.applyProvisionalThumbnails([target: staged])
            }
            try await expectCountersMatchCensus(directory, store)
        }
        await store.shutdown()
    }

    /// A process that ends between a promotion's file write and its commit: the promoted
    /// files are on disk, no commit hook ran and the session never closed. The next open owes
    /// a reconciliation, which removes the file no row names and keeps every named file —
    /// including a named thumbnail the uncommitted promotion overwrote in place.
    @Test func aCrashBetweenAPromotionAndItsCommitOwesAReconciliationAndLosesNoNamedFile() async throws {
        let library = try await GeneratedLibrary.make(["a.jpg", "b.jpg"])
        let directory = library.directory
        let id = library.id
        var store = library.store
        _ = try await store.backgroundReads.reconcileDerivedFilesIfOwed()
        try await render([id("a.jpg"), id("b.jpg")], store: store, directory: directory)
        let namedBefore = try await named(store)
        let folder = try #require(store.derivedFolder)

        // The uncommitted write: one promotion over a named thumbnail, one to a name no row
        // holds. Its transaction never ends, so neither of its hooks runs, as in a crash.
        var crashConfiguration = Configuration()
        crashConfiguration.allowsUnsafeTransactions = true
        let crashQueue = try DatabaseQueue(configuration: crashConfiguration)
        try crashQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE derived_folder (kind TEXT PRIMARY KEY, files INTEGER, bytes INTEGER)")
            try db.execute(sql: "BEGIN")
            for name in [ThumbnailStore.relativeName(for: id("a.jpg")), String(repeating: "e", count: 64) + ".jpg"] {
                let staged = try ThumbnailStore.stageProvisionalJPEG(Data("uncommitted".utf8), finalRelativeName: name, in: directory)
                try folder.promote(staged, db: db)
            }
        }
        await store.shutdown()

        store = try await library.relaunch()
        let outcome = try #require(try await store.backgroundReads.reconcileDerivedFilesIfOwed())
        #expect(outcome.reason == "uncleanExit")
        #expect(outcome.removed?.files[.thumbnail] == 1)
        #expect(try listed(directory) == namedBefore)
        for name in namedBefore {
            #expect(FileManager.default.fileExists(atPath: ThumbnailStore.url(for: name, in: directory).path(percentEncoded: false)))
        }
        try await expectCountersMatchCensus(directory, store)
        withExtendedLifetime(crashQueue) {}
        await store.shutdown()
    }

    /// A root's rename journals its files' moves in the write that renames the rows, and moves
    /// them after it: the folder then holds exactly the new names, and the counters match.
    @Test func aRenamedRootsFilesMoveFromItsJournal() async throws {
        let library = try await GeneratedLibrary.make(["a.jpg", "b.jpg"])
        let store = library.store
        let directory = library.directory
        _ = try await store.backgroundReads.reconcileDerivedFilesIfOwed()
        try await render([library.id("a.jpg"), library.id("b.jpg")], store: store, directory: directory)
        let newRoot = LibraryRootPath(rawValue: library.rootPath.rawValue + "-renamed")
        let moves = ["a.jpg", "b.jpg"].flatMap { name -> [(old: String, new: String)] in
            let old = library.id(name)
            let new = MediaAssetID(libraryRootPath: newRoot, relativePath: MediaRelativePath(rawValue: name))
            return [
                (ThumbnailStore.relativeName(for: old), ThumbnailStore.relativeName(for: new)),
                (ThumbnailStore.previewRelativeName(for: old), ThumbnailStore.previewRelativeName(for: new)),
            ]
        }
        let folder = try #require(store.derivedFolder)
        let journal = try makeTestDatabaseQueue(path: library.databaseURL.path(percentEncoded: false))
        try await journal.write { db in
            try folder.journalRenames(moves, db: db)
        }
        try journal.close()
        try await store.applyPendingDerivedRenames(lane: store.backgroundReads.lane)
        #expect(try listed(directory) == Set(moves.map(\.new)))
        try await expectCountersMatchCensus(directory, store)
        await store.shutdown()
    }

    // Validates: ENR-004
    /// A write that rolls back after promoting leaves a file no row names, so its session
    /// cannot end clean.
    @Test func aRolledBackPromotionKeepsTheSessionsMarker() throws {
        let temp = try makeTestDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = DerivedFolder(directory: directory)
        #expect(folder.openSession() == false)
        let queue = try DatabaseQueue()
        struct Rollback: Error {}
        let staged = try ThumbnailStore.stageProvisionalJPEG(Data("x".utf8), finalRelativeName: "ab.jpg", in: directory)
        #expect(throws: Rollback.self) {
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE derived_folder (kind TEXT PRIMARY KEY, files INTEGER, bytes INTEGER)")
                try folder.promote(staged, db: db)
                throw Rollback()
            }
        }
        #expect(folder.closeSession() == false)
        #expect(FileManager.default.fileExists(atPath: folder.marker.path(percentEncoded: false)))
        #expect(DerivedFolder(directory: directory).openSession() == true)
    }

    /// Renders `ids`: a staged thumbnail and preview each, applied as enrichment applies them.
    private func render(_ ids: [MediaAssetID], store: CatalogStore, directory: URL) async throws {
        let assets = try await store.windowReads.mediaAssets(for: ids)
        let image = try tinyImage()
        var results: [EnrichmentResult] = []
        for id in ids {
            let asset = try #require(assets[id])
            try results.append(EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                thumbnailPath: nil,
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: .empty,
                generatedThumbnail: ThumbnailStore.stage(
                    image, finalRelativeName: ThumbnailStore.relativeName(for: id), in: directory
                ),
                generatedPreview: ThumbnailStore.stagePreview(
                    image, finalRelativeName: ThumbnailStore.previewRelativeName(for: id), in: directory
                )
            ))
        }
        #expect(await store.applyEnrichmentBatch(results) == .applied(count: ids.count))
    }

    /// After the folder's changes settle: a write's deletes follow its commit
    /// (`DerivedFolder.untilSettled`).
    private func expectFolderMatchesRows(_ directory: URL, _ store: CatalogStore) async throws {
        await store.derivedFolder?.untilSettled()
        let rows = try await named(store)
        #expect(try listed(directory) == rows)
    }

    private func expectCountersMatchCensus(_ directory: URL, _ store: CatalogStore) async throws {
        await store.derivedFolder?.untilSettled()
        let census = try DerivedFileReconciliation.Census(DerivedFileReconciliation.list(directory)).normalized
        #expect(try await store.backgroundReads.derivedFolderCounters() == census)
    }

    /// The derived folder's top-level files (staging is a running write's).
    private func listed(_ directory: URL) throws -> Set<String> {
        try Set(DerivedFileReconciliation.list(directory).map(\.name))
    }

    /// Every derived name the rows hold.
    private func named(_ store: CatalogStore) async throws -> Set<String> {
        let ids = try await catalogStoreTestState(store).testAssets.map(\.id)
        let details = try await store.windowReads.mediaTileDetails(for: ids)
        return Set(details.values.flatMap { [$0.thumbnailPath, $0.previewPath].compactMap(\.self) })
    }

    private func tinyImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return try #require(context.makeImage())
    }
}

/// A generated library folder and a file-backed catalog over it, relaunchable on the same
/// catalog and derived folder.
private struct GeneratedLibrary {
    let root: URL
    let databaseURL: URL
    let rootPath: LibraryRootPath
    let directory: URL
    let store: CatalogStore
    let emit: @Sendable (FilesystemEvent) -> Void

    static func make(_ names: [String]) async throws -> GeneratedLibrary {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Generated", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try writeCatalogStoreFile(root.appending(path: name), contents: "jpeg \(name)")
        }
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = makeTestStore(location: .databaseFile(databaseURL), filesystemWatcher: watcher)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == names.count }
        return try GeneratedLibrary(
            root: root,
            databaseURL: databaseURL,
            rootPath: CatalogPath.normalizedDirectoryPath(for: root),
            directory: #require(store.thumbnailDirectory),
            store: store,
            emit: emit
        )
    }

    func id(_ name: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
    }

    /// A new Store on the same catalog, started with its saved library and no scan.
    func relaunch() async throws -> CatalogStore {
        let store = makeTestStore(location: .databaseFile(databaseURL), filesystemWatcher: CatalogFilesystemWatcher.testing().0)
        try await store.start(scansSavedLibraries: false)
        return store
    }

    func move(_ name: String, to newName: String) throws {
        try FileManager.default.moveItem(at: root.appending(path: name), to: root.appending(path: newName))
        emit(FilesystemEvent(path: root.path(percentEncoded: false), flags: 0))
    }

    func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: root.appending(path: name))
        emit(FilesystemEvent(path: root.appending(path: name).path(percentEncoded: false), flags: 0))
    }

    func add(_ name: String) throws {
        try writeCatalogStoreFile(root.appending(path: name), contents: "jpeg \(name)")
        emit(FilesystemEvent(path: root.path(percentEncoded: false), flags: 0))
    }
}

/// A reproducible random sequence (SplitMix64), so a failing run can be replayed.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private extension CatalogStore.DerivedFolderOutcome {
    var reason: String? {
        if case let .reconciled(reason, _, _) = self {
            return reason
        }
        return nil
    }

    var removed: DerivedFileReconciliation.Census? {
        if case let .reconciled(_, _, removed) = self {
            return removed
        }
        return nil
    }
}
