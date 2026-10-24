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
        unreadableSourceIDs: Set<MediaAssetID> = [],
        db: Database
    ) throws -> [PlanningFileFacts] {
        let settledPredicate = EnrichmentClaimGateway.metadataStalenessSQLPredicate()
        return try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, kind, content_type_identifier, byte_size,
                   content_modified_at_unix, capture_wall_compact, capture_wall_precision,
                   enriched_source_size, enriched_source_mtime,
                   NOT (\(settledPredicate)) AS naming_settled,
                   (enriched_source_size IS NOT NULL
                    AND enriched_source_mtime IS NOT NULL) AS enrichment_has_looked
            FROM media_asset
            WHERE library_root_id = ?
            ORDER BY relative_path COLLATE NOCASE, relative_path
            """,
            arguments: [libraryRootID]
        ).map { row in
            let relative = MediaRelativePath(rawValue: row["relative_path"])
            let modified: Double? = row["content_modified_at_unix"]
            let kindRaw: String? = row["kind"]
            let ext = relative.fileExtension
            // `naming_settled` is `NOT metadataStalenessSQLPredicate()`, which answers
            // "should enrichment run again for these file facts?". The naming question
            // is a different one — "do we know enough to name this file?" — and must not
            // borrow that answer wholesale. They diverge on a state the domain admits:
            // an asset with no `content_modified_at_unix` can never satisfy the staleness
            // predicate's `enriched_source_mtime` comparison, so it stays "stale" forever
            // even after enrichment has supplied its capture wall. Deriving `.pending`
            // from that held such a source in `.waitingForMetadata` permanently.
            let captureWall: Int64? = row["capture_wall_compact"]
            let enrichmentHasLooked = ((row["enrichment_has_looked"] as Int?) ?? 0) != 0
            let namingFactState: NamingFactState = if ((row["naming_settled"] as Int?) ?? 0) != 0 {
                .settled
            } else if captureWall != nil {
                // The naming fact itself. Terminal whatever else is outstanding — this is
                // the state ADR 0026 protects, where a row enrichment can never mark
                // current would otherwise wait forever.
                .terminal
            } else if enrichmentHasLooked {
                // Enrichment ran and found no embedded capture wall, so the filesystem
                // mtime is the honest fallback — a *proven* absence, not an assumed one.
                .terminal
            } else {
                // Not yet looked at. "No capture wall" here means "we have not read the
                // file", not "the file has none", so naming from mtime would fabricate a
                // fact. For video that fabrication is provably wrong by the clip's own
                // duration (mtime is when recording stopped), and because the destination
                // name is also the dedupe key, the next plan computes a different name,
                // finds nothing there, and copies again. Field evidence: 23 videos
                // imported twice, five minutes apart, each pair named apart by its own
                // duration.
                .pending
            }
            let assetID = MediaAssetID(libraryRootPath: sourceRoot, relativePath: relative)
            return PlanningFileFacts(
                id: assetID,
                sourceURL: sourceRoot.url.appending(path: relative.rawValue, directoryHint: .notDirectory),
                relativePath: relative,
                byteSize: row["byte_size"],
                contentModifiedAt: modified.map(Date.init(timeIntervalSince1970:)),
                captureWallCompact: captureWall,
                captureWallPrecision: row["capture_wall_precision"],
                namingFactState: namingFactState,
                isSourceUnreadable: unreadableSourceIDs.contains(assetID),
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
