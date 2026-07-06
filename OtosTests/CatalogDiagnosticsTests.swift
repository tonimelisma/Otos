import Foundation
@testable import Otos
import Testing

struct CatalogDiagnosticsTests {
    @Test func diagnosticsWriterAppendsMultipleJSONLinesThroughOneOwner() async throws {
        let temp = try makeDiagnosticsTemporaryDirectory()
        let outputURL = temp.appending(path: "catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)

        await diagnostics.record(
            operation: "catalog.scan",
            phase: "error",
            fields: [
                "rootPath": "/Users/example/Pictures",
                "path": "/Users/example/Pictures/broken.jpg",
            ]
        )
        await diagnostics.record(
            operation: "catalog.scan",
            phase: "finish",
            fields: ["observed": "1"]
        )

        let data = try Data(contentsOf: outputURL)
        let contents = try decodedUTF8(data)
        let lines = contents
            .split(separator: "\n")
        #expect(lines.count == 2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(CatalogDiagnosticEvent.self, from: Data(lines[0].utf8))
        #expect(event.operation == "catalog.scan")
        #expect(event.phase == "error")
        #expect(event.fields["path"] == "/Users/example/Pictures/broken.jpg")
    }

    @Test func diagnosticsRemovalClosesHandleAndNextRecordReopensFile() async throws {
        let temp = try makeDiagnosticsTemporaryDirectory()
        let outputURL = temp.appending(path: "catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)

        await diagnostics.record(operation: "before", phase: "finish")
        try await diagnostics.removeExistingDiagnosticsForTesting()
        await diagnostics.record(operation: "after", phase: "finish")

        let contents = try decodedUTF8(Data(contentsOf: outputURL))
        #expect(!contents.contains("\"operation\":\"before\""))
        #expect(contents.contains("\"operation\":\"after\""))
    }

    @Test func defaultOutputURLIsSessionScopedAndLabelsTestRuns() {
        let outputURL = CatalogDiagnostics.defaultOutputURL(bundleIdentifier: "net.melisma.OtosTests")
        let fileName = outputURL.lastPathComponent

        #expect(fileName.hasPrefix("catalog-diagnostics-"))
        #expect(fileName.contains("-p\(ProcessInfo.processInfo.processIdentifier)-"))
        #expect(fileName.hasSuffix("-\(RunContext.runKind).jsonl"))
        #expect(RunContext.runKind == "test")
    }

    @Test func defaultDiagnosticsWriteInTestSessions() async {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "shared-default-\(UUID().uuidString)")
            .appending(path: "catalog-diagnostics-\(RunContext.sessionID)-test.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL)
        await diagnostics.record(operation: "test", phase: "finish")
        #expect(FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
    }

    @Test func defaultDiagnosticsLifecyclePreparationPrunesOldSessionFilesAndDeletesLegacyFile() async throws {
        let temp = try makeDiagnosticsTemporaryDirectory()
        let diagnosticsDirectory = temp.appending(path: "Diagnostics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let legacyURL = diagnosticsDirectory.appending(path: "catalog-diagnostics.jsonl")
        try Data("legacy\n".utf8).write(to: legacyURL)

        for index in 0 ..< 12 {
            let prodURL = diagnosticsDirectory.appending(
                path: "catalog-diagnostics-20260703T1200\(String(format: "%02d", index))Z-p\(index)-prod.jsonl"
            )
            let testURL = diagnosticsDirectory.appending(
                path: "catalog-diagnostics-20260703T1300\(String(format: "%02d", index))Z-p\(index)-test.jsonl"
            )
            try Data("prod\n".utf8).write(to: prodURL)
            try Data("test\n".utf8).write(to: testURL)
            let date = Date(timeIntervalSince1970: TimeInterval(index))
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: prodURL.path(percentEncoded: false)
            )
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: testURL.path(percentEncoded: false)
            )
        }

        let outputURL = diagnosticsDirectory.appending(path: "catalog-diagnostics-current-p999-prod.jsonl")
        let diagnostics = CatalogDiagnostics(
            outputURL: outputURL,
            isEnabled: true,
            managesDefaultDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)))

