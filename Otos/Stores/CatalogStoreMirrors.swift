import Foundation
import GRDB

/// Mirrors SQL (ADR 0054), run inside the Store's database access by `CatalogStore`'s
/// mirror intents and by every write of a library file's digest.
///
/// An Immich external library that holds a library's files lists each one as an asset
/// whose checksum is the SHA-1 of `path:<its path on the server>`, never of its bytes. A
/// mirror (`immich_mirror`) is the server path a library's relative paths follow there, so
/// a library file's own path names its asset exactly: the checksum of the server prefix
/// plus its relative path. The asset is that file's copy when the server lists it with the
/// size and modification time (whole seconds) the file's digest was read at, and it then
/// takes that digest, stamped with its own listed facts. A later listing of other bytes
/// moves its facts, so the digest stops being current for it, as any stale digest does.
nonisolated enum MirrorGateway {
    /// A library file that may be one of the account's assets: an external library's asset
    /// with its name, size and modification time. Only the server's path for it can say.
    struct Candidate: Equatable, Sendable {
        let relativePath: MediaRelativePath
        let assetID: String
        let pathChecksum: ImmichPathChecksum
    }

    /// One library as an account's mirror discovery sees it: the server prefix learned for
    /// it, if any, and files that may be the account's assets.
    struct Probe: Equatable, Sendable {
        let libraryRootID: Int64
        let libraryRootPath: LibraryRootPath
        let serverPrefix: String?
        let candidates: [Candidate]
    }

    /// Files a probe offers: enough to find the one asset that is not a same-named file from
    /// another folder, without asking the server for more than a few paths.
    static let candidateLimit = 3

    /// Library files whose digest a pass pairs in one transaction: each pair recomputes its
    /// copy group's shown copy (about 0.7 ms on the owner's catalog), so a first pairing of
    /// a whole library never holds the writer for seconds.
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

    static func record(accountRootID: Int64, libraryRootID: Int64, serverPrefix: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO immich_mirror (account_root_id, library_root_id, server_prefix) VALUES (?, ?, ?)
            ON CONFLICT (account_root_id, library_root_id) DO UPDATE SET server_prefix = excluded.server_prefix
            """,
            arguments: [accountRootID, libraryRootID, serverPrefix]
        )
    }

    /// A root's files with a current digest of some bytes; a call adds its path bounds.
    static let digestedFilesSQL = """
    SELECT relative_path, content_sha1, content_hash_source_size, content_hash_source_mtime
    FROM media_asset
    WHERE library_root_id = ?
      AND \(ContentDigestSQL.isCurrent("media_asset"))
      AND content_sha1 <> \(ContentDigestSQL.empty)
      AND byte_size IS NOT NULL AND content_modified_at_unix IS NOT NULL
    """

    /// The library files of `libraryRootID` with a current digest, from `after` on in path
    /// order, at most `limit` of them; one file when `relativePath` names it.
    static func digestedFiles(
        libraryRootID: Int64,
        relativePath: String? = nil,
        after: String? = nil,
        limit: Int = pairBatchSize,
        db: Database
    ) throws -> [DigestedFile] {
        var sql = digestedFilesSQL
        var arguments: StatementArguments = [libraryRootID]
        if let relativePath {
            sql += "\n  AND relative_path = ?"
            arguments += [relativePath]
        }
        if let after {
            sql += "\n  AND relative_path > ?"
            arguments += [after]
        }
        sql += "\nORDER BY relative_path LIMIT \(limit)"
        return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            guard let digest = (row["content_sha1"] as Data?).flatMap(ContentDigest.init(data:)) else {
                return nil
            }
            return DigestedFile(
                relativePath: row["relative_path"],
                digest: digest,
                size: row["content_hash_source_size"],
                mtime: row["content_hash_source_mtime"]
            )
        }
    }

    /// A library file's digest and the facts it was read at.
    struct DigestedFile: Sendable {
        let relativePath: String
        let digest: ContentDigest
        let size: Int64
        let mtime: Int64
    }

    /// The mirrors that hold `libraryRootID`'s files.
    static func mirrors(ofLibrary libraryRootID: Int64, db: Database) throws -> [(accountRootID: Int64, serverPrefix: String)] {
        try Row.fetchAll(
            db,
            sql: "SELECT account_root_id, server_prefix FROM immich_mirror WHERE library_root_id = ?",
            arguments: [libraryRootID]
        ).map { row in (row["account_root_id"], row["server_prefix"]) }
    }

    /// An account's asset at one path checksum (binds the account, the checksum, the size, the
    /// whole-second mtime and the digest) listed with the size and mtime a file's digest was
    /// read at, and not holding that digest already: the asset the file's pair writes.
    static let owesPairCondition = """
    library_root_id = ? AND source_path_sha1 = ?
      AND byte_size = ? AND CAST(content_modified_at_unix AS INTEGER) = ?
      AND (\(ContentDigestSQL.current("media_asset"))) IS NOT ?
    """

    /// An account's asset at one path checksum takes a digest when listed with the size and
    /// whole-second mtime it was read at, unless it holds that digest already.
    static let pairSQL = """
    UPDATE media_asset SET
        content_sha1 = ?,
        content_hash_source_size = byte_size,
        content_hash_source_mtime = CAST(content_modified_at_unix AS INTEGER)
    WHERE \(owesPairCondition)
    """

    static let owesPairSQL = "SELECT EXISTS (SELECT 1 FROM media_asset WHERE \(owesPairCondition))"

    /// The files of `files` whose mirrored asset does not hold their digest yet: read first, so
    /// a pass over a library whose pairs all stand opens no write.
    static func unpaired(
        _ files: [DigestedFile],
        accountRootID: Int64,
        serverPrefix: String,
        db: Database
    ) throws -> [DigestedFile] {
        let statement = try db.cachedStatement(sql: owesPairSQL)
        return try files.filter { file in
            let checksum = ImmichPathChecksum(serverPath: serverPrefix + file.relativePath)
            return try Bool.fetchOne(statement, arguments: [
                accountRootID, checksum.data, file.size, file.mtime, file.digest.data,
            ]) ?? false
        }
    }

    /// Gives each asset that is one of `files` under a mirror the file's digest; returns how
    /// many assets took one. The asset must be listed with the size and modification time
    /// the digest was read at, so a server still holding other bytes keeps its own state.
    static func pair(
        _ files: [DigestedFile],
        accountRootID: Int64,
        serverPrefix: String,
        db: Database
    ) throws -> Int {
        let statement = try db.cachedStatement(sql: pairSQL)
        var paired = 0
        for file in files {
            let checksum = ImmichPathChecksum(serverPath: serverPrefix + file.relativePath)
            try statement.execute(arguments: [
                file.digest.data, accountRootID, checksum.data, file.size, file.mtime, file.digest.data,
            ])
            paired += db.changesCount
        }
        return paired
    }

    /// The digest write of one library file reaches its mirrored assets in the same
    /// transaction (ADR 0054). A pass pairs every file again, so a write path that does not
    /// call this delays a pair until the account's next pass, and never loses one.
    static func pairMirroredAssets(libraryRootID: Int64, relativePath: String, db: Database) throws -> Int {
        let mirrors = try mirrors(ofLibrary: libraryRootID, db: db)
        guard !mirrors.isEmpty else {
            return 0
        }
        let files = try digestedFiles(libraryRootID: libraryRootID, relativePath: relativePath, db: db)
        guard !files.isEmpty else {
            return 0
        }
        return try mirrors.reduce(0) { paired, mirror in
            try paired + pair(files, accountRootID: mirror.accountRootID, serverPrefix: mirror.serverPrefix, db: db)
        }
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
