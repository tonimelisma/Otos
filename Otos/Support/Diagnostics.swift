import Foundation
import OSLog

/// Durable diagnostics guide
///
/// JSONL is a debug-only, machine-checkable record for coarse catalog operations,
/// projection summaries, filesystem issues, failures, and detected stalls. It is
/// not the high-frequency UI tracing system; Logger and OSSignposter serve that
/// path without allocating asynchronous file-write work on MainActor.
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
        )
    )

    private let outputURL: URL
    private let isEnabled: Bool
    private let encoder: JSONEncoder
    private var fileHandle: FileHandle?

    init(outputURL: URL, isEnabled: Bool = CatalogDiagnostics.defaultIsEnabled) {
        self.outputURL = outputURL
        self.isEnabled = isEnabled
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
            .appending(path: "catalog-diagnostics.jsonl")
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

    private nonisolated static var defaultIsEnabled: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}
