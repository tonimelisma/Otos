import Foundation
import GRDB
import MediaMetadata
@testable import OtosKit
import Testing

struct CaptureWallClockTests {
    @Test func selectsLocalFloatingOriginalOverAbsoluteQuickTime() {
        let records = [
            CaptureTimestampRecord(
                role: "quickTimeCreation",
                instant: Date(timeIntervalSince1970: 1_700_000_000),
                utcOffsetSeconds: 0,
                precision: "absolute",
                year: 2023,
                month: 11,
                day: 14,
                hour: 22,
                minute: 13,
                second: 20
            ),
            CaptureTimestampRecord(
                role: "original",
                instant: nil,
                utcOffsetSeconds: nil,
                precision: "localFloating",
                year: 2026,
                month: 1,
                day: 1,
                hour: 12,
                minute: 0,
                second: 0
            ),
        ]

        let wall = CaptureWallClock.select(from: records)
        #expect(wall?.compact == 20_260_101_120_000)
        #expect(wall?.precision == "localFloating")
    }

    /// ADR 0039: the wall clock follows the library's `wallClockPrecedence`, so an AVI's
    /// RIFF recording date (ICRD/IDIT) names it when no earlier role is local, rather than
    /// the mtime-less-duration fallback. A later role never outranks an earlier one.
    @Test func aRiffRecordingDateNamesTheFileWhenNoEarlierRoleIsLocal() {
        let riff = CaptureTimestampRecord(
            role: "riffRecording", instant: nil, utcOffsetSeconds: nil, precision: "localFloating",
            year: 2010, month: 6, day: 5, hour: 14, minute: 3, second: 9
        )
        #expect(CaptureWallClock.select(from: [riff])?.compact == 20_100_605_140_309)
        let original = CaptureTimestampRecord(
            role: "original", instant: nil, utcOffsetSeconds: nil, precision: "localFloating",
            year: 2011, month: 1, day: 2, hour: 3, minute: 4, second: 5
        )
        #expect(CaptureWallClock.select(from: [riff, original])?.compact == 20_110_102_030_405)
    }

    /// A local record whose components are not a real wall clock is left out, so the next
    /// role in `wallClockPrecedence` names the file.
    @Test func anInvalidLocalRecordFallsToTheNextRole() {
        let invalid = CaptureTimestampRecord(
            role: "original", instant: nil, utcOffsetSeconds: nil, precision: "localFloating",
            year: 2026, month: 2, day: 30, hour: 25, minute: 0, second: 0
        )
        let digitized = CaptureTimestampRecord(
            role: "digitized", instant: nil, utcOffsetSeconds: nil, precision: "localFloating",
            year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5
        )
        #expect(CaptureWallClock.select(from: [invalid, digitized])?.compact == 20_260_102_030_405)
    }

    @Test func rejectsAbsoluteOnlyCandidates() {
        let records = [
            CaptureTimestampRecord(
                role: "original",
                instant: Date(),
                utcOffsetSeconds: 0,
                precision: "absolute",
                year: 2026,
                month: 1,
                day: 1,
                hour: 0,
                minute: 0,
                second: 0
            ),
            CaptureTimestampRecord(
                role: "gps",
                instant: Date(),
                utcOffsetSeconds: 0,
                precision: "absolute",
                year: 2026,
                month: 1,
                day: 1,
                hour: 0,
                minute: 0,
                second: 0
            ),
        ]
        #expect(CaptureWallClock.select(from: records) == nil)
    }
}

@Suite(.testDirectory)
struct CatalogStoreSchemaMigrationTests {
    /// ARC-043: a catalog whose migration history this build does not know — one a newer
    /// Otos wrote, or one from before the schema baseline — is refused unopened, and
    /// nothing in it or beside it is erased.
    @Test(arguments: ["v999_future_history", "v21_enrichment_claim_is_a_process_fact"])
    func aCatalogWithUnknownHistoryIsRefusedWithoutErase(identifier: String) async throws {
        let fixture = try await Self.makeUnknownHistoryFixture(identifier: identifier)
        let store = CatalogStore(location: .databaseFile(fixture.databaseURL))

        do {
            try await store.start(scansSavedLibraries: false)
            Issue.record("Expected unsupportedCatalogSchema")
        } catch let CatalogStoreError.unsupportedCatalogSchema(problem) {
            #expect(problem == .writtenByOtherOtos)
        }

        let reader = try DatabaseQueue(path: fixture.databaseURL.path(percentEncoded: false))
        let (rootCount, applied) = try await reader.read { db in
            let rootCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_root") ?? 0
            let applied = try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
            return (rootCount, applied)
        }
        #expect(rootCount == 1)
        #expect(applied.contains(identifier))
        #expect(FileManager.default.fileExists(atPath: fixture.thumbnail.path(percentEncoded: false)))
    }

