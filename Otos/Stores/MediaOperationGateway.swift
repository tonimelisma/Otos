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
        try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, kind, byte_size,
                   content_modified_at_unix, capture_wall_compact
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
            return PlanningFileFacts(
                id: MediaAssetID(libraryRootPath: sourceRoot, relativePath: relative),
                sourceURL: sourceRoot.url.appending(path: relative.rawValue, directoryHint: .notDirectory),
                relativePath: relative,
                byteSize: row["byte_size"],
                contentModifiedAt: modified.map(Date.init(timeIntervalSince1970:)),
                captureWallCompact: row["capture_wall_compact"],
                mediaKind: kindRaw.flatMap(MediaKind.init(rawValue:)),
                fileExtension: ext,
                companions: companionsByPrimary[relative.rawValue] ?? []
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
