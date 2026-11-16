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
        let digest: ContentDigest?
        let kind: String?
        let captureLocal: Double?
        let byteSize: Int64?
        let createdAt: Double?
        let mediaChoice: String?
        let isEdited: Bool
        let pixelWidth: Int?
        let pixelHeight: Int?
        let orientation: Int?
        let hasCompanions: Bool

        func facts(
            pathsByRowID: [Int64: LibraryRootPath],
            librariesByPath: [LibraryRootPath: DuplicateLibrary]
        ) -> DuplicateCopyFacts? {
            guard let digest, let copy = copy(pathsByRowID: pathsByRowID, librariesByPath: librariesByPath) else {
                return nil
            }
            return DuplicateCopyFacts(copy: copy, digest: digest)
        }

        func copy(
            pathsByRowID: [Int64: LibraryRootPath],
            librariesByPath: [LibraryRootPath: DuplicateLibrary]
        ) -> DuplicateCopy? {
            guard let root = pathsByRowID[rootID], let library = librariesByPath[root] else {
                return nil
            }
            let geometry = DuplicatesGateway.upright(width: pixelWidth, height: pixelHeight, orientation: orientation)
            return DuplicateCopy(
                id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: relativePath)),
                libraryDisplayName: library.displayName, libraryKind: library.kind,
                kind: kind.flatMap(MediaKind.init(rawValue:)),
                captureLocalTime: captureLocal.map(CaptureLocalTime.init(seconds:)),
                byteSize: byteSize,
                createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
                pixelWidth: geometry.displayPixelWidth,
                pixelHeight: geometry.displayPixelHeight,
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

    /// A row counts when it is visible, has content, its digest is current for its file, and
    /// it holds bytes of its own. The one rule: the Duplicates read and the Duplicates
    /// scope's rows (`CatalogQueryGateway`) both apply it, so the scope, the sidebar's count
    /// and the list hold exactly the same copies.
    /// - An empty file holds nothing to duplicate: every one shares the digest of no bytes,
    ///   so matching them would group unrelated broken files.
    /// - An Immich external library's asset (`source_path_sha1` set) is the server's view of
    ///   a file on a disk the server reads — for a mirrored library, the very file Otos holds
    ///   there (ADR 0054). Immich holds no bytes of it, so it is never a copy to keep in place
    ///   of another: a group never holds it, so no click, folder rule or default can keep it
    ///   and send the file it mirrors to the Trash (owner, 2026-11-15).
    static func countsAsCopy(_ row: String) -> String {
        """
        \(row).byte_size > 0
          AND \(row).source_path_sha1 IS NULL
          AND \(row).pending_trash_batch_unix_ms IS NULL
          AND \(row).trash_path IS NULL
          AND \(row).hidden_by_source = 0
          AND NOT \(LivePhotoSQL.isPairedMotion(row))
          AND \(ContentDigestSQL.isCurrent(row))
        """
    }

    /// Every visible copy whose current digest another visible copy shares, over `rootCount`
    /// roots (their IDs bound twice) — another in the same root while Duplicates compares
    /// within each library. Both reads walk the digest index, which holds only rows that have
    /// a digest, in digest then root order, so neither visits a row without one nor groups
    /// through a temporary B-tree: most of the owner's rows (an Immich account's) have none
    /// (`docs/research/2026-11-14-owner-scale-query-plans.md`).
    static func duplicateCopiesSQL(rootCount: Int, reach: DuplicatesReach) -> String {
        let placeholders = Array(repeating: "?", count: rootCount).joined(separator: ", ")
        let shared = DuplicatesReachSQL.shared(
            row: "a", twin: "d", reach: reach,
            twinFilter: """
            d.library_root_id IN (\(placeholders))
                AND \(countsAsCopy("d"))
            """
        )
        return """
        SELECT a.library_root_id, a.relative_path, a.content_sha1, a.best_kind, a.best_capture_local,
               a.byte_size, a.created_at_unix, a.media_choice, a.edit_recipe_json IS NOT NULL AS edited,
               m.pixel_width, m.pixel_height, m.orientation,
               EXISTS(
                   SELECT 1 FROM media_companion c
                   WHERE c.library_root_id = a.library_root_id AND c.primary_relative_path = a.relative_path
               ) AS has_companions
        FROM media_asset a INDEXED BY \(ContentDigestSQL.indexName)
        LEFT JOIN asset_metadata m
          ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
        WHERE a.library_root_id IN (\(placeholders))
          AND \(countsAsCopy("a"))
          AND \(shared)
        """
    }

    static func fetchDuplicateCopies(rootIDs: [Int64], reach: DuplicatesReach, db: Database) throws -> [CopyRow] {
        let rows = try Row.fetchAll(
            db,
            sql: duplicateCopiesSQL(rootCount: rootIDs.count, reach: reach),
            arguments: StatementArguments(rootIDs + rootIDs)
        )
        return rows.compactMap { row in
            guard let digest = (row["content_sha1"] as Data?).flatMap(ContentDigest.init(data:)) else {
                return nil
            }
            return CopyRow(
                rootID: row["library_root_id"],
                relativePath: row["relative_path"],
                digest: digest,
                kind: row["best_kind"],
                captureLocal: row["best_capture_local"],
                byteSize: row["byte_size"],
                createdAt: row["created_at_unix"],
                mediaChoice: row["media_choice"],
                isEdited: row["edited"],
                pixelWidth: row["pixel_width"],
                pixelHeight: row["pixel_height"],
                orientation: row["orientation"],
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

/// Whether a row's digest is one another row shares (ADR 0042): the one definition the
/// Duplicates read and the Duplicates scope use. While Duplicates compares within each
/// library, the other row must be in the same root, so the subquery groups by digest and root,
/// the digest index's own order.
nonisolated enum DuplicatesReachSQL {
    /// `row`'s digest, and its root within each library, among `twin`'s groups of more than
    /// one; `twinFilter` says which twins count.
    static func shared(row: String, twin: String, reach: DuplicatesReach, twinFilter: String) -> String {
        switch reach {
        case .acrossLibraries:
            """
            \(row).content_sha1 IN (
                  SELECT \(twin).content_sha1 FROM media_asset \(twin) INDEXED BY \(ContentDigestSQL.indexName)
                  WHERE \(twinFilter)
                  GROUP BY \(twin).content_sha1
                  HAVING COUNT(*) > 1
              )
            """
        case .withinEachLibrary:
            """
            (\(row).content_sha1, \(row).library_root_id) IN (
                  SELECT \(twin).content_sha1, \(twin).library_root_id FROM media_asset \(twin) INDEXED BY \(ContentDigestSQL.indexName)
                  WHERE \(twinFilter)
                  GROUP BY \(twin).content_sha1, \(twin).library_root_id
                  HAVING COUNT(*) > 1
              )
            """
        }
    }
}

/// What a copy needs of its library: the name the list shows, and the kind that says what
/// Otos may do with the copy. Only these two, because a build looks one up per row.
nonisolated struct DuplicateLibrary: Sendable {
    let displayName: String
    let kind: LibraryRootKind

    init(_ root: LibraryRoot) {
        displayName = root.displayName
        kind = root.kind
    }
}

// MARK: - Same photo (ADR 0042)

/// The stored thumbnail a product read from it names — a render signature (ADR 0042), a
/// search embedding (ADR 0048) — by what makes it that image: its path, the edit revision it
/// was rendered with, the file signature it was rendered from (its rendering stamp, empty
/// for a provisional thumbnail), and — for a thumbnail a source drew (ADR 0046 §7) — that
/// source products' stamp, because a changed file gets new source products at the same
/// path. A product whose recorded identity no longer matches is stale.
nonisolated enum StoredThumbnailSQL {
    static func identity(_ row: String) -> String {
        """
        (\(row).thumbnail_path || '|' || \(row).rendered_revision || '|'
            || IFNULL(\(row).rendered_source_size, '') || '|' || IFNULL(\(row).rendered_source_mtime, '')
            || CASE WHEN \(isSourceDrawn(row))
                THEN '|source|' || \(row).source_products_size || '|' || IFNULL(\(row).source_products_mtime, '')
                ELSE '' END)
        """
    }

    /// Whether the shown thumbnail is a source's own (ADR 0046 §7): the source products
    /// are written and Otos has not rendered the original since.
    static func isSourceDrawn(_ row: String) -> String {
        "(\(row).rendered_source_size IS NULL AND \(row).source_products_size IS NOT NULL)"
    }
}

/// The render signature refresher's walk (ADR 0042): one root's stills whose thumbnail has no
/// current signature, in path order after a path, through the asset key
/// (`CandidateWalk.keyPage`; binds the root, the path, the limit).
nonisolated enum RenderSignatureSQL {
    static let candidatesSQL = """
    SELECT library_root_id, relative_path, thumbnail_path, \(StoredThumbnailSQL.identity("media_asset")) AS source
    FROM media_asset INDEXED BY sqlite_autoindex_media_asset_1
    WHERE library_root_id = ? AND relative_path > ?
      AND thumbnail_path IS NOT NULL
      AND kind IN ('image', 'raw')
      AND pending_trash_batch_unix_ms IS NULL
      AND trash_path IS NULL
      AND render_signature_source IS NOT \(StoredThumbnailSQL.identity("media_asset"))
    ORDER BY relative_path
    LIMIT ?
    """
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
    /// Who drew the thumbnail the signature was read from. A source's image and Otos's
    /// rendering of the same photo differ by more than the pixel threshold allows, so pairs
    /// never cross pipelines (ADR 0042, ADR 0046 §7).
    let drawnBy: EnrichedRendering.Origin
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
}

nonisolated extension DuplicatesGateway {
    /// A copy's pixel size as it is seen: the library's answer for the stored size and
    /// orientation (ADR 0039), so a portrait photo reads, and is laid out, as portrait.
    static func upright(width: Int?, height: Int?, orientation: Int?) -> PixelGeometry {
        PixelGeometry(
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation.flatMap(MediaMetadata.Orientation.init(rawValue:))
        )
    }

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
                   m.pixel_width, m.pixel_height, m.orientation, m.camera_model, m.serial_number,
                   \(StoredThumbnailSQL.isSourceDrawn("a"))
            FROM media_asset a
            LEFT JOIN asset_metadata m
              ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
            WHERE a.library_root_id IN (\(placeholders))
              AND a.kind IN ('image', 'raw')
              AND a.pending_trash_batch_unix_ms IS NULL
              AND a.trash_path IS NULL
              AND a.hidden_by_source = 0
              AND a.render_dhash IS NOT NULL
              AND a.render_signature_source = \(StoredThumbnailSQL.identity("a"))
            """,
            arguments: StatementArguments(rootIDs)
        )
        // Columns by position: this read covers every still, and a lookup by name per column
        // was a measurable share of a build (ADR 0043).
        enum Column {
            static let rootID = 0, relativePath = 1, kind = 2, captureInstant = 3, renderHash = 4
            static let pixelWidth = 5, pixelHeight = 6, orientation = 7, cameraModel = 8, serialNumber = 9
            static let isSourceDrawn = 10
        }
        var candidates: [SamePhotoCandidate] = []
        while let row = try rows.next() {
            guard let root = pathsByRowID[row[Column.rootID]] else {
                continue
            }
            let width: Double? = row[Column.pixelWidth]
            let height: Double? = row[Column.pixelHeight]
            // Orientations 5–8 turn the raster a quarter, so display width is stored height.
            let quarterTurned = (5 ... 8).contains(row[Column.orientation] as Int? ?? 1)
            let aspect: Double? = if let width, let height, width > 0, height > 0 {
                quarterTurned ? height / width : width / height
            } else {
                nil
            }
            let kind: String? = row[Column.kind]
            let hash: Int64 = row[Column.renderHash]
            candidates.append(SamePhotoCandidate(
                id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[Column.relativePath])),
                isRaw: kind == "raw",
                drawnBy: row[Column.isSourceDrawn] as Bool ? .source : .otos,
                captureInstant: row[Column.captureInstant],
                cameraModel: row[Column.cameraModel],
                serialNumber: row[Column.serialNumber],
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
        library: DuplicateLibrary,
        db: Database
    ) throws -> SamePhotoDetail? {
        let statement = try db.cachedStatement(sql: """
        SELECT a.best_kind, a.best_capture_local, a.byte_size, a.created_at_unix, a.media_choice,
               a.edit_recipe_json IS NOT NULL AS edited, a.render_dhash, a.render_gray,
               m.pixel_width, m.pixel_height, m.metadata_extra_json,
               EXISTS(
                   SELECT 1 FROM media_companion c
                   WHERE c.library_root_id = a.library_root_id AND c.primary_relative_path = a.relative_path
               ) AS has_companions,
               m.orientation
        FROM media_asset a
        LEFT JOIN asset_metadata m
          ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
        WHERE a.library_root_id = ? AND a.relative_path = ?
        """)
        // Columns by position: this statement runs once per still in a proposed pair, and
        // a lookup by name per column was a measurable share of a build (ADR 0043).
        enum Column {
            static let bestKind = 0, bestCapture = 1, byteSize = 2, createdAt = 3, mediaChoice = 4, edited = 5
            static let renderHash = 6, renderGray = 7, pixelWidth = 8, pixelHeight = 9, metadataExtra = 10
            static let hasCompanions = 11, orientation = 12
        }
        guard let row = try Row.fetchOne(statement, arguments: [rootID, id.relativePath.rawValue]),
              let hash = row[Column.renderHash] as Int64?,
              let gray = row[Column.renderGray] as Data?,
              let signature = RenderSignature(differenceHash: UInt64(bitPattern: hash), gray: Array(gray))
        else {
            return nil
        }
        // The stored record is the library's own report (ADR 0039); a record that does not
        // decode leaves its two facts unknown, which the rule treats as unknown.
        let metadata: AssetMetadata? = (row[Column.metadataExtra] as String?).flatMap { json in
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
        let mediaChoice: String? = row[Column.mediaChoice]
        let createdAt: Double? = row[Column.createdAt]
        let kind: String? = row[Column.bestKind]
        let captureLocal: Double? = row[Column.bestCapture]
        let geometry = Self.upright(width: row[Column.pixelWidth], height: row[Column.pixelHeight], orientation: row[Column.orientation])
        return SamePhotoDetail(
            copy: DuplicateCopy(
                id: id,
                libraryDisplayName: library.displayName, libraryKind: library.kind,
                kind: kind.flatMap(MediaKind.init(rawValue:)),
                captureLocalTime: captureLocal.map(CaptureLocalTime.init(seconds:)),
                byteSize: row[Column.byteSize],
                createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
                pixelWidth: geometry.displayPixelWidth,
                pixelHeight: geometry.displayPixelHeight,
                mediaChoice: mediaChoice.flatMap(MediaChoice.init(rawValue:)) ?? .default,
                isEdited: row[Column.edited],
                hasCompanions: row[Column.hasCompanions]
            ),
            signature: signature,
            fractionalSecondDigits: original?.fractionalSecondDigits
        )
    }
}
