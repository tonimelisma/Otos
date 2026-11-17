import CoreServices
import Foundation
@testable import OtosKit
import Testing

/// A launch walks a fixed library only when its volume's change journal cannot vouch for
/// it (ADR 0002, "Change Journal"; ARC-025). Every case runs against a scripted journal
/// (`ScriptedCatalogFilesystemWatcher`): the test says what the root's probe reads, sees
/// the event ID each Store watches from, and delivers the replay's events and its end at
/// the point it chooses. The root's files are real; only FSEvents is scripted.
@Suite(.testScope)
struct CatalogStoreChangeJournalTests {
    private static let volume = "11111111-2222-3333-4444-555555555555"
    private static let rootIdentity: UInt64 = 7

    /// A library walked once by a first Store, whose journal stood at event 100 then.
    private struct Library {
        let root: URL
        let path: LibraryRootPath
        let databaseURL: URL

        func url(_ relativePath: String) -> URL {
            root.appending(path: relativePath)
        }

        func eventPath(_ relativePath: String) -> String {
            path.rawValue + "/" + relativePath
        }
    }

    private func makeLibrary(files: [String] = ["a.jpg", "b.jpg"]) async throws -> Library {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            try writeCatalogStoreFile(root.appending(path: file), contents: "jpeg")
        }
        let library = try Library(
            root: root,
            path: CatalogPath.normalizedDirectoryPath(for: root),
            databaseURL: temp.appending(path: "db/catalog.sqlite")
        )
        let journal = ScriptedCatalogFilesystemWatcher()
        journal.setProbe(Self.probe(currentEventID: 100), for: library.path)
        let store = makeTestStore(location: .databaseFile(library.databaseURL), filesystemWatcher: journal.watcher, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        #expect(journal.watches() == [.init(root: library.path, since: 100)])
        journal.emitHistoryDone(library.path)
        try await waitUntil { await store.isFilesystemQuiescent }
        #expect(await store.storedJournalPosition(for: library.path) == Self.position(100))
        await store.shutdown()
        return library
    }

    private static func probe(
        volume: String? = CatalogStoreChangeJournalTests.volume,
        currentEventID: UInt64,
        rootIdentity: UInt64 = CatalogStoreChangeJournalTests.rootIdentity
    ) -> FilesystemJournalProbe {
        FilesystemJournalProbe(volumeUUID: volume, currentEventID: currentEventID, rootIdentity: rootIdentity)
    }

    private static func position(_ eventID: UInt64, volume: String = CatalogStoreChangeJournalTests.volume) -> FilesystemJournalPosition {
        FilesystemJournalPosition(volumeUUID: volume, eventID: eventID, rootIdentity: rootIdentity)
    }

    /// A relaunched Store over `library`, its journal probed as `probe`, its scanner counted.
    private func relaunch(
        _ library: Library,
        probe: FilesystemJournalProbe?,
        scanner: CatalogScanner? = nil,
        scans: ScanCalls
    ) async throws -> (CatalogStore, ScriptedCatalogFilesystemWatcher) {
        let journal = ScriptedCatalogFilesystemWatcher()
        journal.setProbe(probe, for: library.path)
        let store = makeTestStore(
            location: .databaseFile(library.databaseURL),
            scanner: scans.counting(scanner ?? .live),
            filesystemWatcher: journal.watcher,
            scanCadence: .milliseconds(10)
        )
        try await store.start()
        return (store, journal)
    }

    /// The write transactions the Store has run since launch.
    private func writerTransactions(_ store: CatalogStore) -> Int {
        store.use().connections.holds.filter { $0.role == "main.writer" }.reduce(0) { $0 + $1.count }
    }

    /// Nothing changed while Otos was not running: the replay delivers no event, and the
    /// launch reads no directory, stats no file and takes the writer for nothing.
    @Test func aReplayWithNoEventsReadsAndWritesNothing() async throws {
        let library = try await makeLibrary()
        let scans = ScanCalls()
        let (store, journal) = try await relaunch(library, probe: Self.probe(currentEventID: 200), scans: scans)
        // The catalog's own load wrote before `start` returned; what follows is the launch's.
        let loaded = writerTransactions(store)
        #expect(journal.watches() == [.init(root: library.path, since: 100)])
        journal.emitHistoryDone(library.path)
        try await waitUntil { await store.isFilesystemQuiescent }
        #expect(await scans.all().isEmpty)
        #expect(writerTransactions(store) == loaded)
        #expect(try await catalogStoreTestState(store).testAssets.count == 2)
        #expect(await store.storedJournalPosition(for: library.path) == Self.position(100))
    }

