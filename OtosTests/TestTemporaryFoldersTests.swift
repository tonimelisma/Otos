import Darwin
import Foundation
import Testing

/// The test process owns its temporary folders: each is named for the process that made it,
/// and a process that starts removes those of processes that no longer run, which a killed
/// host leaves behind (`script/test.sh` fails a run that leaves any).
struct TestTemporaryFoldersTests {
    @Test func aRootIsNamedForItsProcess() {
        let root = TestTemporaryFolders.makeRoot()
        #expect(TestTemporaryFolders.processID(ofRootNamed: root.lastPathComponent) == getpid())
        #expect(TestTemporaryFolders.processID(ofRootNamed: "OtosTests-5D2E1C7A-0000") == nil)
        #expect(TestTemporaryFolders.processID(ofRootNamed: "Other-12-x") == nil)
    }

    @Test func theFoldersOfProcessesThatEndedAreSweptAndOursAreKept() throws {
        // A process that has run and ended: its pid names no running process.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let deadPID = ended.processIdentifier
        try #require(!TestTemporaryFolders.isRunning(deadPID))

        let temp = FileManager.default.temporaryDirectory
        let stale = temp.appending(path: "\(TestTemporaryFolders.prefix)\(deadPID)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let ours = temp.appending(path: "\(TestTemporaryFolders.prefix)\(getpid())-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale.appending(path: "Catalog"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: ours)
        }

        TestTemporaryFolders.sweepRootsOfProcessesThatEnded()

        #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: ours.path(percentEncoded: false)))
    }
}
