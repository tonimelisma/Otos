import Foundation
import GRDB

/// Mirrors SQL (ADR 0054), run inside the Store's database access by `CatalogStore`'s
/// mirror intents, which an account's sync drives (`ImmichCatalogSync`).
///
/// An Immich external library that holds a library's files lists each one as an asset
/// whose checksum is the SHA-1 of `path:<its path on the server>`, never of its bytes. A
/// mirror (`immich_mirror`) is the server path a library's relative paths follow there, so
/// a library file's own path names its asset exactly: the asset whose path checksum is the
/// checksum of the server prefix plus the file's relative path. That is the pair
/// (`immich_mirror_pair`), a fact read from the listing alone: no byte of either file is
/// read and nothing is downloaded. The catalog's triggers make the pair's two rows one
/// photo while its versions agree (`media_asset.copy_key`, schema v79).
nonisolated enum MirrorGateway {
    /// A library file that may be one of the account's assets: an external library's asset
    /// with its name, size and modification time. Only the server's path for it can say.
    struct Candidate: Equatable, Sendable {
        let relativePath: MediaRelativePath
        let assetID: String
        let pathChecksum: ImmichPathChecksum
    }

    /// One library as an account's mirror discovery sees it: the server prefix learned for
    /// it, if any, whether any of its files is paired with one of the account's assets, and
    /// files that may be the account's assets.
    struct Probe: Equatable, Sendable {
        let libraryRootID: Int64
        let libraryRootPath: LibraryRootPath
        let serverPrefix: String?
        let isPaired: Bool
        let candidates: [Candidate]
    }

    /// Files a probe offers: enough to find the one asset that is not a same-named file from
    /// another folder, without asking the server for more than a few paths.
    static let candidateLimit = 3

    /// Library files a walk reads, and writes the pairs of, in one transaction: each pair
    /// that comes or goes regroups its photo's copies (about 0.7 ms on the owner's catalog),
    /// so a first pairing of a whole library never holds the writer for seconds.
    static let pairBatchSize = 500

    /// Library files of a root (second argument) with an external asset of an account (first)
    /// of the same name, size and whole-second mtime: each library row probes the account's
    /// size index. The join order is pinned (`CROSS JOIN`, the library outer): with no
    /// statistics SQLite chose the account as the outer loop, walking its 147,064 rows to
    /// probe the library, over 75 s on the owner's catalog against 0.16 s this way round
    /// (`docs/research/2026-11-16-plan-0116-due-diligence.md` §2).
    static let candidatesSQL = """
    SELECT library.relative_path, asset.source_item_id, asset.source_path_sha1
    FROM media_asset AS library INDEXED BY sqlite_autoindex_media_asset_1
    CROSS JOIN media_asset AS asset INDEXED BY idx_media_asset_size_root_asc
      ON asset.library_root_id = ?
     AND (asset.byte_size IS NULL) = 0
     AND asset.byte_size = library.byte_size
     AND asset.name = library.name
     AND CAST(asset.content_modified_at_unix AS INTEGER) = CAST(library.content_modified_at_unix AS INTEGER)
     AND asset.source_path_sha1 IS NOT NULL
     AND asset.source_item_id IS NOT NULL
    WHERE library.library_root_id = ? AND library.byte_size IS NOT NULL
    LIMIT \(candidateLimit)
    """

    static func candidates(libraryRootID: Int64, accountRootID: Int64, db: Database) throws -> [Candidate] {
        try Row.fetchAll(db, sql: candidatesSQL, arguments: [accountRootID, libraryRootID]).compactMap { row in
            guard let checksum = (row["source_path_sha1"] as Data?).flatMap(ImmichPathChecksum.init(data:)) else {
                return nil
            }
            return Candidate(
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                assetID: row["source_item_id"],
                pathChecksum: checksum
            )
        }
    }

    static func serverPrefix(accountRootID: Int64, libraryRootID: Int64, db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT server_prefix FROM immich_mirror WHERE account_root_id = ? AND library_root_id = ?",
            arguments: [accountRootID, libraryRootID]
        )
    }

    /// Whether any file of the library (first argument) is paired with an asset of the
    /// account (second): a seek of the pair table's key by library.
    static let isPairedSQL = """
    SELECT EXISTS (SELECT 1 FROM immich_mirror_pair WHERE library_root_id = ? AND account_root_id = ?)
    """

    static func isPaired(libraryRootID: Int64, accountRootID: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: isPairedSQL, arguments: [libraryRootID, accountRootID]) ?? false
    }

    static func record(accountRootID: Int64, libraryRootID: Int64, serverPrefix: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO immich_mirror (account_root_id, library_root_id, server_prefix) VALUES (?, ?, ?)
            ON CONFLICT (account_root_id, library_root_id) DO UPDATE SET server_prefix = excluded.server_prefix
            """,
            arguments: [accountRootID, libraryRootID, serverPrefix]
        )
    }

    /// The mirrors of `accountRootID`: each library its server holds and the prefix there.
    static func mirrors(ofAccount accountRootID: Int64, db: Database) throws -> [(libraryRootID: Int64, serverPrefix: String)] {
        try Row.fetchAll(
            db,
            sql: "SELECT library_root_id, server_prefix FROM immich_mirror WHERE account_root_id = ?",
            arguments: [accountRootID]
        ).map { row in (row["library_root_id"], row["server_prefix"]) }
    }

    /// A library's files after a path (both bound), in path order, a batch at a time: a walk
    /// of the table's key.
    static let filesSQL = """
    SELECT relative_path FROM media_asset INDEXED BY sqlite_autoindex_media_asset_1
    WHERE library_root_id = ? AND relative_path > ?
    ORDER BY relative_path
    LIMIT \(pairBatchSize)
    """

    /// The account's asset (first argument) at one path checksum (second): a seek of the
    /// path checksum's index.
    static let assetAtChecksumSQL = """
    SELECT relative_path FROM media_asset INDEXED BY idx_media_asset_source_path_sha1
    WHERE library_root_id = ? AND source_path_sha1 = ?
    """

    /// The pairs of a library's files in a range of paths (library, first and last path bound),
    /// with the account each names: a range of the pair table's key.
    static let pairsInRangeSQL = """
    SELECT file_path, account_root_id, asset_path FROM immich_mirror_pair
    WHERE library_root_id = ? AND file_path >= ? AND file_path <= ?
    """

    /// One file's pair as the walk finds it owed: the asset its path names now (nil for none),
    /// and the asset it is paired with in the account now (nil for none).
    struct OwedPair: Equatable, Sendable {
        let filePath: String
        let pairedAsset: String?
        let namedAsset: String?
    }

    /// One batch of a library's files as the walk reads it: how many files, the last path,
    /// and the files whose pair with `accountRootID` is not what their path names.
    struct Batch: Sendable {
        let count: Int
        let last: String?
        let owed: [OwedPair]
    }

    /// Reads the files of `libraryRootID` after `after`, a batch of them, and returns the ones
    /// whose pair with the account is owed: a file whose path names an asset it is not paired
    /// with, or paired with an asset its path no longer names. A file paired with another
    /// account's asset is that account's, and is left.
    static func owedPairs(
        libraryRootID: Int64,
        accountRootID: Int64,
        serverPrefix: String,
        after: String,
        db: Database
    ) throws -> Batch {
        let files = try String.fetchAll(db.cachedStatement(sql: filesSQL), arguments: [libraryRootID, after])
        guard let first = files.first, let last = files.last else {
            return Batch(count: 0, last: nil, owed: [])
        }
        var paired: [String: (account: Int64, asset: String)] = [:]
        for row in try Row.fetchAll(db.cachedStatement(sql: pairsInRangeSQL), arguments: [libraryRootID, first, last]) {
            paired[row[0]] = (row[1], row[2])
        }
        let named = try db.cachedStatement(sql: assetAtChecksumSQL)
        var owed: [OwedPair] = []
        for file in files {
            let existing = paired[file]
            if let existing, existing.account != accountRootID {
                continue
            }
            let checksum = ImmichPathChecksum(serverPath: serverPrefix + file)
            let asset = try String.fetchOne(named, arguments: [accountRootID, checksum.data])
            if asset != existing?.asset {
                owed.append(OwedPair(filePath: file, pairedAsset: existing?.asset, namedAsset: asset))
            }
        }
        return Batch(count: files.count, last: last, owed: owed)
    }

    static let unpairSQL = """
    DELETE FROM immich_mirror_pair
    WHERE library_root_id = ? AND file_path = ? AND account_root_id = ? AND asset_path = ?
    """

    /// Pairs a file with the account's asset its path names, under the write's own reading:
    /// both rows must still be there and the asset still at that checksum, and neither may
    /// be paired already.
    static let pairSQL = """
    INSERT OR IGNORE INTO immich_mirror_pair (library_root_id, file_path, account_root_id, asset_path)
    SELECT file.library_root_id, file.relative_path, asset.library_root_id, asset.relative_path
    FROM media_asset AS file, media_asset AS asset INDEXED BY idx_media_asset_source_path_sha1
    WHERE file.library_root_id = ? AND file.relative_path = ?
      AND asset.library_root_id = ? AND asset.source_path_sha1 = ? AND asset.relative_path = ?
    """

    /// Writes the owed pairs of one batch: a pair its file's path no longer names goes, and
    /// the pair its path names comes. Returns how many came and how many went.
    static func writePairs(
        _ owed: [OwedPair],
        libraryRootID: Int64,
        accountRootID: Int64,
        serverPrefix: String,
        db: Database
    ) throws -> (paired: Int, unpaired: Int) {
        let unpair = try db.cachedStatement(sql: unpairSQL)
        let pair = try db.cachedStatement(sql: pairSQL)
        var paired = 0
        var unpaired = 0
        for file in owed {
            if let asset = file.pairedAsset {
                try unpair.execute(arguments: [libraryRootID, file.filePath, accountRootID, asset])
                unpaired += db.changesCount
            }
            if let asset = file.namedAsset {
                let checksum = ImmichPathChecksum(serverPath: serverPrefix + file.filePath)
                try pair.execute(arguments: [libraryRootID, file.filePath, accountRootID, checksum.data, asset])
                paired += db.changesCount
            }
        }
        return (paired, unpaired)
    }

    /// Why a candidate's server path taught no prefix, for the probe's log: the server gave
    /// no path, its path does not end with the file's relative path (with how many of the
    /// relative path's trailing components it does end with), or the prefix it gives does
    /// not reproduce the asset's own checksum.
    enum Refusal: Error, Equatable, Sendable {
        case noPath
        case tailMismatch(sharedComponents: Int)
        case checksumMismatch

        var fields: [String: String] {
            switch self {
            case .noPath: ["reason": "noPath"]
            case let .tailMismatch(shared): ["reason": "tailMismatch", "sharedTailComponents": "\(shared)"]
            case .checksumMismatch: ["reason": "checksumMismatch"]
            }
        }
    }

    /// The prefix a candidate's server path teaches, or why it teaches none.
    static func prefix(of originalPath: String?, for candidate: Candidate) -> Result<String, Refusal> {
        guard let originalPath else {
            return .failure(.noPath)
        }
        guard let prefix = serverPrefix(of: originalPath, relativePath: candidate.relativePath) else {
            let server = originalPath.split(separator: "/", omittingEmptySubsequences: false).reversed()
            let local = candidate.relativePath.rawValue.split(separator: "/", omittingEmptySubsequences: false).reversed()
            let shared = zip(server, local).prefix { $0 == $1 }.count
            return .failure(.tailMismatch(sharedComponents: shared))
        }
        guard ImmichPathChecksum(serverPath: prefix + candidate.relativePath.rawValue) == candidate.pathChecksum else {
            return .failure(.checksumMismatch)
        }
        return .success(prefix)
    }

    /// The server prefix `originalPath` has before `relativePath`: the path up to and with
    /// the separator, compared as bytes, so a file name in another Unicode form is never
    /// taken as this one. Nil when the server's path does not end with the relative path.
    static func serverPrefix(of originalPath: String, relativePath: MediaRelativePath) -> String? {
        let path = Array(originalPath.utf8)
        let tail = Array("/\(relativePath.rawValue)".utf8)
        guard path.count > tail.count, path.suffix(tail.count).elementsEqual(tail) else {
            return nil
        }
        return String(decoding: path.dropLast(tail.count - 1), as: UTF8.self)
    }
}
