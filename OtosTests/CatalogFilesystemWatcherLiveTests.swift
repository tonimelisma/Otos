import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Two live watchers are independent: each delivers its own roots' events to its own
/// handler, and stopping one leaves the other watching. Files are written by a child
/// process because the stream ignores events this process causes
/// (`kFSEventStreamCreateFlagIgnoreSelf`).
@Suite(.testScope)
struct CatalogFilesystemWatcherLiveTests {
    // Validates: ARC-041
    @Test func liveWatchersDeliverOnlyTheirOwnRootsAndStopIndependently() async throws {
        let temp = try makeTestDirectory()
        let rootA = temp.appending(path: "A", directoryHint: .isDirectory)
        let rootB = temp.appending(path: "B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let pathA = try CatalogPath.normalizedDirectoryPath(for: rootA)
        let pathB = try CatalogPath.normalizedDirectoryPath(for: rootB)

        let eventsA = WatcherEventRecorder()
        let eventsB = WatcherEventRecorder()
        let watcherA = CatalogFilesystemWatcher.live()
        let watcherB = CatalogFilesystemWatcher.live()
        watcherA.start { eventsA.record($0) }
        watcherB.start { eventsB.record($0) }
        watcherA.watch(pathA, nil)
        watcherB.watch(pathB, nil)
        defer {
            watcherA.stop()
            watcherB.stop()
        }

        try touchFromAnotherProcess(rootA.appending(path: "a.jpg"))
        try touchFromAnotherProcess(rootB.appending(path: "b.jpg"))
        try await waitUntil { eventsA.fileNames().contains("a.jpg") && eventsB.fileNames().contains("b.jpg") }
        #expect(!eventsA.fileNames().contains("b.jpg"))
        #expect(!eventsB.fileNames().contains("a.jpg"))
        // FSEvents reports the test directory's real `/private/var` path; every event arrives
        // spelled as its root is, so the store can tell which library it belongs to.
        #expect(eventsA.paths().allSatisfy { CatalogPath.owningRoot(for: $0, among: [pathA]) == pathA })
        #expect(eventsB.paths().allSatisfy { CatalogPath.owningRoot(for: $0, among: [pathB]) == pathB })

        watcherA.stop()
        try touchFromAnotherProcess(rootB.appending(path: "c.jpg"))
        try await waitUntil { eventsB.fileNames().contains("c.jpg") }
    }

    // Validates: ARC-025
    /// A stream started from an event ID replays what happened after it, then says so: a
    /// file written after the first stream's last event, while no stream watched, is
    /// delivered to a stream started from that event, with a later ID. Each wait is on a
    /// delivery the stream makes, never on time: whether the file arrives as history or,
    /// when the event database had not yet recorded it, as a live event after `historyDone`,
    /// it arrives.
    @Test func aStreamStartedFromAnEventDeliversWhatHappenedAfterIt() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Journal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = try CatalogPath.normalizedDirectoryPath(for: root)
        let probe = try #require(LiveFilesystemJournal.probe(path))
        try #require(probe.volumeUUID != nil, "the test directory's volume keeps FSEvents history")

        let first = WatcherEventRecorder()
        let firstWatcher = CatalogFilesystemWatcher.live()
        firstWatcher.start { first.record($0) }
        firstWatcher.watch(path, probe.currentEventID)
        try await waitUntil { first.historyDone(path) }
        try touchFromAnotherProcess(root.appending(path: "before.jpg"))
        try await waitUntil { first.fileNames().contains("before.jpg") }
        let lastSeen = try #require(first.events().filter { $0.path.hasSuffix("/before.jpg") }.map(\.id).max())
        firstWatcher.stop()

        try touchFromAnotherProcess(root.appending(path: "after.jpg"))
        let second = WatcherEventRecorder()
        let secondWatcher = CatalogFilesystemWatcher.live()
        defer { secondWatcher.stop() }
        secondWatcher.start { second.record($0) }
        secondWatcher.watch(path, lastSeen)
        try await waitUntil { second.fileNames().contains("after.jpg") }
        let delivered = try #require(second.events().filter { $0.path.hasSuffix("/after.jpg") }.map(\.id).max())
        #expect(delivered > lastSeen)
        try await waitUntil { second.historyDone(path) }
    }

    // Validates: ARC-025
    /// A folder made just before it is added, by another process, is current after its first
    /// walk: its real `FullHistory` chunk, which holds the folder's own creation, is read by
    /// nothing after the walk. The history is waited into the event database on a stream's
    /// own delivery of it, and the walk's end on the position the Store stores.
    @Test func aFolderMadeBeforeItIsAddedIsWalkedOnce() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Made", directoryHint: .isDirectory)
        let parent = try CatalogPath.normalizedDirectoryPath(for: temp)
        let recorded = WatcherEventRecorder()
        let recorder = CatalogFilesystemWatcher.live()
        recorder.start { recorded.record($0) }
        recorder.watch(parent, nil)
        try runFromAnotherProcess("/bin/mkdir", root.path)
        try touchFromAnotherProcess(root.appending(path: "a.jpg"))
        try await waitUntil { recorded.fileNames().contains("a.jpg") }
        recorder.stop()

        let path = try CatalogPath.normalizedDirectoryPath(for: root)
        let probe = try #require(LiveFilesystemJournal.probe(path))
        try #require(probe.volumeUUID != nil, "the test directory's volume keeps FSEvents history")
        let scans = ScanCalls()
        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanner: scans.counting(.live),
            filesystemWatcher: .live(),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        try await waitUntil { await store.storedJournalPosition(for: path) != nil }
        try await waitUntil { await store.isFilesystemQuiescent }
        #expect(await scans.all() == ["root"])
        #expect(try await catalogStoreTestState(store).testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
        await store.shutdown()
    }

    private func touchFromAnotherProcess(_ url: URL) throws {
        try runFromAnotherProcess("/usr/bin/touch", url.path)
    }

    private func runFromAnotherProcess(_ executable: String, _ argument: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [argument]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}

private final nonisolated class WatcherEventRecorder: Sendable {
    private let deliveries = Mutex<[FilesystemWatcherDelivery]>([])

    func record(_ delivery: FilesystemWatcherDelivery) {
        deliveries.withLock { $0.append(delivery) }
    }

    func events() -> [FilesystemEvent] {
        deliveries.withLock { deliveries in
            deliveries.compactMap { delivery in
                if case let .event(event) = delivery {
                    return event
                }
                return nil
            }
        }
    }

    func historyDone(_ root: LibraryRootPath) -> Bool {
        deliveries.withLock { $0.contains(.historyDone(root)) }
    }

    func paths() -> [String] {
        events().map(\.path)
    }

    func fileNames() -> Set<String> {
        Set(events().map { URL(fileURLWithPath: $0.path).lastPathComponent })
    }
}
