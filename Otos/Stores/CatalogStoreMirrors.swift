import Foundation
import GRDB

/// Mirrors SQL (ADR 0054), run inside the Store's database access by `CatalogStore`'s
/// mirror intents, which an account's sync drives (`ImmichCatalogSync`).
///
/// An Immich external library that holds a library's files lists each one as an asset
/// whose checksum is the SHA-1 of `path:<its path on the server>`, never of its bytes. A
/// mirror (`immich_mirror`) is a server prefix a library's relative paths follow there; a
/// server can hold one library under several prefixes, so a library has a set of them. A
/// library file's own path names its asset exactly: the asset whose path checksum is the
/// checksum of one of the prefixes plus the file's relative path, in either Unicode normal
/// form (`ImmichPathChecksum.everyForm`). That is the pair (`immich_mirror_pair`), a fact
/// read from the listing alone: no byte of either file is read and nothing is downloaded.
/// The catalog's triggers make the pair's two rows one photo while its versions agree
/// (`media_asset.copy_key`, schema v79 and v80).
nonisolated enum MirrorGateway {
    /// A library file no prefix pairs that may be one of the account's assets: an external
    /// library's asset with its name, size and modification time, neither paired, and not
    /// asked about before at the asset's path. Only the server's path for it can say.
    struct Candidate: Equatable, Sendable {
        let relativePath: MediaRelativePath
        let assetPath: MediaRelativePath
        let assetID: String
        let pathChecksum: ImmichPathChecksum
    }

    /// One library as an account's mirror discovery sees it: the server prefixes learned for
    /// it, in order, and the first file none of them explains that may be an account's asset.
    struct Probe: Equatable, Sendable {
        let libraryRootID: Int64
        let libraryRootPath: LibraryRootPath
        let serverPrefixes: [String]
        let candidate: Candidate?
    }

    /// Library files a walk reads, and writes the pairs of, in one transaction: each pair
    /// that comes or goes regroups its photo's copies (about 0.7 ms on the owner's catalog),
    /// so a first pairing of a whole library never holds the writer for seconds.
    static let pairBatchSize = 500

    /// The first library file of a root (second argument) with an external asset of an
    /// account (first) of the same name, size and whole-second mtime, where neither row is
    /// paired and the server's path for the asset was not read for this file at the asset's
    /// path checksum: each unpaired library row probes the account's size index. The join
    /// order is pinned (`CROSS JOIN`, the library outer): with no statistics SQLite chose the
    /// account as the outer loop, walking its 147,064 rows to probe the library, over 75 s on
    /// the owner's catalog against 0.16 s this way round
    /// (`docs/research/2026-11-16-plan-0116-due-diligence.md` §2).
    static let candidateSQL = """
    SELECT library.relative_path, asset.relative_path, asset.source_item_id, asset.source_path_sha1
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
      AND NOT EXISTS (
          SELECT 1 FROM immich_mirror_pair AS p
          WHERE p.library_root_id = library.library_root_id AND p.file_path = library.relative_path
      )
      AND NOT EXISTS (
          SELECT 1 FROM immich_mirror_pair AS p
          WHERE p.account_root_id = asset.library_root_id AND p.asset_path = asset.relative_path
      )
      AND NOT EXISTS (
          SELECT 1 FROM immich_mirror_asked AS q
          WHERE q.library_root_id = library.library_root_id AND q.file_path = library.relative_path
            AND q.account_root_id = asset.library_root_id AND q.asset_path = asset.relative_path
            AND q.asset_path_sha1 = asset.source_path_sha1
      )
    LIMIT 1
    """

    static func candidate(libraryRootID: Int64, accountRootID: Int64, db: Database) throws -> Candidate? {
        try Row.fetchAll(db, sql: candidateSQL, arguments: [accountRootID, libraryRootID]).lazy.compactMap { row in
            guard let checksum = (row[3] as Data?).flatMap(ImmichPathChecksum.init(data:)) else {
                return nil
            }
            return Candidate(
                relativePath: MediaRelativePath(rawValue: row[0]),
                assetPath: MediaRelativePath(rawValue: row[1]),
                assetID: row[2],
                pathChecksum: checksum
            )
        }.first
    }

    /// The prefixes of the library (second argument) on the account's server (first), in
    /// the order a walk tries them: a seek of the mirror table's key.
    static let serverPrefixesSQL = """
    SELECT server_prefix FROM immich_mirror
    WHERE account_root_id = ? AND library_root_id = ?
    ORDER BY server_prefix
    """

    static func serverPrefixes(accountRootID: Int64, libraryRootID: Int64, db: Database) throws -> [String] {
        try String.fetchAll(db, sql: serverPrefixesSQL, arguments: [accountRootID, libraryRootID])
    }

    /// Adds a prefix to the library's set; one already there is left.
    static func record(accountRootID: Int64, libraryRootID: Int64, serverPrefix: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO immich_mirror (account_root_id, library_root_id, server_prefix) VALUES (?, ?, ?)
            """,
            arguments: [accountRootID, libraryRootID, serverPrefix]
        )
    }

    /// Remembers that the server's path for a candidate's asset taught no new prefix, at the
    /// asset's path checksum then, while both rows are still at their paths; returns whether
    /// it was written.
    static let recordAskedSQL = """
    INSERT OR REPLACE INTO immich_mirror_asked (library_root_id, file_path, account_root_id, asset_path, asset_path_sha1)
    SELECT file.library_root_id, file.relative_path, asset.library_root_id, asset.relative_path, asset.source_path_sha1
    FROM media_asset AS file, media_asset AS asset
    WHERE \(AssetKey.exactText("file"))
      AND \(AssetKey.exactText("asset")) AND asset.source_path_sha1 = ?
    """

    static func recordAsked(_ candidate: Candidate, libraryRootID: Int64, accountRootID: Int64, db: Database) throws -> Bool {
        try db.execute(
            sql: recordAskedSQL,
            arguments: AssetKey(rootID: libraryRootID, path: candidate.relativePath).arguments
                + AssetKey(rootID: accountRootID, path: candidate.assetPath).arguments
                + [candidate.pathChecksum.data]
        )
        return db.changesCount > 0
    }

    /// The mirrors of `accountRootID`: each library its server holds and its prefixes there,
    /// in the order a walk tries them.
    static func mirrors(ofAccount accountRootID: Int64, db: Database) throws -> [(libraryRootID: Int64, serverPrefixes: [String])] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT library_root_id, server_prefix FROM immich_mirror WHERE account_root_id = ? ORDER BY library_root_id, server_prefix",
            arguments: [accountRootID]
        )
        var mirrors: [(libraryRootID: Int64, serverPrefixes: [String])] = []
        for row in rows {
            let library: Int64 = row[0]
            if mirrors.last?.libraryRootID == library {
                mirrors[mirrors.count - 1].serverPrefixes.append(row[1])
            } else {
                mirrors.append((library, [row[1]]))
            }
        }
        return mirrors
    }

    /// A library's files after a path (both bound), in path order, a batch at a time: a walk
    /// of the table's key.
    static let filesSQL = """
    SELECT relative_path FROM media_asset INDEXED BY sqlite_autoindex_media_asset_1
    WHERE library_root_id = ? AND relative_path > ?
    ORDER BY relative_path
    LIMIT \(pairBatchSize)
    """

    /// The account's asset (first argument) at one path checksum (second) that no file is
    /// paired with: a seek of the path checksum's index, and of the pair table's asset key.
    static let freeAssetAtChecksumSQL = """
    SELECT relative_path FROM media_asset INDEXED BY idx_media_asset_source_path_sha1
    WHERE library_root_id = ? AND source_path_sha1 = ?
      AND NOT EXISTS (
          SELECT 1 FROM immich_mirror_pair AS p
          WHERE p.account_root_id = media_asset.library_root_id AND p.asset_path = media_asset.relative_path
      )
    """

    /// The pairs of a library's files in a range of paths (library, first and last path bound),
    /// with the account each names and its asset's path checksum: a range of the pair table's
    /// key, and a seek of each asset.
    static let pairsInRangeSQL = """
    SELECT p.file_path, p.account_root_id, p.asset_path, a.source_path_sha1 FROM immich_mirror_pair AS p
    JOIN media_asset AS a ON a.library_root_id = p.account_root_id AND a.relative_path = p.asset_path
    WHERE p.library_root_id = ? AND p.file_path >= ? AND p.file_path <= ?
    """

    /// One file's pair as the walk finds it owed: the asset it is paired with in the account
    /// now (nil for none), and the free asset its path names now with the checksum that names
    /// it (nil for none).
    struct OwedPair: Equatable, Sendable {
        let filePath: String
        let pairedAsset: String?
        let named: NamedAsset?
    }

    /// The asset a file's path names, and the checksum of the form that names it.
    struct NamedAsset: Equatable, Sendable {
        let asset: String
        let checksum: ImmichPathChecksum
    }

    /// One batch of a library's files as the walk reads it: how many files, the last path,
    /// and the files whose pair with `accountRootID` is not what their path names.
    struct Batch: Sendable {
        let count: Int
        let last: String?
        let owed: [OwedPair]
    }

    /// Reads the files of `libraryRootID` after `after`, a batch of them, and returns the ones
    /// whose pair with the account is owed. A file paired with an asset its path names under
    /// any of `serverPrefixes` stands, with no seek: the asset's own checksum is among the
    /// file's. A file paired with an asset its path no longer names is owed its unpairing, and
    /// a file not paired is owed the first free asset its path names, the prefixes in order. A
    /// file paired with another account's asset is that account's, and is left.
    static func owedPairs(
        libraryRootID: Int64,
        accountRootID: Int64,
        serverPrefixes: [String],
        after: String,
        db: Database
    ) throws -> Batch {
        let files = try String.fetchAll(db.cachedStatement(sql: filesSQL), arguments: [libraryRootID, after])
        guard let first = files.first, let last = files.last else {
            return Batch(count: 0, last: nil, owed: [])
        }
        var paired: [String: (account: Int64, asset: String, checksum: Data?)] = [:]
        for row in try Row.fetchAll(db.cachedStatement(sql: pairsInRangeSQL), arguments: [libraryRootID, first, last]) {
            paired[row[0]] = (row[1], row[2], row[3])
        }
        let free = try db.cachedStatement(sql: freeAssetAtChecksumSQL)
        var owed: [OwedPair] = []
        for file in files {
            let existing = paired[file]
            if let existing, existing.account != accountRootID {
                continue
            }
            let checksums = serverPrefixes.map { ImmichPathChecksum.everyForm(ofServerPath: $0 + file) }
            if let existing, let stored = existing.checksum.flatMap(ImmichPathChecksum.init(data:)),
               checksums.contains(where: { $0.contains(stored) })
            {
                continue
            }
            var named: NamedAsset?
            for checksum in checksums.joined() {
                if let asset = try String.fetchOne(free, arguments: [accountRootID, checksum.data]) {
                    named = NamedAsset(asset: asset, checksum: checksum)
                    break
                }
            }
            if existing != nil || named != nil {
                owed.append(OwedPair(filePath: file, pairedAsset: existing?.asset, named: named))
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
    WHERE \(AssetKey.exactText("file"))
      AND \(AssetKey.exactText("asset")) AND asset.source_path_sha1 = ?
    """

    /// Writes the owed pairs of one batch: a pair its file's path no longer names goes, and
    /// the pair its path names comes. Returns how many came and how many went.
    static func writePairs(
        _ owed: [OwedPair],
        libraryRootID: Int64,
        accountRootID: Int64,
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
            if let named = file.named {
                try pair.execute(
                    arguments: AssetKey(rootID: libraryRootID, path: MediaRelativePath(rawValue: file.filePath)).arguments
                        + AssetKey(rootID: accountRootID, path: MediaRelativePath(rawValue: named.asset)).arguments
                        + [named.checksum.data]
                )
                paired += db.changesCount
            }
        }
        return (paired, unpaired)
    }

    /// Why a candidate's server path taught no new prefix, for the probe's log and its memory
    /// (`immich_mirror_asked`): the server would not describe the asset, gave no path, its path
    /// does not end with the file's relative path (with how many of the relative path's trailing
    /// components it does end with), the prefix it gives does not reproduce the asset's own
    /// checksum, or the prefix it gives is one the library already has.
    enum Refusal: Error, Equatable, Sendable {
        case serverRefused(status: Int)
        case noPath
        case tailMismatch(sharedComponents: Int)
        case checksumMismatch
        case knownPrefix

        var fields: [String: String] {
            switch self {
            case let .serverRefused(status): ["reason": "serverRefused", "status": "\(status)"]
            case .noPath: ["reason": "noPath"]
            case let .tailMismatch(shared): ["reason": "tailMismatch", "sharedTailComponents": "\(shared)"]
            case .checksumMismatch: ["reason": "checksumMismatch"]
            case .knownPrefix: ["reason": "knownPrefix"]
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
        guard candidate.pathChecksum.names(serverPath: prefix + candidate.relativePath.rawValue) else {
            return .failure(.checksumMismatch)
        }
        return .success(prefix)
    }

    /// The server prefix `originalPath` has before `relativePath`, as the server writes it:
    /// the path up to and with the separator. The two are compared as characters, which are
    /// equal in either Unicode normal form, since the server's disk and the Mac's need not
    /// hold a name in the same one; the checksum then decides (`ImmichPathChecksum.names`).
    /// Nil when the server's path does not end with the relative path.
    static func serverPrefix(of originalPath: String, relativePath: MediaRelativePath) -> String? {
        let path = Array(originalPath)
        let tail = Array("/\(relativePath.rawValue)")
        guard path.count > tail.count, path.suffix(tail.count).elementsEqual(tail) else {
            return nil
        }
        return String(path.dropLast(tail.count - 1))
    }

    /// A path's leading components, without its last one: what a refusal logs of a server's
    /// path or a file's, so the log names the folders it compared and never the file.
    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else {
            return ""
        }
        return String(path[..<slash])
    }
}

/// What one walk of an account's mirrors wrote: the pairs that came and the pairs that went.
nonisolated struct MirrorWalk: Equatable, Sendable {
    let paired: Int
    let unpaired: Int

    var changed: Int {
        paired + unpaired
    }
}
