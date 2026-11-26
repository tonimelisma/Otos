import Foundation
import OSLog

/// Diagnostics export guide
///
/// The owner develops Otos from sessions that cannot reach his Mac (plan 0118), so what the
/// installed app experienced reaches a session only when he hands it over. Help ▸ Export
/// Diagnostics… writes one new folder into a folder he chooses (ADR 0060):
///
/// - `about.json`: the build, the Mac, when it was written, and where the log lines came
///   from or why there are none;
/// - `log.ndjson`: Otos's own log lines of the last day at info and above, one JSON object
///   a line (date, category, level, message);
/// - `crash-reports/`: the system's crash and hang reports for Otos;
/// - `metrickit/`: the MetricKit diagnostic payloads the app kept (`MetricKitRecorder`);
/// - `storage.json`: the size and file count of each folder Otos keeps in Application
///   Support.
///
/// Everything is read from where Otos and the system already keep it; nothing is sent
/// anywhere. The folder is written in the system's scratch folder on the destination's
/// volume and moved in by `ExclusivePublication`, so the chosen folder never holds a partial
/// export and nothing in it is ever replaced: a name already taken gets ` 2`, ` 3`….
///
/// `Sources` names every place read, so a test points the export at folders of its own; the
/// app's lifecycle is the one place that names the real ones.
nonisolated struct DiagnosticsExport: Sendable {
    /// One log line as the export writes it.
    struct LogLine: Codable, Equatable, Sendable {
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    /// The log lines since a moment, and which store answered: the system's, which keeps
    /// every Otos session, or only this process's.
    struct LogReading: Sendable {
        let scope: String
        let lines: [LogLine]
    }

    struct About: Codable, Equatable, Sendable {
        let bundleIdentifier: String
        let version: String
        let build: String
        let macOS: String
        let model: String
        var writtenAt: Date
        var logScope: String
        var logSince: Date
        var logLines: Int
    }

    /// Where each part comes from.
    struct Sources: Sendable {
        /// Otos's own folder in Application Support (`…/Application Support/<bundle id>`).
        let applicationSupport: URL
        /// The system's diagnostic reports folder (`~/Library/Logs/DiagnosticReports`).
        let diagnosticReports: URL
        /// The file-name prefix of this app's reports there (`Otos`).
        let processName: String
        let bundleIdentifier: String
        let version: String
        let build: String
        let macOS: String
        let model: String
        /// Otos's log lines since a moment. A throw is written into `about.json` as the reason
        /// there are none; it never stops the rest of the export.
        let readLog: @Sendable (Date) throws -> LogReading
    }

    enum Outcome: Equatable, Sendable {
        case written(URL)
        case failed(String)
    }

    /// How far back the log lines reach.
    static let logWindow: TimeInterval = 24 * 60 * 60
    /// The MetricKit payloads' folder inside Otos's Application Support folder.
    static let metricKitFolder = "Diagnostics/MetricKit"

    let sources: Sources

    /// The new folder's name for a moment: `Otos Diagnostics 2026-11-26 17.40.12`, in the
    /// Mac's own time zone.
    static func folderName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Otos Diagnostics " + formatter.string(from: date)
    }

    /// Writes the export into `folder`, which must exist. Blocking: callers run it off the
    /// main actor.
    func write(into folder: URL, now: Date) -> Outcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .failed("The folder “\(folder.lastPathComponent)” no longer exists.")
        }
        let scratch: URL
        do {
            scratch = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: folder,
                create: true
            )
        } catch {
            OtosLog.app.errorOperation("diagnostics.export", phase: "failed", fields: [
                "step": "scratch",
                "error": String(describing: error),
            ])
            return .failed(error.localizedDescription)
        }
        defer { removeScratch(scratch) }
        let staging = scratch.appending(path: Self.folderName(at: now), directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            try fill(staging, now: now)
        } catch {
            OtosLog.app.errorOperation("diagnostics.export", phase: "failed", fields: [
                "step": "stage",
                "error": String(describing: error),
            ])
            return .failed(error.localizedDescription)
        }
        return publish(staging, into: folder, now: now)
    }

    private func fill(_ staging: URL, now: Date) throws {
        let since = now.addingTimeInterval(-Self.logWindow)
        var about = About(
            bundleIdentifier: sources.bundleIdentifier,
            version: sources.version,
            build: sources.build,
            macOS: sources.macOS,
            model: sources.model,
            writtenAt: now,
            logScope: "unread",
            logSince: since,
            logLines: 0
        )
        do {
            let reading = try sources.readLog(since)
            about.logScope = reading.scope
            about.logLines = reading.lines.count
            try writeLines(reading.lines, to: staging.appending(path: "log.ndjson", directoryHint: .notDirectory))
        } catch {
            about.logScope = "unavailable: \(error)"
            OtosLog.app.errorOperation("diagnostics.export", phase: "logUnavailable", fields: [
                "error": String(describing: error),
            ])
        }
        try copyReports(into: staging.appending(path: "crash-reports", directoryHint: .isDirectory))
        try copyMetricKit(into: staging.appending(path: "metrickit", directoryHint: .isDirectory))
        try encoder().encode(storage()).write(to: staging.appending(path: "storage.json", directoryHint: .notDirectory))
        try encoder().encode(about).write(to: staging.appending(path: "about.json", directoryHint: .notDirectory))
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func writeLines(_ lines: [LogLine], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for line in lines {
            try data.append(encoder.encode(line))
            data.append(0x0A)
        }
        try data.write(to: url)
    }

    /// The system's reports whose names start with the app's name: `Otos-2026-11-26-….ips`,
    /// `Otos_2026-11-26-…_Mac.hang`. Another app's are never copied.
    private func copyReports(into destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for report in try contents(of: sources.diagnosticReports) {
            let name = report.lastPathComponent
            let ownName = name.hasPrefix(sources.processName + "-") || name.hasPrefix(sources.processName + "_")
            guard ownName, ["ips", "crash", "hang", "diag", "spin"].contains(report.pathExtension) else {
                continue
            }
            try FileManager.default.copyItem(at: report, to: destination.appending(path: name, directoryHint: .notDirectory))
        }
    }

    private func copyMetricKit(into destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let kept = sources.applicationSupport.appending(path: Self.metricKitFolder, directoryHint: .isDirectory)
        for payload in try contents(of: kept) where payload.pathExtension == "json" {
            try FileManager.default.copyItem(
                at: payload,
                to: destination.appending(path: payload.lastPathComponent, directoryHint: .notDirectory)
            )
        }
    }

    /// A folder's entries, or none when the folder does not exist: a Mac with no report yet
    /// has no reports folder entry for Otos, and that is a fact, not a failure.
    private func contents(of folder: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    struct FolderSize: Codable, Equatable, Sendable {
        let name: String
        let bytes: Int64
        let files: Int
    }

    /// Each entry of Otos's Application Support folder: its allocated bytes and file count.
    private func storage() throws -> [FolderSize] {
        try contents(of: sources.applicationSupport).map { entry in
            let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let items = isDirectory
                ? try FileManager.default.subpathsOfDirectory(atPath: entry.path(percentEncoded: false)).map {
                    entry.appending(path: $0, directoryHint: .notDirectory)
                }
                : [entry]
            var bytes: Int64 = 0
            var files = 0
            for item in items {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
                guard values.isRegularFile == true, let size = values.totalFileAllocatedSize else { continue }
                files += 1
                bytes += Int64(size)
            }
            return FolderSize(name: entry.lastPathComponent, bytes: bytes, files: files)
        }
    }

    private func publish(_ staging: URL, into folder: URL, now: Date) -> Outcome {
        let name = Self.folderName(at: now)
        for attempt in 1 ... 99 {
            let final = folder.appending(
                path: attempt == 1 ? name : "\(name) \(attempt)",
                directoryHint: .isDirectory
            )
            switch ExclusivePublication.publish(staging: staging, final: final) {
            case .published:
                OtosLog.app.noticeOperation("diagnostics.export", phase: "written", fields: [
                    "path": final.path(percentEncoded: false),
                ])
                return .written(final)
            case .destinationExists:
                continue
            case let .failed(failure):
                OtosLog.app.errorOperation("diagnostics.export", phase: "failed", fields: [
                    "step": "publish",
                    "detail": failure.detail,
                ])
                return .failed(failure.outOfSpace
                    ? "The disk holding “\(folder.lastPathComponent)” is full."
                    : "Otos couldn’t write into “\(folder.lastPathComponent)”.")
            }
        }
        return .failed("“\(folder.lastPathComponent)” already holds 99 exports from this second.")
    }

    /// The scratch folder goes however the export ended: after a publish it is empty.
    private func removeScratch(_ scratch: URL) {
        do {
            try FileManager.default.removeItem(at: scratch)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            OtosLog.app.errorOperation("diagnostics.export", phase: "scratchLeft", fields: [
                "path": scratch.path(percentEncoded: false),
                "error": String(describing: error),
            ])
        }
    }
}

nonisolated extension DiagnosticsExport {
    /// Otos's log lines since `since`, at info and above, from the system's store, which keeps
    /// every session an administrator's account may read; failing that, from this process's
    /// own, which keeps only this launch.
    static func systemLog(subsystem: String) -> @Sendable (Date) throws -> LogReading {
        { since in
            let store: OSLogStore
            let scope: String
            do {
                store = try OSLogStore(scope: .system)
                scope = "system"
            } catch {
                OtosLog.app.errorOperation("diagnostics.export", phase: "systemLogRefused", fields: [
                    "error": String(describing: error),
                ])
                store = try OSLogStore(scope: .currentProcessIdentifier)
                scope = "currentProcess"
            }
            let entries = try store.getEntries(
                at: store.position(date: since),
                matching: NSPredicate(format: "subsystem == %@", subsystem)
            )
            var lines: [LogLine] = []
            for case let entry as OSLogEntryLog in entries where entry.level != .debug && entry.level != .undefined {
                lines.append(LogLine(
                    date: entry.date,
                    category: entry.category,
                    level: Self.levelName(entry.level),
                    message: entry.composedMessage
                ))
            }
            return LogReading(scope: scope, lines: lines)
        }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .debug: "debug"
        case .undefined: "undefined"
        @unknown default: "unknown"
        }
    }
}
