import Foundation
import GRDB

/// Media operation gateway guide
///
/// Pure SQL/mapping helpers for import planning snapshots. `CatalogStore` owns
/// orchestration and revision state; this type groups planning reads
/// synchronously inside Store isolation — not a second actor.
nonisolated enum MediaOperationGateway {
    static func fetchPlanningSourceMedia(
        libraryRootID: Int64,
        sourceRoot: LibraryRootPath,
        companionsByPrimary: [String: [MediaCompanion]],
        db: Database
    ) throws -> [PlanningFileFacts] {
        let settledPredicate = EnrichmentLeaseGateway.metadataStalenessSQLPredicate()
        return try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, kind, content_type_identifier, byte_size,
                   content_modified_at_unix, capture_wall_compact,
                   enriched_source_size, enriched_source_mtime,
                   NOT (\(settledPredicate)) AS naming_settled
            FROM media_asset
            WHERE library_root_id = ?
            ORDER BY relative_path COLLATE NOCASE, relative_path
            """,
            arguments: [libraryRootID]
        ).map { row in
            let relative = MediaRelativePath(rawValue: row["relative_path"])
            let modified: Double? = row["content_modified_at_unix"]
            let kindRaw: String? = row["kind"]
            let ext = URL(fileURLWithPath: relative.rawValue).pathExtension
            // `naming_settled` is `NOT metadataStalenessSQLPredicate()`, which answers
            // "should enrichment run again for these file facts?". The naming question
            // is a different one — "do we know enough to name this file?" — and must not
            // borrow that answer wholesale. They diverge on a state the domain admits
            // (`PlanningFileFacts.hasAnyDate` models it): an asset with no
            // `content_modified_at_unix` can never satisfy the staleness predicate's
            // `enriched_source_mtime` comparison, so it stays "stale" forever even after
            // enrichment has supplied its capture wall. Deriving `.pending` from that
            // held such a source in `.waitingForMetadata` permanently.
            let captureWall: Int64? = row["capture_wall_compact"]
            let namingFactState: NamingFactState = if ((row["naming_settled"] as Int?) ?? 0) != 0 {
                .settled
            } else if captureWall != nil || modified != nil {
                // Terminal, not settled: enrichment is still free to add overlay, but
                // nothing it can add improves this *name*. A known capture wall is the
                // naming fact itself; a durable filesystem mtime is the fallback when
                // no embedded fact exists. Planning proceeds on either.
                .terminal
            } else {
                .pending
            }
            return PlanningFileFacts(
                id: MediaAssetID(libraryRootPath: sourceRoot, relativePath: relative),
                sourceURL: sourceRoot.url.appending(path: relative.rawValue, directoryHint: .notDirectory),
                relativePath: relative,
                byteSize: row["byte_size"],
                contentModifiedAt: modified.map(Date.init(timeIntervalSince1970:)),
                captureWallCompact: captureWall,
                namingFactState: namingFactState,
                mediaKind: kindRaw.flatMap(MediaKind.init(rawValue:)),
                fileExtension: ext,
                companions: companionsByPrimary[relative.rawValue] ?? [],
                contentTypeIdentifier: row["content_type_identifier"]
            )
        }
    }

    static func fetchDestinationOccupants(
        libraryRootID: Int64,
        db: Database
    ) throws -> [MediaRelativePath: DestinationOccupantFacts] {
        var occupants: [MediaRelativePath: DestinationOccupantFacts] = [:]
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, byte_size, content_modified_at_unix
            FROM media_asset
            WHERE library_root_id = ?
            """,
            arguments: [libraryRootID]
        )
        for row in rows {
            let relative = MediaRelativePath(rawValue: row["relative_path"])
            let modified: Double? = row["content_modified_at_unix"]
            occupants[relative] = DestinationOccupantFacts(
                relativePath: relative,
                byteSize: row["byte_size"],
                contentModifiedAt: modified.map(Date.init(timeIntervalSince1970:))
            )
        }
        return occupants
    }
}
