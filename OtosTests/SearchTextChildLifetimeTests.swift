import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// A text-reading child lives no longer than the Otos that started it (`SearchTextChild`): it
/// exits when its input ends, even while a reading holds its reading thread, so Otos's end —
/// closing the session, quitting, crashing, being killed — ends it, and the reader's shutdown
/// returns only once its child is gone.
@Suite(.testScope)
struct SearchTextChildLifetimeTests {
    /// Requests for a picture that does not exist, each answered `.undecodable` at once. Their
    /// answers (19 bytes each) overfill a pipe (64 KB at most) several times over, so a child
    /// whose output no one reads has its reading thread blocked writing an answer, as Vision
    /// blocks it in a reading, while its input thread reads the rest of the requests.
    private static let flood = String(repeating: #"{"path":"/nonexistent/otos-test.jpg"}"# + "\n", count: 20000)

    // Validates: ENR-028
    /// The input closes while the child's reading thread is blocked: the child exits, and
    /// cleanly. Before the input had a thread of its own, the child read it only between
    /// readings and outlived its parent by as long as the reading took.
    @Test func aChildWhoseInputEndsMidReadingExits() async throws {
        let input = Pipe(), output = Pipe()
        let lifetime = SearchTextChildLifetime(input: input.fileHandleForWriting)
        let process = Process()
        process.executableURL = try SearchTextChild.executable()
        process.arguments = [SearchTextReadingProcess.argument]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in lifetime.reportExit() }
        try process.run()
        defer { kill(process.processIdentifier, SIGKILL) }

        // Returns once the child has read all but a pipe's worth of the requests: far more
        // readings are queued than their answers can fit in the unread output.
        try await Task.detached { try lifetime.write(Data(Self.flood.utf8)) }.value
        await lifetime.end()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        try output.fileHandleForReading.close()
    }

    // Validates: ENR-028
    /// The child's parent is killed while the child's reading thread is blocked: the child
    /// exits. A shell stands in for Otos: it starts the child on two pipes it holds alone,
    /// floods its input as above, and is killed.
    @Test func aChildWhoseParentIsKilledMidReadingExits() async throws {
        let directory = try makeTestDirectory()
        let requests = directory.appending(path: "requests").path(percentEncoded: false)
        let answers = directory.appending(path: "answers").path(percentEncoded: false)
        #expect(mkfifo(requests, 0o600) == 0)
        #expect(mkfifo(answers, 0o600) == 0)
        let script = """
        "$0" \(SearchTextReadingProcess.argument) < "$1" > "$2" &
        echo $!
        exec 3> "$1" 4< "$2"
        i=0
        while [ $i -lt 20000 ]; do echo '{"path":"/nonexistent/otos-test.jpg"}' >&3; i=$((i+1)); done
        echo flooded
        read _
        """
        let parent = Process()
        parent.executableURL = URL(filePath: "/bin/sh")
        parent.arguments = try ["-c", script, SearchTextChild.executable().path(percentEncoded: false), requests, answers]
        let parentInput = Pipe(), parentOutput = Pipe()
        parent.standardInput = parentInput
        parent.standardOutput = parentOutput
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        defer { kill(parent.processIdentifier, SIGKILL) }

        let lines = try await Task.detached { try Self.lines(2, from: parentOutput.fileHandleForReading) }.value
        let child = try #require(Int32(lines[0]))
        defer { kill(child, SIGKILL) }
        #expect(lines[1] == "flooded")

        #expect(kill(parent.processIdentifier, SIGKILL) == 0)
        await Self.waitForExit(of: child)
        try parentInput.fileHandleForWriting.close()
    }

    // Validates: ENR-028
    /// The reader's shutdown ends the session whose reading is in flight and returns once its
    /// process is gone; the reading comes back with no result, the page's next still is not
    /// read, and no session starts after. `cat` stands in for a child mid-reading: it keeps
    /// its output open (as descriptor 3) and never answers, and exits at its input's end.
    @Test func theReadersShutdownEndsTheLiveSessionAndStartsNoOther() async throws {
        let directory = try makeTestDirectory()
        let started = Mutex<[Int32]>([])
        let reader = SearchTextReader {
            let child = try SearchTextChild(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exec cat 3>&1 > /dev/null"])
            started.withLock { $0.append(child.processIdentifier) }
            return child
        }
        defer {
            for pid in started.withLock({ $0 }) {
                kill(pid, SIGKILL)
            }
        }
        let page = ["sign", "menu"].map { name in
            SearchTextCandidate(
                id: MediaAssetID(
                    libraryRootPath: LibraryRootPath(rawValue: "/Library"), relativePath: MediaRelativePath(rawValue: "\(name).jpg")
                ),
                previewPath: "\(name)-preview.jpg",
                source: "rendered"
            )
        }
        let reading = Task { await reader.read(page, directory: directory) }
        let pid = try await waitForValue { started.withLock { $0.first } }

        await reader.shutdown()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(await reading.value == .sessionEnded(before: []))
        #expect(await reader.read(page, directory: directory) == .sessionEnded(before: []))
        #expect(started.withLock { $0.count } == 1)
    }

    /// The first `count` lines `handle` holds, waiting for each.
    private static func lines(_ count: Int, from handle: FileHandle) throws -> [String] {
        var text = ""
        while text.split(separator: "\n").count < count || !text.hasSuffix("\n") {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        return text.split(separator: "\n").prefix(count).map(String.init)
    }

    /// Returns once `pid`, a process this one did not start, has exited, as the kernel reports
    /// it (`EVFILT_PROC`, `NOTE_EXIT`). A process already gone fails the registration, which
    /// returns at once.
    private static func waitForExit(of pid: Int32) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                let queue = kqueue()
                var change = kevent(
                    ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                    fflags: NOTE_EXIT, data: 0, udata: nil
                )
                var event = kevent()
                while kevent(queue, &change, 1, &event, 1, nil) < 0, errno == EINTR {}
                close(queue)
                continuation.resume()
            }
        }
    }
}
