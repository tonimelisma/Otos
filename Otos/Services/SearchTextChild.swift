import Foundation

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
/// The child is the app's executable in the installed app, beside the `OtosKit` framework it
/// embeds, and the built `Otos.app` beside the framework when tests load it from the build's
/// products. It reads the same previews from Application Support the app does, and reads
/// nothing else.
final nonisolated class SearchTextChild: SearchTextSession {
    private let process: Process
    private let requests: FileHandle
    private let answers: FileHandle
    private var pending = Data()

    /// Starts a child from Otos's own executable.
    static func start() throws -> any SearchTextSession {
        try SearchTextChild(executable: executable())
    }

    init(executable: URL) throws {
        let input = Pipe()
        let output = Pipe()
        // A write to a child that has exited fails with EPIPE instead of signalling this process.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        process = Process()
        process.executableURL = executable
        process.arguments = [SearchTextReadingProcess.argument]
        // Background reading, as the reader's own queue is.
        process.qualityOfService = .utility
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        requests = input.fileHandleForWriting
        answers = output.fileHandleForReading
        OtosLog.thumbnails.noticeOperation("search.text", phase: "sessionStarted", fields: [
            "pid": "\(process.processIdentifier)",
        ])
    }

    deinit {
        // Closing its input ends the child; terminating it ends one that is mid-reading.
        do {
            try requests.close()
        } catch {
            OtosLog.thumbnails.errorOperation("search.text", phase: "sessionCloseFailed", fields: [
                "pid": "\(process.processIdentifier)", "error": String(describing: error),
            ])
        }
        process.terminate()
    }

    /// The child's process identifier, for a test that ends it.
    var processIdentifier: Int32 {
        process.processIdentifier
    }

    func read(_ url: URL) -> SearchTextPreviewReading {
        do {
            var request = try JSONEncoder().encode(SearchTextReadingProcess.Request(path: url.path(percentEncoded: false)))
            request.append(0x0A)
            try requests.write(contentsOf: request)
            guard let answer = nextAnswer() else {
                return .exited("the reading process exited before it answered")
            }
            return try JSONDecoder().decode(SearchTextPreviewReading.self, from: answer)
        } catch {
            return .ended(String(describing: error))
        }
    }

    /// The next line the child wrote, or nil once its output closed.
    private func nextAnswer() -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex ..< newline])
                pending.removeSubrange(pending.startIndex ... newline)
                return line
            }
            // What the pipe holds now, waiting only until it holds something: a read of a count
            // waits for that many bytes or the end, and an answer is one short line.
            let chunk = answers.availableData
            guard !chunk.isEmpty else {
                return nil
            }
            pending.append(chunk)
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

/// The child's side: what `main.swift` runs when Otos is started to read text.
public nonisolated enum SearchTextReadingProcess {
    /// The argument that starts Otos as a text-reading child.
    public static let argument = "--read-text"

    struct Request: Codable {
        let path: String
    }

    /// Answers each request on standard input, one line each, until the input closes or
    /// Vision's reader is lost for this process.
    public static func serve() -> Never {
        while let line = readLine(strippingNewline: true) {
            let reading: SearchTextPreviewReading
            do {
                let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                reading = SearchTextReading.readPreview(at: URL(filePath: request.path))
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
        exit(0)
    }
}
