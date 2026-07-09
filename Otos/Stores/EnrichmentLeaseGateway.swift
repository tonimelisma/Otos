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
        isRootAvailable: (LibraryRootPath) -> Bool
    ) -> [(asset: MediaAsset, rootID: Int64)] {
        var eligibleClaims: [(asset: MediaAsset, rootID: Int64)] = []
        eligibleClaims.reserveCapacity(ids.count)
        for id in ids {
            guard let asset = assetsByID[id],
                  asset.needsEnrichment,
                  isRootAvailable(asset.libraryRootPath),
                  let rootID = rootIDsByPath[asset.libraryRootPath]
            else {
                continue
            }
            eligibleClaims.append((asset, rootID))
        }
        return eligibleClaims
    }

    static func stalenessSQLPredicate() -> String {
        """
        enriched_source_size IS NULL
           OR enriched_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(enriched_source_mtime, -1)
        """
    }

    static func fetchStoredAssetsNeedingEnrichment(
        rootIDs: [Int64],
        claimNotAfter: TimeInterval,
        limit: Int,
        db: Database
    ) throws -> [StoredAsset] {
        let now = Date().timeIntervalSince1970
        guard let query = enrichmentClaimQuery(
            rootIDs: rootIDs,
            now: now,
            claimNotAfter: claimNotAfter,
            limit: limit
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
        limit: Int
    ) -> SQLQuery? {
        guard !rootIDs.isEmpty, limit > 0 else {
            return nil
        }
        if rootIDs.count == 1, let rootID = rootIDs.first {
            return rootEnrichmentClaimQuery(
                rootID: rootID,
                now: now,
                limit: limit
            )
        }

        return globalEnrichmentClaimQuery(
            rootIDs: rootIDs,
            now: now,
            limit: limit
        )
    }

    static func claimEnrichmentAsset(
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        claimedUntil: TimeInterval,
        db: Database
    ) throws -> Bool {
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
            UPDATE media_asset
            SET enrichment_claimed_until = ?
            WHERE library_root_id = ?
              AND relative_path = ?
              AND (\(stalenessSQLPredicate()))
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
    limit: Int
) -> SQLQuery {
    SQLQuery(
        sql: """
        SELECT library_root_id, relative_path
        FROM media_asset INDEXED BY idx_media_asset_needs_enrichment_root
        WHERE library_root_id = ?
          AND (\(EnrichmentLeaseGateway.stalenessSQLPredicate()))
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
    limit: Int
) -> SQLQuery {
    let placeholders = sqlPlaceholders(count: rootIDs.count)
    var arguments = rootIDs.map { $0 as any DatabaseValueConvertible }
    arguments.append(now)
    arguments.append(limit)
    return SQLQuery(
        sql: """
        SELECT library_root_id, relative_path
        FROM media_asset INDEXED BY idx_media_asset_needs_enrichment_global
        WHERE library_root_id IN (\(placeholders))
          AND (\(EnrichmentLeaseGateway.stalenessSQLPredicate()))
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
          AND (\(EnrichmentLeaseGateway.stalenessSQLPredicate()))
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
               enriched_source_size, enriched_source_mtime, thumbnail_path,
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
        enrichedSourceMTimeSeconds: row["enriched_source_mtime"]
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
