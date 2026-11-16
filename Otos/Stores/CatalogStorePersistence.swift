import CoreGraphics
import Foundation
import GRDB
import OSLog
import SQLite3
import Synchronization

/// Persistence guide
///
/// This extension is the SQLite edge of CatalogStore. It translates between the
/// durable relational schema and the Store's typed records, but it does
/// not own catalog behavior or publish UI state. Keeping SQL here makes the actor
/// methods in CatalogStore read in terms of catalog operations while preserving a
/// single persistence owner.
///
/// SQLite row IDs are deliberately confined to stored root/asset records. The
/// product identity of a library is its normalized LibraryRootPath, and the
/// product identity of an asset is that root path plus MediaRelativePath. A row ID
/// is only the compact foreign key used by SQLite; allowing it across this boundary
/// would give the same library two competing identities.
extension CatalogStore {
    /// Places the rebuildable catalog beside the rest of Otos's Application
    /// Support data. The caller supplies the bundle identifier so tests can use
    /// isolated locations without changing the production path convention.
    static func applicationDatabaseURL(bundleIdentifier: String) throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Catalog", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appending(path: "catalog.sqlite")
    }

    /// Thumbnail files live beside the catalog in Application Support. Created lazily by
    /// `ThumbnailStore.stage`/`promote`; computed here so the location convention has one owner.
    /// Where the thumbnails live. A path, computed without touching the disk: the
    /// thumbnail store creates the folder before it writes into it.
    static func applicationThumbnailDirectory(bundleIdentifier: String) -> URL {
        URL.applicationSupportDirectory
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// File-backed catalogs use a pool so Store-owned reads can eventually run
    /// concurrently with scan/enrichment writes. GRDB puts `DatabasePool` files in
    /// WAL mode by default; the explicit cache/mmap pragmas make the current
    /// architecture decision visible at the one storage-construction point.
    static func fileBackedDatabaseConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -32768")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
        }
        return configuration
    }

    /// The interactive readers' configuration (`CatalogStore.interactiveReader`): a second,
    /// read-only pool on the same file, opened after the writer has migrated it, with the
    /// main pool's cache settings. Two readers: a visible-tile read is a few milliseconds, and
    /// nothing else uses them.
    static func interactiveReaderConfiguration() -> Configuration {
        var configuration = fileBackedDatabaseConfiguration()
        configuration.readonly = true
        configuration.maximumReaderCount = 2
        return configuration
    }

    /// Known migration identifiers in registration order. Future-schema refusal
    /// compares applied identifiers against this set before any write.
    static var knownMigrationIdentifiers: [String] {
        migrator.migrations
    }

    /// One baseline migration creates the schema (`CatalogSchema`); later changes are
    /// additive migrations registered after it. Import history and other non-rebuildable
    /// overlay forbid destructive schema reset, and a catalog whose history this build
    /// does not know refuses to open (ADR 0010).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(CatalogSchema.baselineMigrationIdentifier) { db in
            for statement in CatalogSchema.baselineStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.fileIdentifierMigrationIdentifier) { db in
            for statement in CatalogSchema.fileIdentifierStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.previewPathMigrationIdentifier) { db in
            for statement in CatalogSchema.previewPathStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.editRecipeMigrationIdentifier) { db in
            for statement in CatalogSchema.editRecipeStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.heifOrientationMigrationIdentifier) { db in
            for statement in CatalogSchema.heifOrientationStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.extractionRevisionMigrationIdentifier) { db in
            for statement in CatalogSchema.extractionRevisionStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.familyRevisionMigrationIdentifier) { db in
            try CatalogSchema.migrateToFamilyRevisionsAndFileTypeNames(db)
        }
        migrator.registerMigration(CatalogSchema.captureInstantMigrationIdentifier) { db in
            try CatalogSchema.migrateToCaptureInstant(db)
        }
        migrator.registerMigration(CatalogSchema.contentIdentifierMigrationIdentifier) { db in
            for statement in CatalogSchema.contentIdentifierStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.trashPathMigrationIdentifier) { db in
            for statement in CatalogSchema.trashPathStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.duplicatesMigrationIdentifier) { db in
            for statement in CatalogSchema.duplicatesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.renderSignatureMigrationIdentifier) { db in
            for statement in CatalogSchema.renderSignatureStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.productStampsMigrationIdentifier) { db in
            for statement in CatalogSchema.productStampsStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.awaitingPresenceMigrationIdentifier) { db in
            for statement in CatalogSchema.awaitingPresenceStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.remoteBaseURLMigrationIdentifier) { db in
            for statement in CatalogSchema.remoteBaseURLStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.hiddenBySourceMigrationIdentifier) { db in
            for statement in CatalogSchema.hiddenBySourceStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.sourceProductsMigrationIdentifier) { db in
            for statement in CatalogSchema.sourceProductsStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.facesMigrationIdentifier) { db in
            for statement in CatalogSchema.facesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.peopleMigrationIdentifier) { db in
            for statement in CatalogSchema.peopleStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.sourceItemIDMigrationIdentifier) { db in
            for statement in CatalogSchema.sourceItemIDStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.searchEmbeddingsMigrationIdentifier) { db in
            for statement in CatalogSchema.searchEmbeddingsStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.searchTextMigrationIdentifier) { db in
            for statement in CatalogSchema.searchTextStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.captureLocalTimeMigrationIdentifier) { db in
            try CatalogSchema.migrateToCaptureLocalTime(db)
        }
        migrator.registerMigration(CatalogSchema.rawFacesMigrationIdentifier) { db in
            for statement in CatalogSchema.rawFacesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.decodeVerdictMigrationIdentifier) { db in
            for statement in CatalogSchema.decodeVerdictStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.autoTaggedPeopleMigrationIdentifier) { db in
            for statement in CatalogSchema.autoTaggedPeopleStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.placeNamesMigrationIdentifier) { db in
            for statement in CatalogSchema.placeNamesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.keyPhotoMigrationIdentifier) { db in
            for statement in CatalogSchema.keyPhotoStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.personAdmissionMigrationIdentifier) { db in
            for statement in CatalogSchema.personAdmissionStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.facesFromPreviewMigrationIdentifier) { db in
            for statement in CatalogSchema.facesFromPreviewStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.inThisPhotoMigrationIdentifier) { db in
            for statement in CatalogSchema.inThisPhotoStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.stackKeyMigrationIdentifier) { db in
            for statement in CatalogSchema.stackKeyStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.stackCandidateIndexMigrationIdentifier) { db in
            for statement in CatalogSchema.stackCandidateIndexStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.lastSyncedMigrationIdentifier) { db in
            for statement in CatalogSchema.lastSyncedStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.videoFacesMigrationIdentifier) { db in
            for statement in CatalogSchema.videoFacesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.pathKeysMigrationIdentifier) { db in
            try CatalogSchema.recomputePathKeys(db: db)
        }
        migrator.registerMigration(CatalogSchema.burstMigrationIdentifier) { db in
            for statement in CatalogSchema.burstStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.leftOutIndexMigrationIdentifier) { db in
            for statement in CatalogSchema.leftOutIndexStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.sourceProductsAbsentMigrationIdentifier) { db in
            for statement in CatalogSchema.sourceProductsAbsentStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.accountVideoFacesMigrationIdentifier) { db in
            for statement in CatalogSchema.accountVideoFacesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.resyncOwedMigrationIdentifier) { db in
            for statement in CatalogSchema.resyncOwedStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.continuousFrameMigrationIdentifier) { db in
            for statement in CatalogSchema.continuousFrameStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.placeCellMigrationIdentifier) { db in
            for statement in CatalogSchema.placeCellStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.undecodableIndexMigrationIdentifier) { db in
            for statement in CatalogSchema.undecodableIndexStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.placeNameLanguageMigrationIdentifier) { db in
            try CatalogSchema.convertPlaceNameLanguages(db: db)
        }
        migrator.registerMigration(CatalogSchema.cameraBurstsRemovedMigrationIdentifier) { db in
            for statement in CatalogSchema.cameraBurstsRemovedStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.facesReadSourceMigrationIdentifier) { db in
            for statement in CatalogSchema.facesReadSourceStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.canonicalBirthdayMigrationIdentifier) { db in
            try CatalogSchema.canonicalizeBirthdays(db)
        }
        migrator.registerMigration(CatalogSchema.keyPhotoIsUsersWordMigrationIdentifier) { db in
            for statement in CatalogSchema.keyPhotoIsUsersWordStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.facesOwedIndexesMigrationIdentifier) { db in
            for statement in CatalogSchema.facesOwedIndexesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.unreadThumbnailsMigrationIdentifier) { db in
            for statement in CatalogSchema.unreadThumbnailsStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.leftOutIndexDroppedMigrationIdentifier) { db in
            for statement in CatalogSchema.leftOutIndexDroppedStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.unreadTextPreviewsMigrationIdentifier) { db in
            for statement in CatalogSchema.unreadTextPreviewsStatements {
                try db.execute(sql: statement)
            }
            OtosLog.persistence.noticeOperation("catalog.migration.unreadTextPreviews", phase: "finish", fields: [
                "readings": "\(db.changesCount)",
            ])
        }
        migrator.registerMigration(CatalogSchema.facePersonPhotoIndexMigrationIdentifier) { db in
            for statement in CatalogSchema.facePersonPhotoIndexStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.windowReadIndexesMigrationIdentifier) { db in
            for statement in CatalogSchema.windowReadIndexesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.wholeSecondCaptureLocalMigrationIdentifier) { db in
            try CatalogSchema.migrateToWholeSecondCaptureLocal(db)
        }
        migrator.registerMigration(CatalogSchema.assignedFacePhotoIndexMigrationIdentifier) { db in
            for statement in CatalogSchema.assignedFacePhotoIndexStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.photoDescriptionMigrationIdentifier) { db in
            for statement in CatalogSchema.photoDescriptionStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.stackCandidatePathMigrationIdentifier) { db in
            for statement in CatalogSchema.stackCandidatePathStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.copiesMigrationIdentifier) { db in
            for statement in CatalogSchema.copiesStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.mirrorsMigrationIdentifier) { db in
            for statement in CatalogSchema.mirrorsStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.captureDayMigrationIdentifier) { db in
            for statement in CatalogSchema.captureDayStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.locationIndexMigrationIdentifier) { db in
            for statement in CatalogSchema.locationIndexStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.photoCopiesMigrationIdentifier) { db in
            for statement in CatalogSchema.photoCopiesStatements {
                try db.execute(sql: statement)
            }
        }
        return migrator
    }

    /// Compatibility check run before any migrator write. A schema whose history this
    /// build does not know refuses without erase, so non-rebuildable overlay is never
    /// destroyed.
    static func catalogSchemaCompatibility(_ db: Database) throws -> CatalogSchemaCompatibility {
        if try migrator.hasBeenSuperseded(db) {
            return .writtenByOtherOtos
        }
        let userTables = try Set(String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """
        ))
        if userTables.isEmpty {
            return .readyToMigrate
        }
        let applied = try migrator.appliedIdentifiers(db)
        let known = Set(migrator.migrations)
        if applied.isDisjoint(with: known) {
            return .unrecognized
        }
        return .readyToMigrate
    }

    /// Escalates `synchronous = FULL` for the duration of one write transaction so
    /// journal and settlement commits survive power loss, not only app crashes.
    /// The pool's default remains `NORMAL`; restore after the body returns.
    ///
    /// SQLite forbids changing the safety level inside a transaction, so the
    /// pragma is set on the writer connection before `BEGIN` and restored after
    /// commit/rollback.
    static func writeWithJournalDurability<T>(
        _ dbWriter: any DatabaseWriter,
        _ body: (Database) throws -> T
    ) throws -> T {
        do {
            return try writeWithFullSynchronous(dbWriter, body)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
            // Typed here, where the catalog's writes are, so an import stops on a full disk
            // rather than failing entry after entry (ADR 0027).
            throw CatalogStoreError.outOfSpace
        }
    }

    private static func writeWithFullSynchronous<T>(
        _ dbWriter: any DatabaseWriter,
        _ body: (Database) throws -> T
    ) throws -> T {
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            defer {
                do {
                    try db.execute(sql: "PRAGMA synchronous = NORMAL")
                } catch {
                    // The connection stays at FULL: slower, never less durable.
                    OtosLog.persistence.errorOperation("catalog.durability", phase: "restoreFailed", fields: [
                        "error": String(describing: error),
                    ])
                }
            }
            var result: T!
            try db.inTransaction {
                result = try body(db)
                return .commit
            }
            return result
        }
    }

    static func fetchRoots(_ db: Database) throws -> [StoredRoot] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, path, kind, device_identity, display_name, last_seen_at, sort_index,
                   case_sensitive_names, device_model, remote_base_url
            FROM library_root
            ORDER BY sort_index, path COLLATE NOCASE, path
            """
        ).map { row in
            let kindRaw: String = row["kind"]
            let lastSeenUnix: Double? = row["last_seen_at"]
            let remoteBaseURL: String? = row["remote_base_url"]
            // A kind this build does not know is a catalog it cannot read, never a library:
            // reading it as one would scan and serve another kind's staging folder.
            guard let kind = LibraryRootKind(rawValue: kindRaw) else {
                throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "unknown library_root.kind \(kindRaw)")
            }
            return StoredRoot(
                id: row["id"],
                path: LibraryRootPath(rawValue: row["path"]),
                kind: kind,
                deviceIdentity: row["device_identity"],
                displayName: row["display_name"],
                lastSeenAt: lastSeenUnix.map(Date.init(timeIntervalSince1970:)),
                sortIndex: row["sort_index"],
                capabilities: VolumeNamespaceCapabilities(storedCaseSensitiveColumn: row["case_sensitive_names"]),
                deviceModel: row["device_model"],
                remoteBaseURL: remoteBaseURL.flatMap(URL.init(string:))
            )
        }
    }

    /// How the root `rootRowID`'s volume compares names (ARC-056), as stored with the root:
    /// the one read every write that keys a path in a transaction of its own makes.
    static func storedCapabilities(rootRowID: Int64, db: Database) throws -> VolumeNamespaceCapabilities {
        try VolumeNamespaceCapabilities(storedCaseSensitiveColumn: Int?.fetchOne(
            db,
            sql: "SELECT case_sensitive_names FROM library_root WHERE id = ?",
            arguments: [rootRowID]
        ) ?? nil)
    }

    /// One past the highest `sort_index` currently in use, so a newly added root
    /// (library or removable) appends after everything else rather than colliding.
    /// Global rather than scoped to `kind` — the column is only *meaningful* for
    /// ordering library-kind roots (`import-bar.md`), but
    /// every row needs some value, and a single counter is simpler than two.
    static func nextLibraryRootSortIndex(db: Database) throws -> Int64 {
        try (Int64.fetchOne(db, sql: "SELECT MAX(sort_index) FROM library_root") ?? -1) + 1
    }

    static func insertLibraryRoot(
        path: LibraryRootPath,
        kind: LibraryRootKind = .library,
        deviceIdentity: DeviceIdentity? = nil,
        displayName: String? = nil,
        lastSeenAt: Date? = nil,
        sortIndex: Int64? = nil,
        capabilities: VolumeNamespaceCapabilities,
        deviceModel: String? = nil,
        remoteBaseURL: URL? = nil,
        db: Database
    ) throws -> StoredRoot {
        let resolvedSortIndex = try sortIndex ?? nextLibraryRootSortIndex(db: db)
        try db.execute(
            sql: """
            INSERT INTO library_root (
                path, kind, device_identity, display_name, last_seen_at, sort_index,
                case_sensitive_names, device_model, remote_base_url
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                path.rawValue,
                kind.rawValue,
                deviceIdentity,
                displayName,
                lastSeenAt?.timeIntervalSince1970,
                resolvedSortIndex,
                capabilities.storedCaseSensitiveColumn,
                deviceModel,
                remoteBaseURL?.absoluteString,
            ]
        )
        return StoredRoot(
            id: db.lastInsertedRowID,
            path: path,
            kind: kind,
            deviceIdentity: deviceIdentity,
            displayName: displayName,
            lastSeenAt: lastSeenAt,
            sortIndex: resolvedSortIndex,
            capabilities: capabilities,
            deviceModel: deviceModel,
            remoteBaseURL: remoteBaseURL
        )
    }

    /// Writes new `sort_index` values for a reordered set of library roots. The
    /// caller (`CatalogStore.moveLibrary(_:_:)`) computes the reordered array;
    /// this only persists it. One statement per row rather than a single UPDATE
    /// with a CASE expression — the set is sidebar-sized (tens, not thousands) and
    /// this reads far more directly than a generated CASE list.
    static func writeLibraryRootSortIndexes(_ pathsInOrder: [LibraryRootPath], db: Database) throws {
        for (index, path) in pathsInOrder.enumerated() {
            try db.execute(
                sql: "UPDATE library_root SET sort_index = ? WHERE path = ?",
                arguments: [index, path.rawValue]
            )
        }
    }

    static func updateLibraryRootPath(
        rootRowID: Int64,
        path: LibraryRootPath,
        db: Database
    ) throws -> [ThumbnailPathMigration] {
        try db.execute(
            sql: "UPDATE library_root SET path = ? WHERE id = ?",
            arguments: [path.rawValue, rootRowID]
        )
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, thumbnail_path, preview_path, face_frames_path
            FROM media_asset WHERE library_root_id = ?
            """,
            arguments: [rootRowID]
        )
        var thumbnailMigrations: [ThumbnailPathMigration] = []
        for row in rows {
            let relativePath: String = row["relative_path"]
            let relativePathValue = MediaRelativePath(rawValue: relativePath)
            let newID = MediaAssetID(libraryRootPath: path, relativePath: relativePathValue)
            // Each derived image the row has takes the new identity's name.
            let images: [(old: String?, new: String)] = [
                (row["thumbnail_path"], ThumbnailStore.relativeName(for: newID)),
                (row["preview_path"], ThumbnailStore.previewRelativeName(for: newID)),
                (row["face_frames_path"], ThumbnailStore.faceFramesRelativeName(for: newID)),
            ]
            let renamed = images.map { image in image.old.map { _ in image.new } }
            try db.execute(
                sql: """
                UPDATE media_asset
                SET sort_key = ?, thumbnail_path = ?, preview_path = ?, face_frames_path = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [
                    MediaSortKey.make(libraryRootPath: path, relativePath: relativePathValue),
                    renamed[0],
                    renamed[1],
                    renamed[2],
                    rootRowID,
                    relativePath,
                ]
            )
            for image in images {
                if let old = image.old, old != image.new {
                    thumbnailMigrations.append(ThumbnailPathMigration(oldRelativeName: old, newRelativeName: image.new))
                }
            }
        }
        return thumbnailMigrations
    }

    /// Points every import and card-erase journal row that names `oldPath` as its source at
    /// `newPath`: a moved staging root's interrupted work recovers against where the root now
    /// is (`MediaImportRecovery`).
    static func moveJournaledSourceRoot(from oldPath: LibraryRootPath, to newPath: LibraryRootPath, db: Database) throws {
        for table in ["active_file_operation", "active_source_erase"] {
            try db.execute(
                sql: "UPDATE \(table) SET source_root_path = ? WHERE source_root_path = ?",
                arguments: [newPath.rawValue, oldPath.rawValue]
            )
        }
    }

    static func updateLibraryRootLastSeen(rootRowID: Int64, lastSeenAt: Date, db: Database) throws {
        try db.execute(
            sql: "UPDATE library_root SET last_seen_at = ? WHERE id = ?",
            arguments: [lastSeenAt.timeIntervalSince1970, rootRowID]
        )
    }

    static func updateLibraryRootSourceFacts(
        rootRowID: Int64,
        path: LibraryRootPath,
        displayName: String?,
        lastSeenAt: Date?,
        capabilities: VolumeNamespaceCapabilities,
        deviceModel: String? = nil,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE library_root
            SET path = ?, display_name = ?, last_seen_at = ?,
                case_sensitive_names = ?, device_model = ?
            WHERE id = ?
            """,
            arguments: [
                path.rawValue,
                displayName,
                lastSeenAt?.timeIntervalSince1970,
                capabilities.storedCaseSensitiveColumn,
                deviceModel,
                rootRowID,
            ]
        )
    }

    static func deleteLibraryRoot(rootRowID: Int64, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM library_root WHERE id = ?",
            arguments: [rootRowID]
        )
    }

    @discardableResult
    static func deleteAssetRow(
        rootRowID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws -> Bool {
        try db.execute(
            sql: "DELETE FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
            arguments: [rootRowID, relativePath.rawValue]
        )
        return db.changesCount > 0
    }

    /// Removes a path proven gone from its root — its media or companion row — and
    /// re-pairs the companions left in its directory. The one purge for a single gone
    /// path, shared by filesystem-event reconciliation and card erase. Returns whether
    /// any row changed.
    static func purgeGonePath(
        relativePath: MediaRelativePath,
        rootRowID: Int64,
        capabilities: VolumeNamespaceCapabilities,
        db: Database
    ) throws -> Bool {
        var changed = false
        if try deleteAssetRow(rootRowID: rootRowID, relativePath: relativePath, db: db) {
            changed = true
        }
        if try deleteCompanionRow(rootRowID: rootRowID, relativePath: relativePath, db: db) {
            changed = true
        }
        if try repairCompanionsInDirectory(
            of: relativePath,
            libraryRootID: rootRowID,
            capabilities: capabilities,
            db: db
        ) {
            changed = true
        }
        return changed
    }

    /// Marks every row of a source as not yet seen by its new attachment, or clears that
    /// mark (ADR 0013). Returns how many rows changed.
    static func setAwaitingPresence(_ awaiting: Bool, rootRowID: Int64, db: Database) throws -> Int {
        if awaiting {
            try db.execute(
                sql: "UPDATE media_asset SET awaiting_presence = 1 WHERE library_root_id = ? AND awaiting_presence = 0",
                arguments: [rootRowID]
            )
        } else {
            try db.execute(
                sql: "UPDATE media_asset SET awaiting_presence = 0 WHERE library_root_id = ? AND awaiting_presence <> 0",
                arguments: [rootRowID]
            )
        }
        return db.changesCount
    }

    /// No source is attached while the catalog loads, so no row awaits an attachment.
    /// Clears what a process that ended mid-read left set.
    static func clearAllAwaitingPresence(db: Database) throws -> Int {
        try db.execute(sql: "UPDATE media_asset SET awaiting_presence = 0 WHERE awaiting_presence <> 0")
        return db.changesCount
    }

    struct CatalogedFileDeletionTarget {
        /// The thumbnail, preview and face frames files to delete with the row.
        let derivedImagePaths: [String]
        /// Where the system Trash holds the row's file, when the queue moved it there.
        let trashPath: String?
    }

    /// The derived images a row names (`thumbnail_path`, `preview_path`, `face_frames_path`),
    /// the files deleted with it.
    static func derivedImagePaths(of row: Row) -> [String] {
        [row["thumbnail_path"], row["preview_path"], row["face_frames_path"]].compactMap { (path: String?) in path }
    }

    /// Whether a row whose path is missing must be kept because its file is in the system
    /// Trash: the queue recorded where the Trash put it, and that file is still there. Only
    /// an `ENOENT` proves it gone; any other answer is not a fact, so the row is kept and
    /// the next scan asks again (ADR 0008, ADR 0032 rule 4).
    static func isHeldInTrash(trashPath: String?) -> Bool {
        guard let trashPath else {
            return false
        }
        var info = stat()
        if lstat(trashPath, &info) == 0 {
            return true
        }
        return errno != ENOENT
    }

    static func catalogedFileDeletionTarget(
        relativePath: MediaRelativePath,
        rootRowID: Int64,
        db: Database
    ) throws -> CatalogedFileDeletionTarget? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT thumbnail_path, preview_path, face_frames_path, trash_path
            FROM media_asset
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootRowID, relativePath.rawValue]
        ) else {
            return nil
        }
        return CatalogedFileDeletionTarget(
            derivedImagePaths: derivedImagePaths(of: row),
            trashPath: row["trash_path"]
        )
    }

    /// A row that shows its source's own thumbnail and preview (ADR 0046 §7): never
    /// edited, so no rendering of an edit is owed, and not yet rendered by Otos. An edited
    /// still always shows Otos's rendering, so the source's images are neither fetched for
    /// it nor written to it. The one predicate both the fetch and its write test, so a row
    /// is offered exactly when its products would be applied.
    static let showsSourceProductsSQL = "(edit_revision = 0 AND rendered_source_size IS NULL)"

    static func enrichmentResultMatchesCurrentRow(
        _ result: EnrichmentResult,
        libraryRootID: Int64,
        db: Database
    ) throws -> Bool {
        let sourceMTimeSeconds = result.sourceMTimeSeconds ?? -1
        // Only a thumbnail is drawn with the edit; metadata and a digest are the file's
        // whatever the photo's edit.
        let editCondition: String
        var editArguments: StatementArguments = []
        if result.rendering?.origin == .source {
            editCondition = showsSourceProductsSQL
        } else if result.rendering != nil || result.provisionalThumbnail != nil {
            editCondition = "edit_revision = ?"
            editArguments = [result.editRevision]
        } else {
            editCondition = "1"
        }
        return try Row.fetchOne(
            db,
            sql: """
            SELECT 1
            FROM media_asset
            WHERE library_root_id = ?
                AND relative_path = ?
                AND COALESCE(byte_size, -1) = ?
                AND (
                    (content_modified_at_unix IS NULL AND ? = -1)
                    OR (content_modified_at_unix >= ? AND content_modified_at_unix < ?)
                )
                AND \(editCondition)
            """,
            arguments: [
                libraryRootID,
                result.id.relativePath.rawValue,
                result.sourceSize ?? -1,
                sourceMTimeSeconds,
                sourceMTimeSeconds,
                sourceMTimeSeconds + 1,
            ] + editArguments
        ) != nil
    }

    /// Writes each product the result carries with its own stamp (ADR 0009), and leaves
    /// the row's other products as they are: a card's metadata pass does not touch its
    /// rendering or digest, and a rendering-and-digest pass does not re-write its metadata.
    /// A provisional thumbnail replaces the shown thumbnail without stamping a rendering.
    static func writeEnrichmentOverlay(_ result: EnrichmentResult, libraryRootID: Int64, db: Database) throws {
        let row = (rootID: libraryRootID, relativePath: result.id.relativePath)
        if let rendering = result.rendering, rendering.origin == .source {
            try writeSourceProducts(
                thumbnailPath: rendering.thumbnailPath,
                previewPath: rendering.previewPath,
                stamp: (result.sourceSize, result.sourceMTimeSeconds),
                row: row,
                db: db
            )
        } else if let rendering = result.rendering {
            try writeRendering(
                thumbnailPath: rendering.thumbnailPath,
                previewPath: rendering.previewPath,
                renderedRevision: result.editRevision,
                stamp: (result.sourceSize, result.sourceMTimeSeconds),
                row: row,
                db: db
            )
        } else if let provisional = result.provisionalThumbnail {
            try writeProvisionalThumbnail(provisional.finalRelativePath, row: row, db: db)
        }
        if let contentHash = result.contentHash {
            try db.execute(
                sql: """
                UPDATE media_asset SET
                    content_sha1 = ?,
                    content_hash_source_size = ?,
                    content_hash_source_mtime = ?
                WHERE library_root_id = ?
                    AND relative_path = ?
                """,
                arguments: [
                    contentHash.data,
                    result.sourceSize,
                    result.sourceMTimeSeconds,
                    libraryRootID,
                    result.id.relativePath.rawValue,
                ]
            )
            _ = try MirrorGateway.pairMirroredAssets(
                libraryRootID: libraryRootID, relativePath: result.id.relativePath.rawValue, db: db
            )
        }
        if let metadata = result.metadata {
            try writeMetadata(metadata, stamp: (result.sourceSize, result.sourceMTimeSeconds), row: row, db: db)
        }
        if let verdict = result.decodeVerdict {
            try db.execute(
                sql: "UPDATE media_asset SET undecodable_by = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [verdict.undecodableBy, row.rootID, row.relativePath.rawValue]
            )
        }
        if let videoFaces = result.videoFaces {
            try writeFaces(
                videoFaces.faces.map { ReadFace(face: $0.face, frameIndex: $0.frameIndex) },
                analysisRevision: videoFaces.analysisRevision,
                stamp: (result.sourceSize, result.sourceMTimeSeconds),
                matchBy: .likeness,
                row: row,
                db: db
            )
            try db.execute(
                sql: "UPDATE media_asset SET face_frames_path = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [videoFaces.frames?.finalRelativePath, row.rootID, row.relativePath.rawValue]
            )
        }
    }

    /// Hands every file that a decoder other than its kind's current one could not decode back
    /// to enrichment: a still's rendering stamp is cleared, so it is rendered again (ENR-029),
    /// and a video's faces stamp, so its faces are read again (ENR-031), each with its
    /// verdict, which the new read records afresh. Each kind is judged by its own decoder, so
    /// a still's verdict never releases a video, nor a video's a still. Returns how many
    /// stills and videos were released.
    static func releaseUndecodedByAnotherDecoder(
        still stillDecoder: String,
        video videoDecoder: String,
        db: Database
    ) throws -> (stills: Int, videos: Int) {
        try db.execute(sql: releaseUndecodedStillsSQL, arguments: [stillDecoder])
        let stills = db.changesCount
        try db.execute(sql: releaseUndecodedVideosSQL, arguments: [videoDecoder])
        return (stills, db.changesCount)
    }

    /// `releaseUndecodedByAnotherDecoder`'s stills, sought through `idx_media_asset_undecodable`.
    static let releaseUndecodedStillsSQL = """
    UPDATE media_asset SET
        rendered_source_size = NULL, rendered_source_mtime = NULL,
        undecodable_by = NULL
    WHERE undecodable_by IS NOT NULL AND undecodable_by <> ? AND best_kind IS NOT 'video'
    """

    /// `releaseUndecodedByAnotherDecoder`'s videos, sought through `idx_media_asset_undecodable`.
    static let releaseUndecodedVideosSQL = """
    UPDATE media_asset SET
        faces_source_size = NULL, faces_source_mtime = NULL,
        undecodable_by = NULL
    WHERE undecodable_by IS NOT NULL AND undecodable_by <> ? AND best_kind = 'video'
    """

    /// A still's faces (ADR 0047): the reading replaces the faces the asset held, and its
    /// stamp names the source its preview was made from, so a still with no face in it is
    /// not read again until a preview of other bytes arrives.
    ///
    /// What the user said about a face is overlay, and outlives a new reading of the same
    /// source (an analysis revision, a reading through an edit that hides part of the photo):
    /// each act — a person they gave, a removed name, a key photo, rejections, "not a face" —
    /// moves to the new face that matches it (`FaceCarryOver`), and a face the user said
    /// something about that the new reading does not find is kept as it was read. A seed
    /// moves to the face that matches it too, so a person Otos found keeps the faces it was
    /// found from; Otos's guesses do not carry, since assignment remakes them. The source the
    /// faces were read from is the asset's own record (`faces_read_source_*`), never the faces
    /// stamp, which a migration clears to owe a re-read. A reading of other bytes than that is
    /// a changed file, read afresh: its faces replace every face, and only a person given, a
    /// removed name, a key photo, rejections and a seed carry, by match.
    ///
    /// A still's faces match by the overlap of their boxes. A video's faces match by likeness
    /// (`FaceCarryOver.matches(previous:new:)` over embeddings), since each box belongs to the
    /// frame its face was read in, and a re-read may keep a person from another frame. A
    /// video's face carries the image of its stored face frames it was read in; a face kept as
    /// it was read has none, since the reading replaced those frames.
    ///
    /// A stored face row no reading writes (an assignment no case holds, an embedding not of
    /// unit length) is dropped and logged: the reading replaces it.
    static func writeFaces(_ faces: EnrichedFaces, stamp: ProductStamp, row: ProductRow, db: Database) throws {
        try writeFaces(
            faces.faces.map { ReadFace(face: $0, frameIndex: nil) },
            analysisRevision: faces.analysisRevision, stamp: stamp, matchBy: .box, row: row, db: db
        )
    }

    /// One face of a reading, and the image of a video's face frames it was read in.
    struct ReadFace {
        let face: DetectedFace
        let frameIndex: Int?
    }

    /// A face row of the reading being replaced, as it was stored.
    private struct StoredFace {
        let index: Int
        let box: CGRect
        let landmarks: Data
        let quality: Double
        let analysisRevision: Int
        let embedding: FaceEmbedding
        let assignment: FaceAssignment
        let isKeyPhoto: Bool
        let isNotFace: Bool

        /// Nil for a row no reading writes.
        init?(_ row: Row) {
            guard let embedding = FaceStorage.embedding(from: row["embedding"]),
                  let assignment = try? FaceAssignmentColumn.assignment(column: row["assignment"], person: row["person_id"])
            else {
                return nil
            }
            index = row["face_index"]
            box = CGRect(x: row["box_x"] as Double, y: row["box_y"] as Double, width: row["box_width"] as Double, height: row["box_height"] as Double)
            landmarks = row["landmarks"]
            quality = row["quality"]
            analysisRevision = row["analysis_revision"]
            self.embedding = embedding
            self.assignment = assignment
            isKeyPhoto = (row["is_key_photo"] as Int) != 0
            isNotFace = (row["is_not_face"] as Int) != 0
        }
    }

    private static func writeFaces(
        _ faces: [ReadFace],
        analysisRevision: Int,
        stamp: ProductStamp,
        matchBy: FaceCarryOver.Match,
        row: ProductRow,
        db: Database
    ) throws {
        let key: StatementArguments = [row.rootID, row.relativePath.rawValue]
        let readSource = try Row.fetchOne(
            db,
            sql: "SELECT faces_read_source_size, faces_read_source_mtime FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
            arguments: key
        )
        let readSize: Int64? = readSource?["faces_read_source_size"]
        let readMTime: Int? = readSource?["faces_read_source_mtime"]
        let sameSource = readSize != nil && readSize == stamp.size && readMTime == stamp.mtimeSeconds
        var previous: [StoredFace] = []
        for face in try Row.fetchAll(
            db,
            sql: """
            SELECT face_index, box_x, box_y, box_width, box_height, landmarks, quality, analysis_revision,
                   embedding, person_id, assignment, is_key_photo, is_not_face
            FROM face WHERE library_root_id = ? AND relative_path = ? ORDER BY face_index
            """,
            arguments: key
        ) {
            if let stored = StoredFace(face) {
                previous.append(stored)
            } else {
                OtosLog.catalog.errorOperation("faces.write", phase: "malformedRowDropped", fields: [
                    "relativePath": row.relativePath.rawValue, "faceIndex": "\(face["face_index"] as Int)",
                ])
            }
        }
        var rejections: [Int: [Int64]] = [:]
        for rejection in try Row.fetchAll(
            db,
            sql: "SELECT face_index, person_id FROM face_rejection WHERE library_root_id = ? AND relative_path = ?",
            arguments: key
        ) {
            rejections[rejection["face_index"], default: []].append(rejection["person_id"])
        }
        let carried = switch matchBy {
        case .box: FaceCarryOver.matches(previous: previous.map(\.box), new: faces.map(\.face.box))
        case .likeness: FaceCarryOver.matches(previous: previous.map(\.embedding), new: faces.map(\.face.embedding))
        }
        let unmatched = Set(previous.indices).subtracting(carried.values)
        let keptAsRead = sameSource ? unmatched.sorted().filter { index in
            let face = previous[index]
            return face.assignment.isUserWord || face.isNotFace || rejections[face.index] != nil
        } : []
        try db.execute(sql: "DELETE FROM face WHERE library_root_id = ? AND relative_path = ?", arguments: key)
        for (index, read) in faces.enumerated() {
            let face = read.face
            let prior = carried[index].map { previous[$0] }
            let kept: FaceAssignment = prior.map { $0.assignment.isGuessable ? .open : $0.assignment } ?? .open
            try insertFace(FaceRowValues(
                index: index,
                box: face.box,
                landmarks: FaceStorage.landmarksData(face.landmarks),
                quality: Double(face.quality),
                analysisRevision: analysisRevision,
                embedding: FaceStorage.embeddingData(face.embedding),
                frameIndex: read.frameIndex,
                assignment: kept,
                isKeyPhoto: kept.person != nil && prior?.isKeyPhoto == true,
                isNotFace: sameSource && prior?.isNotFace == true,
                rejections: prior.flatMap { rejections[$0.index] } ?? []
            ), row: row, db: db)
        }
        for (offset, priorIndex) in keptAsRead.enumerated() {
            let prior = previous[priorIndex]
            try insertFace(FaceRowValues(
                index: faces.count + offset,
                box: prior.box,
                landmarks: prior.landmarks,
                quality: prior.quality,
                analysisRevision: prior.analysisRevision,
                embedding: FaceStorage.embeddingData(prior.embedding),
                frameIndex: nil,
                assignment: prior.assignment.isGuessable ? .open : prior.assignment,
                isKeyPhoto: prior.isKeyPhoto,
                isNotFace: prior.isNotFace,
                rejections: rejections[prior.index] ?? []
            ), row: row, db: db)
        }
        try db.execute(
            sql: """
            UPDATE media_asset SET faces_source_size = ?, faces_source_mtime = ?,
                faces_read_source_size = ?, faces_read_source_mtime = ?
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [stamp.size, stamp.mtimeSeconds, stamp.size, stamp.mtimeSeconds, row.rootID, row.relativePath.rawValue]
        )
    }

    /// One face row as `writeFaces` writes it, with the user's acts it carries.
    private struct FaceRowValues {
        let index: Int
        let box: CGRect
        let landmarks: Data
        let quality: Double
        let analysisRevision: Int
        let embedding: Data
        /// The image of a video's face frames the face was read in; nil for a still.
        let frameIndex: Int?
        let assignment: FaceAssignment
        let isKeyPhoto: Bool
        let isNotFace: Bool
        let rejections: [Int64]
    }

    private static func insertFace(_ face: FaceRowValues, row: ProductRow, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO face (
                library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                landmarks, quality, analysis_revision, embedding, frame_index, person_id, assignment, is_key_photo,
                is_not_face
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                row.rootID, row.relativePath.rawValue, face.index,
                Double(face.box.minX), Double(face.box.minY), Double(face.box.width), Double(face.box.height),
                face.landmarks, face.quality, face.analysisRevision, face.embedding, face.frameIndex,
                face.assignment.person?.rawValue, FaceAssignmentColumn(face.assignment).rawValue,
                face.isKeyPhoto ? 1 : 0, face.isNotFace ? 1 : 0,
            ]
        )
        for person in face.rejections {
            try db.execute(
                sql: """
                INSERT INTO face_rejection (library_root_id, relative_path, face_index, person_id)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [row.rootID, row.relativePath.rawValue, face.index, person]
            )
        }
    }

    /// The row a product write targets.
    typealias ProductRow = (rootID: Int64, relativePath: MediaRelativePath)
    /// The `(size, mtime-seconds)` a product was made from, which its stamp records.
    typealias ProductStamp = (size: Int64?, mtimeSeconds: Int?)

    /// A rendering — thumbnail and preview, made together — with its stamp and the edit
    /// revision it shows (ADR 0009, ADR 0035, ADR 0036).
    private static func writeRendering(
        thumbnailPath: String?,
        previewPath: String?,
        renderedRevision: Int64,
        stamp: ProductStamp,
        row: ProductRow,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE media_asset SET
                thumbnail_path = ?,
                preview_path = ?,
                rendered_revision = ?,
                rendered_source_size = ?,
                rendered_source_mtime = ?
            WHERE library_root_id = ?
                AND relative_path = ?
            """,
            arguments: [
                thumbnailPath, previewPath, renderedRevision, stamp.size, stamp.mtimeSeconds,
                row.rootID, row.relativePath.rawValue,
            ]
        )
    }

    /// A source's own thumbnail and preview (ADR 0035, ADR 0046 §7): they replace the shown
    /// images and are stamped as source products, never as the rendering, which stays
    /// owed until Otos renders the original.
    private static func writeSourceProducts(
        thumbnailPath: String?,
        previewPath: String?,
        stamp: ProductStamp,
        row: ProductRow,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE media_asset SET
                thumbnail_path = ?,
                preview_path = ?,
                source_products_size = ?,
                source_products_mtime = ?
            WHERE library_root_id = ?
                AND relative_path = ?
            """,
            arguments: [
                thumbnailPath, previewPath, stamp.size, stamp.mtimeSeconds,
                row.rootID, row.relativePath.rawValue,
            ]
        )
    }

    /// A thumbnail that is not a rendering: it replaces the shown thumbnail and stamps
    /// nothing, so the rendering stays owed.
    private static func writeProvisionalThumbnail(_ thumbnailPath: String?, row: ProductRow, db: Database) throws {
        try db.execute(
            sql: "UPDATE media_asset SET thumbnail_path = ? WHERE library_root_id = ? AND relative_path = ?",
            arguments: [thumbnailPath, row.rootID, row.relativePath.rawValue]
        )
    }

    /// Metadata with its stamp, and every column derived from it.
    private static func writeMetadata(_ metadata: EnrichedMetadata, stamp: ProductStamp, row: ProductRow, db: Database) throws {
        try db.execute(
            sql: """
            UPDATE media_asset SET metadata_source_size = ?, metadata_source_mtime = ?
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [stamp.size, stamp.mtimeSeconds, row.rootID, row.relativePath.rawValue]
        )
        try writeMetadataProjection(
            metadata.metadata,
            enrichedKind: metadata.kind,
            enrichedFormat: metadata.format,
            sourceMTimeSeconds: stamp.mtimeSeconds,
            libraryRootID: row.rootID,
            relativePath: row.relativePath,
            db: db
        )
    }

    /// Writes a metadata record and every column derived from it: the stored record, the
    /// `ts_*` instants, the kind and format, the duration, the capture wall and the content
    /// identifier a Live Photo pairs on (ADR 0041). Enrichment
    /// and a metadata refresh (ADR 0039) both write through here, so a re-read row derives
    /// exactly what a fresh enrichment would.
    ///
    /// Both date projections derive from the one stored truth, here at the write. A video
    /// with no local-authority embedded timestamp falls back to its filesystem mtime —
    /// which for video is when recording *stopped*, so the name is wrong by the clip's own
    /// length. Where the duration is known, derive the capture instant instead and store it
    /// as the wall, marked with its own precision so it stays self-identifying. Deriving
    /// here rather than at naming time keeps `capture_wall_compact` the single stored truth.
    static func writeMetadataProjection(
        _ metadata: AssetMetadata,
        enrichedKind: MediaKind?,
        enrichedFormat: MediaFormatToken?,
        sourceMTimeSeconds: Int?,
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws {
        let embeddedWall = CaptureWallClock.select(from: metadata.timestamps)
        let captureWall = embeddedWall ?? (
            enrichedKind == .video
                ? CaptureWallClock.derivedFromDuration(
                    modifiedAt: sourceMTimeSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    durationSeconds: metadata.durationSeconds
                )
                : nil
        )
        // The assumed offset follows the absolute time the row is now placed by, and is
        // kept when that time is unchanged (`CaptureLocalTime.assumedUTCOffset`).
        let captureInstant = metadata.captureInstant?.timeIntervalSince1970
        let dates = try Row.fetchOne(
            db,
            sql: """
            SELECT \(CatalogSchema.absoluteCaptureSQL) AS absolute, created_at_unix, content_modified_at_unix,
                   assumed_utc_offset_seconds
            FROM media_asset WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [libraryRootID, relativePath.rawValue]
        )
        let fileDate: Double? = dates.flatMap { row in
            (row["created_at_unix"] as Double?) ?? (row["content_modified_at_unix"] as Double?)
        }
        let assumedOffset = CaptureLocalTime.assumedUTCOffset(
            for: captureInstant ?? fileDate,
            previousAbsolute: dates?["absolute"],
            previousOffset: dates?["assumed_utc_offset_seconds"]
        )
        try db.execute(
            sql: """
            UPDATE media_asset SET
                assumed_utc_offset_seconds = ?,
                capture_instant_unix = ?,
                enriched_kind = ?,
                enriched_format = ?,
                duration_seconds = ?,
                capture_wall_compact = ?,
                capture_wall_precision = ?,
                content_identifier = ?,
                burst_identifier = ?
            WHERE library_root_id = ?
                AND relative_path = ?
            """,
            arguments: [
                assumedOffset,
                captureInstant,
                enrichedKind?.rawValue,
                enrichedFormat?.rawValue,
                metadata.durationSeconds,
                captureWall?.compact,
                captureWall?.precision,
                metadata.contentIdentifier,
                metadata.burstIdentifier,
                libraryRootID,
                relativePath.rawValue,
            ]
        )
        try upsertAssetMetadata(metadata, libraryRootID: libraryRootID, relativePath: relativePath, db: db)
    }

    /// Writes each product the copy `landed` settled with gets, stamped with the
    /// destination's own file facts (ADR 0009): its metadata, reused or read by the import,
    /// and its rendering, reused, made by the import, or the source's provisional thumbnail
    /// with no stamp. A product it does not get stays owed, for enrichment.
    static func writeLandedProducts(_ landed: LandedImport, db: Database) throws {
        let row = (rootID: landed.destinationRootID, relativePath: landed.operation.destinationRelativePath)
        let stamp: ProductStamp = (landed.byteSize, Int(landed.contentModifiedAt.timeIntervalSince1970.rounded(.down)))
        if let rendering = landed.rendering {
            if rendering.stamped {
                try writeRendering(
                    thumbnailPath: rendering.thumbnailPath,
                    previewPath: rendering.previewPath,
                    renderedRevision: rendering.renderedRevision,
                    stamp: stamp,
                    row: row,
                    db: db
                )
            } else {
                try writeProvisionalThumbnail(rendering.thumbnailPath, row: row, db: db)
            }
        }
        // Derived for the destination exactly as enrichment of the destination file would
        // derive it.
        if let metadata = landed.metadata {
            try writeMetadata(metadata, stamp: stamp, row: row, db: db)
        }
    }

    static func updateThumbnailPath(
        _ thumbnailPath: String,
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        onlyWhenMissing: Bool,
        db: Database
    ) throws {
        let missingPredicate = onlyWhenMissing ? "AND thumbnail_path IS NULL" : ""
        try db.execute(
            sql: """
            UPDATE media_asset
            SET thumbnail_path = ?
            WHERE library_root_id = ?
              AND relative_path = ?
              \(missingPredicate)
            """,
            arguments: [thumbnailPath, libraryRootID, relativePath.rawValue]
        )
    }

    /// The stored form of an asset's metadata. Encoding failing is an error, never a
    /// silently missing record.
    static func encodeMetadataExtraJSON(_ metadata: AssetMetadata) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(decoding: encoder.encode(metadata), as: UTF8.self)
    }

    /// Reads a stored metadata record back. A record that does not decode is an error,
    /// not an asset without metadata: each caller decides what that means for it.
    static func decodeMetadataExtraJSON(_ json: String) throws -> AssetMetadata {
        try JSONDecoder().decode(AssetMetadata.self, from: Data(json.utf8))
    }

    /// A cataloged media row as a scan's deletion pass sees it.
    struct ExistingAssetRow {
        let relativePath: MediaRelativePath
        /// The thumbnail, preview and face frames files to delete with the row.
        let derivedImagePaths: [String]
        let hadEnrichment: Bool
        /// Where the system Trash holds the row's file, when the queue moved it there.
        let trashPath: String?
    }

    static func fetchExistingAssetRows(
        libraryRootID: Int64,
        underSubtree: MediaRelativePath? = nil,
        db: Database
    ) throws -> [ExistingAssetRow] {
        let rows: [Row] = if let underSubtree {
            // Component-safe: `a/b` matches itself and `a/b/...`, never `a/b2`.
            // Cached: a listing reads one subtree per folder it completes.
            try Row.fetchAll(
                db.cachedStatement(sql: """
                SELECT relative_path, thumbnail_path, preview_path, face_frames_path, metadata_source_size,
                    metadata_source_mtime, trash_path
                FROM media_asset
                WHERE library_root_id = ?
                  AND \(Self.subtreeSQL)
                """),
                arguments: [libraryRootID] + Self.subtreeArguments(underSubtree)
            )
        } else {
            try Row.fetchAll(
                db,
                sql: """
                SELECT relative_path, thumbnail_path, preview_path, face_frames_path, metadata_source_size,
                    metadata_source_mtime, trash_path
                FROM media_asset
                WHERE library_root_id = ?
                """,
                arguments: [libraryRootID]
            )
        }
        return rows.map { row in
            ExistingAssetRow(
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                derivedImagePaths: derivedImagePaths(of: row),
                hadEnrichment: (row["metadata_source_size"] as Int64?) != nil
                    || (row["metadata_source_mtime"] as Int64?) != nil,
                trashPath: row["trash_path"]
            )
        }
    }

    static func fetchExistingCompanionPaths(
        libraryRootID: Int64,
        underSubtree: MediaRelativePath? = nil,
        db: Database
    ) throws -> Set<MediaRelativePath> {
        let paths: [String] = if let underSubtree {
            try String.fetchAll(
                db,
                sql: """
                SELECT relative_path
                FROM media_companion
                WHERE library_root_id = ?
                  AND \(Self.subtreeSQL)
                """,
                arguments: [libraryRootID] + Self.subtreeArguments(underSubtree)
            )
        } else {
            try String.fetchAll(
                db,
                sql: """
                SELECT relative_path
                FROM media_companion
                WHERE library_root_id = ?
                """,
                arguments: [libraryRootID]
            )
        }
        return Set(paths.map(MediaRelativePath.init(rawValue:)))
    }

    /// A `relative_path` that is `subtree` itself or inside `subtree/`, never a sibling
    /// such as `subtree2` or `subtree.jpg`. One range of the binary-collated path,
    /// `[subtree, subtree0)` (`0` is the byte after `/`), which the
    /// `(library_root_id, relative_path)` key seeks; inside it, only `subtree` and paths at
    /// or after `subtree/` are kept. A `LIKE` prefix, or an `OR` of two ranges, makes SQLite
    /// read every row of the root once per folder. Bound with `subtreeArguments`.
    static let subtreeSQL = """
    (relative_path >= ? AND relative_path < ? AND (relative_path = ? OR relative_path >= ?))
    """

    static func subtreeArguments(_ subtree: MediaRelativePath) -> StatementArguments {
        let path = subtree.rawValue
        return [path, path + "0", path, path + "/"]
    }

    static func fetchCompanions(
        libraryRootID: Int64,
        db: Database
    ) throws -> [MediaCompanion] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, primary_relative_path, kind, byte_size, content_modified_at
            FROM media_companion
            WHERE library_root_id = ?
            ORDER BY relative_path COLLATE NOCASE, relative_path
            """,
            arguments: [libraryRootID]
        ).compactMap { row in
            guard let kind = MediaCompanionKind(rawValue: row["kind"]) else {
                return nil
            }
            let primary: String? = row["primary_relative_path"]
            let modified: Double? = row["content_modified_at"]
            return MediaCompanion(
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                primaryRelativePath: primary.map(MediaRelativePath.init(rawValue:)),
                kind: kind,
                byteSize: row["byte_size"],
                contentModifiedAt: modified.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    static func fetchPrimariesInDirectory(
        libraryRootID: Int64,
        directoryKey: String,
        db: Database
    ) throws -> [ScannedMediaFile] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, name, content_type_identifier, kind, format,
                   byte_size, created_at_unix, content_modified_at_unix
            FROM media_asset
            WHERE library_root_id = ? AND parent_path = ?
            """,
            // `parent_path` keeps the trailing slash `MediaRelativePath.folder` drops.
            arguments: [libraryRootID, directoryKey.isEmpty ? "" : directoryKey + "/"]
        )
        return rows.compactMap { row in
            let relativePath = MediaRelativePath(rawValue: row["relative_path"])
            guard MediaCompanionPairing.directoryKey(of: relativePath) == directoryKey else {
                return nil
            }
            let created: Double? = row["created_at_unix"]
            let modified: Double? = row["content_modified_at_unix"]
            let kindRaw: String? = row["kind"]
            let formatRaw: String? = row["format"]
            return ScannedMediaFile(
                relativePath: relativePath,
                name: row["name"],
                contentTypeIdentifier: row["content_type_identifier"],
                byteSize: row["byte_size"],
                createdAt: created.map(Date.init(timeIntervalSince1970:)),
                contentModifiedAt: modified.map(Date.init(timeIntervalSince1970:)),
                kind: kindRaw.flatMap(MediaKind.init(rawValue:)),
                format: formatRaw.map(MediaFormatToken.init(rawValue:))
            )
        }
    }

    static func fetchCompanionsInDirectory(
        libraryRootID: Int64,
        directoryKey: String,
        db: Database
    ) throws -> [ScannedCompanionFile] {
        try fetchCompanions(libraryRootID: libraryRootID, db: db)
            .filter { MediaCompanionPairing.directoryKey(of: $0.relativePath) == directoryKey }
            .map {
                ScannedCompanionFile(
                    relativePath: $0.relativePath,
                    kind: $0.kind,
                    byteSize: $0.byteSize,
                    contentModifiedAt: $0.contentModifiedAt
                )
            }
    }

    @discardableResult
    static func upsertCompanion(
        _ companion: MediaCompanion,
        libraryRootID: Int64,
        capabilities: VolumeNamespaceCapabilities,
        db: Database
    ) throws -> Bool {
        let pathKey = FilesystemNamespaceSemantics.nameKey(
            relativePath: companion.relativePath,
            capabilities: capabilities
        ).rawValue
        if let existingPath: String = try String.fetchOne(
            db,
            sql: """
            SELECT relative_path FROM media_companion
            WHERE library_root_id = ? AND relative_path_key = ? AND relative_path <> ? LIMIT 1
            """,
            arguments: [libraryRootID, pathKey, companion.relativePath.rawValue]
        ) {
            try db.execute(
                sql: """
                UPDATE media_companion SET relative_path = ?, relative_path_key = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [companion.relativePath.rawValue, pathKey, libraryRootID, existingPath]
            )
            let message = "op=catalog.scan.reconcile phase=respellCompanion "
                + "rootID=\(libraryRootID) "
                + "from=\(existingPath) "
                + "to=\(companion.relativePath.rawValue)"
            OtosLog.catalog.notice("\(message, privacy: .public)")
            return true
        }
        try db.execute(
            sql: """
            INSERT INTO media_companion (
                library_root_id,
                relative_path,
                relative_path_key,
                primary_relative_path,
                kind,
                byte_size,
                content_modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
                primary_relative_path = excluded.primary_relative_path,
                kind = excluded.kind,
                byte_size = excluded.byte_size,
                content_modified_at = excluded.content_modified_at,
                relative_path_key = excluded.relative_path_key
            WHERE media_companion.primary_relative_path IS NOT excluded.primary_relative_path
               OR media_companion.relative_path_key IS NOT excluded.relative_path_key
               OR media_companion.kind IS NOT excluded.kind
               OR media_companion.byte_size IS NOT excluded.byte_size
               OR CAST(COALESCE(media_companion.content_modified_at, -1) AS INTEGER)
                  IS NOT CAST(COALESCE(excluded.content_modified_at, -1) AS INTEGER)
            """,
            arguments: [
                libraryRootID,
                companion.relativePath.rawValue,
                pathKey,
                companion.primaryRelativePath?.rawValue,
                companion.kind.rawValue,
                companion.byteSize,
                companion.contentModifiedAt?.timeIntervalSince1970,
            ]
        )
        return db.changesCount > 0
    }

    @discardableResult
    static func deleteCompanionRow(
        rootRowID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
            DELETE FROM media_companion
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootRowID, relativePath.rawValue]
        )
        return db.changesCount > 0
    }

    /// Re-derives `primary_relative_path` for every companion in the directory
    /// that contains `relativePath` (targeted FSEvents / media upsert path).
    @discardableResult
    static func repairCompanionsInDirectory(
        of relativePath: MediaRelativePath,
        libraryRootID: Int64,
        capabilities: VolumeNamespaceCapabilities,
        db: Database
    ) throws -> Bool {
        let directoryKey = MediaCompanionPairing.directoryKey(of: relativePath)
        // Most folders hold no companions; they need no primaries read.
        let companions = try fetchCompanionsInDirectory(
            libraryRootID: libraryRootID,
            directoryKey: directoryKey,
            db: db
        )
        guard !companions.isEmpty else {
            return false
        }
        let primaries = try fetchPrimariesInDirectory(
            libraryRootID: libraryRootID,
            directoryKey: directoryKey,
            db: db
        )
        let paired = MediaCompanionPairing.pair(
            companions: companions,
            primaries: primaries,
            capabilities: capabilities
        )
        var changed = false
        for companion in paired {
            changed = try upsertCompanion(companion, libraryRootID: libraryRootID, capabilities: capabilities, db: db)
                || changed
        }
        return changed
    }

    static func applyScannedCompanions(
        _ companions: [ScannedCompanionFile],
        libraryRootID: Int64,
        capabilities: VolumeNamespaceCapabilities,
        db: Database
    ) throws -> Int {
        var changedCount = 0
        let byDirectory = Dictionary(grouping: companions) {
            MediaCompanionPairing.directoryKey(of: $0.relativePath)
        }
        for (directoryKey, directoryCompanions) in byDirectory {
            let primaries = try fetchPrimariesInDirectory(
                libraryRootID: libraryRootID,
                directoryKey: directoryKey,
                db: db
            )
            let paired = MediaCompanionPairing.pair(
                companions: directoryCompanions,
                primaries: primaries,
                capabilities: capabilities
            )
            for companion in paired {
                let changed = try upsertCompanion(
                    companion,
                    libraryRootID: libraryRootID,
                    capabilities: capabilities,
                    db: db
                )
                changedCount += changed ? 1 : 0
            }
        }
        return changedCount
    }

    static func reconcileMissingCompanions(
        libraryRootID: Int64,
        observedPaths: Set<MediaRelativePath>,
        capabilities: VolumeNamespaceCapabilities,
        underSubtree: MediaRelativePath? = nil,
        db: Database
    ) throws -> Int {
        let existing = try fetchExistingCompanionPaths(
            libraryRootID: libraryRootID,
            underSubtree: underSubtree,
            db: db
        )
        var existingKeys: [FilesystemNameKey: MediaRelativePath] = [:]
        var ambiguousKeys = Set<FilesystemNameKey>()
        for path in existing {
            let key = FilesystemNamespaceSemantics.nameKey(relativePath: path, capabilities: capabilities)
            if existingKeys[key] != nil {
                ambiguousKeys.insert(key)
            } else {
                existingKeys[key] = path
            }
        }
        let observedKeys = Set(observedPaths.map {
            FilesystemNamespaceSemantics.nameKey(relativePath: $0, capabilities: capabilities)
        })
        let missing = existingKeys
            .filter { !ambiguousKeys.contains($0.key) && !observedKeys.contains($0.key) }
            .map(\.value)
        var deleted = 0
        for path in missing {
            let removed = try deleteCompanionRow(rootRowID: libraryRootID, relativePath: path, db: db)
            deleted += removed ? 1 : 0
        }
        return deleted
    }

    /// The row a newly seen path moved from outside Otos, when the move witness says so
    /// (ADR 0008): no row exists at the new path; exactly one row on the same volume
    /// records this file's identifier, size and creation time (whole seconds); and that
    /// row's own path no longer exists on disk. The witness is evidence for this one
    /// write, never an identity — a path stays the asset. Modification time is left out
    /// on purpose: OneDrive rewrites it on remote renames and moves (research `2026-10-25-cloud-drives.md`, R2). A
    /// copy has a new identifier, and a file still present at its old path is not moved,
    /// so neither is paired; anything ambiguous pairs nothing and stays today's purge.
    static func movedRowWitnessed(
        for file: ScannedMediaFile,
        libraryRootPath: LibraryRootPath,
        libraryRootID: Int64,
        db: Database
    ) throws -> (libraryRootID: Int64, rootPath: String, relativePath: String)? {
        guard let identifier = file.fileIdentifier, let size = file.byteSize, let created = file.createdAt else {
            return nil
        }
        let rowAtPath = try Bool.fetchOne(
            db,
            sql: "SELECT 1 FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
            arguments: [libraryRootID, file.relativePath.rawValue]
        ) ?? false
        guard !rowAtPath else {
            return nil
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT a.library_root_id, a.relative_path, r.path AS root_path
            FROM media_asset a JOIN library_root r ON r.id = a.library_root_id
            WHERE a.file_identifier = ? AND a.byte_size = ?
              AND CAST(COALESCE(a.created_at_unix, -1) AS INTEGER) = ?
            """,
            arguments: [Int64(bitPattern: identifier), size, Int64(created.timeIntervalSince1970)]
        )
        guard !rows.isEmpty, let volume = volumeDevice(of: libraryRootPath.url.path(percentEncoded: false)) else {
            return nil
        }
        let candidates: [(libraryRootID: Int64, rootPath: String, relativePath: String)] = rows.compactMap { row in
            let rootPath: String = row["root_path"]
            let relativePath: String = row["relative_path"]
            guard volumeDevice(of: rootPath) == volume else {
                return nil
            }
            let oldPath = LibraryRootPath(rawValue: rootPath).url
                .appendingPathComponent(relativePath, isDirectory: false).path(percentEncoded: false)
            var info = stat()
            guard lstat(oldPath, &info) != 0, errno == ENOENT else {
                return nil
            }
            return (row["library_root_id"], rootPath, relativePath)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func volumeDevice(of path: String) -> dev_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_dev : nil
    }

    /// Writes one observed file's filesystem facts to its row, and says what that did to
    /// the catalog: an `.inserted` row is new and carries nothing Otos derives (no
    /// metadata, digest, rendering, faces or embedding), so only what lists rows has new
    /// input; an `.updated` row existed and may carry any of it.
    static func upsertScannedFile(
        _ file: ScannedMediaFile,
        libraryRootPath: LibraryRootPath,
        libraryRootID: Int64,
        capabilities: VolumeNamespaceCapabilities,
        db: Database
    ) throws -> ScannedFileUpsert {
        let pathKey = FilesystemNamespaceSemantics.nameKey(
            relativePath: file.relativePath,
            capabilities: capabilities
        ).rawValue
        // One read answers both questions this write asks before it upserts: which other
        // path spells this one (a respell), and whether a row already sits at this path.
        // Two index seeks in one cached statement: preparing a statement costs more than
        // both seeks, and this one runs for every file a scan or listing writes.
        let spellings = try Row.fetchAll(
            db.cachedStatement(sql: """
            SELECT relative_path, 0 AS at_path FROM media_asset
            WHERE library_root_id = ? AND relative_path_key = ? AND relative_path <> ?
            UNION ALL
            SELECT relative_path, 1 AS at_path FROM media_asset
            WHERE library_root_id = ? AND relative_path = ?
            """),
            arguments: [libraryRootID, pathKey, file.relativePath.rawValue, libraryRootID, file.relativePath.rawValue]
        )
        var existed = spellings.contains { row in row["at_path"] as Bool }
        if let existingPath: String = spellings.first(where: { row in !(row["at_path"] as Bool) })?["relative_path"] {
            try db.execute(
                sql: """
                UPDATE media_asset SET relative_path = ?, relative_path_key = ?, awaiting_presence = 0
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [file.relativePath.rawValue, pathKey, libraryRootID, existingPath]
            )
            let message = "op=catalog.scan.reconcile phase=respell "
                + "rootPath=\(libraryRootPath.rawValue) "
                + "from=\(existingPath) "
                + "to=\(file.relativePath.rawValue)"
            OtosLog.catalog.notice("\(message, privacy: .public)")
            return .updated
        }
        if let moved = try movedRowWitnessed(for: file, libraryRootPath: libraryRootPath, libraryRootID: libraryRootID, db: db) {
            existed = true
            // The row keeps everything Otos holds for the file and takes the new path;
            // the upsert below then refreshes its filesystem facts. `asset_metadata` and
            // every other child row follow through `ON UPDATE CASCADE`.
            try db.execute(
                sql: """
                UPDATE media_asset SET library_root_id = ?, relative_path = ?, relative_path_key = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [libraryRootID, file.relativePath.rawValue, pathKey, moved.libraryRootID, moved.relativePath]
            )
            let message = "op=catalog.scan.reconcile phase=moveWitnessed "
                + "fromRoot=\(moved.rootPath) from=\(moved.relativePath) "
                + "rootPath=\(libraryRootPath.rawValue) to=\(file.relativePath.rawValue)"
            OtosLog.catalog.notice("\(message, privacy: .public)")
        }
        // A file at the path of a row whose file sits in the system Trash is that file put
        // back — Finder's Put Back, or undo — so the row shows again with everything Otos
        // held for it (ADR 0022). Path is identity (ADR 0008): whatever file now occupies
        // the path is the asset.
        // This statement and the upsert below run for every file a scan or listing writes,
        // so both are cached: preparing a write on media_asset compiles the upkeep of each of
        // its indexes, and costs more than the write itself.
        try db.cachedStatement(sql: """
        UPDATE media_asset SET pending_trash_batch_unix_ms = NULL, trash_path = NULL
        WHERE library_root_id = ? AND relative_path = ? AND trash_path IS NOT NULL
        """).execute(arguments: [libraryRootID, file.relativePath.rawValue])
        let putBack = db.changesCount > 0
        if putBack {
            let message = "op=catalog.scan.reconcile phase=putBack "
                + "rootPath=\(libraryRootPath.rawValue) relativePath=\(file.relativePath.rawValue)"
            OtosLog.catalog.notice("\(message, privacy: .public)")
        }
        // The compound key makes a scan idempotent: observing the same relative
        // path refreshes its current filesystem facts instead of creating scan
        // history or a second asset identity. Observing a row the current attachment
        // had not yet seen reveals it (`awaiting_presence`), and that is a change.
        // The assumed offset (`CaptureLocalTime.assumedUTCOffset`) is made for the
        // absolute time the row is placed by. The file's dates stand in for it only while
        // no capture instant does, and an absolute time unchanged to the second keeps the
        // offset it was given, so a rescan in another zone moves nothing.
        try db.cachedStatement(sql: """
        INSERT INTO media_asset (
            library_root_id,
            relative_path,
            relative_path_key,
            sort_key,
            name_sort_key,
            name,
            content_type_identifier,
            kind,
            format,
            byte_size,
            created_at_unix,
            content_modified_at_unix,
            file_identifier,
            assumed_utc_offset_seconds
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
            assumed_utc_offset_seconds = CASE
                WHEN CAST(COALESCE(media_asset.capture_instant_unix, media_asset.created_at_unix,
                                   media_asset.content_modified_at_unix) AS INTEGER)
                  IS CAST(COALESCE(media_asset.capture_instant_unix, excluded.created_at_unix,
                                   excluded.content_modified_at_unix) AS INTEGER)
                THEN media_asset.assumed_utc_offset_seconds
                ELSE excluded.assumed_utc_offset_seconds
            END,
            sort_key = excluded.sort_key,
            name_sort_key = excluded.name_sort_key,
            name = excluded.name,
            content_type_identifier = excluded.content_type_identifier,
            kind = excluded.kind,
            format = excluded.format,
            byte_size = excluded.byte_size,
            created_at_unix = excluded.created_at_unix,
            content_modified_at_unix = excluded.content_modified_at_unix,
            file_identifier = excluded.file_identifier,
            relative_path_key = excluded.relative_path_key,
            awaiting_presence = 0
        WHERE media_asset.awaiting_presence <> 0
           OR media_asset.relative_path_key IS NOT excluded.relative_path_key
           OR media_asset.sort_key IS NOT excluded.sort_key
           OR media_asset.file_identifier IS NOT excluded.file_identifier
           OR media_asset.name_sort_key IS NOT excluded.name_sort_key
           OR media_asset.name IS NOT excluded.name
           OR media_asset.content_type_identifier IS NOT excluded.content_type_identifier
           OR media_asset.kind IS NOT excluded.kind
           OR media_asset.format IS NOT excluded.format
           OR media_asset.byte_size IS NOT excluded.byte_size
           OR CAST(COALESCE(media_asset.created_at_unix, -1) AS INTEGER)
              IS NOT CAST(COALESCE(excluded.created_at_unix, -1) AS INTEGER)
           OR CAST(COALESCE(media_asset.content_modified_at_unix, -1) AS INTEGER)
              IS NOT CAST(COALESCE(excluded.content_modified_at_unix, -1) AS INTEGER)
        """).execute(
            arguments: scannedFileUpsertArguments(
                file,
                libraryRootPath: libraryRootPath,
                libraryRootID: libraryRootID,
                pathKey: pathKey
            )
        )
        guard db.changesCount > 0 || putBack else {
            return .unchanged
        }
        return existed ? .updated : .inserted
    }

    private static func upsertAssetMetadata(
        _ metadata: AssetMetadata,
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws {
        let primaryLocation = metadata.locations.first
        let arguments = try assetMetadataStatementArguments(
            metadata,
            libraryRootID: libraryRootID,
            relativePath: relativePath,
            primaryLocation: primaryLocation
        )
        try db.execute(
            sql: upsertAssetMetadataSQL(),
            arguments: arguments
        )
    }
}

private nonisolated func upsertAssetMetadataSQL() -> String {
    """
    INSERT INTO asset_metadata (
        library_root_id,
        relative_path,
        family,
        file_extension,
        brand,
        camera_make,
        camera_model,
        lens_model,
        serial_number,
        orientation,
        pixel_width,
        pixel_height,
        duration_seconds,
        frame_rate,
        video_codec,
        primary_latitude,
        primary_longitude,
        primary_altitude_meters,
        metadata_extra_json,
        extraction_revision
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
        family = excluded.family,
        file_extension = excluded.file_extension,
        brand = excluded.brand,
        camera_make = excluded.camera_make,
        camera_model = excluded.camera_model,
        lens_model = excluded.lens_model,
        serial_number = excluded.serial_number,
        orientation = excluded.orientation,
        pixel_width = excluded.pixel_width,
        pixel_height = excluded.pixel_height,
        duration_seconds = excluded.duration_seconds,
        frame_rate = excluded.frame_rate,
        video_codec = excluded.video_codec,
        primary_latitude = excluded.primary_latitude,
        primary_longitude = excluded.primary_longitude,
        primary_altitude_meters = excluded.primary_altitude_meters,
        metadata_extra_json = excluded.metadata_extra_json,
        extraction_revision = excluded.extraction_revision
    """
}

private nonisolated func sqlPlaceholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}

private nonisolated func sqlTuplePlaceholders(rowCount: Int, columnCount: Int) -> String {
    let tuple = "(\(sqlPlaceholders(count: columnCount)))"
    return Array(repeating: tuple, count: rowCount).joined(separator: ",")
}

private nonisolated func sqlArguments(_ values: (any DatabaseValueConvertible)...) -> StatementArguments {
    StatementArguments(values)
}

private nonisolated func scannedFileUpsertArguments(
    _ file: ScannedMediaFile,
    libraryRootPath: LibraryRootPath,
    libraryRootID: Int64,
    pathKey: String
) -> StatementArguments {
    let values: [(any DatabaseValueConvertible)?] = [
        libraryRootID,
        file.relativePath.rawValue,
        pathKey,
        MediaSortKey.make(libraryRootPath: libraryRootPath, relativePath: file.relativePath),
        MediaSortKey.naturalKey(file.name ?? file.relativePath.fileName),
        file.name,
        file.contentTypeIdentifier,
        file.kind?.rawValue,
        file.format?.rawValue,
        file.byteSize,
        file.createdAt?.timeIntervalSince1970,
        file.contentModifiedAt?.timeIntervalSince1970,
        file.fileIdentifier.map { Int64(bitPattern: $0) },
        CaptureLocalTime.assumedUTCOffset(
            for: (file.createdAt ?? file.contentModifiedAt)?.timeIntervalSince1970,
            previousAbsolute: nil,
            previousOffset: nil
        ),
    ]
    return StatementArguments(values)
}

private nonisolated func assetMetadataStatementArguments(
    _ metadata: AssetMetadata,
    libraryRootID: Int64,
    relativePath: MediaRelativePath,
    primaryLocation: GeoRecord?
) throws -> StatementArguments {
    let values: [(any DatabaseValueConvertible)?] = try [
        libraryRootID,
        relativePath.rawValue,
        metadata.family,
        metadata.fileExtension,
        metadata.brand,
        metadata.cameraMake,
        metadata.cameraModel,
        metadata.lensModel,
        metadata.serialNumber,
        metadata.orientation,
        metadata.pixelWidth,
        metadata.pixelHeight,
        metadata.durationSeconds,
        metadata.frameRate,
        metadata.videoCodec,
        primaryLocation?.latitude,
        primaryLocation?.longitude,
        primaryLocation?.altitudeMeters,
        CatalogStore.encodeMetadataExtraJSON(metadata),
        metadata.extractionRevision,
    ]
    return StatementArguments(values)
}

/// A device identity is stored as its text.
nonisolated extension DeviceIdentity: DatabaseValueConvertible {
    var databaseValue: DatabaseValue {
        rawValue.databaseValue
    }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DeviceIdentity? {
        String.fromDatabaseValue(dbValue).map(DeviceIdentity.init(rawValue:))
    }
}

// MARK: - Reads that free their connection

extension DatabaseReader {
    /// Runs `body` in a read transaction and frees its connection the moment the body ends,
    /// on the connection's own queue. GRDB's async `read` frees it only once the reading task
    /// resumes on a cooperative-pool thread at its own priority (`Pool.get(block:)`), so a
    /// background read whose task waits for a thread keeps a connection it no longer uses,
    /// and every read behind it waits too: the visible tiles' reads waited 1–6 s on the
    /// installed app, with no read running
    /// (`docs/research/2026-11-15-cooperative-pool-holders.md`). `asyncRead` hands the
    /// connection back from its queue as the body returns, whatever the caller's task is
    /// waiting for.
    ///
    /// Cancelling the task interrupts the body's statement, as GRDB's own read does, and the
    /// read throws `CancellationError`. The cancellation holds for the rest of the body: a
    /// statement that starts after it is stopped too, because SQLite clears an interrupt that
    /// lands while no statement runs.
    nonisolated func readFreeingConnection<T: Sendable>(
        _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        let interruption = ReadInterruption()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                asyncRead { connection in
                    continuation.resume(with: Result {
                        let db = try connection.get()
                        try interruption.begin(db)
                        defer { interruption.end(db) }
                        do {
                            return try body(db)
                        } catch {
                            if interruption.wasCancelled {
                                throw CancellationError()
                            }
                            throw error
                        }
                    })
                }
            }
        } onCancel: {
            interruption.cancel()
        }
    }
}

