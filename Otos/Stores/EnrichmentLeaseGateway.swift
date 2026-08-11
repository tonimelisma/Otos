import Foundation
import GRDB

/// Enrichment lease gateway guide
///
/// Cohesive claim/refresh/release SQL and `enrichment_claimed_until` lease policy
/// for enrichment scheduling. `CatalogStore` owns orchestration (DB writes, root
/// availability, diagnostics); this type groups the lease bookkeeping and
/// persistence helpers synchronously inside Store isolation — not a second actor.
nonisolated enum EnrichmentLeaseGateway {
    static let claimLeaseDuration: TimeInterval = 300

    /// Partial-index names for the claim queries' `INDEXED BY`. Two pairs (broad vs
    /// metadata-only) so a root that never hashes (`.removableVolume`) leaves the
    /// index as soon as its metadata is current, instead of staying pinned forever
    /// because `content_hash_xxh3_128 IS NULL` never becomes false. See ADR 0018.
    static let broadGlobalIndexName = "idx_media_asset_needs_enrichment_global"
    static let broadRootIndexName = "idx_media_asset_needs_enrichment_root"
    static let metadataOnlyGlobalIndexName = "idx_media_asset_needs_enrichment_global_metadata_only"
    static let metadataOnlyRootIndexName = "idx_media_asset_needs_enrichment_root_metadata_only"

    static func globalIndexName(hashRequired: Bool) -> String {
        hashRequired ? broadGlobalIndexName : metadataOnlyGlobalIndexName
    }

    static func rootIndexName(hashRequired: Bool) -> String {
        hashRequired ? broadRootIndexName : metadataOnlyRootIndexName
    }

    static func claimedUntil(from date: Date = Date()) -> TimeInterval {
        date.timeIntervalSince1970 + claimLeaseDuration
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
        isRootAvailable: (LibraryRootPath) -> Bool,
        isHashRequired: (LibraryRootPath) -> Bool
    ) -> [(asset: MediaAsset, rootID: Int64, hashRequired: Bool)] {
        var eligibleClaims: [(asset: MediaAsset, rootID: Int64, hashRequired: Bool)] = []
        eligibleClaims.reserveCapacity(ids.count)
        for id in ids {
            guard let asset = assetsByID[id],
                  isRootAvailable(asset.libraryRootPath),
                  let rootID = rootIDsByPath[asset.libraryRootPath]
            else {
                continue
            }
            let hashRequired = isHashRequired(asset.libraryRootPath)
            guard asset.needsEnrichment(hashRequired: hashRequired) else {
                continue
            }
            eligibleClaims.append((asset, rootID, hashRequired))
        }
        return eligibleClaims
    }

    static func metadataStalenessSQLPredicate() -> String {
        """
        enriched_source_size IS NULL
           OR enriched_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(enriched_source_mtime, -1)
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

    /// The Swift-side twin of `MediaAsset.needsEnrichment(hashRequired:)`. `hashRequired
    /// == false` yields the metadata-only predicate verbatim (not `OR FALSE`), so it
    /// stays byte-identical to the metadata-only partial index's `WHERE` clause —
    /// required for `INDEXED BY` to accept it (see `createEnrichmentClaimIndexes`).
    ///
    /// The `true` branch must also stay token-identical to the broad partial index's
    /// `WHERE` clause as migration v12 created it. SQLite's `INDEXED BY` partial-index
    /// implication check is syntactic: re-parenthesizing the same OR-clauses
    /// (`(A) OR (B)` in place of `A OR B`) is rejected with `no query solution` at
    /// prepare time even though it is logically equivalent, so a production catalog
    /// whose broad index was built by the pre-plan v12 migration would fail every
    /// hash-required claim query. Verified against SQLite 3.54.0.
    static func stalenessSQLPredicate(hashRequired: Bool) -> String {
        guard hashRequired else {
            return metadataStalenessSQLPredicate()
        }
        return """
        \(metadataStalenessSQLPredicate())
           OR \(hashStalenessSQLPredicate())
        """
    }

    static func fetchStoredAssetsNeedingEnrichment(
        rootIDs: [Int64],
        claimNotAfter: TimeInterval,
        limit: Int,
        hashRequired: Bool,
        db: Database
    ) throws -> [StoredAsset] {
        let now = Date().timeIntervalSince1970
        guard let query = enrichmentClaimQuery(
            rootIDs: rootIDs,
            now: now,
            claimNotAfter: claimNotAfter,
            limit: limit,
            hashRequired: hashRequired
        ) else {
            return []
        }
        let keys = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).map(enrichmentCandidateKey(from:))
        guard !keys.isEmpty else {
            return []
        }
        try claimStoredAssetsNeedingEnrichment(
            keys,
            now: now,
            claimedUntil: claimNotAfter,
            hashRequired: hashRequired,
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
        now: TimeInterval,
        claimNotAfter _: TimeInterval,
        limit: Int,
        hashRequired: Bool
    ) -> SQLQuery? {
        guard !rootIDs.isEmpty, limit > 0 else {
            return nil
        }
        if rootIDs.count == 1, let rootID = rootIDs.first {
            return rootEnrichmentClaimQuery(
                rootID: rootID,
                now: now,
                limit: limit,
                hashRequired: hashRequired
            )
        }

        return globalEnrichmentClaimQuery(
            rootIDs: rootIDs,
            now: now,
            limit: limit,
            hashRequired: hashRequired
        )
    }

    static func claimEnrichmentAsset(
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        claimedUntil: TimeInterval,
        hashRequired: Bool,
        db: Database
    ) throws -> Bool {
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
            UPDATE media_asset
            SET enrichment_claimed_until = ?
            WHERE library_root_id = ?
              AND relative_path = ?
              AND (\(stalenessSQLPredicate(hashRequired: hashRequired)))
              AND (
                enrichment_claimed_until IS NULL
                OR enrichment_claimed_until < ?
              )
            """,
            arguments: [claimedUntil, libraryRootID, relativePath.rawValue, now]
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
                SET enrichment_claimed_until = NULL
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
            SET enrichment_claimed_until = NULL
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
            SET enrichment_claimed_until = NULL
            WHERE enrichment_claimed_until IS NOT NULL
            """
        )
        return db.changesCount
    }

    static func refreshEnrichmentClaims(
        ids: [MediaAssetID],
        rootIDsByPath: [LibraryRootPath: Int64],
        claimedUntil: TimeInterval,
        db: Database
    ) throws {
        for id in ids {
            guard let rootID = rootIDsByPath[id.libraryRootPath] else {
                continue
            }
            try db.execute(
                sql: """
                UPDATE media_asset
                SET enrichment_claimed_until = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [claimedUntil, rootID, id.relativePath.rawValue]
            )
        }
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
    now: TimeInterval,
    limit: Int,
    hashRequired: Bool
) -> SQLQuery {
    let indexName = EnrichmentLeaseGateway.rootIndexName(hashRequired: hashRequired)
    return SQLQuery(
        sql: """
        SELECT library_root_id, relative_path
        FROM media_asset INDEXED BY \(indexName)
        WHERE library_root_id = ?
          AND (\(EnrichmentLeaseGateway.stalenessSQLPredicate(hashRequired: hashRequired)))
          AND (
            enrichment_claimed_until IS NULL
            OR enrichment_claimed_until < ?
          )
        ORDER BY best_capture_unix DESC, relative_path
        LIMIT ?
        """,
        arguments: sqlArguments(rootID, now, limit)
    )
}

