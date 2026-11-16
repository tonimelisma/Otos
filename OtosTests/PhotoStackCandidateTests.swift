import Foundation
import GRDB
@testable import OtosKit
import Testing

/// The stack candidates (ADR 0052) are the stills that can be in a stack and no others: the
/// stills of each folder that holds a present RAW and another present still, and every still
/// carrying a burst identifier. On a catalog of the owner's shape (`OwnerShapedCatalog`) the
/// read builds exactly the stacks the read of every RAW folder's stills built, from fewer
/// candidates, through indexes alone, with no sort of the candidates.
@Suite(.testScope)
struct PhotoStackCandidateTests {
    /// The candidates before folders that cannot hold a pair were left out: every present still
    /// of every folder holding a present RAW, and every present burst still. The oracle the
    /// narrower read is judged by.
    static func everyRawFolderQuery(rootIDs: [Int64]) -> SQLQuery {
        let roots = rootIDs.map(String.init).joined(separator: ",")
        let columns = """
        still.library_root_id, still.relative_path, still.best_kind, still.relative_path_key,
        still.sort_key, still.stack_key_chosen_at_unix_ms, still.burst_identifier,
        still.best_capture_local, still.media_choice, still.burst_key_chosen_at_unix_ms
        """
        return SQLQuery(
            sql: """
            WITH raw_folder AS (
                SELECT DISTINCT library_root_id, parent_path FROM media_asset
                WHERE library_root_id IN (\(roots)) AND best_kind = 'raw' AND \(CatalogVisibilitySQL.isPresent("media_asset"))
            )
            SELECT \(columns)
            FROM raw_folder
            JOIN media_asset AS still
              ON still.library_root_id = raw_folder.library_root_id AND still.parent_path = raw_folder.parent_path
            WHERE still.best_kind IN ('raw', 'image') AND \(CatalogVisibilitySQL.isPresent("still"))
            UNION
            SELECT \(columns)
            FROM media_asset AS still
            WHERE still.library_root_id IN (\(roots)) AND still.burst_identifier IS NOT NULL
              AND still.best_kind IN ('raw', 'image') AND \(CatalogVisibilitySQL.isPresent("still"))
            """,
            arguments: []
        )
    }

    @Test func theCandidatesBuildEveryStackOfTheOwnersShapeFromStillsThatCanStack() async throws {
        let scale = StallReproductionTests.ownerSize ? 1 : 0.05
        let catalog = try OwnerShapedCatalog.make(in: makeTestDirectory(), scale: scale)
        let queue = try DatabaseQueue(path: catalog.databaseURL.path(percentEncoded: false))
        defer { try? queue.close() }
        let (narrow, every, rootPaths, plan) = try await queue.read { db in
            var rootPaths: [Int64: LibraryRootPath] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, path FROM library_root") {
                rootPaths[row[0]] = LibraryRootPath(rawValue: row[1])
            }
            let rootIDs = rootPaths.keys.sorted()
            let query = try #require(PhotoStackSQL.candidateQuery(rootIDs: rootIDs))
            return try (
                PhotoStackSQL.fetchCandidates(query: query, start: .now, db: db),
                PhotoStackSQL.fetchCandidates(query: Self.everyRawFolderQuery(rootIDs: rootIDs), start: .now, db: db),
                rootPaths,
                String.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments)
                    .joined(separator: "\n")
            )
        }
        let narrowStacks = CatalogStacks(PhotoStackSQL.stacks(of: narrow, rootPaths: rootPaths))
        let everyStacks = CatalogStacks(PhotoStackSQL.stacks(of: every, rootPaths: rootPaths))
        #expect(narrowStacks == everyStacks)
        let kinds = narrowStacks.stacks.values.map(\.id.kind)
        #expect(kinds.count { $0 == .pair } == OwnerShapedCatalog.scaled(5384, scale) + OwnerShapedCatalog.scaled(464, scale))
        #expect(kinds.count { $0 == .burst } == 1)

        // The account's RAWs, each alone in its asset's folder, are not read.
        #expect(narrow.count < every.count)
        let accountRaws = OwnerShapedCatalog.scaled(10906, scale)
        #expect(narrow.count == every.count - accountRaws)
        for (rootID, candidates) in narrow.byRoot {
            let byFolder = Dictionary(grouping: candidates) { $0.relativePath.folder }
            for (folder, stills) in byFolder where stills.count < 2 {
                #expect(stills.allSatisfy { $0.burstIdentifier != nil }, "root \(rootID) folder \(folder) cannot hold a pair")
            }
        }

        // Indexes alone, and no candidate is sorted: the arms share no row.
        let lines = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(!lines.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
        for table in ["media_asset", "still", "other", "raw"] {
            #expect(!lines.contains { $0 == "SCAN \(table)" || $0.hasPrefix("SCAN \(table) ") }, "\(plan)")
        }
    }
}
