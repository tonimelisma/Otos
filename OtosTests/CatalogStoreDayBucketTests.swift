import Foundation
@testable import OtosKit
import Testing

/// DES-069 day buckets: `CatalogStore.orderedAssetIDs` only populates them under
/// `.bestDate` sort, and pairs them index-for-index with the returned IDs.
struct CatalogStoreDayBucketTests {
    @Test func bestDateSortReturnsStartOfDayBucketsPairedWithIDs() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "older.jpg"), contents: "one")
        try writeCatalogStoreFile(root.appending(path: "newer.jpg"), contents: "two")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)

        let olderID = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "older.jpg"))
        let newerID = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "newer.jpg"))
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_300_000) // ~3.5 days later, distinct day bucket
        for (id, date) in [(olderID, olderDate), (newerID, newerDate)] {
            let asset = try #require(try await store.mediaAssets(for: [id])[id])
            let enrichment = EnrichmentResult(
                id: id,
                metadata: .absoluteCapture(instant: date),
                thumbnailPath: "\(id.relativePath.rawValue)-thumb.jpg",
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                contentHash: .empty
            )
            _ = await store.applyEnrichmentBatch([enrichment])
        }

        let available: Set<LibraryRootPath> = [rootPath]
        let byDate = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia, sort: .dateNewest),
            availableLibraryPaths: available
        )
        let byName = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia, sort: .filenameAscending),
            availableLibraryPaths: available
        )
        await store.shutdown()

        #expect(byDate.dayBuckets.count == byDate.ids.count)
        let olderIndex = try #require(byDate.ids.firstIndex(of: olderID))
        let newerIndex = try #require(byDate.ids.firstIndex(of: newerID))
        #expect(byDate.dayBuckets[olderIndex] == Calendar.current.startOfDay(for: olderDate))
        #expect(byDate.dayBuckets[newerIndex] == Calendar.current.startOfDay(for: newerDate))
        #expect(byDate.dayBuckets[olderIndex] != byDate.dayBuckets[newerIndex])

        #expect(byName.dayBuckets.isEmpty)
    }
}
