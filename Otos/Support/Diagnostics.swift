import Foundation
import OSLog

/// Durable diagnostics guide
///
/// JSONL is a debug-only, machine-checkable record for coarse catalog operations,
/// projection summaries, aggregated scan issues, failures, and detected stalls.
/// It is not the high-frequency UI tracing system; Logger and OSSignposter serve
/// that path without allocating asynchronous file-write work on MainActor.
///
/// Default diagnostics are session-scoped:
/// `catalog-diagnostics-<UTC>-p<PID>-<prod|test>.jsonl`. Default lifecycle
/// preparation removes the retired unbounded `catalog-diagnostics.jsonl` and keeps
/// only the newest ten default files per run kind, even when JSONL writes are
/// disabled. Injected `outputURL` instances are exempt from pruning so focused
/// tests can use temporary paths without side effects.
///
/// This actor serializes append order and owns one lazily opened file handle.
/// Callers outside UI hot paths may await `record`, which provides natural
/// backpressure and guarantees that a returned call has written one complete
/// line. Tests can remove the file safely because removal first closes the owned
/// handle and the next record lazily reopens it.
nonisolated struct CatalogDiagnosticEvent: Codable, Equatable {
    let timestamp: Date
    let operation: String
    let phase: String
    let fields: [String: String]
}

actor CatalogDiagnostics {
    static let shared = CatalogDiagnostics(
        outputURL: CatalogDiagnostics.defaultOutputURL(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos"
        ),
        managesDefaultDirectory: true
    )

    private nonisolated static let retainedSessionFileCountPerRunKind = 10
    private nonisolated static let legacyDiagnosticsFileName = "catalog-diagnostics.jsonl"

    private let outputURL: URL
    private let isEnabled: Bool
    private let managesDefaultDirectory: Bool
    private let encoder: JSONEncoder
    private var fileHandle: FileHandle?
    private var preparedDefaultDirectory = false

    init(
        outputURL: URL,
        isEnabled: Bool = CatalogDiagnostics.defaultIsEnabled,
        managesDefaultDirectory: Bool = false
    ) {
        self.outputURL = outputURL
        self.isEnabled = isEnabled
        self.managesDefaultDirectory = managesDefaultDirectory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    deinit {
        try? fileHandle?.close()
    }

    nonisolated static func defaultOutputURL(bundleIdentifier: String) -> URL {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupportURL
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
            .appending(
                path: "catalog-diagnostics-\(RunContext.sessionID)-\(RunContext.runKind).jsonl"
            )
    }

    func prepareForLifecycle() {
        prepareDefaultDirectoryIfNeeded()
    }

    func record(operation: String, phase: String, fields: [String: String] = [:]) async {
        guard isEnabled else {
            return
        }

        let event = CatalogDiagnosticEvent(
            timestamp: Date(),
            operation: operation,
            phase: phase,
            fields: fields
        )

        do {
            var data = try encoder.encode(event)
            data.append(0x0A)
            let handle = try writableHandle()
            try handle.write(contentsOf: data)
        } catch {
            try? fileHandle?.close()
            fileHandle = nil
            OtosLog.performance.error("Catalog diagnostics write failed")
        }
    }

    func removeExistingDiagnosticsForTesting() throws {
        try fileHandle?.close()
        fileHandle = nil
        guard FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: outputURL)
    }

    func outputURLForTesting() -> URL {
        outputURL
    }

    private func writableHandle() throws -> FileHandle {
        if let fileHandle {
            return fileHandle
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let path = outputURL.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        try handle.seekToEnd()
        fileHandle = handle
        return handle
    }

    private func prepareDefaultDirectoryIfNeeded() {
        guard managesDefaultDirectory, !preparedDefaultDirectory else {
            return
        }
        preparedDefaultDirectory = true
        Self.prepareDefaultDirectory(for: outputURL)
    }

    private nonisolated static func prepareDefaultDirectory(for outputURL: URL) {
        let directory = outputURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacyURL = directory.appending(path: legacyDiagnosticsFileName)
            if fileManager.fileExists(atPath: legacyURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: legacyURL)
            }
            try pruneSessionFiles(in: directory, runKind: "prod", fileManager: fileManager)
            try pruneSessionFiles(in: directory, runKind: "test", fileManager: fileManager)
        } catch {
            OtosLog.performance.error(
                "Catalog diagnostics retention failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private nonisolated static func pruneSessionFiles(
        in directory: URL,
        runKind: String,
        fileManager: FileManager
    ) throws {
        let suffix = "-\(runKind).jsonl"
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let sessionFiles = urls.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("catalog-diagnostics-") && name.hasSuffix(suffix)
        }
        let sortedFiles = sessionFiles.sorted { lhs, rhs in
            modificationDate(of: lhs) > modificationDate(of: rhs)
        }
        for url in sortedFiles.dropFirst(retainedSessionFileCountPerRunKind) {
            try fileManager.removeItem(at: url)
        }
    }

    private nonisolated static func modificationDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    /// Debug builds write shared session JSONL for both app and test runs. Release
    /// builds keep durable diagnostics disabled until a shipping requirement asks for
    /// them.
    private nonisolated static var defaultIsEnabled: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}
