import Foundation
import Testing

struct SQLiteRetirementSourceHygieneTests {
    @Test func projectionPreservesDirtyQueryDescriptorRequestsAcrossAwaitedReads() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: repoRoot.appending(path: "Otos/Services/CatalogProjection.swift"),
            encoding: .utf8
        )
        let clearBeforeAwait = try #require(content.range(of: "dirty = false"))
        let awaitedQuery = try #require(content.range(of: "orderedAssetIDs = try await store.orderedAssetIDs"))
        let afterAwaitedQuery = content[awaitedQuery.lowerBound...]

        #expect(clearBeforeAwait.lowerBound < awaitedQuery.lowerBound)
        #expect(!afterAwaitedQuery.contains("dirty = false"))
        #expect(content.contains("if dirty {"))
        #expect(content.contains("markDirty(wakeImmediately: true, store: store)"))
        #expect(content.contains("let selectedRequest = queryRequest"))
        #expect(content.contains("request: selectedRequest"))
        #expect(content.contains("selectedDescriptor: selectedRequest.descriptor"))
        #expect(!content.contains("needsOrderRequery"))
        #expect(!content.contains("cachedOrderedAssetIDs"))
    }

    @Test func retiredSnapshotFixturesAndCopiedProductionSQLStayRetired() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let testFiles = try sqliteRetirementSwiftFiles(under: repoRoot.appending(path: "OtosTests"))
            .filter { url in
                let path = url.path(percentEncoded: false)
                return !path.hasSuffix("SQLiteRetirementSourceHygieneTests.swift")
                    && !path.hasSuffix("SourceHygieneTests.swift")
            }
        let retiredTerms = [
            "ProjectionTestState",
            "func makeSnapshot",
            "rootOrderSQL",
            "globalOrderSQL",
            "rootEnrichmentSQL",
            "globalEnrichmentSQL",
            "claimEnrichmentSQL",
        ]

        for file in testFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            for term in retiredTerms {
                #expect(!content.contains(term), "\(term) should not appear in \(file.path(percentEncoded: false))")
            }
        }

        let queryPlanTests = try String(
            contentsOf: repoRoot.appending(path: "OtosTests/CatalogStoreQueryPlanTests.swift"),
            encoding: .utf8
        )
        #expect(queryPlanTests.contains("CatalogStore.orderedAssetIDQuery"))
        #expect(queryPlanTests.contains("CatalogStore.enrichmentClaimQuery"))
    }
}

private func sqliteRetirementSwiftFiles(under directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return try enumerator.compactMap { item in
        guard let url = item as? URL else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true, url.pathExtension == "swift" else {
            return nil
        }
        return url
    }
}
