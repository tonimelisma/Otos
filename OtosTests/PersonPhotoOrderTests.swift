import Foundation
import GRDB
@testable import OtosKit
import SQLite3
import Testing

/// v78 reads a person's order from `person_photo` (ADR 0047, "A person's photos"), never the
/// order: under every sort, filter and scope a person's photos come back in the order the
/// previous implementation's read put them in — every row of the scope tested for one of the
/// person's faces on it or on a present copy (`PhotoFaceSQL.holds`), in the order's own index
/// order — before the migration, after it, and after every kind of write that moves a photo in
/// or out of a person or along their order. The corpus holds photos with several faces of one
/// person, faces of several people, unidentified faces and a face that is not one, a video, a
/// photo with an identical copy in the other library that holds no face, and the writes are
/// reassignments, readings, a choice, a rename, a Trash, a new capture time, a new photo, a
/// deleted photo, a face on the copy and a person's removal.
@Suite(.testScope)
struct PersonPhotoOrderTests {
    static let sorts: [MediaSortOrder] = [
        .dateNewest, .dateOldest, .filenameAscending, .filenameDescending, .sizeLargest, .sizeSmallest,
        .likenessMost, .likenessLeast,
    ]

    /// The people of the corpus.
    static let anna: Int64 = 1
    static let ben: Int64 = 2

    // Validates: ARC-022
    @Test func aPersonsOrderIsThePreviousReadsOrderThroughEveryWrite() async throws {
        let temp = try makeTestDirectory()
        let queue = try makeTestDatabaseQueue(path: temp.appending(path: "catalog.sqlite").path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.noThumbnailComingMigrationIdentifier)
        try await queue.write { db in try Self.insertCorpus(db) }
        let before = try await queue.read { db in try Self.reads.map { try Self.previousOrder($0, db) } }
        try CatalogStore.migrator.migrate(queue)
        let migrated = try await queue.read { db in try Self.reads.map { try Self.order($0, db) } }
        for (index, read) in Self.reads.enumerated() {
            #expect(migrated[index] == before[index], "migrated: \(read.name)")
        }
        #expect(before.contains { $0.count > 10 }, "the corpus reads rows")
        try await Self.expectSame(queue, after: "the migration")
        for (name, write) in Self.writes {
            try await queue.write { db in try db.execute(sql: write) }
            try await Self.expectSame(queue, after: name)
        }
    }

