import Foundation
import GRDB

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
        let digest: XXH3Digest128
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
            guard let root = pathsByRowID[rootID], let name = namesByPath[root] else {
                return nil
            }
            return DuplicateCopyFacts(
                copy: DuplicateCopy(
                    id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: relativePath)),
                    libraryDisplayName: name,
                    byteSize: byteSize,
                    createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    mediaChoice: mediaChoice.flatMap(MediaChoice.init(rawValue:)) ?? .default,
                    isEdited: isEdited,
                    hasCompanions: hasCompanions
                ),
                digest: digest
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

    /// A row counts when it is visible and its digest is current for its file.
    private static func visibleCurrentPredicate(_ row: String) -> String {
        """
        \(row).pending_trash_batch_unix_ms IS NULL
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
