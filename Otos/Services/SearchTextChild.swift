import CoreGraphics
import Foundation
import Synchronization

/// Search text reading process guide (ADR 0048)
///
/// Vision loses its text reader for good in a process whose compiled model's files macOS
/// purged under disk pressure, and only a new process reads again
/// (`docs/research/2026-11-15-text-reading-lost-to-a-cache-purge.md`). So Otos reads text in a
/// child process of its own: its own executable, started with `SearchTextReadingProcess.argument`,
/// which never starts the app and serves readings until its input closes. One request is one
/// line of JSON holding a preview's path; one answer is one line of JSON holding its
/// `SearchTextPreviewReading`. A child that answers `.ended` exits after the answer, and the
/// reader starts another for the next page (`SearchTextReader`). A child whose output closes
/// before it answers ended while reading that picture (`.exited`): the reader pages past the
/// picture and reads the rest in another child.
///
/// A child that neither answers nor exits is ended after `answerDeadline` (ADR 0033 `time:
/// deadline`): nothing can report that a reading will never finish — the child's output stays
/// open, and a heartbeat from it would beat on while Vision is stuck in another of its
/// threads — so the child is terminated and its picture is `.exited` like a crash's: owed and
/// paged past. The bound is 20 minutes, about twice the slowest reading measured, a cold first
/// one under parallel load at 649 s (a warm one takes 0.15–3.4 s;
/// `docs/research/2026-11-14-vision-text-reading-breaks-for-its-process.md`).
///
/// A child lives no longer than its session, and no session outlives Otos. The child exits
/// when its input ends, even mid-reading (`SearchTextReadingProcess.serve`), and Otos holds
/// that input's only writer: ending a session closes it (`end`, and `deinit` for a session
/// dropped), and Otos's own end — a quit, a crash, a kill — closes it with every other
/// descriptor. `end` returns once the child's exit is reported (`Process.terminationHandler`),
/// so a shutdown that awaits it leaves no child behind.
///
/// The child is the app's executable in the installed app, beside the `OtosKit` framework it
/// embeds, and the built `Otos.app` beside the framework when tests load it from the build's
/// products. It reads the same previews from Application Support the app does, and reads
/// nothing else.
final nonisolated class SearchTextChild: SearchTextSession {
    private let process: Process
    private let lifetime: SearchTextChildLifetime
    private let answers: FileHandle
    private var pending = Data()
    private var hasAsked = false
    private let answerDeadline: Duration

    /// How long a reading may go unanswered before its child is ended.
    static let answerDeadline: Duration = .seconds(1200)

    /// Starts a child from Otos's own executable.
    static func start() throws -> any SearchTextSession {
        try SearchTextChild(executable: executable())
    }

    /// `arguments` and `answerDeadline` are the reading process's own, unless a test starts
    /// another program to stand in for a child that never answers.
    init(
        executable: URL,
        arguments: [String] = [SearchTextReadingProcess.argument],
        answerDeadline: Duration = SearchTextChild.answerDeadline
    ) throws {
        self.answerDeadline = answerDeadline
        let input = Pipe()
        let output = Pipe()
        // A write to a child that has exited fails with EPIPE instead of signalling this process.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        let lifetime = SearchTextChildLifetime(input: input.fileHandleForWriting)
        self.lifetime = lifetime
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Background reading, as the reader's own queue is.
        process.qualityOfService = .utility
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in lifetime.reportExit() }
        try process.run()
        answers = output.fileHandleForReading
        OtosLog.thumbnails.noticeOperation("search.text", phase: "sessionStarted", fields: [
            "pid": "\(process.processIdentifier)",
        ])
    }

    deinit {
        // Its input's end ends the child, mid-reading or not.
        lifetime.closeInput()
    }

    /// The child's process identifier, for a test that ends it.
    var processIdentifier: Int32 {
        process.processIdentifier
    }

    var end: @Sendable () async -> Void {
        let lifetime = lifetime
        return { await lifetime.end() }
    }

    /// A child's first reading loads the system's text model, which takes 0.2 s warm and many
    /// minutes cold (a purged compiled-model cache, a loaded machine), while the window says it
    /// is still reading. Its wait is logged as a fact (`op=search.text phase=firstReading
    /// waitMs=`), whatever it came to, so a survey can tell a cold load from a stall.
    func read(_ url: URL) -> SearchTextPreviewReading {
        let isFirst = !hasAsked
        hasAsked = true
        let asked = ContinuousClock.now
        let reading = ask(url)
        if isFirst {
            OtosLog.thumbnails.noticeOperation("search.text", phase: "firstReading", fields: [
                "pid": "\(process.processIdentifier)",
                "waitMs": "\(DiagnosticsTiming.milliseconds(since: asked))",
                "outcome": reading.outcomeName,
            ])
        }
        return reading
    }

    private func ask(_ url: URL) -> SearchTextPreviewReading {
        do {
            var request = try JSONEncoder().encode(SearchTextReadingProcess.Request(path: url.path(percentEncoded: false)))
            request.append(0x0A)
            try lifetime.write(request)
            switch nextAnswer(by: ContinuousClock.now + answerDeadline) {
            case let .line(answer):
                return try JSONDecoder().decode(SearchTextPreviewReading.self, from: answer)
            case .closed:
                return .exited("the reading process exited before it answered")
            case .overran:
                // Ended here, so the reader's next page starts a new child. A child stuck in
                // Vision still reads its input's end, but a stand-in that never reads its input
                // does not, so this one is terminated.
                process.terminate()
                OtosLog.thumbnails.errorOperation("search.text", phase: "sessionOverran", fields: [
                    "pid": "\(process.processIdentifier)", "deadlineSeconds": "\(answerDeadline.components.seconds)",
                ])
                return .exited("the reading process gave no answer within \(answerDeadline.components.seconds) s and was ended")
            }
        } catch {
            return .ended(String(describing: error))
        }
    }

    private enum Answer {
        case line(Data)
        /// The child's output closed: it exited.
        case closed
        /// Nothing came by the deadline.
        case overran
    }

    /// The next line the child wrote, its output's close, or the deadline passing first.
    private func nextAnswer(by deadline: ContinuousClock.Instant) -> Answer {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex ..< newline])
                pending.removeSubrange(pending.startIndex ... newline)
                return .line(line)
            }
            guard waitForOutput(until: deadline) else {
                return .overran
            }
            // What the pipe holds now, waiting only until it holds something: a read of a count
            // waits for that many bytes or the end, and an answer is one short line.
            let chunk = answers.availableData
            guard !chunk.isEmpty else {
                return .closed
            }
            pending.append(chunk)
        }
    }

    /// Whether the child's output became readable (a line, or its close) before `deadline`.
    private func waitForOutput(until deadline: ContinuousClock.Instant) -> Bool {
        var descriptor = pollfd(fd: answers.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            let milliseconds = Int32(clamping: DiagnosticsTiming.milliseconds(remaining))
            // time: deadline — a reading that hangs in the child reports nothing (file guide)
            let ready = poll(&descriptor, 1, max(milliseconds, 1))
            if ready > 0 {
                return true
            }
            if ready < 0, errno != EINTR {
                // A descriptor poll cannot wait on: let the read report what the pipe holds.
                return true
            }
        }
    }

    /// Otos's executable: the app's own when this framework is embedded in it, else the
    /// `Otos.app` built beside it.
    static func executable() throws -> URL {
        let frameworks = Bundle(for: SearchTextChild.self).bundleURL.deletingLastPathComponent()
        let app = frameworks.lastPathComponent == "Frameworks"
            ? frameworks.deletingLastPathComponent().deletingLastPathComponent()
            : frameworks.appending(path: "Otos.app", directoryHint: .isDirectory)
        guard let executable = Bundle(url: app)?.executableURL else {
            throw SearchTextChildError.noExecutable(app.path(percentEncoded: false))
        }
        return executable
    }
}

