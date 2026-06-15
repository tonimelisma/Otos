import Foundation
import OSLog

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

    init(outputURL: URL, isEnabled: Bool = CatalogDiagnostics.defaultIsEnabled) {
        self.outputURL = outputURL
        self.isEnabled = isEnabled
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
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
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
                _ = FileManager.default.createFile(atPath: outputURL.path(percentEncoded: false), contents: nil)
            }
            var data = try encoder.encode(event)
            data.append(0x0A)
            let handle = try FileHandle(forWritingTo: outputURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            OtosLog.performance.error("Catalog diagnostics write failed")
        }
    }

    func removeExistingDiagnosticsForTesting() throws {
        guard FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: outputURL)
    }

    func outputURLForTesting() -> URL {
        outputURL
    }

    private nonisolated static var defaultIsEnabled: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}
