import Foundation
import GRDB
@testable import OtosKit
import Testing

/// ADR 0054 (owner, 2026-11-15): a face on any copy of a photo is the photo's. A person's
/// photos, People and the People filter find a photo by a face on a copy the scope does not
/// show, whether the person's photos are sought or the order is walked, and a person's photo
/// count counts the photo once.
@Suite(.testScope)
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

    /// What a photo shows of its copies' faces (owner, 2026-11-15: a named face on any copy is
    /// the photo's). The shown copy lists its own faces, then each person named only on another
    /// copy, with that copy's face: its box is of that copy's pixels, so it is outlined only
    /// where that copy shows, and an act on it acts on that copy. Another copy's unidentified
    /// faces are not listed, a held act on the other copy's face shows on this one, two copies
    /// selected list the face once, and the Person sheet's row shows the photo once.
    @Test func aPhotoShowsThePeopleNamedOnItsCopiesWithTheirOwnFaces() {
        typealias Fixture = FaceAssignmentPolicyTests
        let shown = Fixture.face("IMG_1.JPG", toward: [0: 1], at: 0)
        let named = Fixture.face("a/IMG_1.JPG", toward: [0: 1], at: 0, assignment: .user(Fixture.sam))
        let unidentified = Fixture.face("a/IMG_1.JPG", index: 1, toward: [1: 1], at: 0)
        let ian = Fixture.face("IMG_1.JPG", index: 1, toward: [2: 1], at: 0, assignment: .user(Fixture.ian))
        let ianOnCopy = Fixture.face("a/IMG_1.JPG", index: 2, toward: [2: 1], at: 0, assignment: .model(Fixture.ian))
        var snapshot = PeopleStateTests.snapshot([shown, ian, named, unidentified, ianOnCopy])
        let (library, account) = (shown.id.asset, named.id.asset)
        snapshot.copies = [[library, account]]
        snapshot.photoOf = [account: library]
        let state = PeopleStateBuilder.state(from: snapshot)

        // Ian is on both: the library's own face. Sam is named only on the account's.
        #expect(state.faces(of: library).map(\.id) == [shown.id, ian.id, named.id])
        #expect(state.faces(of: library).last?.person == Fixture.sam)
        #expect(state.faces(of: account).map(\.id) == [named.id, unidentified.id, ianOnCopy.id])
        #expect(state.selectionFaces(for: [library, account]).faces.map(\.id)
            == [shown.id, ian.id, named.id, unidentified.id, ianOnCopy.id])
        #expect(state.face(named.id)?.id.asset == account, "the face is the account copy's")
        #expect(state.person(Fixture.sam)?.media.total == 1)
        #expect(state.person(Fixture.ian)?.media.total == 1)
        #expect(state.person(Fixture.ian)?.newestFaces.count == 1, "one face per photo")

        // `This Is Not Sam` held on the account's face: the library no longer lists her, and
        // the face, unidentified now, is the account's own.
        let held = state.overlaying(PeopleOverlayEffect(faces: [named.id: .person(nil)]))
        #expect(held.faces(of: library).map(\.id) == [shown.id, ian.id])
        #expect(held.faces(of: account).first?.person == nil)
    }

    /// The likeness that orders a person's photos (`Most Like First`) compares a face with the
    /// person's faces in other photos only: a copy's face, read from another preview of the
    /// same photo, is not evidence of how like the person the photo is.
    @Test func aLikenessIsNeverToTheSamePhotosOtherCopy() {
        typealias Fixture = FaceAssignmentPolicyTests
        let shown = Fixture.face("IMG_1.JPG", toward: [0: 1, 1: 0.05], at: 0, assignment: .user(Fixture.sam))
        let copy = Fixture.face("a/IMG_1.JPG", toward: [0: 1, 1: 0.05], at: 0, assignment: .user(Fixture.sam))
        let other = Fixture.face("IMG_2.JPG", toward: [0: 1, 1: 1], at: Fixture.day, assignment: .user(Fixture.sam))
        let faces = [shown, copy, other]
        let separate = FaceAssignmentPolicy.assign(faces: faces, people: Fixture.people)
        let onePhoto = FaceAssignmentPolicy.assign(faces: faces, people: Fixture.people, photoOf: [copy.id.asset: shown.id.asset])
        #expect(separate.likeness[shown.id].map { $0 > 0.99 } == true, "counted twice, the photo is like itself")
        let toOther = zip(shown.embedding.values, other.embedding.values).map(*).reduce(0, +)
        #expect(onePhoto.likeness[shown.id].map { abs($0 - toOther) < 1e-4 } == true)
        #expect(onePhoto.likeness[copy.id].map { abs($0 - toOther) < 1e-4 } == true)
        #expect(onePhoto.likeness[other.id].map { abs($0 - toOther) < 1e-4 } == true)
    }

    /// A face named on one copy is the photo's on every copy, and stays the user's when the
    /// other copy is read for its own faces (each copy is read from its own preview: a
    /// library's Otos rendering, an account's Immich preview). The other copy shows the name
    /// before it is read and after; once assignment gives its own face the person, it shows
    /// that, and the person's photo is counted once. A photo whose two copies are both owed
    /// faces is one photo not yet checked.
    @Test func aNameOnOneCopySurvivesTheOtherCopysReading() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg", "c.jpg"])
        let (a, b) = (library.id("a.jpg"), library.id("b.jpg"))
        let store = library.store
        let libraries = await store.currentLibraries()
        let paths = CatalogWindowPolicy.availablePaths(from: libraries)
        // A digest of the same bytes, as enrichment would read for two identical files.
        let sameBytes = try #require(ContentDigest(bytes: Array(repeating: 7, count: ContentDigest.byteCount)))
        func digest(_ ids: [MediaAssetID]) async throws {
            for (id, asset) in try await store.mediaAssets(for: ids) {
                _ = try await store.applyContentHash(ContentHashResult(
                    id: id, contentHash: sameBytes, sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt)
                ))
            }
        }
        #expect(try await store.uncheckedForFaces(availableLibraryPaths: paths) == MediaCount(photos: 3))
        try await digest([a, b])
        #expect(try await store.uncheckedForFaces(availableLibraryPaths: paths) == MediaCount(photos: 2))

        try await library.readFaces([library.result(for: "b.jpg", faces: [PeopleStoreTests.face(x: 0.3)])])
        try await digest([b])
        let named = FaceID(asset: b, index: 0)
        let sam = try #require(try await store.perform(.moveToNewPerson([named], name: "Sam")).person)
        var state = try await PeopleStateBuilder.state(from: store.peopleSnapshot(availableLibraryPaths: paths))
        #expect(state.faces(of: a).map(\.id) == [named], "a, not yet read, shows the name on b")
        #expect(state.unchecked == MediaCount(photos: 2))

        try await library.readFaces([library.result(for: "a.jpg", faces: [PeopleStoreTests.face(x: 0.3)])])
        try await digest([a])
        let own = FaceID(asset: a, index: 0)
        let snapshot = try await store.peopleSnapshot(availableLibraryPaths: paths)
        #expect(snapshot.faces.first { $0.id == named }?.assignment == .user(sam), "the user's word survives")
        state = PeopleStateBuilder.state(from: snapshot)
        #expect(state.faces(of: a).map(\.id) == [own, named])

        state = try await PeopleAssignment.settle(store: store, libraries: libraries)
        #expect(state.faces(of: a).map(\.id) == [own])
        #expect(state.faces(of: a).first?.person == sam)
        #expect(state.person(sam)?.media.total == 1)
        #expect(state.unchecked == MediaCount(photos: 1))
        await store.shutdown()
    }

    /// The copies People resolves a photo's faces through are read from the digest index, by
    /// the digest of a file with a face and a present copy: every present copy of the photo,
    /// the copy with no face of its own included. A photo with no copy is not asked for.
    @Test func thePhotosCopiesAreReadThroughTheDigestIndex() async throws {
        let dbQueue = try await Self.catalog { db in
            try Self.face(person: 1, on: "a/IMG_0001.JPG", db: db)
            try db.execute(sql: """
            INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                              landmarks, quality, analysis_revision)
            VALUES (1, 'IMG_0200.JPG', 0, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1)
            """)
        }
        let (asked, rows, plan) = try await dbQueue.read { db in
            let asked = try Data.fetchAll(db, sql: """
            SELECT m.content_sha1 FROM face f
            JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
            WHERE m.has_copies = 1
            """)
            return try (
                asked,
                asked.flatMap { digest in
                    try Row.fetchAll(db, sql: PhotoFaceSQL.presentCopiesOfDigest, arguments: [digest])
                        .map { "\($0[0] as Int64):\($0[1] as String)" }
                },
                Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(PhotoFaceSQL.presentCopiesOfDigest)", arguments: [Data()])
                    .map { $0["detail"] as String }
            )
        }
        #expect(asked.count == 1, "IMG_0200.JPG has no copy, so its photo is not asked for")
        #expect(Set(rows) == ["1:IMG_0001.JPG", "2:a/IMG_0001.JPG"])
        #expect(plan.contains { $0.hasPrefix("SEARCH face_copy USING") && $0.contains(ContentDigestSQL.indexName) }, "\(plan)")
        #expect(!plan.contains { $0.hasPrefix("SCAN face_copy") }, "\(plan)")
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
                          landmarks, quality, analysis_revision, person_id)
        VALUES (2, ?, ?, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1, ?)
        """, arguments: [path, person, person])
    }
}
