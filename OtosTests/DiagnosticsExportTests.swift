import Foundation
@testable import OtosKit
import Testing

/// Help ▸ Export Diagnostics… (APP-098, ADR 0060): what the export writes, from sources a
/// test names, and that it never replaces anything in the chosen folder.
@Suite(.testScope)
struct DiagnosticsExportTests {
    /// A fixed moment, so the folder's name is known: 2026-11-26 17:40:12 UTC.
    private static let moment = Date(timeIntervalSince1970: 1_795_714_812)

    private struct Fixture {
        let sources: DiagnosticsExport.Sources
        let destination: URL
    }

    private enum LogRefused: Error {
        case notAllowed
    }

    private func makeFixture(
        readLog: @escaping @Sendable (Date) throws -> DiagnosticsExport.LogReading = { _ in
            DiagnosticsExport.LogReading(scope: "system", lines: [
                .init(date: DiagnosticsExportTests.moment, category: "App", level: "notice", message: "op=sessionStart"),
                .init(date: DiagnosticsExportTests.moment, category: "UI", level: "error", message: "op=ui.open phase=failed"),
            ])
        }
    ) throws -> Fixture {
        let root = try makeTestDirectory()
        let support = root.appending(path: "Application Support/net.melisma.Otos", directoryHint: .isDirectory)
        let catalog = support.appending(path: "Catalog", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: catalog.appending(path: "catalog.sqlite", directoryHint: .notDirectory))
        let kept = support.appending(path: DiagnosticsExport.metricKitFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data(#"{"hangDiagnostics":[]}"#.utf8).write(to: kept.appending(path: "a.json", directoryHint: .notDirectory))
        let reports = root.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        for name in ["Otos-2026-11-26-174000.ips", "Otos_2026-11-26-174100_Mac.hang", "OtosHelper-2026.ips", "Safari-2026.ips"] {
            try Data("report".utf8).write(to: reports.appending(path: name, directoryHint: .notDirectory))
        }
        let destination = root.appending(path: "Desktop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return Fixture(
            sources: DiagnosticsExport.Sources(
                applicationSupport: support,
                diagnosticReports: reports,
                processName: "Otos",
                bundleIdentifier: "net.melisma.Otos",
                version: "0.1.7",
                build: "1612",
                macOS: "Version 27.0 (Build 27A1)",
                model: "Mac14,7",
                readLog: readLog
            ),
            destination: destination
        )
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }

    @Test func anExportWritesOneNewFolderOfLogsReportsPayloadsAndSizes() throws {
        let fixture = try makeFixture()
        let export = DiagnosticsExport(sources: fixture.sources)
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(DiagnosticsExport.folderName(at: Self.moment, timeZone: utc) == "Otos Diagnostics 2026-11-26 17.40.12")

        guard case let .written(folder) = export.write(into: fixture.destination, now: Self.moment) else {
            Issue.record("the export was not written")
            return
        }
        #expect(try names(in: fixture.destination) == [folder.lastPathComponent])
        #expect(try names(in: folder) == ["about.json", "crash-reports", "log.ndjson", "metrickit", "storage.json"])
        #expect(try names(in: folder.appending(path: "crash-reports", directoryHint: .isDirectory))
            == ["Otos-2026-11-26-174000.ips", "Otos_2026-11-26-174100_Mac.hang"])
        #expect(try names(in: folder.appending(path: "metrickit", directoryHint: .isDirectory)) == ["a.json"])

        let lines = try String(decoding: Data(contentsOf: folder.appending(path: "log.ndjson", directoryHint: .notDirectory)), as: UTF8.self)
            .split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.contains(#""message":"op=sessionStart""#) == true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let about = try decoder.decode(
            DiagnosticsExport.About.self,
            from: Data(contentsOf: folder.appending(path: "about.json", directoryHint: .notDirectory))
        )
        #expect(about.build == "1612")
        #expect(about.logScope == "system")
        #expect(about.logLines == 2)
        #expect(about.logSince == Self.moment.addingTimeInterval(-DiagnosticsExport.logWindow))

        let storage = try decoder.decode(
            [DiagnosticsExport.FolderSize].self,
            from: Data(contentsOf: folder.appending(path: "storage.json", directoryHint: .notDirectory))
        )
        let catalog = try #require(storage.first { $0.name == "Catalog" })
        #expect(catalog.files == 1)
        #expect(catalog.bytes >= 4096)
        #expect(storage.first { $0.name == "Diagnostics" }?.files == 1)
    }

    @Test func aSecondExportInTheSameSecondIsANewFolderAndTheFirstIsUntouched() throws {
        let fixture = try makeFixture()
        let export = DiagnosticsExport(sources: fixture.sources)
        guard case let .written(first) = export.write(into: fixture.destination, now: Self.moment),
              case let .written(second) = export.write(into: fixture.destination, now: Self.moment)
        else {
            Issue.record("an export was not written")
            return
        }
        #expect(second.lastPathComponent == first.lastPathComponent + " 2")
        #expect(try names(in: fixture.destination) == [first.lastPathComponent, second.lastPathComponent].sorted())
        #expect(try names(in: first) == ["about.json", "crash-reports", "log.ndjson", "metrickit", "storage.json"])
    }

    @Test func aLogThatCannotBeReadIsNamedAndTheRestIsWritten() throws {
        let fixture = try makeFixture(readLog: { _ in throw LogRefused.notAllowed })
        guard case let .written(folder) = DiagnosticsExport(sources: fixture.sources)
            .write(into: fixture.destination, now: Self.moment)
        else {
            Issue.record("the export was not written")
            return
        }
        #expect(try names(in: folder) == ["about.json", "crash-reports", "metrickit", "storage.json"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let about = try decoder.decode(
            DiagnosticsExport.About.self,
            from: Data(contentsOf: folder.appending(path: "about.json", directoryHint: .notDirectory))
        )
        #expect(about.logScope.hasPrefix("unavailable: "))
        #expect(about.logLines == 0)
    }

    @Test func aFolderThatNoLongerExistsIsReportedAndNothingIsWritten() throws {
        let fixture = try makeFixture()
        let gone = fixture.destination.appending(path: "Gone", directoryHint: .isDirectory)
        let outcome = DiagnosticsExport(sources: fixture.sources).write(into: gone, now: Self.moment)
        #expect(outcome == .failed("The folder “Gone” no longer exists."))
        #expect(try names(in: fixture.destination).isEmpty)
    }

    @Test func keptPayloadsAreWrittenAsNewFilesNeverReplacingOne() throws {
        let folder = try makeTestDirectory().appending(path: "MetricKit", directoryHint: .isDirectory)
        MetricKitRecorder.keep([Data("{}".utf8), Data("{\"a\":1}".utf8)], in: folder)
        MetricKitRecorder.keep([Data("{}".utf8)], in: folder)
        let files = try names(in: folder)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.hasSuffix(".json") })
    }
}