    // Validates: ARC-022
    /// The table is what `face` and `media_asset` say after every write: a row for each photo
    /// holding a face of a person that is a face, with the photo's columns.
    @Test func thePersonsPhotosAreWhatTheFacesAndThePhotosSay() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.noThumbnailComingMigrationIdentifier)
        try await queue.write { db in try Self.insertCorpus(db) }
        try CatalogStore.migrator.migrate(queue)
        try await queue.read { db in
            let stored = try Self.stored(db)
            let computed = try Self.computed(db)
            #expect(stored == computed, "after the migration")
        }
        for (name, write) in Self.writes {
            try await queue.write { db in try db.execute(sql: write) }
            try await queue.read { db in
                let stored = try Self.stored(db)
                let computed = try Self.computed(db)
                #expect(stored == computed, "after \(name)")
            }
        }
    }

    // Validates: ARC-022
    /// A person's order, under every sort and with a filter or none, reads the person's own
    /// range of `person_photo`'s key and nothing of another person's, finds the photos through
    /// a copy from the person's photos that have copies, and scans no table: on a catalog of
    /// 2,000 photos, a person of 300 among people of 1,700 visits 300 rows.
    @Test func aPersonsOrderVisitsOnlyThePersonsRows() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path) VALUES (1, '/generated/first')")
            try db.execute(sql: "INSERT INTO person (id) VALUES (1), (2), (3)")
            try db.execute(sql: """
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 1999)
            INSERT INTO media_asset (library_root_id, relative_path, name_sort_key, name, content_type_identifier, kind,
                format, byte_size, content_modified_at_unix, capture_wall_compact)
            SELECT 1, printf('%03d/IMG_%04d.%s', i / 50, i, CASE WHEN i % 10 = 0 THEN 'MOV' ELSE 'JPG' END),
                   printf('img_%04d', i), printf('IMG_%04d', i), 'public.jpeg',
                   CASE WHEN i % 10 = 0 THEN 'video' ELSE 'image' END, 'JPEG', 1000 + i % 97, 1000,
                   20190303120000 + (i * 7919) % 86400
            FROM n
            """)
            try db.execute(sql: """
            INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height, landmarks,
                quality, analysis_revision, person_id, likeness)
            SELECT library_root_id, relative_path, 0, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1,
                   CASE WHEN rowid % 20 < 3 THEN 1 WHEN rowid % 20 < 12 THEN 2 ELSE 3 END, (rowid % 13) / 13.0
            FROM media_asset
            """)
        }
        let person = PersonID(rawValue: 1)
        let scope = CatalogScopePredicate(rootIDs: [1], content: .person(1), showsOneCopy: true, holdsEveryCopyRoot: true)
        for sort in Self.sorts {
            for filter in [MediaFilter.all, MediaFilter(kinds: [.video])] {
                let name = "\(sort.field.rawValue)-\(sort.direction.rawValue) \(filter.kinds.isEmpty ? "all" : "video")"
                let (plan, loops, rows) = try await queue.read { db in
                    let query = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
                        descriptor: CatalogQueryDescriptor(scope: .person(person), filter: filter, sort: sort), scope: scope,
                        stacks: .readWhenNeeded(.paired), db: db
                    ))
                    let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments)
                        .map { ($0["detail"] as String).trimmingCharacters(in: .whitespaces) }
                    let statement = try db.makeStatement(sql: query.sql)
                    try statement.setArguments(query.arguments)
                    let rows = try Row.fetchAll(statement).count
                    return (plan, OrderReadSurvey.loopVisits(statement.sqliteStatement), rows)
                }
                #expect(plan.contains { $0.hasPrefix("SEARCH media_asset USING PRIMARY KEY (person_id=?") }, "\(name): \(plan)")
                #expect(plan.contains { $0.contains("INDEX \(PersonPhotoSQL.copiesIndexName) (person_id=?") }, "\(name): \(plan)")
                #expect(!plan.contains { $0.hasPrefix("SCAN media_asset") || $0.hasPrefix("SCAN member") }, "\(name): \(plan)")
                #expect(rows == (filter.kinds.isEmpty ? 300 : 100), "\(name)")
                // The person's rows are visited once each; the face index's seeks under the
                // likeness order are one a row per key read.
                let personRows = loops.filter { $0.name.contains("person_photo_1") }.map(\.visited).reduce(0, +)
                #expect(personRows == 300, "\(name): \(loops)")
                let faceSeeks = loops.filter { $0.name.contains("face") }.map(\.visited).reduce(0, +)
                #expect(faceSeeks <= (sort.field == .likeness ? 600 : 0), "\(name): \(loops)")
            }
        }
    }

    // Validates: ARC-022
    /// A sought order builds only its own rows' stacks while it holds at most
    /// `PhotoStackSQL.rowsSpanMostRows` rows, and every stack of its roots past that.
    @Test func aSoughtOrderOfMoreThanTwoThousandRowsBuildsEveryStackOfItsRoots() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue)
        let most = PhotoStackSQL.rowsSpanMostRows
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path) VALUES (1, '/generated/first')")
            try db.execute(sql: "INSERT INTO person (id) VALUES (1), (2)")
            try db.execute(sql: """
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
            INSERT INTO media_asset (library_root_id, relative_path, name_sort_key, name, content_type_identifier, kind,
                format, byte_size, content_modified_at_unix)
            SELECT 1, printf('IMG_%05d.JPG', i), printf('img_%05d', i), printf('IMG_%05d', i), 'public.jpeg', 'image',
                   'JPEG', 1000, 1000
            FROM n
            """, arguments: [most])
            // Person 1 is in every photo, person 2 in all but one: one row past the bound and on it.
            try db.execute(sql: """
            INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height, landmarks,
                quality, analysis_revision, person_id)
            SELECT library_root_id, relative_path, 0, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1, 1 FROM media_asset
            UNION ALL
            SELECT library_root_id, relative_path, 1, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1, 2 FROM media_asset WHERE rowid > 1
            """)
        }
        for (person, rows, span) in [(Int64(1), most + 1, PhotoStackSQL.Span.roots), (2, most, .rows)] {
            let order = try await queue.read { db in
                try CatalogQueryGateway.readOrder(
                    descriptor: CatalogQueryDescriptor(scope: .person(PersonID(rawValue: person))),
                    scope: CatalogScopePredicate(rootIDs: [1], content: .person(person)),
                    stackRootPaths: [1: LibraryRootPath(rawValue: "/generated/first/")], held: nil, pairing: .paired, db: db
                )
            }
            #expect(order.rows.count == rows, "person \(person)")
            #expect(order.stacks.span == span, "person \(person)")
        }
    }

    // MARK: - Reads

    struct Read {
        let name: String
        let descriptor: CatalogQueryDescriptor
        let scope: CatalogScopePredicate
    }

    static let reads: [Read] = {
        let filters: [(String, MediaFilter)] = [
            ("none", .all), ("video", MediaFilter(kinds: [.video])), ("liked", MediaFilter(choices: [.liked])),
            ("ben", MediaFilter(people: [PersonID(rawValue: ben)])), ("unidentified", MediaFilter(unassignedFaces: true)),
        ]
        let scopes: [(String, CatalogScopePredicate)] = [
            ("oneCopy", CatalogScopePredicate(rootIDs: [1, 2], content: .person(anna), showsOneCopy: true, holdsEveryCopyRoot: true)),
            ("oneCopyOffline", CatalogScopePredicate(rootIDs: [2], content: .person(anna), showsOneCopy: true)),
            ("everyCopy", CatalogScopePredicate(rootIDs: [1, 2], content: .person(anna))),
            ("second", CatalogScopePredicate(rootIDs: [2], content: .person(anna))),
            ("ben", CatalogScopePredicate(rootIDs: [1, 2], content: .person(ben), showsOneCopy: true, holdsEveryCopyRoot: true)),
        ]
        return scopes.flatMap { scopeName, scope in
            filters.flatMap { filterName, filter in
                sorts.map { sort in
                    let person: Int64 = if case let .person(person) = scope.content {
                        person
                    } else {
                        anna
                    }
                    return Read(
                        name: "\(scopeName).\(filterName).\(sort.field.rawValue)-\(sort.direction.rawValue)",
                        descriptor: CatalogQueryDescriptor(scope: .person(PersonID(rawValue: person)), filter: filter, sort: sort),
                        scope: scope
                    )
                }
            }
        }
    }()

    static func expectSame(_ queue: DatabaseQueue, after write: String) async throws {
        let (now, previous) = try await queue.read { db in
            try (Self.reads.map { try Self.order($0, db) }, Self.reads.map { try Self.previousOrder($0, db) })
        }
        for (index, read) in Self.reads.enumerated() {
            #expect(now[index] == previous[index], "after \(write): \(read.name)")
        }
    }

    static func order(_ read: Read, _ db: Database) throws -> [String] {
        try CatalogQueryGateway.fetchOrderedAssetIDRows(descriptor: read.descriptor, scope: read.scope, stacks: .readWhenNeeded(.paired), db: db)
            .map { "\($0.libraryRootID)/\($0.relativePath.rawValue)" }
    }

    /// `PhotoFaceSQL.holds` as the schema the read runs on can answer it: before v79 a row's
    /// copies were the rows of its current digest, read through the digest index.
    static func holds(_ db: Database, condition: String) throws -> String {
        let current = PhotoFaceSQL.holds("media_asset", condition: condition)
        guard try !db.columns(in: "media_asset").contains(where: { $0.name == "copy_key" }) else {
            return current
        }
        return current
            .replacingOccurrences(of: PhotoCopySQL.indexName, with: ContentDigestSQL.indexName)
            .replacingOccurrences(
                of: PhotoCopySQL.isCopy("face_copy", of: "media_asset"),
                with: CatalogSchema.isCopy("face_copy", of: "media_asset")
            )
    }

    /// The previous implementation's read, as it was before v78: the scope's rows, each tested
    /// for a face of the person on it or on a present copy, in the order's own terms.
    static func previousOrder(_ read: Read, _ db: Database) throws -> [String] {
        let scope = read.scope
        guard case let .person(person) = scope.content else { return [] }
        let roots = scope.rootIDs.map(String.init).joined(separator: ", ")
        var arguments: [any DatabaseValueConvertible] = []
        var predicate = """
        media_asset.library_root_id IN (\(roots))
          AND \(CatalogVisibilitySQL.isPresent("media_asset"))
          AND NOT \(LivePhotoSQL.isPairedMotion("media_asset"))
        """
        if scope.showsOneCopy {
            predicate += "\n  AND (media_asset.shown_copy_root_id IS NULL OR media_asset.shown_copy_root_id NOT IN (\(roots)))"
        }
        if scope.showsOneCopy, !scope.holdsEveryCopyRoot {
            predicate += """

              AND (media_asset.shown_copy_root_id IS NULL
                   OR NOT EXISTS (
                       SELECT 1 FROM media_asset AS better INDEXED BY \(ContentDigestSQL.indexName)
                       WHERE \(CatalogSchema.isCopy("better", of: "media_asset"))
                         AND better.library_root_id IN (\(roots))
                         AND \(CatalogVisibilitySQL.isPresent("better"))
                         AND (\(CatalogSchema.copyRank("better"))) < (\(CatalogSchema.copyRank("media_asset")))
                   ))
            """
        }
        try predicate += "\n  AND \(Self.holds(db, condition: "face.person_id = ? AND face.is_not_face = 0"))"
        arguments += [person, person]
        let filter = read.descriptor.filter
        if !filter.kinds.isEmpty {
            predicate += "\n  AND best_kind IN (\(filter.kinds.map { "'\($0.rawValue)'" }.sorted().joined(separator: ", ")))"
        }
        if !filter.choices.isEmpty {
            predicate += "\n  AND media_choice IN (\(filter.choices.map { "'\($0.rawValue)'" }.sorted().joined(separator: ", ")))"
        }
        for other in filter.people.sorted() {
            try predicate += "\n  AND \(Self.holds(db, condition: "face.is_not_face = 0 AND face.person_id = ?"))"
            arguments += [other.rawValue, other.rawValue]
        }
        if filter.unassignedFaces {
            try predicate += "\n  AND \(Self.holds(db, condition: "face.is_not_face = 0 AND face.person_id IS NULL"))"
        }
        let sort = read.descriptor.effectiveSort
        let direction = sort.direction == .descending ? "DESC" : "ASC"
        let orderBy: String
        switch sort.field {
        case .bestDate:
            orderBy = "media_asset.best_capture_local \(direction), media_asset.library_root_id, media_asset.relative_path"
        case .name:
            orderBy = "media_asset.name_sort_key \(direction), media_asset.library_root_id, media_asset.relative_path"
        case .size:
            orderBy = """
            (media_asset.byte_size IS NULL), media_asset.byte_size \(direction), media_asset.library_root_id, \
            media_asset.relative_path
            """
        case .likeness:
            let likeness = """
            (SELECT face.likeness FROM face WHERE face.library_root_id = media_asset.library_root_id
                AND face.relative_path = media_asset.relative_path AND face.person_id = ?)
            """
            orderBy = """
            (\(likeness) IS NULL), \(likeness) \(direction), media_asset.best_capture_local DESC, \
            media_asset.library_root_id, media_asset.relative_path
            """
            arguments += [person, person]
        }
        return try Row.fetchAll(
            db,
            sql: "SELECT media_asset.library_root_id, media_asset.relative_path FROM media_asset WHERE \(predicate) ORDER BY \(orderBy)",
            arguments: StatementArguments(arguments)
        ).map { "\($0[0] as Int64)/\($0[1] as String)" }
    }

    // MARK: - The table's rows

    /// The capture time compared as a number: `media_asset`'s generated column gives an
    /// integer where `person_photo`'s column holds it as a real, and SQLite orders the two alike.
    static let copiedColumns = """
    CAST(best_capture_local AS REAL), name_sort_key, byte_size, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, \
    best_kind, best_format, content_identifier, burst_identifier, copy_key, shown_copy_root_id, has_copies, media_choice
    """

    static func stored(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: """
        SELECT person_id, library_root_id, relative_path, parent_path, \(copiedColumns) FROM person_photo
        ORDER BY person_id, library_root_id, relative_path
        """).map { $0.databaseValues.map(\.description).joined(separator: " | ") }
    }

    static func computed(_ db: Database) throws -> [String] {
        let columns = copiedColumns.split(separator: ",").map { column in
            let name = column.trimmingCharacters(in: .whitespaces)
            return name.hasPrefix("CAST(") ? "CAST(m." + String(name.dropFirst(5)) : "m.\(name)"
        }.joined(separator: ", ")
        return try Row.fetchAll(db, sql: """
        SELECT DISTINCT f.person_id, m.library_root_id, m.relative_path, m.parent_path, \(columns)
        FROM face AS f NOT INDEXED JOIN media_asset AS m NOT INDEXED
          ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
        WHERE f.person_id IS NOT NULL AND f.is_not_face = 0
        ORDER BY f.person_id, m.library_root_id, m.relative_path
        """).map { $0.databaseValues.map(\.description).joined(separator: " | ") }
    }

    // MARK: - Corpus

    /// Thirty photos in the first library and two in the second: names, sizes, dates and kinds
    /// that tie and differ; Anna on most, Ben on some of hers and his own; two faces of Anna on
    /// one photo, unidentified faces, a face that is not one; `copy.jpg` in both libraries with
    /// one digest, Anna's face only on the first library's.
    static func insertCorpus(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO library_root (id, path) VALUES (1, '/generated/first'), (2, '/generated/second')")
        try db.execute(sql: "INSERT INTO person (id, name) VALUES (1, 'Anna'), (2, 'Ben')")
        let names = OrderReadDifferentialTests.names
        for index in 0 ..< 30 {
            let name = (index < 10 ? "2024/a/" : "2024/b/") + names[index % names.count]
            let (type, kind, format) = OrderReadDifferentialTests.type(of: name)
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, name_sort_key, name, content_type_identifier, kind, format,
                    byte_size, created_at_unix, content_modified_at_unix, media_choice, capture_wall_compact
                ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, 1600000100, ?, ?)
                """,
                arguments: [
                    name, MediaSortKey.naturalKey((name as NSString).lastPathComponent), (name as NSString).lastPathComponent,
                    type, kind, format, index % 7 == 6 ? nil : Int64(1000 + (index % 4) * 10),
                    1_600_000_000.0 + Double(index % 9) * 3600, ["notRated", "liked", "notRated"][index % 3],
                    index % 9 == 8 ? nil : Int64(20_240_601_120_000 + (index % 6) * 100),
                ]
            )
        }
        let digest = "x'0102030405060708090a0b0c0d0e0f1011121314'"
        for rootID in [1, 2] {
            try db.execute(sql: """
            INSERT INTO media_asset (library_root_id, relative_path, name_sort_key, name, content_type_identifier, kind,
                format, byte_size, created_at_unix, content_modified_at_unix, capture_wall_compact,
                content_sha1, content_hash_source_size, content_hash_source_mtime)
            VALUES (\(rootID), 'copy.jpg', 'copy.jpg', 'copy.jpg', 'public.jpeg', 'image', 'JPEG', 5000, 1600000000,
                1600000100, 20240601120300, \(digest), 5000, 1600000100)
            """)
        }
        try db.execute(sql: """
        INSERT INTO media_asset (library_root_id, relative_path, name_sort_key, name, content_type_identifier, kind, format,
            byte_size, created_at_unix, content_modified_at_unix)
        VALUES (2, 'only.jpg', 'only.jpg', 'only.jpg', 'public.jpeg', 'image', 'JPEG', 10, 1600000000, 1600000100)
        """)
        var faces: [Face] = []
        let paths = try String.fetchAll(db, sql: """
        SELECT relative_path FROM media_asset WHERE library_root_id = 1 AND relative_path LIKE '2024/%' ORDER BY rowid
        """)
        for (index, path) in paths.enumerated() {
            if index < 15 {
                faces.append(Face(1, path, 0, anna, index % 5 == 4 ? nil : Double(index % 4) / 4, 0))
            }
            if index >= 10, index < 21 {
                faces.append(Face(1, path, 1, ben, 0.5, 0))
            }
            if index == 21 || index == 22 {
                faces.append(Face(1, path, 2, nil, nil, 0))
            }
            if index == 23 {
                faces.append(Face(1, path, 2, nil, nil, 1))
            }
        }
        // Two faces of Anna on one photo, the second likelier.
        faces.append(Face(1, paths[3], 3, anna, 0.99, 0))
        faces.append(Face(1, "copy.jpg", 0, anna, 0.7, 0))
        faces.append(Face(2, "only.jpg", 0, anna, 0.6, 0))
        for face in faces {
            try db.execute(
                sql: """
                INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                                  landmarks, quality, analysis_revision, person_id, likeness, is_not_face)
                VALUES (?, ?, ?, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1, ?, ?, ?)
                """,
                arguments: [face.rootID, face.path, face.index, face.person, face.likeness, face.notAFace]
            )
        }
    }

    struct Face {
        let rootID: Int64
        let path: String
        let index: Int
        let person: Int64?
        let likeness: Double?
        let notAFace: Int

        init(_ rootID: Int64, _ path: String, _ index: Int, _ person: Int64?, _ likeness: Double?, _ notAFace: Int) {
            self.rootID = rootID
            self.path = path
            self.index = index
            self.person = person
            self.likeness = likeness
            self.notAFace = notAFace
        }
    }

    /// The writes after the migration, each a kind of change that moves a photo in or out of a
    /// person or along their order.
    static let writes: [(String, String)] = [
        ("a reassignment", "UPDATE face SET person_id = 2 WHERE library_root_id = 1 AND face_index = 0 AND rowid = (SELECT min(rowid) FROM face)"),
        ("one of two faces of a person leaving", "DELETE FROM face WHERE face_index = 3"),
        ("a photo's only face of a person leaving", """
        DELETE FROM face WHERE rowid = (SELECT max(rowid) FROM face WHERE person_id = 1 AND face_index = 0 AND relative_path LIKE '2024/%')
        """),
        ("an unidentified face named", "UPDATE face SET person_id = 1 WHERE person_id IS NULL AND is_not_face = 0 AND face_index = 2"),
        ("a face that is not one", "UPDATE face SET is_not_face = 1 WHERE rowid = (SELECT min(rowid) + 5 FROM face)"),
        ("a choice", "UPDATE media_asset SET media_choice = 'liked' WHERE relative_path = 'copy.jpg' AND library_root_id = 2"),
        ("a rename", "UPDATE media_asset SET relative_path = '2024/c/renamed.jpg' WHERE rowid = 8"),
        ("a Trash", "UPDATE media_asset SET pending_trash_batch_unix_ms = 1700000000000 WHERE rowid = 9"),
        ("a new capture time", "UPDATE media_asset SET capture_wall_compact = 20300101000000 WHERE rowid = 10"),
        ("a new size", "UPDATE media_asset SET byte_size = 1 WHERE rowid = 2"),
        ("a new photo and its face", """
        INSERT INTO media_asset (library_root_id, relative_path, name_sort_key, name, content_type_identifier, kind, format,
            byte_size, created_at_unix, content_modified_at_unix)
        VALUES (1, '2025/new.jpg', 'new.jpg', 'new.jpg', 'public.jpeg', 'image', 'JPEG', 77, 1700000000, 1700000000);
        INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height, landmarks,
            quality, analysis_revision, person_id, likeness)
        VALUES (1, '2025/new.jpg', 0, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1, 1, 0.3)
        """),
        ("a deleted photo", "DELETE FROM media_asset WHERE rowid = 12"),
        ("a reading replacing a photo's faces", """
        DELETE FROM face WHERE library_root_id = 1 AND relative_path = (SELECT relative_path FROM media_asset WHERE rowid = 13);
        INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height, landmarks,
            quality, analysis_revision, person_id)
        SELECT 1, relative_path, 0, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 2, NULL FROM media_asset WHERE rowid = 13
        """),
        ("the copy's own face", """
        INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height, landmarks,
            quality, analysis_revision, person_id, likeness)
        VALUES (2, 'copy.jpg', 0, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1, 1, 0.1)
        """),
        ("the copy gone", "DELETE FROM media_asset WHERE library_root_id = 1 AND relative_path = 'copy.jpg'"),
        ("a person removed", "DELETE FROM person WHERE id = 2"),
    ]
}
