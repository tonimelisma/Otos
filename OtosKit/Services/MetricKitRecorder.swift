import Foundation
import MetricKit

/// MetricKit recorder guide
///
/// macOS hands an app the hangs, crashes, CPU and disk-write exceptions it had, as MetricKit
/// diagnostic reports delivered to the app itself. Nothing else tells a session that cannot
/// reach the owner's Mac what the installed app ran into, so each report is kept as its own
/// JSON (`DiagnosticReport` is `Codable`) in Otos's Application Support folder
/// (`Diagnostics/MetricKit`), where Help ▸ Export Diagnostics… copies it from (ADR 0060). Its
/// call stacks are binary images and offsets; a session symbolicates them against the
/// release's dSYMs.
///
/// One `MetricManager` for the session, and one loop over its diagnostic reports, detached
/// from the main actor because each report is a file write. The loop ends when the recorder
/// goes. A report that cannot be written is logged and dropped: the next one is independent
/// of it.
final nonisolated class MetricKitRecorder: Sendable {
    private let consumer: Task<Void, Never>

    private init(folder: URL) {
        let manager = MetricManager()
        consumer = Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            for await report in manager.diagnosticReports {
                do {
                    try Self.keep([encoder.encode(report)], in: folder)
                } catch {
                    OtosLog.app.errorOperation("diagnostics.metricKit", phase: "encodeFailed", fields: [
                        "error": String(describing: error),
                    ])
                }
            }
        }
    }

    deinit {
        consumer.cancel()
    }

    /// Starts keeping the session's diagnostic reports in `folder`. The caller holds the
    /// recorder for the session.
    static func start(folder: URL) -> MetricKitRecorder {
        let recorder = MetricKitRecorder(folder: folder)
        OtosLog.app.noticeOperation("diagnostics.metricKit", phase: "listening", fields: [
            "folder": folder.path(percentEncoded: false),
        ])
        return recorder
    }

    /// Writes each report as `<UTC time>-<token>.json`, never replacing a file.
    static func keep(_ representations: [Data], in folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            OtosLog.app.errorOperation("diagnostics.metricKit", phase: "folderFailed", fields: [
                "error": String(describing: error),
            ])
            return
        }
        let stamp = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
        for data in representations {
            let token = UUID().uuidString.prefix(8)
            let file = folder.appending(path: "\(stamp)-\(token).json", directoryHint: .notDirectory)
            do {
                try data.write(to: file, options: .withoutOverwriting)
                OtosLog.app.noticeOperation("diagnostics.metricKit", phase: "kept", fields: [
                    "file": file.lastPathComponent,
                    "bytes": "\(data.count)",
                ])
            } catch {
                OtosLog.app.errorOperation("diagnostics.metricKit", phase: "writeFailed", fields: [
                    "file": file.lastPathComponent,
                    "error": String(describing: error),
                ])
            }
        }
    }
}