nonisolated enum SearchTextChildError: Error {
    case noExecutable(String)
}

/// A child's input and its exit, shared by the session that reads through it, the reader's
/// shutdown that ends it from another thread mid-reading, and `Process`'s termination handler
/// that reports its exit.
final nonisolated class SearchTextChildLifetime: Sendable {
    private struct State {
        /// The child's input, until it is closed.
        var input: FileHandle?
        var exited = false
        var exitWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(input: FileHandle) {
        state = Mutex(State(input: input))
    }

    /// Writes one request to the child's input; a closed input throws.
    func write(_ request: Data) throws {
        try state.withLock { state in
            guard let input = state.input else {
                throw POSIXError(.EPIPE)
            }
            try input.write(contentsOf: request)
        }
    }

    /// Closes the child's input, once: the child exits at its end.
    func closeInput() {
        guard let input = state.withLock({ state in
            defer { state.input = nil }
            return state.input
        }) else { return }
        do {
            try input.close()
        } catch {
            OtosLog.thumbnails.errorOperation("search.text", phase: "sessionCloseFailed", fields: [
                "error": String(describing: error),
            ])
        }
    }

    /// Ends the child and returns once its exit is reported.
    func end() async {
        closeInput()
        await withCheckedContinuation { continuation in
            let exited = state.withLock { state in
                if !state.exited {
                    state.exitWaiters.append(continuation)
                }
                return state.exited
            }
            if exited {
                continuation.resume()
            }
        }
    }

    /// The child exited: what `Process.terminationHandler` reports.
    func reportExit() {
        let waiters = state.withLock { state in
            state.exited = true
            defer { state.exitWaiters = [] }
            return state.exitWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// The child's side: what `main.swift` runs when Otos is started to read text.
public nonisolated enum SearchTextReadingProcess {
    /// The argument that starts Otos as a text-reading child.
    public static let argument = "--read-text"
    /// Followed by a text, after `argument`: the child answers every picture that decodes with
    /// that one line instead of asking Vision. Only a test starts a child this way, so the
    /// child's pipe protocol, answer deadline and input's-end exit are tested as they run
    /// without waiting on a cold system text model, which can take minutes.
    static let answeringArgument = "--answering"

    struct Request: Codable {
        let path: String
    }

    /// How a child started with `arguments` (those after `argument`) recognises a picture's
    /// text: Vision, or the fixed line `answeringArgument` names. `nil` for arguments it does
    /// not know.
    static func recognizer(for arguments: [String]) -> ((CGImage) throws -> [RecognizedTextLine])? {
        switch arguments.count {
        case 0:
            return SearchTextReading.read
        case 2 where arguments[0] == answeringArgument:
            let line = RecognizedTextLine(text: arguments[1], confidence: SearchTextReading.certainConfidence)
            return { _ in [line] }
        default:
            return nil
        }
    }

    /// Serves as `main.swift` starts it: `arguments` are those after `argument`. Arguments it
    /// does not know end the child at once (status 64), so its parent reads a closed output.
    public static func serve(arguments: [String]) -> Never {
        guard let recognize = recognizer(for: arguments) else {
            OtosLog.thumbnails.errorOperation("search.text", phase: "childArgumentsUnknown", fields: [
                "arguments": arguments.joined(separator: " "),
            ])
            exit(64)
        }
        serve(recognize: recognize)
    }

    /// Answers each request on standard input, one line each, until the input ends or
    /// Vision's reader is lost for this process.
    ///
    /// The input's end is this process's end, whatever a reading is doing. Otos holds the only
    /// writer of this pipe (`Process` closes every other descriptor in a child it starts), so
    /// the input ends when Otos ends the session, quits, crashes or is killed: the kernel
    /// closes a dead process's descriptors. A reading holds its thread inside Vision for as
    /// long as Vision takes — minutes, cold and under load — so the input is read on a thread
    /// that never reads a picture, and at the input's end it exits the process at once
    /// (`_exit`), mid-reading or not. No one is left to read that reading's answer, and its
    /// picture stays owed in Otos's catalog, which only a written reading stamps.
    private static func serve(recognize: @escaping (CGImage) throws -> [RecognizedTextLine]) -> Never {
        let readings = DispatchSerialQueue(label: "net.melisma.Otos.search.text.child", qos: .utility)
        let input = Thread {
            while let line = readLine(strippingNewline: true) {
                // Otos asks for one picture at a time and waits for its answer, so at most
                // one reading is queued here.
                readings.async { answer(line, recognize: recognize) }
            }
            OtosLog.thumbnails.noticeOperation("search.text", phase: "childInputEnded", fields: [
                "pid": "\(getpid())",
            ])
            _exit(0)
        }
        input.qualityOfService = .utility
        input.start()
        dispatchMain()
    }

    /// Reads one request's picture and writes its answer. The process exits after an answer
    /// that ends it, and when an answer cannot be written.
    private static func answer(_ line: String, recognize: (CGImage) throws -> [RecognizedTextLine]) {
        let reading: SearchTextPreviewReading
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            reading = SearchTextReading.readPreview(at: URL(filePath: request.path), recognize: recognize)
        } catch {
            reading = .failed("unreadable request: \(error)")
        }
        do {
            var answer = try JSONEncoder().encode(reading)
            answer.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: answer)
        } catch {
            exit(1)
        }
        if case .ended = reading {
            exit(0)
        }
    }
}