    /// A replay naming two folders reads exactly those two, never the root, and the position
    /// stored is the last event it applied.
    @Test func aReplayNamingTwoFoldersReadsOnlyThem() async throws {
        let library = try await makeLibrary()
        try FileManager.default.createDirectory(at: library.url("A"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.url("B/C"), withIntermediateDirectories: true)
        try writeCatalogStoreFile(library.url("A/x.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(library.url("B/C/y.jpg"), contents: "jpeg")
        let scans = ScanCalls()
        let (store, journal) = try await relaunch(library, probe: Self.probe(currentEventID: 200), scans: scans)
        let directory = UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
        journal.emit(FilesystemEvent(path: library.eventPath("A"), flags: directory, id: 150))
        journal.emit(FilesystemEvent(path: library.eventPath("B/C"), flags: directory, id: 160))
        journal.emitHistoryDone(library.path)
        try await waitUntil { await store.isFilesystemQuiescent }
        #expect(await scans.all().sorted() == ["subtree:A", "subtree:B/C"])
        let paths = try await Set(catalogStoreTestState(store).testAssets.map(\.relativePath.rawValue))
        #expect(paths == ["a.jpg", "b.jpg", "A/x.jpg", "B/C/y.jpg"])
        #expect(await store.storedJournalPosition(for: library.path) == Self.position(160))
    }

    /// A file deleted while Otos was not running is purged through the lifecycle from the
    /// replay's one event, with no walk.
    @Test func aFileDeletedWhileNotRunningIsPurgedFromTheReplay() async throws {
        let library = try await makeLibrary()
        try FileManager.default.removeItem(at: library.url("b.jpg"))
        let scans = ScanCalls()
        let (store, journal) = try await relaunch(library, probe: Self.probe(currentEventID: 200), scans: scans)
        let removed = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRemoved)
        journal.emit(FilesystemEvent(path: library.eventPath("b.jpg"), flags: removed, id: 120))
        journal.emitHistoryDone(library.path)
        try await waitUntil { await store.isFilesystemQuiescent }
        #expect(await scans.all() == ["file:b.jpg"])
        #expect(try await catalogStoreTestState(store).testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
        #expect(await store.storedJournalPosition(for: library.path) == Self.position(120))
    }

    /// An event that says the journal lost track — dropped events, wrapped IDs, a change on
    /// the path to the root, a mount under it, or subdirectories to rescan at the root —
    /// makes the launch walk the whole root.
    @Test(arguments: [
        UInt32(kFSEventStreamEventFlagMustScanSubDirs),
        UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped),
        UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped),
        UInt32(kFSEventStreamEventFlagEventIdsWrapped),
        UInt32(kFSEventStreamEventFlagRootChanged),
        UInt32(kFSEventStreamEventFlagMount),
        UInt32(kFSEventStreamEventFlagUnmount),
    ])
    func aFallbackFlagWalksTheRoot(flags: UInt32) async throws {
        let library = try await makeLibrary()
        let scans = ScanCalls()
        let (store, journal) = try await relaunch(library, probe: Self.probe(currentEventID: 200), scans: scans)
        let mounted = flags & UInt32(kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0
        journal.emit(FilesystemEvent(path: mounted ? library.eventPath("Volume") : library.path.rawValue, flags: flags, id: 150))
        journal.emitHistoryDone(library.path)
        try await waitUntil { await store.isFilesystemQuiescent }
        #expect(await scans.all() == ["root"])
        #expect(await store.storedJournalPosition(for: library.path) == Self.position(150))
    }

    /// A journal that cannot vouch — another event database, another folder at the path,
    /// a stored position ahead of the stream, or a volume that keeps no history — walks the
    /// root, watched from now; a volume with no history never stores a position.
    @Test(arguments: [
        (CatalogStoreChangeJournalTests.probe(volume: "99999999-2222-3333-4444-555555555555", currentEventID: 30), true),
        (CatalogStoreChangeJournalTests.probe(currentEventID: 200, rootIdentity: 8), true),
        (CatalogStoreChangeJournalTests.probe(currentEventID: 50), true),
        (CatalogStoreChangeJournalTests.probe(volume: nil, currentEventID: 200), false),
    ])
    func aJournalThatCannotVouchWalksTheRoot(probe: FilesystemJournalProbe, keepsHistory: Bool) async throws {
        let library = try await makeLibrary()
        let scans = ScanCalls()
        let (store, journal) = try await relaunch(library, probe: probe, scans: scans)
        #expect(journal.watches() == [.init(root: library.path, since: keepsHistory ? probe.currentEventID : nil)])
        if keepsHistory {
            journal.emitHistoryDone(library.path)
        }
        try await waitUntil { await store.isFilesystemQuiescent }
        #expect(await scans.all() == ["root"])
        let stored = await store.storedJournalPosition(for: library.path)
        if let volume = probe.volumeUUID {
            #expect(stored == FilesystemJournalPosition(volumeUUID: volume, eventID: probe.currentEventID, rootIdentity: probe.rootIdentity))
        } else {
            #expect(stored == Self.position(100))
        }
    }

    /// An event delivered while a walk is suspended is not lost: it is applied once the walk
    /// ends. The walk it overtook could not delete what it did not find (the event made its
    /// observation stale, ARC-041), so it settles nothing and no position is stored past it:
    /// at the suspension and after, the catalog holds the old position, and the next launch
    /// walks again. That walk, overtaken by nothing, stores its own.
    @Test func anEventDuringAWalkIsAppliedAndNoPositionPassesTheWalkItOvertook() async throws {
        let library = try await makeLibrary()
        let gate = WalkGate()
        let otherVolume = "99999999-2222-3333-4444-555555555555"
        let (store, journal) = try await relaunch(
            library,
            probe: Self.probe(volume: otherVolume, currentEventID: 30),
            scanner: gate.scanner(),
            scans: ScanCalls()
        )
        await gate.untilEntered()
        try writeCatalogStoreFile(library.url("c.jpg"), contents: "jpeg")
        let created = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)
        journal.emit(FilesystemEvent(path: library.eventPath("c.jpg"), flags: created, id: 300))
        journal.emitHistoryDone(library.path)
        try await waitUntil { await store.handledFilesystemEventCount == 1 }
        #expect(await store.storedJournalPosition(for: library.path) == Self.position(100))
        gate.release()
        try await waitUntil { await store.isFilesystemQuiescent }
        let paths = try await Set(catalogStoreTestState(store).testAssets.map(\.relativePath.rawValue))
        #expect(paths == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(await store.storedJournalPosition(for: library.path) == Self.position(100))
        await store.shutdown()

        let scans = ScanCalls()
        let (next, nextJournal) = try await relaunch(library, probe: Self.probe(volume: otherVolume, currentEventID: 400), scans: scans)
        nextJournal.emitHistoryDone(library.path)
        try await waitUntil { await next.isFilesystemQuiescent }
        #expect(await scans.all() == ["root"])
        #expect(await next.storedJournalPosition(for: library.path) == Self.position(400, volume: otherVolume))
    }
}