    /// A refused catalog cannot say whether a persisted root is registered, so a
    /// namespace lease for that root reports the catalog, never the root, as missing.
    /// ARC-043: a catalog written at the baseline opens through the additive
    /// `file_identifier` migration and keeps its rows.
    @Test func aBaselineCatalogGainsTheFileIdentifierColumnAndKeepsItsRows() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            for statement in CatalogSchema.baselineStatements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [CatalogSchema.baselineMigrationIdentifier]
            )
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            try db.execute(sql: """
            INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key)
            VALUES (1, 'a.jpg', 'a.jpg', 'a.jpg', 'a.jpg')
            """)
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let (applied, columns, rows) = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try (
                String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"),
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('media_asset')")),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset") ?? 0
            )
        }
        #expect(applied == [
            CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier,
            CatalogSchema.previewPathMigrationIdentifier, CatalogSchema.editRecipeMigrationIdentifier,
            CatalogSchema.heifOrientationMigrationIdentifier,
            CatalogSchema.extractionRevisionMigrationIdentifier,
            CatalogSchema.familyRevisionMigrationIdentifier,
            CatalogSchema.captureInstantMigrationIdentifier,
            CatalogSchema.contentIdentifierMigrationIdentifier,
            CatalogSchema.trashPathMigrationIdentifier,
            CatalogSchema.duplicatesMigrationIdentifier,
            CatalogSchema.renderSignatureMigrationIdentifier,
            CatalogSchema.productStampsMigrationIdentifier,
            CatalogSchema.awaitingPresenceMigrationIdentifier,
            CatalogSchema.remoteBaseURLMigrationIdentifier,
            CatalogSchema.hiddenBySourceMigrationIdentifier,
            CatalogSchema.sourceProductsMigrationIdentifier,
            CatalogSchema.facesMigrationIdentifier,
            CatalogSchema.peopleMigrationIdentifier,
            CatalogSchema.sourceItemIDMigrationIdentifier,
            CatalogSchema.searchEmbeddingsMigrationIdentifier,
            CatalogSchema.searchTextMigrationIdentifier,
            CatalogSchema.captureLocalTimeMigrationIdentifier,
            CatalogSchema.rawFacesMigrationIdentifier,
            CatalogSchema.decodeVerdictMigrationIdentifier,
            CatalogSchema.autoTaggedPeopleMigrationIdentifier,
            CatalogSchema.placeNamesMigrationIdentifier,
            CatalogSchema.keyPhotoMigrationIdentifier,
            CatalogSchema.personAdmissionMigrationIdentifier,
            CatalogSchema.facesFromPreviewMigrationIdentifier,
            CatalogSchema.inThisPhotoMigrationIdentifier,
            CatalogSchema.stackKeyMigrationIdentifier,
            CatalogSchema.stackCandidateIndexMigrationIdentifier,
            CatalogSchema.lastSyncedMigrationIdentifier,
            CatalogSchema.videoFacesMigrationIdentifier,
            CatalogSchema.pathKeysMigrationIdentifier,
            CatalogSchema.burstMigrationIdentifier,
            CatalogSchema.leftOutIndexMigrationIdentifier,
            CatalogSchema.sourceProductsAbsentMigrationIdentifier,
            CatalogSchema.accountVideoFacesMigrationIdentifier,
            CatalogSchema.resyncOwedMigrationIdentifier,
            CatalogSchema.continuousFrameMigrationIdentifier,
            CatalogSchema.placeCellMigrationIdentifier,
            CatalogSchema.undecodableIndexMigrationIdentifier,
            CatalogSchema.placeNameLanguageMigrationIdentifier,
            CatalogSchema.cameraBurstsRemovedMigrationIdentifier,
            CatalogSchema.facesReadSourceMigrationIdentifier,
            CatalogSchema.canonicalBirthdayMigrationIdentifier,
            CatalogSchema.keyPhotoIsUsersWordMigrationIdentifier,
            CatalogSchema.facesOwedIndexesMigrationIdentifier,
            CatalogSchema.unreadThumbnailsMigrationIdentifier,
            CatalogSchema.leftOutIndexDroppedMigrationIdentifier,
            CatalogSchema.unreadTextPreviewsMigrationIdentifier,
            CatalogSchema.facePersonPhotoIndexMigrationIdentifier,
            CatalogSchema.windowReadIndexesMigrationIdentifier,
            CatalogSchema.wholeSecondCaptureLocalMigrationIdentifier,
            CatalogSchema.assignedFacePhotoIndexMigrationIdentifier,
            CatalogSchema.photoDescriptionMigrationIdentifier,
            CatalogSchema.stackCandidatePathMigrationIdentifier,
            CatalogSchema.copiesMigrationIdentifier,
        ])
        #expect(columns.contains("file_identifier"))
        #expect(rows == 1)
    }

    /// v8 (ENR-003): the four `ts_*_unix` columns become the library's capture instant. A
    /// row with stored records takes the first role in `instantPrecedence` with an instant
    /// (digitized here, which the old order ranked behind QuickTime's creation date); a row
    /// whose records cannot be decoded, or that has none, keeps the old columns' value in
    /// the library's order. The absolute time the timeline falls back to still falls back
    /// from it to the file's dates (v23 keeps that chain under `best_capture_local`).
    @Test func theCaptureInstantMigrationOrdersByTheLibrarysInstant() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let records = try CatalogStore.encodeMetadataExtraJSON(AssetMetadata(timestamps: [
            .absolute(.digitized, instant: Date(timeIntervalSince1970: 200)),
            .absolute(.quickTimeCreation, instant: Date(timeIntervalSince1970: 300)),
        ]))
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            for statement in CatalogSchema.baselineStatements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [CatalogSchema.baselineMigrationIdentifier]
            )
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            struct OldRow {
                let path: String
                var original: Double?
                var quickTime: Double?
                var digitized: Double?
                var gps: Double?
            }
            let rows = [
                OldRow(path: "recorded.mov", quickTime: 300, digitized: 200),
                OldRow(path: "undecodable.jpg", original: 100),
                OldRow(path: "unread.jpg", gps: 500),
                OldRow(path: "undated.jpg"),
            ]
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (
                        library_root_id, relative_path, relative_path_key, sort_key, name_sort_key, created_at_unix,
                        ts_original_unix, ts_quicktime_creation_unix, ts_digitized_unix, ts_gps_unix
                    ) VALUES (1, ?, ?, ?, ?, 50, ?, ?, ?, ?)
                    """,
                    arguments: [row.path, row.path, row.path, row.path, row.original, row.quickTime, row.digitized, row.gps]
                )
            }
            try db.execute(
                sql: "INSERT INTO asset_metadata (library_root_id, relative_path, metadata_extra_json) VALUES (1, ?, ?)",
                arguments: ["recorded.mov", records]
            )
            try db.execute(
                sql: "INSERT INTO asset_metadata (library_root_id, relative_path, metadata_extra_json) VALUES (1, ?, ?)",
                arguments: ["undecodable.jpg", "not json"]
            )
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let (best, columns, indexes) = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try (
                Dictionary(uniqueKeysWithValues: Row.fetchAll(
                    db, sql: "SELECT relative_path, \(CatalogSchema.absoluteCaptureSQL) AS absolute FROM media_asset"
                ).map { ($0["relative_path"] as String, $0["absolute"] as Double?) }),
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('media_asset')")),
                Set(String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_media_asset_best_capture_%'"
                ))
            )
        }
        #expect(best["recorded.mov"] == 200)
        #expect(best["undecodable.jpg"] == 100)
        #expect(best["unread.jpg"] == 500)
        #expect(best["undated.jpg"] == 50)
        #expect(columns.contains("capture_instant_unix"))
        #expect(columns.isDisjoint(with: ["ts_original_unix", "ts_quicktime_creation_unix", "ts_digitized_unix", "ts_gps_unix"]))
        #expect(indexes.count == 4)
    }

    /// ADR 0047: v26 auto-tags faces. A face the user confirmed is the user's; a face of a
    /// group they ignored is held, never given a person by Otos; every other face is open
    /// for assignment. The ignored flag is gone, and a person may be hidden or a favourite.
    @Test func theAutoTaggedPeopleMigrationKeepsTheUsersWord() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.decodeVerdictMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            try db.execute(sql: """
            INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key)
            VALUES (1, 'a.jpg', 'a.jpg', 'a.jpg', 'a.jpg')
            """)
            try db.execute(sql: "INSERT INTO person (id, name) VALUES (1, 'Sam')")
            for (index, person, ignored) in [(0, Int64?(1), 0), (1, nil, 1), (2, nil, 0)] {
                try db.execute(
                    sql: """
                    INSERT INTO face (
                        library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                        landmarks, quality, analysis_revision, embedding, person_id, is_ignored
                    ) VALUES (1, 'a.jpg', ?, 0, 0, 0.1, 0.1, x'', 0.5, 1, x'', ?, ?)
                    """,
                    arguments: [index, person, ignored]
                )
            }
        }
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.autoTaggedPeopleMigrationIdentifier)
        let (assignments, faceColumns, personColumns) = try await queue.read { db in
            try (
                Int.fetchAll(db, sql: "SELECT assignment FROM face ORDER BY face_index"),
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('face')")),
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('person')"))
            )
        }
        #expect(assignments == [FaceAssignmentColumn.user, .held, .open].map(\.rawValue))
        #expect(!faceColumns.contains("is_ignored"))
        #expect(faceColumns.isSuperset(of: ["assignment", "likeness", "is_feature"]))
        #expect(personColumns.isSuperset(of: ["is_hidden", "is_favorite"]))
    }

    /// ADR 0047: v28 names v26's feature flag the key photo. A person's chosen face stays
    /// chosen, and the one-per-person rule holds under the new name.
    @Test func theKeyPhotoMigrationKeepsEachPersonsChosenFace() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.placeNamesMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            try db.execute(sql: """
            INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key)
            VALUES (1, 'a.jpg', 'a.jpg', 'a.jpg', 'a.jpg')
            """)
            try db.execute(sql: "INSERT INTO person (id, name) VALUES (1, 'Sam')")
            for (index, chosen) in [(0, 0), (1, 1)] {
                try db.execute(
                    sql: """
                    INSERT INTO face (
                        library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                        landmarks, quality, analysis_revision, embedding, person_id, is_feature
                    ) VALUES (1, 'a.jpg', ?, 0, 0, 0.1, 0.1, x'', 0.5, 1, x'', 1, ?)
                    """,
                    arguments: [index, chosen]
                )
            }
        }
        try CatalogStore.migrator.migrate(queue)
        let (chosen, columns) = try await queue.read { db in
            try (
                Int.fetchAll(db, sql: "SELECT is_key_photo FROM face ORDER BY face_index"),
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('face')"))
            )
        }
        #expect(chosen == [0, 1])
        #expect(!columns.contains("is_feature"))
        await #expect(throws: DatabaseError.self) {
            try await queue.write { db in try db.execute(sql: "UPDATE face SET is_key_photo = 1 WHERE face_index = 0") }
        }
    }

    /// ADR 0039: v23 puts the timeline on local capture time. A row with a wall clock —
    /// floating or offset-bearing — is its wall clock read as UTC, whatever its instant or
    /// file dates say; a row without one is its absolute time read in the zone the
    /// migration runs in, at that time; an undated row stays undated. Every index over the
    /// old column is rebuilt under its own name over the new one.
    @Test func theCaptureLocalTimeMigrationPutsEveryRowOnItsOwnDay() async throws {
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.searchTextMigrationIdentifier)
        let indexesBefore = try await queue.read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql LIKE '%best_capture_unix%'"
            ))
        }
        // 2024-04-25 14:51 floating, created 101 days later; 2025-11-09 20:00 at −08:00
        // (04:00 UTC on the 10th); a screenshot with only a creation date in July (−07:00).
        struct OldRow {
            let path: String
            let wall: Int64?
            let instant: Double?
            let created: Double?
        }
        let rows = [
            OldRow(path: "floating.jpg", wall: 20_240_425_145_100, instant: nil, created: 1_722_800_000),
            OldRow(path: "california.heic", wall: 20_251_109_200_000, instant: 1_762_747_200, created: 1_762_747_300),
            OldRow(path: "screenshot.png", wall: nil, instant: nil, created: 1_751_400_000),
            OldRow(path: "undated.jpg", wall: nil, instant: nil, created: nil),
        ]
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (
                        library_root_id, relative_path, relative_path_key, sort_key, name_sort_key,
                        capture_wall_compact, capture_instant_unix, created_at_unix
                    ) VALUES (1, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [row.path, row.path, row.path, row.path, row.wall, row.instant, row.created]
                )
            }
            try CatalogSchema.migrateToCaptureLocalTime(db, timeZone: pacific)
        }
        let (local, columns, indexesAfter, stale) = try await queue.read { db in
            try (
                Dictionary(uniqueKeysWithValues: Row.fetchAll(
                    db, sql: "SELECT relative_path, best_capture_local FROM media_asset"
                ).map { ($0["relative_path"] as String, $0["best_capture_local"] as Double?) }),
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('media_asset')")),
                Set(String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql LIKE '%best_capture_local%'"
                )),
                String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE sql LIKE '%best_capture_unix%'")
            )
        }
        #expect(local["floating.jpg"] == 1_714_056_660) // 2024-04-25 14:51 read as UTC
        #expect(local["california.heic"] == 1_762_718_400) // 2025-11-09 20:00 read as UTC
        #expect(local["screenshot.png"] == 1_751_400_000 - 7 * 3600)
        #expect(local["undated.jpg"] == .some(nil))
        #expect(!columns.contains("best_capture_unix"))
        #expect(columns.contains("assumed_utc_offset_seconds"))
        #expect(!indexesBefore.isEmpty)
        #expect(indexesAfter == indexesBefore)
        #expect(stale.isEmpty)
    }

    /// ADR 0039: v56 puts an item without a wall clock on the second its absolute time
    /// falls in, as a wall clock is: an unread Immich still placed by the server's date
    /// with milliseconds sits where the read's wall clock of that second will put it, so the
    /// read does not move it. A time before 1970 goes to its earlier second, a wall clock
    /// keeps its value, and every index over the column is rebuilt under its own name.
    @Test func theWholeSecondMigrationPutsAnUnreadItemOnTheSecondItsReadWillGiveIt() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.windowReadIndexesMigrationIdentifier)
        // 2026-09-12 20:16:27.353 UTC, as Immich reports a still's date, assumed at −07:00;
        // the same still read: its wall clock 2026-09-12 13:16:27.
        let reported = 1_789_244_187.353
        let rows: [(path: String, wall: Int64?, created: Double?)] = [
            ("unread.jpg", nil, reported),
            ("read.jpg", 20_260_912_131_627, reported),
            ("before1970.jpg", nil, -0.5),
        ]
        let indexesBefore = try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (
                        library_root_id, relative_path, relative_path_key, sort_key, name_sort_key,
                        capture_wall_compact, created_at_unix, assumed_utc_offset_seconds
                    ) VALUES (1, ?, ?, ?, ?, ?, ?, -25200)
                    """,
                    arguments: [row.path, row.path, row.path, row.path, row.wall, row.created]
                )
            }
            return try Set(String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql LIKE '%best_capture_local%'"
            ))
        }
        try CatalogStore.migrator.migrate(queue)
        let (local, indexesAfter) = try await queue.read { db in
            try (
                Dictionary(uniqueKeysWithValues: Row.fetchAll(
                    db, sql: "SELECT relative_path, best_capture_local FROM media_asset"
                ).map { ($0["relative_path"] as String, $0["best_capture_local"] as Double?) }),
                Set(String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql LIKE '%best_capture_local%'"
                ))
            )
        }
        #expect(local["read.jpg"] == 1_789_218_987) // 2026-09-12 13:16:27 read as UTC
        #expect(local["unread.jpg"] == local["read.jpg"])
        #expect(local["before1970.jpg"] == -1 - 25200)
        #expect(!indexesBefore.isEmpty)
        #expect(indexesAfter == indexesBefore)
    }

    /// ADR 0009: v13 turns the one enrichment stamp into the metadata stamp and gives every
    /// row the rendering stamp it already had in effect — except a card's or camera's still
    /// or RAW without a preview, whose thumbnail was QuickLook's or the camera's, not a
    /// rendering, and which is rendered again.
    /// v20 (ADR 0046 §2): an account's existing rows are stills, each named by its asset's
    /// folder, so each takes its folder as its source item ID; no other kind gets one.
    @Test func theSourceItemMigrationNamesAccountRowsByTheirFolder() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.sourceProductsMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/RemoteStaging/family', 'immichAccount')")
            for (root, path) in [(1, "2026/a.jpg"), (2, "a1/IMG_1.JPG"), (2, "b2/IMG_2.HEIC")] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind)
                    VALUES (?, ?, ?, ?, ?, 'image')
                    """,
                    arguments: [root, path, path, path, path]
                )
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let named = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Row.fetchAll(db, sql: "SELECT relative_path, source_item_id FROM media_asset ORDER BY relative_path")
                .map { row -> String in
                    let path: String = row["relative_path"]
                    let item: String? = row["source_item_id"]
                    return "\(path)=\(item ?? "nil")"
                }
        }
        #expect(named == ["2026/a.jpg=nil", "a1/IMG_1.JPG=a1", "b2/IMG_2.HEIC=b2"])
    }

    /// v60 (ADR 0054, ADR 0018): every XXH3 digest is cleared, so its row owes a SHA-1, and
    /// every Immich account owes a full resync, which lists each asset with its checksum. Once
    /// two rows hold the same SHA-1, the triggers name the library's copy as the one shown.
    @Test func theCopiesMigrationClearsXXH3AndOwesEveryAccountAResync() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.assignedFacePhotoIndexMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/RemoteStaging/family', 'immichAccount')")
            for (root, path) in [(1, "IMG_1.JPG"), (2, "a1/IMG_1.JPG")] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, byte_size, content_modified_at_unix,
                        content_hash_xxh3_128, content_hash_source_size, content_hash_source_mtime)
                    VALUES (?, ?, ?, ?, ?, 'image', 4, 1700000000, zeroblob(16), 4, 1700000000)
                    """,
                    arguments: [root, path, path, path, path]
                )
            }
        }
        try CatalogStore.migrator.migrate(queue)

        let (digests, owed) = try await queue.read { db in
            try (
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset WHERE content_sha1 IS NOT NULL OR content_hash_source_size IS NOT NULL"),
                Int.fetchOne(db, sql: "SELECT resync_owed FROM library_root WHERE id = 2")
            )
        }
        #expect(digests == 0)
        #expect(owed == 1)

        try await queue.write { db in
            try db.execute(sql: """
            UPDATE media_asset SET content_sha1 = zeroblob(20), content_hash_source_size = 4,
                content_hash_source_mtime = 1700000000
            """)
        }
        let shown = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT relative_path, shown_copy_root_id FROM media_asset ORDER BY relative_path")
                .map { row -> String in
                    let path: String = row["relative_path"]
                    let root: Int64? = row["shown_copy_root_id"]
                    return "\(path)=\(root.map(String.init) ?? "shown")"
                }
        }
        #expect(shown == ["IMG_1.JPG=shown", "a1/IMG_1.JPG=1"])
    }

    @Test func theProductStampsMigrationStampsRenderingsExceptProvisionalOnes() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.renderSignatureMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/Volumes/Card', 'removableVolume')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (3, '/DeviceStaging/Cam', 'deviceMTP')")
            struct Row13 {
                let root: Int
                let path: String
                let kind: String
                let preview: String?
            }
            let rows = [
                Row13(root: 1, path: "lib.jpg", kind: "image", preview: nil),
                Row13(root: 2, path: "card.arw", kind: "raw", preview: nil),
                Row13(root: 2, path: "card.heif", kind: "image", preview: "card.heic"),
                Row13(root: 2, path: "card.mov", kind: "video", preview: nil),
                Row13(root: 3, path: "cam.jpg", kind: "image", preview: nil),
            ]
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, enriched_kind, preview_path, enriched_source_size, enriched_source_mtime)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 10, 20)
                    """,
                    arguments: [row.root, row.path, row.path, row.path, row.path, row.kind, row.kind, row.preview]
                )
            }
        }

        // Up to this migration only: a later one (v25) retries a library still stamped with
        // no preview, which `lib.jpg` here is, and that is not this migration's decision.
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.productStampsMigrationIdentifier)

        let (metadataStamped, rendered) = try await queue.read { db in
            try (
                Set(String.fetchAll(db, sql: "SELECT relative_path FROM media_asset WHERE metadata_source_size = 10 AND metadata_source_mtime = 20")),
                Set(String.fetchAll(db, sql: "SELECT relative_path FROM media_asset WHERE rendered_source_size = 10 AND rendered_source_mtime = 20"))
            )
        }
        #expect(metadataStamped == ["lib.jpg", "card.arw", "card.heif", "card.mov", "cam.jpg"])
        #expect(rendered == ["lib.jpg", "card.heif", "card.mov"])
    }

    /// ADR 0035 backfill: the preview migration clears the enrichment stamps of library
    /// stills — so they re-enrich and gain a rendered thumbnail and preview — and leaves
    /// videos and card rows stamped.
    @Test func thePreviewMigrationReEnrichesLibraryStillsOnly() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            for statement in CatalogSchema.baselineStatements + CatalogSchema.fileIdentifierStatements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in [CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier] {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/Volumes/Card', 'removableVolume')")
            for (root, path, kind) in [(1, "still.jpg", "image"), (1, "clip.mov", "video"), (2, "card.jpg", "image")] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, enriched_source_size, enriched_source_mtime)
                    VALUES (?, ?, ?, ?, ?, ?, 10, 20)
                    """,
                    arguments: [root, path, path, path, path, kind]
                )
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let stamped = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT relative_path FROM media_asset WHERE metadata_source_size IS NOT NULL"
            ))
        }
        #expect(stamped == ["clip.mov", "card.jpg"])
    }

    /// A RAW whose upright original could not be decoded was stamped as read with no faces.
    /// The migration clears the faces stamp of a RAW with no face row, so it is read again,
    /// and leaves a RAW with faces, a still that is no RAW and an unread RAW as they were.
    @Test func theRawFacesMigrationReReadsOnlyRAWsStampedWithoutFaces() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let fresh = CatalogStore(location: .databaseFile(databaseURL))
        try await fresh.start(scansSavedLibraries: false)
        await fresh.shutdown()

        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            let rows: [(String, String, Int?)] = [
                ("faceless.arw", "raw", 10), ("withFace.arw", "raw", 10), ("still.jpg", "image", 10), ("unread.arw", "raw", nil),
            ]
            for (path, kind, stamp) in rows {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, faces_source_size, faces_source_mtime)
                    VALUES (1, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [path, path, path, path, kind, stamp, stamp]
                )
            }
            try db.execute(sql: """
            INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                landmarks, quality, analysis_revision, embedding)
            VALUES (1, 'withFace.arw', 0, 0, 0, 0.5, 0.5, x'00', 0.9, 1, x'00')
            """)
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [CatalogSchema.rawFacesMigrationIdentifier]
            )
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let stamped = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT relative_path FROM media_asset WHERE faces_source_size IS NOT NULL"
            ))
        }
        #expect(stamped == ["withFace.arw", "still.jpg"])
    }

    /// Faces revision 2 only turns more detections away, so the migration clears the faces
    /// stamp of a photo with a face read under revision 1, and leaves a photo stamped with no
    /// face, a photo whose faces revision 2 read, and an unread photo as they were.
    @Test func thePersonAdmissionMigrationReReadsOnlyPhotosWithEarlierFaces() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let fresh = CatalogStore(location: .databaseFile(databaseURL))
        try await fresh.start(scansSavedLibraries: false)
        await fresh.shutdown()

        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            let rows: [(String, Int?)] = [("faceless.jpg", 10), ("earlier.jpg", 10), ("current.jpg", 10), ("unread.jpg", nil)]
            for (path, stamp) in rows {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, faces_source_size, faces_source_mtime)
                    VALUES (1, ?, ?, ?, ?, 'image', ?, ?)
                    """,
                    arguments: [path, path, path, path, stamp, stamp]
                )
            }
            for (path, revision) in [("earlier.jpg", 1), ("current.jpg", 2)] {
                try db.execute(
                    sql: """
                    INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                        landmarks, quality, analysis_revision, embedding)
                    VALUES (1, ?, 0, 0, 0, 0.5, 0.5, x'00', 0.9, ?, x'00')
                    """,
                    arguments: [path, revision]
                )
            }
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [CatalogSchema.personAdmissionMigrationIdentifier]
            )
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let stamped = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT relative_path FROM media_asset WHERE faces_source_size IS NOT NULL"
            ))
        }
        #expect(stamped == ["faceless.jpg", "current.jpg"])
    }

    /// Faces read from originals become faces read from stored previews (ADR 0047): the
    /// migration drops the library claim's index pair, which owed faces, and clears every
    /// faces stamp, with faces or without, so every still is read again from its preview; the
    /// faces themselves stay until each re-reading replaces them.
    /// v35 (ADR 0047): a catalog from before it gains a video's face frames and each face's
    /// frame, and the library claim's index pair, made from the text the claim queries with.
    @Test func theVideoFacesMigrationAddsFramesAndTheLibraryClaimsIndexes() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // v35 as it ran: on a catalog migrated up to it, before v60 renamed the digest it names.
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue, upTo: CatalogSchema.videoFacesMigrationIdentifier)

        let (assetColumns, faceColumns, indexes) = try await dbQueue.read { db in
            try (
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('media_asset')")),
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('face')")),
                Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            )
        }
        #expect(assetColumns.contains("face_frames_path"))
        #expect(faceColumns.contains("frame_index"))
        #expect(indexes.isSuperset(of: [EnrichmentClaimGateway.libraryGlobalIndexName, EnrichmentClaimGateway.libraryRootIndexName]))
    }

    /// v36 (ARC-056): every stored name key is made again from its row's path under its
    /// root's case capability — an empty key and the key of a path a reorganization moved a
    /// row from alike, for media and companions.
    @Test func thePathKeysMigrationMakesEveryKeyFromItsPath() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.videoFacesMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO library_root (id, path, kind, case_sensitive_names) VALUES
                (1, '/Pictures', 'library', 0), (2, '/Sensitive', 'library', 1)
            """)
            for (root, path, key) in [
                (1, "2026/IMG_1.JPG", ""),
                (1, "2023/03/a.jpg", "a.jpg"),
                (1, "b.jpg", "b.jpg"),
                (2, "C.JPG", ""),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind)
                    VALUES (?, ?, ?, ?, ?, 'image')
                    """,
                    arguments: [root, path, key, path, path]
                )
            }
            try db.execute(sql: """
            INSERT INTO media_companion (library_root_id, relative_path, relative_path_key, primary_relative_path, kind)
            VALUES (1, '2026/IMG_1.XMP', '', '2026/IMG_1.JPG', 'xmp')
            """)
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let keys = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Row.fetchAll(db, sql: """
            SELECT relative_path, relative_path_key FROM media_asset
            UNION ALL SELECT relative_path, relative_path_key FROM media_companion
            ORDER BY relative_path
            """).map { row -> String in
                let path: String = row[0]
                let key: String = row[1]
                return "\(path)=\(key)"
            }
        }
        #expect(keys == [
            "2023/03/a.jpg=2023/03/a.jpg",
            "2026/IMG_1.JPG=2026/img_1.jpg",
            "2026/IMG_1.XMP=2026/img_1.xmp",
            "C.JPG=C.JPG",
            "b.jpg=b.jpg",
        ])
    }

    /// v37 (ADR 0052): each row's burst identifier is filled from the metadata record Otos
    /// already stored for it, so a burst stacks without its file being read again.
    @Test func theBurstMigrationFillsEachIdentifierFromItsStoredMetadata() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.pathKeysMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            for (path, extra) in [
                ("IMG_1.HEIC", #"{"burstIdentifier":"B1","family":"heif"}"#),
                ("IMG_2.HEIC", #"{"family":"heif"}"#),
                ("IMG_3.HEIC", nil),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind)
                    VALUES (1, ?, ?, ?, ?, 'image')
                    """,
                    arguments: [path, path, path, path]
                )
                if let extra {
                    try db.execute(
                        sql: """
                        INSERT INTO asset_metadata (library_root_id, relative_path, family, metadata_extra_json)
                        VALUES (1, ?, 'heif', ?)
                        """,
                        arguments: [path, extra]
                    )
                }
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let identifiers = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Row.fetchAll(db, sql: "SELECT relative_path, burst_identifier FROM media_asset ORDER BY relative_path")
                .map { row -> String in
                    let path: String = row[0]
                    let identifier: String? = row[1]
                    return "\(path)=\(identifier ?? "nil")"
                }
        }
        #expect(identifiers == ["IMG_1.HEIC=B1", "IMG_2.HEIC=nil", "IMG_3.HEIC=nil"])
    }

    /// v46 (ADR 0052): camera bursts no longer stack, so the frame-number column and its
    /// index go; an iPhone burst's identifier stays, read through `idx_media_asset_burst` again.
    @Test func theCameraBurstMigrationDropsTheFrameNumberAndKeepsBurstIdentifiers() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.continuousFrameMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: """
            INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key,
                kind, burst_identifier, continuous_shooting_frame)
            VALUES (1, 'IMG_1.HEIC', 'img_1.heic', 'IMG_1.HEIC', 'IMG_1.HEIC', 'image', 'B1', NULL),
                   (1, 'DSC1.JPG', 'dsc1.jpg', 'DSC1.JPG', 'DSC1.JPG', 'image', NULL, 2)
            """)
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let (columns, indexes, identifiers) = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false))
            .read { db in
                try (
                    Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('media_asset')")),
                    Set(String.fetchAll(db, sql: "SELECT name FROM pragma_index_list('media_asset')")),
                    String.fetchAll(db, sql: "SELECT burst_identifier FROM media_asset WHERE burst_identifier IS NOT NULL")
                )
            }
        #expect(!columns.contains("continuous_shooting_frame"))
        #expect(indexes.contains("idx_media_asset_burst"))
        #expect(!indexes.contains("idx_media_asset_burst_or_frame"))
        #expect(identifiers == ["B1"])
    }

    @Test func theFacesFromPreviewMigrationReReadsEveryStill() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let fresh = CatalogStore(location: .databaseFile(databaseURL))
        try await fresh.start(scansSavedLibraries: false)
        await fresh.shutdown()

        let libraryIndexes = ["idx_media_asset_needs_enrichment_global_library", "idx_media_asset_needs_enrichment_root_library"]
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            for path in ["faceless.jpg", "withFace.jpg"] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, faces_source_size, faces_source_mtime)
                    VALUES (1, ?, ?, ?, ?, 'image', 10, 10)
                    """,
                    arguments: [path, path, path, path]
                )
            }
            try db.execute(sql: """
            INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                landmarks, quality, analysis_revision, embedding)
            VALUES (1, 'withFace.jpg', 0, 0, 0, 0.5, 0.5, x'00', 0.9, 2, x'00')
            """)
            // The v18 pair, which v35 made again under the same names for the library claim.
            for name in libraryIndexes {
                try db.execute(sql: "DROP INDEX IF EXISTS \(name)")
                try db.execute(sql: "CREATE INDEX \(name) ON media_asset(relative_path)")
            }
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [CatalogSchema.facesFromPreviewMigrationIdentifier]
            )
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let (stamped, faces, indexes) = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try (
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset WHERE faces_source_size IS NOT NULL") ?? -1,
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face") ?? -1,
                Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            )
        }
        #expect(stamped == 0)
        #expect(faces == 1)
        #expect(indexes.isDisjoint(with: libraryIndexes))
    }

    /// A HEIF rotated by its `irot` property was cataloged with no orientation before
    /// MediaMetadata 0.6.1. The migration clears the enrichment stamps of library HEIF
    /// rows with no orientation, so they re-enrich and read it anew, and leaves HEIFs
    /// that have one, other formats and card rows stamped.
    @Test func theHeifOrientationMigrationReReadsLibraryHeifsWithoutOrientationOnly() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let earlier = [
            CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier,
            CatalogSchema.previewPathMigrationIdentifier, CatalogSchema.editRecipeMigrationIdentifier,
        ]
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            let statements = CatalogSchema.baselineStatements + CatalogSchema.fileIdentifierStatements
                + CatalogSchema.previewPathStatements + CatalogSchema.editRecipeStatements
            for statement in statements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in earlier {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/Volumes/Card', 'removableVolume')")
            struct Row {
                let root: Int
                let path: String
                let family: String
                let orientation: Int?
            }
            let rows = [
                Row(root: 1, path: "turned.heif", family: "heif", orientation: nil),
                Row(root: 1, path: "tagged.heic", family: "heif", orientation: 6),
                Row(root: 1, path: "plain.jpg", family: "jpeg", orientation: nil),
                Row(root: 2, path: "card.heif", family: "heif", orientation: nil),
            ]
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, enriched_source_size, enriched_source_mtime)
                    VALUES (?, ?, ?, ?, ?, 'image', 10, 20)
                    """,
                    arguments: [row.root, row.path, row.path, row.path, row.path]
                )
                try db.execute(
                    sql: """
                    INSERT INTO asset_metadata (library_root_id, relative_path, family, orientation)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [row.root, row.path, row.family, row.orientation]
                )
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let stamped = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT relative_path FROM media_asset WHERE metadata_source_size IS NOT NULL"
            ))
        }
        #expect(stamped == ["tagged.heic", "plain.jpg", "card.heif"])
    }

    /// ADR 0039: v7 renames stored format tokens to MediaMetadata's file-type names and
    /// clears the single-number revisions v6 stored, which per-family revisions replace.
    @Test func v7RenamesFileTypesAndClearsSingleNumberRevisions() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let earlier = [
            CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier,
            CatalogSchema.previewPathMigrationIdentifier, CatalogSchema.editRecipeMigrationIdentifier,
            CatalogSchema.heifOrientationMigrationIdentifier, CatalogSchema.extractionRevisionMigrationIdentifier,
        ]
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            let statements = CatalogSchema.baselineStatements + CatalogSchema.fileIdentifierStatements
                + CatalogSchema.previewPathStatements + CatalogSchema.editRecipeStatements
                + CatalogSchema.heifOrientationStatements + CatalogSchema.extractionRevisionStatements
            for statement in statements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in earlier {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            for (path, format, enriched) in [("a.heic", "HEIC", "HEIC"), ("b.jpg", "JPG", "JPEG"), ("c.arw", "ARW", nil)] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, format, enriched_format)
                    VALUES (1, ?, ?, ?, ?, 'image', ?, ?)
                    """,
                    arguments: [path, path, path, path, format, enriched]
                )
                try db.execute(
                    sql: "INSERT INTO asset_metadata (library_root_id, relative_path, family, extraction_revision) VALUES (1, ?, 'heif', 1)",
                    arguments: [path]
                )
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let rows = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Row.fetchAll(db, sql: """
            SELECT a.relative_path, a.format, a.best_format, m.extraction_revision
            FROM media_asset a JOIN asset_metadata m USING (library_root_id, relative_path)
            ORDER BY a.relative_path
            """).map { row -> String in
                let format: String? = row["format"]
                let best: String? = row["best_format"]
                let revision: Int? = row["extraction_revision"]
                return "\(format ?? "-") \(best ?? "-") \(revision.map(String.init) ?? "nil")"
            }
        }
        #expect(rows == ["HEIF HEIF nil", "JPEG JPEG nil", "ARW ARW nil"])
    }

    /// ADR 0041: v9 adds the content identifier a Live Photo pairs on, and makes the
    /// families that can carry it — HEIF, JPEG and ISO BMFF — stale, so `MetadataRefresher`
    /// re-reads them from local bytes. Other families keep their revision.
    @Test func v9ClearsTheRevisionsOfFamiliesThatCarryAContentIdentifier() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let earlier = [
            CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier,
            CatalogSchema.previewPathMigrationIdentifier, CatalogSchema.editRecipeMigrationIdentifier,
            CatalogSchema.heifOrientationMigrationIdentifier, CatalogSchema.extractionRevisionMigrationIdentifier,
            CatalogSchema.familyRevisionMigrationIdentifier, CatalogSchema.captureInstantMigrationIdentifier,
        ]
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            let statements = CatalogSchema.baselineStatements + CatalogSchema.fileIdentifierStatements
                + CatalogSchema.previewPathStatements + CatalogSchema.editRecipeStatements
                + CatalogSchema.heifOrientationStatements + CatalogSchema.extractionRevisionStatements
            for statement in statements {
                try db.execute(sql: statement)
            }
            try CatalogSchema.migrateToFamilyRevisionsAndFileTypeNames(db)
            try CatalogSchema.migrateToCaptureInstant(db)
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in earlier {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            for (path, family) in [("a/b.heic", "heif"), ("c.jpg", "jpeg"), ("d.mov", "isoBMFF"), ("e.arw", "tiff")] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind)
                    VALUES (1, ?, ?, ?, ?, 'image')
                    """,
                    arguments: [path, path, path, path]
                )
                try db.execute(
                    sql: "INSERT INTO asset_metadata (library_root_id, relative_path, family, extraction_revision) VALUES (1, ?, ?, 1)",
                    arguments: [path, family]
                )
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let rows = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Row.fetchAll(db, sql: """
            SELECT a.relative_path, a.parent_path, a.content_identifier, m.extraction_revision
            FROM media_asset a JOIN asset_metadata m USING (library_root_id, relative_path)
            ORDER BY a.relative_path
            """).map { row -> String in
                let parent: String = row["parent_path"]
                let identifier: String? = row["content_identifier"]
                let revision: Int? = row["extraction_revision"]
                return "\(row["relative_path"] as String) '\(parent)' \(identifier ?? "-") \(revision.map(String.init) ?? "nil")"
            }
        }
        // v12 then clears the EXIF families too (MediaMetadata 0.9's sub-seconds), the TIFF
        // RAW among them, so every row here reads its local bytes again.
        #expect(rows == ["a/b.heic 'a/' - nil", "c.jpg '' - nil", "d.mov '' - nil", "e.arw '' - nil"])
    }

    @Test func refusedCatalogDeniesNamespaceLeaseAsCatalogUnavailable() async throws {
        let fixture = try await Self.makeUnknownHistoryFixture(identifier: "v999_future_history")
        let persistedRoot = try await DatabaseQueue(path: fixture.databaseURL.path(percentEncoded: false)).read { db in
            try String.fetchOne(db, sql: "SELECT path FROM library_root")
        }
        let store = CatalogStore(location: .databaseFile(fixture.databaseURL))

        let acquisition = try await store.acquireNamespaceMutationLease(
            for: LibraryRootPath(rawValue: #require(persistedRoot)),
            owner: .importPublication
        )

        #expect(acquisition == .catalogUnavailable)
    }

    @Test func unrecognizedLegacySchemaIsRefusedWithoutErase() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let staleThumbnail = thumbnailDirectory.appending(path: "keep-me.jpg", directoryHint: .notDirectory)
        try Data("keep".utf8).write(to: staleThumbnail)

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try await dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE library_root (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE
            )
            """)
            try db.execute(sql: """
            CREATE TABLE media_asset (
                library_root_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                PRIMARY KEY (library_root_id, relative_path)
            )
            """)
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/legacy"])
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        do {
            try await store.start(scansSavedLibraries: false)
            Issue.record("Expected unsupportedCatalogSchema")
        } catch let CatalogStoreError.unsupportedCatalogSchema(problem) {
            #expect(problem == .unrecognized)
        }
        #expect(FileManager.default.fileExists(atPath: staleThumbnail.path(percentEncoded: false)))
    }

    @Test func importBatchQueriesReturnNewestFirst() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "a")
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "b")
        try writeCatalogStoreFile(root.appending(path: "c.jpg"), contents: "c")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }

        let older = ImportBatchID(unixMilliseconds: 1_700_000_000_000)
        let newer = ImportBatchID(unixMilliseconds: 1_800_000_000_000)
        try await Self.stampImportBatches(
            databaseURL: databaseURL,
            stamps: [
                "a.jpg": older.unixMilliseconds,
                "b.jpg": newer.unixMilliseconds,
                "c.jpg": newer.unixMilliseconds,
            ]
        )

        let batches = try await store.importBatches()
        #expect(batches.map(\.batchID) == [newer, older])
        #expect(batches.map(\.photoCount) == [2, 1])

        let newerIDs = try await store.assetIDs(inImportBatch: newer)
        #expect(Set(newerIDs.map(\.relativePath.rawValue)) == ["b.jpg", "c.jpg"])
    }

    @Test func enrichmentWritesCaptureWallCompact() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "shot.jpg"), contents: "jpeg")

        let store = CatalogStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)

        let metadata = AssetMetadata(
            timestamps: [
                CaptureTimestampRecord(
                    role: "original",
                    instant: nil,
                    utcOffsetSeconds: -25200,
                    precision: "localWithOffset",
                    year: 2026,
                    month: 7,
                    day: 10,
                    hour: 15,
                    minute: 30,
                    second: 0
                ),
            ]
        )
        let outcome = await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: metadata,
                thumbnailPath: nil,
                sourceSize: 4,
                sourceMTimeSeconds: Int(scanned.testAssets[0].contentModifiedAt?.timeIntervalSince1970 ?? 0),
                contentHash: .empty
            ),
        ])
        #expect(outcome == .applied(count: 1))

        let wall = try await store.captureWall(for: id)
        #expect(wall?.compact == 20_260_710_153_000)
        #expect(wall?.precision == "localWithOffset")
    }
}

