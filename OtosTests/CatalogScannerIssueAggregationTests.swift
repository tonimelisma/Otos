import Foundation
@testable import Otos
import Testing

struct CatalogScannerIssueAggregationTests {
    @Test func scanAggregatesRepeatedRelativePathIssuesForMismatchedRootSpelling() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let realRoot = temp.appending(path: "CloudStorage/Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        for index in 0 ..< 12 {
            try writeCatalogStoreFile(realRoot.appending(path: "photo-\(index).jpg"), contents: "jpeg")
        }
        let mismatchedRoot = LibraryRootPath(rawValue: realRoot.path(percentEncoded: false) + "/.")

        do {
            _ = try await CatalogScanner.live.scanRoot(
                mismatchedRoot,
                .milliseconds(1),
                nil
            ) { _ in }
            Issue.record("A non-normalized root spelling should not produce successful relative paths")
        } catch let CatalogScanError.filesystemErrorsEncountered(count, summaries) {
            #expect(count == 12)
            #expect(summaries.count == 1)
            let summary = try #require(summaries.first)
            #expect(summary.kind == "resource")
            #expect(summary.errorDescription == "relativePathUnavailable")
            #expect(summary.count == 12)
            #expect(summary.examplePaths.count == 10)
        }
    }
}