/// The one connection a `readFreeingConnection` body is running on, so a cancellation
/// interrupts that statement and never a connection the pool has since handed to another
/// read: the body takes and gives back the connection under the same lock the cancellation
/// interrupts under.
private final nonisolated class ReadInterruption: Sendable {
    /// The connection's address: a value the lock can hold, which `cancel` turns back into the
    /// connection only while the body runs on it.
    private struct State {
        var connection: Int?
        var cancelled = false
    }

    private let state = Mutex(State())

    var wasCancelled: Bool {
        state.withLock(\.cancelled)
    }

    /// SQLite's virtual-machine steps between checks of `wasCancelled` (`progressHandler`).
    private static let progressCheckInterval: Int32 = 1000

    func begin(_ db: Database) throws {
        try state.withLock { state in
            guard !state.cancelled else {
                throw CancellationError()
            }
            state.connection = db.sqliteConnection.map { Int(bitPattern: $0) }
        }
        // `sqlite3_interrupt` stops only a statement that is running when it lands: SQLite
        // clears it as the next statement starts on an idle connection, so a cancel between
        // two statements, or before the first steps, would let the rest of the body run. The
        // progress handler makes it hold: every statement the body starts afterwards stops at
        // its first check with `SQLITE_INTERRUPT`. The body holds this object until `end`.
        sqlite3_progress_handler(db.sqliteConnection, Self.progressCheckInterval, { context in
            guard let context else {
                return 0
            }
            return Unmanaged<ReadInterruption>.fromOpaque(context).takeUnretainedValue().wasCancelled ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func end(_ db: Database) {
        sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil)
        state.withLock { $0.connection = nil }
    }

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            if let address = state.connection, let connection = OpaquePointer(bitPattern: address) {
                sqlite3_interrupt(connection)
            }
        }
    }
}
