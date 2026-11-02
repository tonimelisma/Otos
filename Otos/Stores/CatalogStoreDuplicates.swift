import Foundation
import GRDB
import MediaMetadata

/// Duplicates SQL (ADR 0042), run inside the Store's database access by `CatalogStore`'s
/// duplicates reads and Keep All writes (in `CatalogStore.swift`, beside the state they use).
///
/// A copy belongs to duplicates only while it is visible — in an available fixed library,
/// not waiting for or in the Trash, not a Live Photo's movie (a member of its still's
/// item) — and while its digest is current for its file. The grouping and the keeper rule
/// are pure (`DuplicateGroupPolicy`) and run in Projection.
nonisolated enum DuplicatesGateway {
    struct CopyRow {
        let rootID: Int64
        let relativePath: String
        /// The current digest; present for an identical-copies read, absent for a same-photo
        /// read, which compares pixels instead.
        let digest: XXH3Digest128?
        let byteSize: Int64?
        let createdAt: Double?
        let mediaChoice: String?
        let isEdited: Bool
        let pixelWidth: Int?
        let pixelHeight: Int?
        let hasCompanions: Bool

        func facts(
            pathsByRowID: [Int64: LibraryRootPath],
            namesByPath: [LibraryRootPath: String]
        ) -> DuplicateCopyFacts? {
            guard let digest, let copy = copy(pathsByRowID: pathsByRowID, namesByPath: namesByPath) else {
                return nil
            }
            return DuplicateCopyFacts(copy: copy, digest: digest)
        }

        func copy(
            pathsByRowID: [Int64: LibraryRootPath],
            namesByPath: [LibraryRootPath: String]
        ) -> DuplicateCopy? {
            guard let root = pathsByRowID[rootID], let name = namesByPath[root] else {
                return nil
            }
            return DuplicateCopy(
                id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: relativePath)),
                libraryDisplayName: name,
                byteSize: byteSize,
                createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                mediaChoice: mediaChoice.flatMap(MediaChoice.init(rawValue:)) ?? .default,
                isEdited: isEdited,
                hasCompanions: hasCompanions
            )
        }
    }

    struct KeptPairRow {
        let firstRootID: Int64
        let firstPath: String
        let secondRootID: Int64
        let secondPath: String

        func pair(pathsByRowID: [Int64: LibraryRootPath]) -> DuplicateKeptPair? {
            guard let firstRoot = pathsByRowID[firstRootID], let secondRoot = pathsByRowID[secondRootID] else {
                return nil
            }
            return DuplicateKeptPair(
                MediaAssetID(libraryRootPath: firstRoot, relativePath: MediaRelativePath(rawValue: firstPath)),
                MediaAssetID(libraryRootPath: secondRoot, relativePath: MediaRelativePath(rawValue: secondPath))
            )
        }
    }

    /// A row counts when it is visible, has content, and its digest is current for its
    /// file. An empty file holds nothing to duplicate: every one shares the digest of no
    /// bytes, so matching them would group unrelated broken files.
    private static func visibleCurrentPredicate(_ row: String) -> String {
        """
        \(row).byte_size > 0
          AND \(row).pending_trash_batch_unix_ms IS NULL
          AND \(row).trash_path IS NULL
          AND NOT \(LivePhotoSQL.isPairedMotion(row))
          AND \(row).content_hash_xxh3_128 IS NOT NULL
          AND length(\(row).content_hash_xxh3_128) = 16
          AND \(row).content_hash_source_size = COALESCE(\(row).byte_size, -1)
          AND \(row).content_hash_source_mtime = CAST(COALESCE(\(row).content_modified_at_unix, -1) AS INTEGER)
        """
    }

    static func fetchDuplicateCopies(rootIDs: [Int64], db: Database) throws -> [CopyRow] {
        let placeholders = Array(repeating: "?", count: rootIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT a.library_root_id, a.relative_path, a.content_hash_xxh3_128, a.byte_size, a.created_at_unix,
                   a.media_choice, a.edit_recipe_json IS NOT NULL AS edited,
                   m.pixel_width, m.pixel_height,
                   EXISTS(
                       SELECT 1 FROM media_companion c
                       WHERE c.library_root_id = a.library_root_id AND c.primary_relative_path = a.relative_path
                   ) AS has_companions
            FROM media_asset a
            LEFT JOIN asset_metadata m
              ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
            WHERE a.library_root_id IN (\(placeholders))
              AND \(visibleCurrentPredicate("a"))
              AND a.content_hash_xxh3_128 IN (
                  SELECT d.content_hash_xxh3_128 FROM media_asset d
                  WHERE d.library_root_id IN (\(placeholders))
                    AND \(visibleCurrentPredicate("d"))
                  GROUP BY d.content_hash_xxh3_128
                  HAVING COUNT(*) > 1
              )
            """,
            arguments: StatementArguments(rootIDs + rootIDs)
        )
        return rows.compactMap { row in
            guard let digest = (row["content_hash_xxh3_128"] as Data?).flatMap(XXH3Digest128.init(data:)) else {
                return nil
            }
            return CopyRow(
                rootID: row["library_root_id"],
                relativePath: row["relative_path"],
                digest: digest,
                byteSize: row["byte_size"],
                createdAt: row["created_at_unix"],
                mediaChoice: row["media_choice"],
                isEdited: row["edited"],
                pixelWidth: row["pixel_width"],
                pixelHeight: row["pixel_height"],
                hasCompanions: row["has_companions"]
            )
        }
    }

    static func fetchKeptPairs(rootIDs: [Int64], db: Database) throws -> [KeptPairRow] {
        let placeholders = Array(repeating: "?", count: rootIDs.count).joined(separator: ", ")
        return try Row.fetchAll(
            db,
            sql: """
            SELECT first_root_id, first_path, second_root_id, second_path FROM duplicate_kept_pair
            WHERE first_root_id IN (\(placeholders)) AND second_root_id IN (\(placeholders))
            """,
            arguments: StatementArguments(rootIDs + rootIDs)
        ).map { row in
            KeptPairRow(
                firstRootID: row["first_root_id"],
                firstPath: row["first_path"],
                secondRootID: row["second_root_id"],
                secondPath: row["second_path"]
            )
        }
    }
}

// MARK: - Same photo (ADR 0042)

/// The thumbnail a render signature is read from, named by what makes it that rendering:
/// its path, the edit revision it was rendered with, and the file signature it was
/// rendered from (its rendering stamp, empty for a provisional thumbnail). A signature
/// whose source no longer matches is stale.
nonisolated enum RenderSignatureSQL {
    static func source(_ row: String) -> String {
        """
        (\(row).thumbnail_path || '|' || \(row).rendered_revision || '|'
            || IFNULL(\(row).rendered_source_size, '') || '|' || IFNULL(\(row).rendered_source_mtime, ''))
        """
    }
}

/// A still whose thumbnail has no current render signature.
nonisolated struct RenderSignatureCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let thumbnailPath: String
    let source: String
}

/// What a render signature read produced for one candidate: the signature, or nil when the
/// thumbnail could not be decoded — recorded, so the row is not offered again until its
/// thumbnail changes.
nonisolated struct RenderSignatureResult: Equatable, Sendable {
    let id: MediaAssetID
    let source: String
    let signature: RenderSignature?
}

/// One still the same-photo rule compares, with only the column facts pairs are proposed
/// from. Everything else about it — the copy the list shows, the render, the record facts —
/// is read only for the stills a proposed pair names (`SamePhotoDetail`).
nonisolated struct SamePhotoCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let isRaw: Bool
    /// Whole-second capture instant, from the library's selection.
    let captureInstant: Double?
    let cameraModel: String?
    let serialNumber: String?
    /// Display width over height, from stored geometry.
    let aspectRatio: Double?
    let differenceHash: UInt64

    /// Whether the file names its capture: an instant and a camera.
    var hasCaptureMetadata: Bool {
        captureInstant != nil && cameraModel != nil
    }
}

/// A still in a proposed pair: the copy a group lists, the grayscale render that confirms
/// or rejects the pair, and the capture facts that live in its stored metadata record rather
/// than in a column. Read only for these stills: building every still's copy and decoding
/// every record was most of a build.
nonisolated struct SamePhotoDetail: Equatable, Sendable {
    let copy: DuplicateCopy
    let signature: RenderSignature
    let fractionalSecondDigits: String?
    let burstIdentifier: String?
}

nonisolated extension DuplicatesGateway {
    /// Visible stills with a current render signature, as pairing facts. The read walks a
    /// cursor rather than copying every row, because it covers every still in the libraries.
    static func fetchSamePhotoCandidates(
        rootIDs: [Int64],
        pathsByRowID: [Int64: LibraryRootPath],
        db: Database
    ) throws -> [SamePhotoCandidate] {
        let placeholders = Array(repeating: "?", count: rootIDs.count).joined(separator: ", ")
        let rows = try Row.fetchCursor(
            db,
            sql: """
            SELECT a.library_root_id, a.relative_path, a.kind, a.capture_instant_unix, a.render_dhash,
                   m.pixel_width, m.pixel_height, m.orientation, m.camera_model, m.serial_number
            FROM media_asset a
            LEFT JOIN asset_metadata m
              ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
            WHERE a.library_root_id IN (\(placeholders))
              AND a.kind IN ('image', 'raw')
              AND a.pending_trash_batch_unix_ms IS NULL
              AND a.trash_path IS NULL
              AND a.render_dhash IS NOT NULL
              AND a.render_signature_source = \(RenderSignatureSQL.source("a"))
            """,
            arguments: StatementArguments(rootIDs)
        )
        var candidates: [SamePhotoCandidate] = []
        while let row = try rows.next() {
            guard let root = pathsByRowID[row["library_root_id"]] else {
                continue
            }
            let width: Double? = row["pixel_width"]
            let height: Double? = row["pixel_height"]
            // Orientations 5–8 turn the raster a quarter, so display width is stored height.
            let quarterTurned = (5 ... 8).contains(row["orientation"] as Int? ?? 1)
            let aspect: Double? = if let width, let height, width > 0, height > 0 {
                quarterTurned ? height / width : width / height
            } else {
                nil
            }
            let kind: String? = row["kind"]
            let hash: Int64 = row["render_dhash"]
            candidates.append(SamePhotoCandidate(
                id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"])),
                isRaw: kind == "raw",
                captureInstant: row["capture_instant_unix"],
                cameraModel: row["camera_model"],
                serialNumber: row["serial_number"],
                aspectRatio: aspect,
                differenceHash: UInt64(bitPattern: hash)
            ))
        }
        return candidates
    }

    /// The details of one still in a proposed pair, run once per still through a cached
    /// statement. Nil when the still has no stored signature any more.
    static func fetchSamePhotoDetail(
        rootID: Int64,
        id: MediaAssetID,
        libraryDisplayName: String,
        db: Database
    ) throws -> SamePhotoDetail? {
        let statement = try db.cachedStatement(sql: """
        SELECT a.byte_size, a.created_at_unix, a.media_choice, a.edit_recipe_json IS NOT NULL AS edited,
               a.render_dhash, a.render_gray,
               m.pixel_width, m.pixel_height, m.metadata_extra_json,
               EXISTS(
                   SELECT 1 FROM media_companion c
                   WHERE c.library_root_id = a.library_root_id AND c.primary_relative_path = a.relative_path
               ) AS has_companions
        FROM media_asset a
        LEFT JOIN asset_metadata m
          ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
        WHERE a.library_root_id = ? AND a.relative_path = ?
        """)
        guard let row = try Row.fetchOne(statement, arguments: [rootID, id.relativePath.rawValue]),
              let hash = row["render_dhash"] as Int64?,
              let gray = row["render_gray"] as Data?,
              let signature = RenderSignature(differenceHash: UInt64(bitPattern: hash), gray: Array(gray))
        else {
            return nil
        }
        // The stored record is the library's own report (ADR 0039); a record that does not
        // decode leaves its two facts unknown, which the rule treats as unknown.
        let metadata: AssetMetadata? = (row["metadata_extra_json"] as String?).flatMap { json in
            do {
                return try CatalogStore.decodeMetadataExtraJSON(json)
            } catch {
                OtosLog.catalog.errorOperation("duplicates.samePhoto", phase: "metadataUndecodable", fields: [
                    "relativePath": id.relativePath.rawValue,
                ])
                return nil
            }
        }
        let original = metadata?.timestamps.first { $0.role == CaptureTimestamps.Role.original.rawValue }
        let mediaChoice: String? = row["media_choice"]
        let createdAt: Double? = row["created_at_unix"]
        return SamePhotoDetail(
            copy: DuplicateCopy(
                id: id,
                libraryDisplayName: libraryDisplayName,
                byteSize: row["byte_size"],
                createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
                pixelWidth: row["pixel_width"],
                pixelHeight: row["pixel_height"],
                mediaChoice: mediaChoice.flatMap(MediaChoice.init(rawValue:)) ?? .default,
                isEdited: row["edited"],
                hasCompanions: row["has_companions"]
            ),
            signature: signature,
            fractionalSecondDigits: original?.fractionalSecondDigits,
            burstIdentifier: metadata?.burstIdentifier
        )
    }
}
