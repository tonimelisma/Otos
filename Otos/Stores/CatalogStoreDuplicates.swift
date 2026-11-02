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

/// One still the same-photo rule compares, with the capture facts every still's row
/// carries in columns. The finer facts and the pixels are read only for proposed pairs
/// (`SamePhotoDetail`).
nonisolated struct SamePhotoCandidate: Equatable, Sendable {
    let copy: DuplicateCopy
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

/// What confirms or rejects a proposed pair: the still's grayscale render, and the capture
/// facts that live in its stored metadata record rather than in a column. Read only for the
/// stills a proposed pair names, because decoding every still's record is most of the cost
/// of reading the library's candidates.
nonisolated struct SamePhotoDetail: Equatable, Sendable {
    let signature: RenderSignature
    let fractionalSecondDigits: String?
    let burstIdentifier: String?
}

nonisolated extension DuplicatesGateway {
    struct SamePhotoRow {
        let copy: CopyRow
        let kind: String?
        let captureInstant: Double?
        let cameraModel: String?
        let serialNumber: String?
        let orientation: Int?
        let differenceHash: Int64

        func candidate(
            pathsByRowID: [Int64: LibraryRootPath],
            namesByPath: [LibraryRootPath: String]
        ) -> SamePhotoCandidate? {
            guard let copied = copy.copy(pathsByRowID: pathsByRowID, namesByPath: namesByPath) else {
                return nil
            }
            let width = copied.pixelWidth.map(Double.init)
            let height = copied.pixelHeight.map(Double.init)
            // Orientations 5–8 turn the raster a quarter, so display width is stored height.
            let quarterTurned = (5 ... 8).contains(orientation ?? 1)
            let aspect: Double? = if let width, let height, width > 0, height > 0 {
                quarterTurned ? height / width : width / height
            } else {
                nil
            }
            return SamePhotoCandidate(
                copy: copied,
                isRaw: kind == "raw",
                captureInstant: captureInstant,
                cameraModel: cameraModel,
                serialNumber: serialNumber,
                aspectRatio: aspect,
                differenceHash: UInt64(bitPattern: differenceHash)
            )
        }
    }

    static func fetchSamePhotoCandidates(rootIDs: [Int64], db: Database) throws -> [SamePhotoRow] {
        let placeholders = Array(repeating: "?", count: rootIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT a.library_root_id, a.relative_path, a.content_hash_xxh3_128, a.byte_size, a.created_at_unix,
                   a.media_choice, a.edit_recipe_json IS NOT NULL AS edited, a.kind, a.capture_instant_unix,
                   a.render_dhash,
                   m.pixel_width, m.pixel_height, m.orientation, m.camera_model, m.serial_number,
                   EXISTS(
                       SELECT 1 FROM media_companion c
                       WHERE c.library_root_id = a.library_root_id AND c.primary_relative_path = a.relative_path
                   ) AS has_companions
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
        return rows.map { row in
            SamePhotoRow(
                copy: CopyRow(
                    rootID: row["library_root_id"],
                    relativePath: row["relative_path"],
                    digest: nil,
                    byteSize: row["byte_size"],
                    createdAt: row["created_at_unix"],
                    mediaChoice: row["media_choice"],
                    isEdited: row["edited"],
                    pixelWidth: row["pixel_width"],
                    pixelHeight: row["pixel_height"],
                    hasCompanions: row["has_companions"]
                ),
                kind: row["kind"],
                captureInstant: row["capture_instant_unix"],
                cameraModel: row["camera_model"],
                serialNumber: row["serial_number"],
                orientation: row["orientation"],
                differenceHash: row["render_dhash"]
            )
        }
    }
}
