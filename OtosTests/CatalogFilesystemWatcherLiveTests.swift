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
        watcherA.start([pathA]) { eventsA.record($0) }
        watcherB.start([pathB]) { eventsB.record($0) }
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

    private func touchFromAnotherProcess(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}

private final nonisolated class WatcherEventRecorder: Sendable {
    private let events = Mutex<[FilesystemEvent]>([])

    func record(_ event: FilesystemEvent) {
        events.withLock { $0.append(event) }
    }

    func paths() -> [String] {
        events.withLock { $0.map(\.path) }
    }

    func fileNames() -> Set<String> {
        events.withLock { Set($0.map { URL(fileURLWithPath: $0.path).lastPathComponent }) }
    }
}
