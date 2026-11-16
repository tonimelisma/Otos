import Foundation
import GRDB
@testable import OtosKit
import Testing

/// ADR 0054 (owner, 2026-11-15): a face on any copy of a photo is the photo's. A person's
/// photos, People and the People filter find a photo by a face on a copy the scope does not
/// show, whether the person's photos are sought or the order is walked, and a person's photo
/// count counts the photo once.
@Suite(.testDirectory)
struct PhotoCopiesTests {
    /// Library rows in root 1, `IMG_0001.JPG`…; the first `copied` of them also in account
    /// root 2 as `a/IMG_….JPG`, with the same digest.
    static let rows = 300
    static let copied = 10

    @Test func aFaceOnACopyTheScopeDoesNotShowFindsThePhoto() async throws {
        let dbQueue = try await Self.catalog { db in
            // Person 1, one photo: few enough to seek. Person 2, every copied photo: enough to
            // walk the order. Both only on the account's copies, which no combined scope shows.
            try Self.face(person: 1, on: "a/IMG_0001.JPG", db: db)
            for index in 1 ... Self.copied {
                try Self.face(person: 2, on: String(format: "a/IMG_%04d.JPG", index), db: db)
            }
        }
        let first = Set(["IMG_0001.JPG"])
        let all = Set((1 ... Self.copied).map { String(format: "IMG_%04d.JPG", $0) })
        let filter = {
            var filter = MediaFilter.all
            filter.people = [PersonID(rawValue: 1)]
            return filter
        }()

        let reads = try await dbQueue.read { db in
            try [
                Self.read(.person(1), db: db),
                Self.read(.person(2), db: db),
                Self.read(.withPerson, db: db),
                Self.read(.any, filter: filter, db: db),
            ]
        }
        #expect(reads[0].paths == first)
        #expect(reads[0].seeks)
        #expect(reads[1].paths == all)
        #expect(!reads[1].seeks)
        #expect(reads[2].paths == all)
        #expect(reads[3].paths == first)
        for read in reads {
            #expect(read.count == read.paths.count)
        }
    }

