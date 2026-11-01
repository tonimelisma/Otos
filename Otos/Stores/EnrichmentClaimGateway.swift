import Foundation
import GRDB

/// Enrichment claim gateway guide
///
/// Cohesive claim/release SQL over `enrichment_claimed` for enrichment scheduling.
/// `CatalogStore` owns orchestration (DB writes, root availability, diagnostics); this
/// type groups the claim bookkeeping and persistence helpers synchronously inside Store
/// isolation — not a second actor.
///
/// A claim is a process fact, not a lease: it holds until its owner releases it or the
/// process that took it ends, and `CatalogStore` clears every claim when it loads the
/// catalog, which is the one point where the previous owner is known to be gone. No
/// expiry stands in for "the claimant is still alive".
nonisolated enum EnrichmentClaimGateway {
    /// Partial-index names for the claim queries' `INDEXED BY`. Two pairs: every product
    /// (metadata, rendering, digest) for a root whose rows are read for all of them at once,
    /// and metadata-only for a card's first pass and a camera, which leave that index as
    /// soon as their metadata is current. See ADR 0009 and ADR 0018.
    static let broadGlobalIndexName = "idx_media_asset_needs_enrichment_global"
    static let broadRootIndexName = "idx_media_asset_needs_enrichment_root"
    static let metadataOnlyGlobalIndexName = "idx_media_asset_needs_enrichment_global_metadata_only"
    static let metadataOnlyRootIndexName = "idx_media_asset_needs_enrichment_root_metadata_only"

    static func globalIndexName(everyProduct: Bool) -> String {
        everyProduct ? broadGlobalIndexName : metadataOnlyGlobalIndexName
    }

    static func rootIndexName(everyProduct: Bool) -> String {
        everyProduct ? broadRootIndexName : metadataOnlyRootIndexName
    }

    static func unclaimedPriorityIDs(
        _ priorityIDs: [MediaAssetID],
        claimedIDs: inout Set<MediaAssetID>
    ) -> [MediaAssetID] {
        priorityIDs.reduce(into: [MediaAssetID]()) { result, id in
            guard !claimedIDs.contains(id) else {
                return
            }
            claimedIDs.insert(id)
            result.append(id)
        }
    }

    static func priorityClaimInputs(
        ids: [MediaAssetID],
        assetsByID: [MediaAssetID: MediaAsset],
        rootIDsByPath: [LibraryRootPath: Int64],
        isRootEnrichable: (LibraryRootPath) -> Bool,
        claimsEveryProduct: (LibraryRootPath) -> Bool
    ) -> [(asset: MediaAsset, rootID: Int64, everyProduct: Bool)] {
        var eligibleClaims: [(asset: MediaAsset, rootID: Int64, everyProduct: Bool)] = []
        eligibleClaims.reserveCapacity(ids.count)
        for id in ids {
            guard let asset = assetsByID[id],
                  isRootEnrichable(asset.libraryRootPath),
                  let rootID = rootIDsByPath[asset.libraryRootPath]
            else {
                continue
            }
            let everyProduct = claimsEveryProduct(asset.libraryRootPath)
            guard asset.needsEnrichment(everyProduct: everyProduct) else {
                continue
            }
            eligibleClaims.append((asset, rootID, everyProduct))
        }
        return eligibleClaims
    }

    static func metadataStalenessSQLPredicate() -> String {
        """
        metadata_source_size IS NULL
           OR metadata_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(metadata_source_mtime, -1)
        """
    }

    /// The rendering (thumbnail and preview, ADR 0035) was made from bytes other than the
    /// current `(size, mtime)`, or never. Its own stamp, so a row's metadata can be current
    /// while its rendering is still owed (a card's first pass, a camera, an edit).
    static func renderingStalenessSQLPredicate() -> String {
        """
        rendered_source_size IS NULL
           OR rendered_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(rendered_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(rendered_source_mtime, -1)
        """
    }

    static func hashStalenessSQLPredicate() -> String {
        """
        content_hash_xxh3_128 IS NULL
           OR length(content_hash_xxh3_128) <> 16
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)
        """
    }

    /// The Swift-side twin of `MediaAsset.needsEnrichment(everyProduct:)`, and the `WHERE`
    /// clause of the claim indexes `CatalogSchema` creates from it. `everyProduct == false`
    /// yields the metadata-only predicate verbatim (not `OR FALSE`).
    ///
    /// The claim queries and the indexes share this one text because SQLite's `INDEXED
    /// BY` partial-index implication check is syntactic: re-parenthesizing the same
    /// OR-clauses (`(A) OR (B)` in place of `A OR B`) is rejected with `no query solution`
    /// at prepare time even though it is logically equivalent. Verified against SQLite
    /// 3.54.0.
    static func stalenessSQLPredicate(everyProduct: Bool) -> String {
        guard everyProduct else {
            return metadataStalenessSQLPredicate()
        }
        return """
        \(metadataStalenessSQLPredicate())
           OR \(renderingStalenessSQLPredicate())
           OR \(hashStalenessSQLPredicate())
        """
    }

    /// Whether any row of this root still needs its metadata — claimed or not, so a row in
    /// flight still counts. Through the metadata-only root index.
    static func hasRowsNeedingMetadata(rootID: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM media_asset INDEXED BY \(metadataOnlyRootIndexName)
                WHERE library_root_id = ?
                  AND (\(stalenessSQLPredicate(everyProduct: false)))
                  AND trash_path IS NULL
            )
            """,
            arguments: [rootID]
        ) ?? false
    }

    static func fetchStoredAssetsNeedingEnrichment(
        rootIDs: [Int64],
        limit: Int,
        everyProduct: Bool,
        db: Database
    ) throws -> [StoredAsset] {
        guard let query = enrichmentClaimQuery(
            rootIDs: rootIDs,
            limit: limit,
            everyProduct: everyProduct
        ) else {
            return []
        }
        let keys = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).map(enrichmentCandidateKey(from:))
        guard !keys.isEmpty else {
            return []
        }
        try claimStoredAssetsNeedingEnrichment(
            keys,
            everyProduct: everyProduct,
            db: db
        )
        let assets = try fetchStoredAssetsForEnrichmentCandidates(keys, db: db)
        let assetsByKey = Dictionary(uniqueKeysWithValues: assets.map { asset in
            (EnrichmentCandidateKey(libraryRootID: asset.libraryRootID, relativePath: asset.relativePath), asset)
        })
        return keys.compactMap { assetsByKey[$0] }
    }

    static func enrichmentClaimQuery(
        rootIDs: [Int64],
        limit: Int,
        everyProduct: Bool
    ) -> SQLQuery? {
        guard !rootIDs.isEmpty, limit > 0 else {
            return nil
        }
        if rootIDs.count == 1, let rootID = rootIDs.first {
            return rootEnrichmentClaimQuery(
                rootID: rootID,
                limit: limit,
                everyProduct: everyProduct
            )
        }

        return globalEnrichmentClaimQuery(
            rootIDs: rootIDs,
            limit: limit,
            everyProduct: everyProduct
        )
    }

    static func claimEnrichmentAsset(
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        everyProduct: Bool,
        db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
            UPDATE media_asset
            SET enrichment_claimed = 1
            WHERE library_root_id = ?
              AND relative_path = ?
              AND (\(stalenessSQLPredicate(everyProduct: everyProduct)))
              AND enrichment_claimed IS NULL
              AND trash_path IS NULL
            """,
            arguments: [libraryRootID, relativePath.rawValue]
        )
        return db.changesCount > 0
    }

    static func releaseEnrichmentClaims(
        ids: [MediaAssetID],
        rootIDsByPath: [LibraryRootPath: Int64],
        db: Database
    ) throws {
        for id in ids {
            guard let rootID = rootIDsByPath[id.libraryRootPath] else {
                continue
            }
            try db.execute(
                sql: """
                UPDATE media_asset
                SET enrichment_claimed = NULL
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [rootID, id.relativePath.rawValue]
            )
        }
    }

    static func releaseEnrichmentClaims(rootID: Int64, db: Database) throws {
        try db.execute(
            sql: """
            UPDATE media_asset
            SET enrichment_claimed = NULL
            WHERE library_root_id = ?
            """,
            arguments: [rootID]
        )
    }

    @discardableResult
    static func clearEnrichmentClaims(db: Database) throws -> Int {
        try db.execute(
            sql: """
            UPDATE media_asset
            SET enrichment_claimed = NULL
            WHERE enrichment_claimed IS NOT NULL
            """
        )
        return db.changesCount
    }
}

private nonisolated struct EnrichmentCandidateKey: Hashable {
    let libraryRootID: Int64
    let relativePath: MediaRelativePath
}

private nonisolated func enrichmentCandidateKey(from row: Row) -> EnrichmentCandidateKey {
    EnrichmentCandidateKey(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"])
    )
}

private nonisolated func rootEnrichmentClaimQuery(
    rootID: Int64,
    limit: Int,
    everyProduct: Bool
) -> SQLQuery {
    let indexName = EnrichmentClaimGateway.rootIndexName(everyProduct: everyProduct)
    return SQLQuery(
        sql: """
        SELECT library_root_id, relative_path
        FROM media_asset INDEXED BY \(indexName)
        WHERE library_root_id = ?
          AND (\(EnrichmentClaimGateway.stalenessSQLPredicate(everyProduct: everyProduct)))
          AND enrichment_claimed IS NULL
          AND trash_path IS NULL
        ORDER BY best_capture_unix DESC, relative_path
        LIMIT ?
        """,
        arguments: sqlArguments(rootID, limit)
    )
}

private nonisolated func globalEnrichmentClaimQuery(
    rootIDs: [Int64],
    limit: Int,
    everyProduct: Bool
) -> SQLQuery {
    let placeholders = sqlPlaceholders(count: rootIDs.count)
    var arguments = rootIDs.map { $0 as any DatabaseValueConvertible }
    arguments.append(limit)
    let indexName = EnrichmentClaimGateway.globalIndexName(everyProduct: everyProduct)
    return SQLQuery(
        sql: """
        SELECT library_root_id, relative_path
        FROM media_asset INDEXED BY \(indexName)
        WHERE library_root_id IN (\(placeholders))
          AND (\(EnrichmentClaimGateway.stalenessSQLPredicate(everyProduct: everyProduct)))
          AND enrichment_claimed IS NULL
          AND trash_path IS NULL
        ORDER BY best_capture_unix DESC, library_root_id, relative_path
        LIMIT ?
        """,
        arguments: StatementArguments(arguments)
    )
}

private nonisolated func claimStoredAssetsNeedingEnrichment(
    _ keys: [EnrichmentCandidateKey],
    everyProduct: Bool,
    db: Database
) throws {
    guard !keys.isEmpty else {
        return
    }
    let arguments: [any DatabaseValueConvertible] = enrichmentCandidateKeyArguments(keys)
    try db.execute(
        sql: """
        UPDATE media_asset
        SET enrichment_claimed = 1
        WHERE (library_root_id, relative_path) IN (\(sqlTuplePlaceholders(rowCount: keys.count, columnCount: 2)))
          AND (\(EnrichmentClaimGateway.stalenessSQLPredicate(everyProduct: everyProduct)))
          AND enrichment_claimed IS NULL
          AND trash_path IS NULL
        """,
        arguments: StatementArguments(arguments)
    )
}

private nonisolated func fetchStoredAssetsForEnrichmentCandidates(
    _ keys: [EnrichmentCandidateKey],
    db: Database
) throws -> [StoredAsset] {
    guard !keys.isEmpty else {
        return []
    }
    return try Row.fetchAll(
        db,
        sql: """
        SELECT library_root_id, relative_path, name, content_type_identifier, byte_size,
               created_at_unix, content_modified_at_unix,
               metadata_source_size, metadata_source_mtime, rendered_source_size, rendered_source_mtime,
               content_hash_xxh3_128, content_hash_source_size, content_hash_source_mtime,
               thumbnail_path,
               duration_seconds,
               best_capture_unix, best_kind, best_format
        FROM media_asset
        WHERE (library_root_id, relative_path) IN (\(sqlTuplePlaceholders(rowCount: keys.count, columnCount: 2)))
        """,
        arguments: StatementArguments(enrichmentCandidateKeyArguments(keys))
    ).map(enrichmentCandidateStoredAsset(from:))
}

private nonisolated func enrichmentCandidateStoredAsset(from row: Row) -> StoredAsset {
    let createdUnix: Double? = row["created_at_unix"]
    let modifiedUnix: Double? = row["content_modified_at_unix"]
    let bestCaptureUnix: Double? = row["best_capture_unix"]
    let bestKindRaw: String? = row["best_kind"]
    let bestFormatRaw: String? = row["best_format"]
    return StoredAsset(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"]),
        name: row["name"],
        contentTypeIdentifier: row["content_type_identifier"],
        byteSize: row["byte_size"],
        createdAt: createdUnix.map(Date.init(timeIntervalSince1970:)),
        contentModifiedAt: modifiedUnix.map(Date.init(timeIntervalSince1970:)),
        thumbnailPath: row["thumbnail_path"],
        bestCaptureDate: bestCaptureUnix.map(Date.init(timeIntervalSince1970:)),
        bestKind: bestKindRaw.flatMap(MediaKind.init(rawValue:)),
        bestFormat: bestFormatRaw.map(MediaFormatToken.init(rawValue:)),
        durationSeconds: row["duration_seconds"],
        metadataSourceSize: row["metadata_source_size"],
        metadataSourceMTimeSeconds: row["metadata_source_mtime"],
        renderedSourceSize: row["rendered_source_size"],
        renderedSourceMTimeSeconds: row["rendered_source_mtime"],
        contentHash: (row["content_hash_xxh3_128"] as Data?).flatMap(XXH3Digest128.init(data:)),
        contentHashSourceSize: row["content_hash_source_size"],
        contentHashSourceMTimeSeconds: row["content_hash_source_mtime"]
    )
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

private nonisolated func enrichmentCandidateKeyArguments(
    _ keys: [EnrichmentCandidateKey]
) -> [any DatabaseValueConvertible] {
    keys.flatMap { key in
        [key.libraryRootID, key.relativePath.rawValue] as [any DatabaseValueConvertible]
    }
}
