import Foundation
import GRDB
@testable import OtosKit
import Testing

/// An applied migration's outcome never changes (ADR 0002): a catalog upgraded through a
/// migration holds the index text that migration wrote, a new catalog the text it writes
/// now, and `INDEXED BY` matches a partial index by its text. These guard both halves: each
/// migration still builds exactly the indexes it was frozen with, and every partial index a
/// query names is implied by that query's own predicate in the schema the migrations build.
@Suite(.testScope)
struct CatalogMigrationFreezeTests {
    /// Each migration's indexes as it built them when it was applied, by migration: an
    /// index's stored `CREATE` text, or null for one it dropped. A new migration adds its
    /// entry here; an applied migration's entry never changes.
    private static let frozenURL = SourceTree.root.appending(path: "OtosTests/Fixtures/Catalog/migration-indexes.json")

    @Test func everyMigrationBuildsTheIndexesItWasFrozenWith() async throws {
        let frozen = try Self.frozenIndexes()
        let built = try await Self.indexesByMigration()
        #expect(built.map(\.migration) == frozen.map(\.migration), "a migration was added, removed or reordered")
        let frozenByMigration = Dictionary(uniqueKeysWithValues: frozen.map { ($0.migration, $0.indexes) })
        for step in built {
            guard let expected = frozenByMigration[step.migration] else {
                Issue.record("\(step.migration) has no frozen entry; add {\"migration\": \"\(step.migration)\", \"indexes\": \(Self.json(step.indexes))}")
                continue
            }
            for name in Set(expected.keys).union(step.indexes.keys).sorted() where expected[name] != step.indexes[name] {
                Issue.record("""
                \(step.migration) changed what it builds for \(name): an applied migration's outcome never changes.
                frozen: \(String(describing: expected[name] ?? nil))
                built:  \(String(describing: step.indexes[name] ?? nil))
                """)
            }
        }
    }

    /// Every partial index a query names with `INDEXED BY`, with the predicate that query
    /// tests, as the code holds it now. SQLite proves the implication when it prepares the
    /// statement and refuses it with "no query solution" when the predicate does not imply
    /// the index's condition, as a query against an upgraded catalog would be refused.
    @Test func everyNamedPartialIndexIsImpliedByItsQuerysPredicate() async throws {
        let dbQueue = try await Self.migratedQueue()
        var claims: [(String, String, String)] = []
        for claim in EnrichmentClaim.allCases {
            let predicate = "(\(EnrichmentClaimGateway.stalenessSQLPredicate(claim)))\(EnrichmentClaimGateway.backgroundScope(claim))"
            claims.append(("media_asset", EnrichmentClaimGateway.globalIndexName(claim), predicate))
            claims.append(("media_asset", EnrichmentClaimGateway.rootIndexName(claim), predicate))
        }
        let named: [(table: String, index: String, predicate: String)] = claims + [
            ("media_asset", RenderSignatureSQL.owedIndexName, RenderSignatureSQL.owedPredicate),
            ("media_asset", SourceProductsSQL.owedIndexName, SourceProductsSQL.owedPredicate),
            ("media_asset", SamePhotoSQL.candidateIndexName, SamePhotoSQL.candidatePredicate),
            ("media_asset", CatalogSchema.stillOwesFacesIndexName, CatalogSchema.stillOwesFacesPredicate),
            ("media_asset", CatalogSchema.stillAwaitsPreviewIndexName, CatalogSchema.stillAwaitsPreviewPredicate),
            ("media_asset", CatalogSchema.videoOwesFacesIndexName, CatalogSchema.videoOwesFacesPredicate),
            ("face", PeopleGallerySQL.anchorIndexName, PeopleGallerySQL.anchorPredicate),
            ("media_asset", SearchEmbeddingStorage.noThumbnailComingIndexName, SearchEmbeddingStorage.noThumbnailComingPredicate),
            ("person_photo", PersonPhotoSQL.copiesIndexName, PersonPhotoSQL.copiesPredicate),
        ]
        let partial = try await dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql LIKE '%WHERE%'"))
        }
        for query in named {
            #expect(partial.contains(query.index), "\(query.index) is no partial index of the migrated schema")
            do {
                try await dbQueue.read { db in
                    _ = try db.makeStatement(sql: "SELECT 1 FROM \(query.table) INDEXED BY \(query.index) WHERE (\(query.predicate))")
                }
            } catch {
                Issue.record("\(query.index): its query's predicate does not imply the index's condition: \(error)")
            }
        }
    }

    // MARK: - Support

    private struct Step {
        let migration: String
        let indexes: [String: String?]
    }

    private static func migratedQueue() async throws -> DatabaseQueue {
        let dbQueue = try makeTestDatabaseQueue(path: makeTestDirectory().appending(path: "catalog.sqlite").path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        return dbQueue
    }

    /// Runs the migrations one at a time on an empty catalog and records what each changed.
    private static func indexesByMigration() async throws -> [Step] {
        let dbQueue = try makeTestDatabaseQueue(path: makeTestDirectory().appending(path: "catalog.sqlite").path(percentEncoded: false))
        let migrator = CatalogStore.migrator
        var previous: [String: String] = [:]
        var steps: [Step] = []
        for identifier in migrator.migrations {
            try migrator.migrate(dbQueue, upTo: identifier)
            let now = try await dbQueue.read { db in
                try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                    db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL"
                ).map { ($0["name"] as String, $0["sql"] as String) })
            }
            var changed: [String: String?] = [:]
            for (name, sql) in now where previous[name] != sql {
                changed[name] = sql
            }
            for name in previous.keys where now[name] == nil {
                changed[name] = .some(nil)
            }
            steps.append(Step(migration: identifier, indexes: changed))
            previous = now
        }
        return steps
    }

    private static func frozenIndexes() throws -> [Step] {
        let entries = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: frozenURL)) as? [[String: Any]]
        )
        return try entries.map { entry in
            let indexes = try #require(entry["indexes"] as? [String: Any])
            return try Step(
                migration: #require(entry["migration"] as? String),
                indexes: indexes.mapValues { $0 as? String }
            )
        }
    }

    private static func json(_ indexes: [String: String?]) -> String {
        let object = indexes.mapValues { $0.map { $0 as Any } ?? NSNull() }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