private extension CatalogStoreSchemaMigrationTests {
    struct UnknownHistoryFixture {
        let databaseURL: URL
        let thumbnail: URL
    }

    /// A baseline catalog with one library and one asset whose migration record also
    /// names `identifier`, which this build does not register, beside a thumbnail.
    static func makeUnknownHistoryFixture(identifier: String) async throws -> UnknownHistoryFixture {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let thumbnail = thumbnailDirectory.appending(path: "kept.jpg", directoryHint: .notDirectory)
        try Data("kept".utf8).write(to: thumbnail)

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/unknown-history"])
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, sort_key, name_sort_key, name
                ) VALUES (?, 'kept.jpg', 'k', 'kept.jpg', 'kept.jpg')
                """,
                arguments: [db.lastInsertedRowID]
            )
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
        }
        return UnknownHistoryFixture(databaseURL: databaseURL, thumbnail: thumbnail)
    }

    static func stampImportBatches(databaseURL: URL, stamps: [String: Int64]) async throws {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            for (relativePath, batch) in stamps {
                try db.execute(
                    sql: """
                    UPDATE media_asset
                    SET import_batch_unix_ms = ?
                    WHERE relative_path = ?
                    """,
                    arguments: [batch, relativePath]
                )
            }
        }
    }
}

/// ADR 0047's catalog after the faces review: where faces were read from, birthdays in their
/// one form, and key photos on the user's word.
extension CatalogStoreSchemaMigrationTests {
    /// v47 records the source each photo's faces were read from: its stamp where it has one,
    /// else the source the stamp would name now. A photo with no face row records none.
    @Test func theFacesReadSourceMigrationKeepsWhereFacesCameFrom() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.continuousFrameMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            for (path, stamp, rendered, faces) in [
                ("stamped.jpg", Int64?(5), Int64(7), true), ("cleared.jpg", nil, 7, true), ("none.jpg", nil, 7, false),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key,
                        kind, byte_size, faces_source_size, faces_source_mtime, rendered_source_size, rendered_source_mtime)
                    VALUES (1, ?, ?, ?, ?, 'image', 7, ?, ?, ?, 70)
                    """,
                    arguments: [path, path, path, path, stamp, stamp.map { $0 * 10 }, rendered]
                )
                if faces {
                    try db.execute(
                        sql: """
                        INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                            landmarks, quality, analysis_revision, embedding)
                        VALUES (1, ?, 0, 0, 0, 0.1, 0.1, x'', 0.5, 3, x'')
                        """,
                        arguments: [path]
                    )
                }
            }
        }
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.facesReadSourceMigrationIdentifier)
        let sources = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT relative_path, faces_read_source_size, faces_read_source_mtime FROM media_asset ORDER BY relative_path")
                .map { "\($0["relative_path"] as String) \(($0["faces_read_source_size"] as Int64?).map(String.init) ?? "nil") \(($0["faces_read_source_mtime"] as Int64?).map(String.init) ?? "nil")" }
        }
        #expect(sources == ["cleared.jpg 7 70", "none.jpg nil nil", "stamped.jpg 5 50"])
    }

    /// v48 writes each birthday in its one form: a spelling of a valid date the rule before
    /// it accepted is rewritten, and one naming no date is cleared, so no stored birthday
    /// fails the People read.
    @Test func theBirthdayMigrationWritesEachBirthdayInItsForm() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.facesReadSourceMigrationIdentifier)
        let stored = ["1985-6-7", "+985", "0000", "2020", "2021-02-30", "1990-01-02"]
        try await queue.write { db in
            for (id, birthday) in stored.enumerated() {
                try db.execute(sql: "INSERT INTO person (id, birthday) VALUES (?, ?)", arguments: [id + 1, birthday])
            }
        }
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.canonicalBirthdayMigrationIdentifier)
        let birthdays = try await queue.read { db in
            try String?.fetchAll(db, sql: "SELECT birthday FROM person ORDER BY id")
        }
        #expect(birthdays == ["1985-06-07", "0985", nil, "2020", nil, "1990-01-02"])
        #expect(birthdays.compactMap(\.self).allSatisfy { PersonBirthday($0) != nil })
    }

    /// v49 makes a key photo chosen on a face Otos had guessed the user's word, as choosing
    /// one now is; every other face keeps whose word it was.
    @Test func aKeyPhotoOnAGuessBecomesTheUsersWord() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.canonicalBirthdayMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            try db.execute(sql: """
            INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key)
            VALUES (1, 'a.jpg', 'a.jpg', 'a.jpg', 'a.jpg')
            """)
            try db.execute(sql: "INSERT INTO person (id, name) VALUES (1, 'Sam'), (2, 'Ian')")
            for (index, person, assignment, key) in [(0, 1, FaceAssignmentColumn.model, 1), (1, 2, .model, 0)] {
                try db.execute(
                    sql: """
                    INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                        landmarks, quality, analysis_revision, embedding, person_id, assignment, is_key_photo)
                    VALUES (1, 'a.jpg', ?, 0, 0, 0.1, 0.1, x'', 0.5, 3, x'', ?, ?, ?)
                    """,
                    arguments: [index, person, assignment.rawValue, key]
                )
            }
        }
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.keyPhotoIsUsersWordMigrationIdentifier)
        let assignments = try await queue.read { db in
            try Int.fetchAll(db, sql: "SELECT assignment FROM face ORDER BY face_index")
        }
        #expect(assignments == [FaceAssignmentColumn.user, .model].map(\.rawValue))
    }

    /// v53: an empty text reading of a photo with a stored preview may be a preview that did
    /// not decode, so it goes and the photo is owed a reading from its preview again; a reading
    /// with lines stays current, and a photo with no preview, which is never read, keeps its row.
    @Test func theUnreadTextPreviewsMigrationReReadsEmptyReadingsOfStoredPreviews() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.unreadThumbnailsMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            for (path, preview, lines) in [
                ("empty.jpg", String?("empty.heic"), "[]"),
                ("sign.jpg", String?("sign.heic"), #"[{"text":"STOP","confidence":1}]"#),
                ("previewless.jpg", String?.none, "[]"),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key,
                        kind, thumbnail_path, preview_path)
                    VALUES (1, ?, ?, ?, ?, 'image', 'thumb.jpg', ?)
                    """,
                    arguments: [path, path, path, path, preview]
                )
                try db.execute(
                    sql: """
                    INSERT INTO search_text (library_root_id, relative_path, source, lines)
                    SELECT a.library_root_id, a.relative_path, IFNULL(\(SearchTextStorage.currentSource("a")), 'none'), ?
                    FROM media_asset AS a WHERE a.relative_path = ?
                    """,
                    arguments: [lines, path]
                )
            }
        }
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.unreadTextPreviewsMigrationIdentifier)
        let (readings, owed) = try await queue.read { db in
            try (
                String.fetchAll(db, sql: "SELECT relative_path FROM search_text ORDER BY relative_path"),
                String.fetchAll(
                    db, sql: "SELECT a.relative_path \(SearchTextStorage.owedFrom(rootCount: 1)) ORDER BY a.relative_path",
                    arguments: [1]
                )
            )
        }
        #expect(readings == ["previewless.jpg", "sign.jpg"])
        #expect(owed == ["empty.jpg"])
    }
}
