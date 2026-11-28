import Foundation
import GRDB
@testable import OtosKit
import Testing

/// An applied migration's outcome never changes (ADR 0002): a catalog upgraded through a
/// migration holds the schema text that migration wrote — every index's, table's, trigger's
/// and view's `CREATE` as `sqlite_master` stores it — and a new catalog the text it writes
/// now. `INDEXED BY` matches a partial index by its text, and a trigger or a generated column
/// runs as it was written. These guard both halves: each migration still builds exactly the
/// schema objects it was frozen with, and every partial index a query names is implied by
/// that query's own predicate in the schema the migrations build.
@Suite(.testScope)
struct CatalogMigrationFreezeTests {
    /// Each migration's schema objects as it built them when it was applied, by migration and
    /// kind: an object's stored `CREATE` text, or null for one it dropped. A new migration
    /// adds its entry here; an applied migration's entry never changes.
    private static let frozenURL = SourceTree.root.appending(path: "OtosTests/Fixtures/Catalog/migration-schema.json")

    /// The kinds of schema object `sqlite_master` holds text for, as the fixture names them.
    private static let kinds = ["index": "indexes", "table": "tables", "trigger": "triggers", "view": "views"]

    @Test func everyMigrationBuildsTheSchemaItWasFrozenWith() async throws {
        let frozen = try Self.frozenSteps()
        let built = try await Self.schemaByMigration()
        #expect(built.map(\.migration) == frozen.map(\.migration), "a migration was added, removed or reordered")
        let frozenByMigration = Dictionary(uniqueKeysWithValues: frozen.map { ($0.migration, $0.objects) })
        for step in built {
            guard let expected = frozenByMigration[step.migration] else {
                Issue.record("\(step.migration) has no frozen entry; add \(Self.json(step))")
                continue
            }
            for key in Set(expected.keys).union(step.objects.keys).sorted() where expected[key] != step.objects[key] {
                Issue.record("""
                \(step.migration) changed what it builds for \(key.kind) \(key.name): an applied migration's outcome never changes.
                frozen: \(String(describing: expected[key] ?? nil))
                built:  \(String(describing: step.objects[key] ?? nil))
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
            ("media_asset", AssetRowSQL.unreadIndexName, AssetRowSQL.unreadPredicate),
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

    private struct ObjectKey: Hashable, Comparable {
        /// The fixture's name for the kind: `indexes`, `tables`, `triggers` or `views`.
        let kind: String
        let name: String

        static func < (lhs: ObjectKey, rhs: ObjectKey) -> Bool {
            (lhs.kind, lhs.name) < (rhs.kind, rhs.name)
        }
    }

    private struct Step {
        let migration: String
        let objects: [ObjectKey: String?]
    }

    private static func migratedQueue() async throws -> DatabaseQueue {
        let dbQueue = try makeTestDatabaseQueue(path: makeTestDirectory().appending(path: "catalog.sqlite").path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        return dbQueue
    }

    /// Runs the migrations one at a time on an empty catalog and records what each changed.
    /// GRDB's own bookkeeping table is not the catalog's schema.
    private static func schemaByMigration() async throws -> [Step] {
        let dbQueue = try makeTestDatabaseQueue(path: makeTestDirectory().appending(path: "catalog.sqlite").path(percentEncoded: false))
        let migrator = CatalogStore.migrator
        var previous: [ObjectKey: String] = [:]
        var steps: [Step] = []
        for identifier in migrator.migrations {
            try migrator.migrate(dbQueue, upTo: identifier)
            let now = try await dbQueue.read { db in
                try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                    db, sql: "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name <> 'grdb_migrations'"
                ).compactMap { row -> (ObjectKey, String)? in
                    guard let kind = kinds[row["type"] as String] else { return nil }
                    return (ObjectKey(kind: kind, name: row["name"]), row["sql"] as String)
                })
            }
            var changed: [ObjectKey: String?] = [:]
            for (key, sql) in now where previous[key] != sql {
                changed[key] = sql
            }
            for key in previous.keys where now[key] == nil {
                changed[key] = .some(nil)
            }
            steps.append(Step(migration: identifier, objects: changed))
            previous = now
        }
        return steps
    }

    private static func frozenSteps() throws -> [Step] {
        let entries = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: frozenURL)) as? [[String: Any]]
        )
        return try entries.map { entry in
            var objects: [ObjectKey: String?] = [:]
            for kind in kinds.values {
                for (name, sql) in entry[kind] as? [String: Any] ?? [:] {
                    objects[ObjectKey(kind: kind, name: name)] = .some(sql as? String)
                }
            }
            return try Step(migration: #require(entry["migration"] as? String), objects: objects)
        }
    }

    /// A step as its fixture entry: the migration, and a map for each kind it changed.
    private static func json(_ step: Step) -> String {
        var object: [String: Any] = ["migration": step.migration]
        for (key, sql) in step.objects {
            var kind = object[key.kind] as? [String: Any] ?? [:]
            kind[key.name] = sql.map { $0 as Any } ?? NSNull()
            object[key.kind] = kind
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