/// The scanner calls a Store made, in order: `root`, `subtree:<path>`, `file:<path>`.
private actor ScanCalls {
    private var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }

    func all() -> [String] {
        calls
    }

    nonisolated func counting(_ scanner: CatalogScanner) -> CatalogScanner {
        CatalogScanner(
            scanRoot: { root, cadence, handler in
                await self.record("root")
                return try await scanner.scanRoot(root, cadence, handler)
            },
            scanSubtree: { root, subtree, cadence, handler in
                await self.record("subtree:\(subtree.rawValue)")
                return try await scanner.scanSubtree(root, subtree, cadence, handler)
            },
            observeFile: { url, root in
                await self.record("file:\(CatalogPath.relativePath(rootPath: root, fileURL: url)?.rawValue ?? url.path)")
                return try await scanner.observeFile(url, root)
            }
        )
    }
}

/// A live scanner whose first full walk waits, after it is entered, until the test
/// releases it: the walk's suspension, where a competing event is delivered.
private final nonisolated class WalkGate: Sendable {
    private let entered: AsyncStream<Void>
    private let enter: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releaser: AsyncStream<Void>.Continuation

    init() {
        (entered, enter) = AsyncStream<Void>.makeStream()
        (released, releaser) = AsyncStream<Void>.makeStream()
    }

    func scanner() -> CatalogScanner {
        CatalogScanner(
            scanRoot: { [self] root, cadence, handler in
                enter.yield()
                for await _ in released {
                    break
                }
                return try await CatalogScanner.live.scanRoot(root, cadence, handler)
            }
        )
    }

    func untilEntered() async {
        for await _ in entered {
            return
        }
    }

    func release() {
        releaser.yield()
    }
}