        await diagnostics.prepareForLifecycle()

        let remaining = try FileManager.default.contentsOfDirectory(
            at: diagnosticsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
        #expect(remaining.count(where: { $0.lastPathComponent.hasSuffix("-prod.jsonl") }) == 10)
        #expect(remaining.count(where: { $0.lastPathComponent.hasSuffix("-test.jsonl") }) == 10)
    }

    @Test func disabledDiagnosticsDoesNotCreateAFile() async throws {
        let temp = try makeDiagnosticsTemporaryDirectory()
        let outputURL = temp.appending(path: "catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: false)

        await diagnostics.record(operation: "disabled", phase: "finish")

        #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
    }

    @Test func disabledDefaultDiagnosticsLifecyclePreparationStillPrunesOldFiles() async throws {
        let temp = try makeDiagnosticsTemporaryDirectory()
        let diagnosticsDirectory = temp.appending(path: "Diagnostics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let legacyURL = diagnosticsDirectory.appending(path: "catalog-diagnostics.jsonl")
        try Data("legacy\n".utf8).write(to: legacyURL)

        for index in 0 ..< 12 {
            let prodURL = diagnosticsDirectory.appending(
                path: "catalog-diagnostics-20260703T1400\(String(format: "%02d", index))Z-p\(index)-prod.jsonl"
            )
            try Data("prod\n".utf8).write(to: prodURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: prodURL.path(percentEncoded: false)
            )
        }

        let outputURL = diagnosticsDirectory.appending(path: "catalog-diagnostics-current-p999-prod.jsonl")
        let diagnostics = CatalogDiagnostics(
            outputURL: outputURL,
            isEnabled: false,
            managesDefaultDirectory: true
        )

        await diagnostics.prepareForLifecycle()

        let remaining = try FileManager.default.contentsOfDirectory(
            at: diagnosticsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
        #expect(remaining.count(where: { $0.lastPathComponent.hasSuffix("-prod.jsonl") }) == 10)
    }

    @Test func diagnosticsScriptSummarizesJsonLines() async throws {
        let temp = try makeDiagnosticsTemporaryDirectory()
        let outputURL = temp.appending(path: "catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)
        await writeSummaryFixtureEvents(diagnostics)

        let result = try runDiagnosticsScript(diagnosticsFile: outputURL)
        #expect(result.status == 0)
        let output = result.output
        #expect(output.contains("events: 13"))
        #expect(output.contains("scan starts: 1"))
        #expect(output.contains("scan batches: 1"))
        #expect(output.contains("stale scan callbacks ignored: 1"))
        #expect(output.contains("skipped packages: 1"))
        #expect(output.contains("startup callers coalesced: 1"))
        #expect(output.contains("window projections: 1"))
        #expect(output.contains("window projection detail refreshes: 1"))
        #expect(output.contains("structural applies: 1"))
        #expect(output.contains("tile-detail query slow single-row records: 0"))
        #expect(output.contains("grid counter records: 1"))
        #expect(output.contains("download lifecycle materialized: 1"))
        #expect(output.contains("main run loop stalls: 1"))
        #expect(output.contains("library availability changes: 1"))
        #expect(output.contains("catalog diagnostics check passed"))
    }

    @Test func diagnosticsScriptCheckFailsForWatchdogCounter() async throws {
        let temp = try makeDiagnosticsTemporaryDirectory()
        let outputURL = temp.appending(path: "catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)
        await diagnostics.record(
            operation: "ui.grid.counters",
            phase: "interval",
            fields: [
                "watchdogCount": "1",
                "totalWatchdogCount": "1",
            ]
        )

        let result = try runDiagnosticsScript(diagnosticsFile: outputURL)
        #expect(result.status == 1)
        #expect(result.output.contains("watchdog counter is 1, expected 0"))
    }
}

private func writeSummaryFixtureEvents(_ diagnostics: CatalogDiagnostics) async {
    await writeBasicSummaryFixtureEvents(diagnostics)
    await writeHealthyGridFixtureEvents(diagnostics)
    await writeHealthyDownloadFixtureEvents(diagnostics)
}

private func writeBasicSummaryFixtureEvents(_ diagnostics: CatalogDiagnostics) async {
    await diagnostics.record(operation: "catalog.scan", phase: "start")
    await diagnostics.record(operation: "catalog.scan.batch", phase: "finish", fields: ["count": "2"])
    await diagnostics.record(operation: "catalog.scan.staleCallback", phase: "ignored")
    await diagnostics.record(operation: "catalog.start", phase: "coalesced")
    await diagnostics.record(
        operation: "catalog.scan.skippedPackage",
        phase: "skip",
        fields: ["path": "/Users/example/Pictures/Photos Library.photoslibrary"]
    )
    await diagnostics.record(
        operation: "catalog.projection.window",
        phase: "finish",
        fields: [
            "assetCount": "2",
            "storeReadMs": "1",
            "projectionMs": "2",
            "totalMs": "3",
            "assetOrderQueryMs": "1",
            "detailRefreshChanged": "true",
        ]
    )
    await diagnostics.record(
        operation: "ui.mainRunLoop.stall",
        phase: "detected",
        fields: [
            "stallMs": "150",
            "latestUpdateID": "1",
            "latestItems": "2",
        ]
    )
    await diagnostics.record(operation: "catalog.library.availability", phase: "unavailable")
}

private func writeHealthyGridFixtureEvents(_ diagnostics: CatalogDiagnostics) async {
    await diagnostics.record(
        operation: "ui.mediaGrid.structuralApply",
        phase: "finish",
        fields: [
            "applyMs": "80",
            "visibleDetailRequestCount": "30",
        ]
    )
    await diagnostics.record(
        operation: "catalog.store.query.tileDetail",
        phase: "finish",
        fields: [
            "requested": "30",
            "returned": "30",
            "queryMs": "20",
        ]
    )
    await diagnostics.record(
        operation: "ui.grid.counters",
        phase: "interval",
        fields: [
            "cacheHits": "10",
            "cacheMisses": "2",
            "cacheInserts": "3",
            "watchdogCount": "0",
            "totalCacheHits": "10",
            "totalCacheMisses": "2",
            "totalCacheInserts": "3",
            "totalCacheHitRatePermille": "833",
            "totalWatchdogCount": "0",
        ]
    )
}

private func writeHealthyDownloadFixtureEvents(_ diagnostics: CatalogDiagnostics) async {
    await diagnostics.record(
        operation: "catalog.thumbnails.visibleLifecycle",
        phase: "materialized",
        fields: [
            "rootPath": "/Users/example/Pictures",
            "relativePath": "cloud.jpg",
            "outcome": "materialized",
            "rerequestCount": "2",
            "requestToCompleteMs": "123",
        ]
    )
    await diagnostics.record(
        operation: "catalog.thumbnails.visibleLifecycle",
        phase: "claimed",
        fields: [
            "rootPath": "/Users/example/Pictures",
            "relativePath": "cloud.jpg",
        ]
    )
}

private func runDiagnosticsScript(diagnosticsFile: URL) throws -> (status: Int32, output: String) {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let process = Process()
    process.executableURL = repoRoot.appending(path: "script/catalog-diagnostics.sh")
    process.arguments = ["check"]
    var environment = ProcessInfo.processInfo.environment
    environment["OTOS_CATALOG_DIAGNOSTICS_FILE"] = diagnosticsFile.path(percentEncoded: false)
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    return try (
        process.terminationStatus,
        decodedUTF8(pipe.fileHandleForReading.readDataToEndOfFile())
    )
}

private func makeDiagnosticsTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosDiagnosticsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func decodedUTF8(_ data: Data) throws -> String {
    guard let string = String(data: data, encoding: .utf8) else {
        throw CatalogDiagnosticsTestError.invalidUTF8
    }
    return string
}

private enum CatalogDiagnosticsTestError: Error {
    case invalidUTF8
}
