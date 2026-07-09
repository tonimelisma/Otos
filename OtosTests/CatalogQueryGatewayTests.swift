import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogQueryGatewayTests {
    @Test func orderedAssetIDQueryReturnsNilForEmptyRoots() {
        #expect(CatalogQueryGateway.orderedAssetIDQuery(descriptor: .default, rootIDs: []) == nil)
    }

    @Test func countAssetsReturnsZeroForEmptyRoots() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let count = try await dbQueue.read { db in
            try CatalogQueryGateway.countAssets(rootIDs: [], db: db)
        }
        #expect(count == 0)
    }

    @Test func filterOptionsReturnsEmptyForEmptyRoots() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let options = try await dbQueue.read { db in
            try CatalogQueryGateway.filterOptions(rootIDs: [], db: db)
        }
        #expect(options == .empty)
    }

    @Test func fetchStoredAssetsReturnsEmptyForEmptyIDs() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let assets = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchStoredAssets(ids: [], rootIDsByPath: [:], db: db)
        }
        #expect(assets.isEmpty)
    }

    @Test func fetchStoredTileDetailsReturnsEmptyForEmptyIDs() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let details = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchStoredTileDetails(ids: [], rootIDsByPath: [:], db: db)
        }
        #expect(details.isEmpty)
    }

    @Test func metadataExtraReturnsNilWhenRowMissing() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let metadata = try await dbQueue.read { db in
            try CatalogQueryGateway.metadataExtra(
                libraryRootID: 1,
                relativePath: MediaRelativePath(rawValue: "missing.jpg"),
                db: db
            )
        }
        #expect(metadata == nil)
    }
}
