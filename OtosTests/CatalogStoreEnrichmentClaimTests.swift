import Foundation
import GRDB
@testable import OtosKit
import Testing

struct CatalogStoreEnrichmentClaimTests {
    @Test func startupClearsAbandonedEnrichmentClaims() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let rel = MediaRelativePath(rawValue: "a.jpg")

        let store = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: claimTestSingleFileScanner(rel)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        let firstClaim = try await store.enrichmentCandidates(prioritizing: [], limit: 1)
        #expect(firstClaim.map(\.asset.relativePath) == [rel])
        let blockedByLease = try await store.enrichmentCandidates(prioritizing: [], limit: 1)
        #expect(blockedByLease.isEmpty)
        #expect(try await enrichmentClaimedRowCount(databaseURL: databaseURL) == 1)

        let reloaded = CatalogStore(location: .databaseFile(databaseURL))
        try await reloaded.start(scansSavedLibraries: false)

        #expect(try await enrichmentClaimedRowCount(databaseURL: databaseURL) == 0)
    }

    @Test func priorityClaimingContinuesPastContendedRowsBeforeFallback() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(
            location: .inMemory,
            scanner: claimTestMultiFileScanner([
                EnrichmentClaimScanFixture(name: "claimed.jpg", modifiedAt: 1000),
                EnrichmentClaimScanFixture(name: "visible-second.jpg", modifiedAt: 3000),
                EnrichmentClaimScanFixture(name: "visible-third.jpg", modifiedAt: 2000),
                EnrichmentClaimScanFixture(name: "fallback-newest.jpg", modifiedAt: 4000),
            ])
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 4 }
        let idsByName = Dictionary(uniqueKeysWithValues: scanned.testAssets.map { ($0.relativePath.rawValue, $0.id) })
        let claimedID = try #require(idsByName["claimed.jpg"])
        let visibleSecondID = try #require(idsByName["visible-second.jpg"])
        let visibleThirdID = try #require(idsByName["visible-third.jpg"])

        let firstClaim = try await store.enrichmentCandidates(prioritizing: [claimedID], limit: 1)
        #expect(firstClaim.map(\.asset.relativePath.rawValue) == ["claimed.jpg"])

        let visibleClaims = try await store.enrichmentCandidates(
            prioritizing: [claimedID, visibleSecondID, visibleThirdID],
            limit: 2
        )

        #expect(visibleClaims.map(\.asset.relativePath.rawValue) == ["visible-second.jpg", "visible-third.jpg"])
    }

    @Test func fallbackEnrichmentClaimsUseNewestBestDateOrder() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(
            location: .inMemory,
            scanner: claimTestMultiFileScanner([
                EnrichmentClaimScanFixture(name: "old.jpg", modifiedAt: 1000),
                EnrichmentClaimScanFixture(name: "newest.jpg", modifiedAt: 3000),
                EnrichmentClaimScanFixture(name: "middle.jpg", modifiedAt: 2000),
            ])
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }

        let claims = try await store.enrichmentCandidates(prioritizing: [], limit: 3)

        #expect(claims.map(\.asset.relativePath.rawValue) == ["newest.jpg", "middle.jpg", "old.jpg"])
    }

    @Test func fallbackEnrichmentClaimsRemovableSourcesBeforeFixedLibraries() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let removableRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removableRoot, withIntermediateDirectories: true)
        let removableRawPath = try CatalogPath.normalizedDirectoryPath(for: removableRoot).rawValue
        let scanner = CatalogScanner { rootPath, _, batchHandler in
            let fixture = rootPath.rawValue == removableRawPath
                ? EnrichmentClaimScanFixture(name: "card-old.jpg", modifiedAt: 1000)
                : EnrichmentClaimScanFixture(name: "fixed-new.jpg", modifiedAt: 3000)
            let file = ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: fixture.name),
                name: fixture.name,
                contentTypeIdentifier: "public.jpeg",
                byteSize: 100,
                createdAt: Date(timeIntervalSince1970: fixture.modifiedAt),
                contentModifiedAt: Date(timeIntervalSince1970: fixture.modifiedAt)
            )
            try await batchHandler([file])
            return .mediaOnly([file.relativePath])
        }
        let store = CatalogStore(
            location: .inMemory,
            scanner: scanner,
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        try await store.attachRemovableVolume(
            mountURL: removableRoot,
            identity: "volume:claim-card",
            displayName: "Card",
            isEjectable: false
        )
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning
                && snapshot.removableSources.first?.path.rawValue == removableRawPath
                && snapshot.removableSources.first?.availability == .available
        }

        let claims = try await store.enrichmentCandidates(prioritizing: [], limit: 2)

        #expect(claims.map(\.asset.relativePath.rawValue) == ["card-old.jpg", "fixed-new.jpg"])
    }
}

private struct EnrichmentClaimScanFixture {
    let name: String
    let modifiedAt: TimeInterval
}

private func enrichmentClaimedRowCount(databaseURL: URL) async throws -> Int {
    try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
        try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM media_asset
            WHERE enrichment_claimed_until IS NOT NULL
            """
        ) ?? 0
    }
}

private func claimTestSingleFileScanner(_ rel: MediaRelativePath) -> CatalogScanner {
    CatalogScanner { _, _, batchHandler in
        try await batchHandler([
            ScannedMediaFile(
                relativePath: rel,
                name: "a.jpg",
                contentTypeIdentifier: "public.jpeg",
                byteSize: 100,
                createdAt: Date(timeIntervalSince1970: 500),
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            ),
        ])
        return .mediaOnly([rel])
    }
}

private func claimTestMultiFileScanner(_ fixtures: [EnrichmentClaimScanFixture]) -> CatalogScanner {
    CatalogScanner { _, _, batchHandler in
        let files = fixtures.map { fixture in
            ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: fixture.name),
                name: fixture.name,
                contentTypeIdentifier: "public.jpeg",
                byteSize: 100,
                createdAt: Date(timeIntervalSince1970: fixture.modifiedAt),
                contentModifiedAt: Date(timeIntervalSince1970: fixture.modifiedAt)
            )
        }
        try await batchHandler(files)
        return .mediaOnly(Set(files.map(\.relativePath)))
    }
}