private nonisolated func globalEnrichmentClaimQuery(
    rootIDs: [Int64],
    now: TimeInterval,
    limit: Int,
    hashRequired: Bool
) -> SQLQuery {
    let placeholders = sqlPlaceholders(count: rootIDs.count)
    var arguments = rootIDs.map { $0 as any DatabaseValueConvertible }
    arguments.append(now)
    arguments.append(limit)
    let indexName = EnrichmentLeaseGateway.globalIndexName(hashRequired: hashRequired)
    return SQLQuery(
        sql: """
        SELECT library_root_id, relative_path
        FROM media_asset INDEXED BY \(indexName)
        WHERE library_root_id IN (\(placeholders))
          AND (\(EnrichmentLeaseGateway.stalenessSQLPredicate(hashRequired: hashRequired)))
          AND (
            enrichment_claimed_until IS NULL
            OR enrichment_claimed_until < ?
          )
        ORDER BY best_capture_unix DESC, library_root_id, relative_path
        LIMIT ?
        """,
        arguments: StatementArguments(arguments)
    )
}

private nonisolated func claimStoredAssetsNeedingEnrichment(
    _ keys: [EnrichmentCandidateKey],
    now: TimeInterval,
    claimedUntil: TimeInterval,
    hashRequired: Bool,
    db: Database
) throws {
    guard !keys.isEmpty else {
        return
    }
    var arguments: [any DatabaseValueConvertible] = [claimedUntil]
    arguments.append(contentsOf: enrichmentCandidateKeyArguments(keys))
    arguments.append(now)
    try db.execute(
        sql: """
        UPDATE media_asset
        SET enrichment_claimed_until = ?
        WHERE (library_root_id, relative_path) IN (\(sqlTuplePlaceholders(rowCount: keys.count, columnCount: 2)))
          AND (\(EnrichmentLeaseGateway.stalenessSQLPredicate(hashRequired: hashRequired)))
          AND (
            enrichment_claimed_until IS NULL
            OR enrichment_claimed_until < ?
          )
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
               enriched_source_size, enriched_source_mtime,
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
        enrichedSourceSize: row["enriched_source_size"],
        enrichedSourceMTimeSeconds: row["enriched_source_mtime"],
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