    /// The faces on both copies of one photo, of one person, are one photo of theirs.
    @Test func aPersonsPhotoIsCountedOnceOverItsCopies() {
        let library = LibraryRootPath(rawValue: "/Pictures/")
        let account = LibraryRootPath(rawValue: "/Family/")
        let raw = MediaAssetID(libraryRootPath: library, relativePath: MediaRelativePath(rawValue: "IMG_1.ARW"))
        let jpeg = MediaAssetID(libraryRootPath: library, relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"))
        let accountJPEG = MediaAssetID(libraryRootPath: account, relativePath: MediaRelativePath(rawValue: "a/IMG_1.JPG"))
        let photoOf = PeopleSnapshot.photos(
            stackKeys: [jpeg: raw],
            copies: [[
                PeopleSnapshot.Copy(asset: accountJPEG, rootID: 2, isAccount: true),
                PeopleSnapshot.Copy(asset: jpeg, rootID: 1, isAccount: false),
            ]]
        )
        // The account's copy stands for the library's, which is its stack's key's file.
        #expect(photoOf == [jpeg: raw, accountJPEG: raw])
        #expect(MediaCount(items: [raw, jpeg, accountJPEG].map { (photoOf[$0] ?? $0, false) }).total == 1)
    }

    /// The copies' questions are seeks of the digest index, never a scan, and the order still
    /// walks its index with no sort: whether a better copy is reachable (the library away), and
    /// whether a copy holds a person's face (a walked person, People, the People filter).
    @Test func aPhotosCopiesAreAskedThroughTheDigestIndex() async throws {
        let dbQueue = try await Self.catalog { db in
            for index in 1 ... Self.copied {
                try Self.face(person: 2, on: String(format: "a/IMG_%04d.JPG", index), db: db)
            }
        }
        let filter = {
            var filter = MediaFilter.all
            filter.people = [PersonID(rawValue: 2)]
            return filter
        }()
        struct Read {
            let roots: [Int64]
            let content: CatalogScopePredicate.ContentConstraint
            let filter: MediaFilter
            let alias: String
        }
        let reads = [
            Read(roots: [2], content: .any, filter: .all, alias: "better"),
            Read(roots: [1, 2], content: .person(2), filter: .all, alias: "face_copy"),
            Read(roots: [1, 2], content: .withPerson, filter: .all, alias: "face_copy"),
            Read(roots: [1, 2], content: .any, filter: filter, alias: "face_copy"),
        ]
        let plans = try await dbQueue.read { db in
            try reads.map { read in
                var scope = CatalogScopePredicate(rootIDs: read.roots, content: read.content)
                scope.showsOneCopy = true
                let query = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
                    descriptor: CatalogQueryDescriptor(scope: .allMedia, filter: read.filter), scope: scope, db: db
                ))
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments)
                    .map { $0["detail"] as String }
                return (read.alias, plan)
            }
        }
        for (alias, plan) in plans {
            #expect(plan.first?.contains("idx_media_asset_best_capture_") == true, "\(plan)")
            #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
            #expect(plan.contains { $0.hasPrefix("SEARCH \(alias) USING") && $0.contains(ContentDigestSQL.indexName) }, "\(plan)")
            #expect(!plan.contains { $0.hasPrefix("SCAN \(alias)") }, "\(plan)")
        }
    }

    // MARK: - Fixture

    private struct Read {
        let paths: Set<String>
        let seeks: Bool
        let count: Int
    }

    private static func read(
        _ content: CatalogScopePredicate.ContentConstraint,
        filter: MediaFilter = .all,
        db: Database
    ) throws -> Read {
        var scope = CatalogScopePredicate(rootIDs: [1, 2], content: content)
        scope.showsOneCopy = true
        let query = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: CatalogQueryDescriptor(scope: .allMedia, filter: filter), scope: scope, db: db
        ))
        let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
        let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments)
            .map { $0["detail"] as String }
        #expect(rows.allSatisfy { ($0[0] as Int64) == 1 }, "\(rows)")
        return try Read(
            paths: Set(rows.map { $0[1] as String }),
            seeks: plan.contains { $0.hasPrefix("SEARCH media_asset USING INDEX sqlite_autoindex_media_asset_1") },
            count: CatalogQueryGateway.countAssets(scope: scope, filter: filter, db: db)
        )
    }

    private static func catalog(_ shape: @escaping @Sendable (Database) throws -> Void) async throws -> DatabaseQueue {
        let url = try makeTestDirectory().appending(path: "catalog.sqlite")
        let dbQueue = try DatabaseQueue(path: url.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: """
            INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures/', 'library'), (2, '/Family/', 'immichAccount')
            """)
            try db.execute(sql: """
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
            INSERT INTO media_asset (
                library_root_id, relative_path, sort_key, name_sort_key, name, content_type_identifier,
                byte_size, content_modified_at_unix, capture_wall_compact, enriched_kind,
                content_sha1, content_hash_source_size, content_hash_source_mtime
            )
            SELECT 1, printf('IMG_%04d.JPG', i), printf('img_%04d', i), printf('img_%04d', i), printf('IMG_%04d.JPG', i),
                   'public.jpeg', 100, 1000, 20190303120000 + i % 60, 'image', unhex(printf('%040d', i)), 100, 1000
            FROM n
            """, arguments: [rows])
            try db.execute(sql: """
            INSERT INTO media_asset (
                library_root_id, relative_path, sort_key, name_sort_key, name, content_type_identifier,
                byte_size, content_modified_at_unix, capture_wall_compact, enriched_kind,
                content_sha1, content_hash_source_size, content_hash_source_mtime
            )
            SELECT 2, 'a/' || relative_path, sort_key, name_sort_key, name, content_type_identifier,
                   byte_size, content_modified_at_unix, capture_wall_compact, enriched_kind,
                   content_sha1, content_hash_source_size, content_hash_source_mtime
            FROM media_asset WHERE library_root_id = 1 AND rowid <= ?
            """, arguments: [copied])
            try db.execute(sql: "INSERT INTO person (id, name) VALUES (1, 'Sam'), (2, 'Ian')")
            try shape(db)
        }
        return dbQueue
    }

    private static func face(person: Int64, on path: String, db: Database) throws {
        try db.execute(sql: """
        INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                          landmarks, quality, analysis_revision, embedding, person_id)
        VALUES (2, ?, ?, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1, x'00', ?)
        """, arguments: [path, person, person])
    }
}
