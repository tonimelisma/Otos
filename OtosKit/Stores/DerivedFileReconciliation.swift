import CryptoKit
import Darwin
import Foundation
import GRDB
import Synchronization

/// Derived folder guide
///
/// Every derived image Otos keeps (a thumbnail, a preview, a video's face frames) is a
/// file in the derived folder that one catalog row names (`thumbnail_path`,
/// `preview_path`, `face_frames_path`). That is the overlay's one lifecycle (ADR 0008): a
/// file lives exactly as long as a row names it. Each writer keeps it through `DerivedFolder`:
/// a promotion and the row that names it are one write transaction
/// (`DerivedFolder.promote`), and a name a write stops holding is counted out in that write
/// and its file deleted once it commits (`DerivedFolder.unname`, `DerivedRemoval`).
///
/// **Counters.** The folder's files and allocated bytes by kind are stored counters
/// (`derived_folder`), changed in the same transaction as the write that names or unnames a
/// file, so a session's disk number never needs a listing (`op=derived.folder phase=counted`).
/// No rows means the counters are unknown (a catalog from before them).
///
/// **When leftovers can exist.** A file can outlive every row that named it only when a
/// change to the folder did not finish: a write that rolled back after promoting, a process
/// that ended between a promotion and its commit, or between a commit and the deletes after
/// it. `DerivedFolder` counts such changes while they run and keeps a marker file
/// (`DerivedFolder.open`) for the session: a clean quit removes it when no change is in flight
/// and none rolled back. So a reconciliation is owed exactly when the previous session's
/// marker is still there at launch, or the counters are unknown; otherwise a launch lists
/// nothing (`CatalogStore.reconcileDerivedFilesIfOwed`).
///
/// **Reconciliation**, when owed, as one admitted background load at the lowest priority:
/// 1. names written from here on are noted (`DerivedFolder.startNoting`);
/// 2. the protected names are read in short keyed pages of rows (`ProtectedNames`): every
///    name a row holds and every name a present row's identity derives, as 128-bit keys;
/// 3. the folder's top level is read as a stream of pages (`readdir`, `fstatat`; never
///    `.staging`, whose files are a running write's), each unprotected file a candidate;
/// 4. each page of candidates is deleted inside a short write transaction that leaves out
///    every name noted so far. A promotion happens only inside a write transaction and notes
///    its name there, so no file this deletes can have become named;
/// 5. the counters are set to the census the stream took, and the drift from what they held
///    is logged (`op=derived.reconcile phase=finish`). A write that lands during the stream
///    can leave them off by what it wrote until the next census.
/// It also removes the files of a retired sink: the July
/// `Diagnostics/catalog-diagnostics-*.jsonl` that ADR 0015's removed JSONL writer left.
nonisolated enum DerivedFileReconciliation {
    /// What kind of derived file a name is, by the extension `ThumbnailStore` gives it.
    enum Kind: String, CaseIterable, Sendable {
        case thumbnail
        case preview
        case faceFrames
        case other

        init(name: String) {
            if name.hasSuffix(".faces.heic") {
                self = .faceFrames
            } else if name.hasSuffix(".heic") {
                self = .preview
            } else if name.hasSuffix(".jpg") {
                self = .thumbnail
            } else {
                self = .other
            }
        }
    }

    /// One listed file.
    struct Entry: Equatable, Sendable {
        let name: String
        let bytes: Int64
    }

    /// Files and allocated bytes, by kind. Also a change to them, whose values may be negative.
    struct Census: Equatable, Sendable {
        var files: [Kind: Int] = [:]
        var bytes: [Kind: Int64] = [:]

        init(_ entries: [Entry] = []) {
            for entry in entries {
                add(entry)
            }
        }

        mutating func add(_ entry: Entry) {
            add(kind: Kind(name: entry.name), files: 1, bytes: entry.bytes)
        }

        mutating func remove(_ entry: Entry) {
            add(kind: Kind(name: entry.name), files: -1, bytes: -entry.bytes)
        }

        mutating func add(kind: Kind, files: Int, bytes: Int64) {
            self.files[kind, default: 0] += files
            self.bytes[kind, default: 0] += bytes
        }

        mutating func add(_ other: Census) {
            for kind in Kind.allCases {
                add(kind: kind, files: other.files[kind, default: 0], bytes: other.bytes[kind, default: 0])
            }
        }

        /// The same change with every sign flipped.
        var negated: Census {
            var negated = Census()
            for kind in Kind.allCases {
                negated.add(kind: kind, files: -files[kind, default: 0], bytes: -bytes[kind, default: 0])
            }
            return negated
        }

        var isZero: Bool {
            files.values.allSatisfy { $0 == 0 } && bytes.values.allSatisfy { $0 == 0 }
        }

        var totalFiles: Int {
            files.values.reduce(0, +)
        }

        var totalBytes: Int64 {
            bytes.values.reduce(0, +)
        }

        /// The same census with every kind present, so two censuses compare by value.
        var normalized: Census {
            var normalized = Census()
            normalized.add(self)
            return normalized
        }

        /// `files=… bytes=… thumbnailFiles=… thumbnailBytes=… …` for an `op=` line, each key
        /// after `prefix`.
        func fields(prefix: String) -> [String: String] {
            func key(_ name: String) -> String {
                prefix.isEmpty ? name : prefix + name.prefix(1).uppercased() + name.dropFirst()
            }
            var fields: [String: String] = [key("files"): "\(totalFiles)", key("bytes"): "\(totalBytes)"]
            for kind in Kind.allCases {
                fields[key("\(kind.rawValue)Files")] = "\(files[kind, default: 0])"
                fields[key("\(kind.rawValue)Bytes")] = "\(bytes[kind, default: 0])"
            }
            return fields
        }

        var fields: [String: String] {
            fields(prefix: "")
        }
    }

    /// A file's allocated bytes, or nil when nothing is there.
    static func allocatedBytes(of name: String, in directory: URL) -> Int64? {
        var info = stat()
        guard lstat(ThumbnailStore.url(for: name, in: directory).path(percentEncoded: false), &info) == 0,
              info.st_mode & S_IFMT == S_IFREG
        else {
            return nil
        }
        return Int64(info.st_blocks) * 512
    }

    /// Reads the folder's top-level regular files as a stream, `pageSize` at a time, with
    /// their allocated bytes: one `readdir` pass and an `fstatat` per name, so no listing,
    /// URL or resource cache outlives its page. Hidden names (`.staging`) are skipped. A
    /// missing folder is empty.
    static func stream(_ directory: URL, pageSize: Int, _ page: ([Entry]) throws -> Void) throws {
        guard let folder = opendir(directory.path(percentEncoded: false)) else {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(folder) }
        let descriptor = dirfd(folder)
        var entries: [Entry] = []
        entries.reserveCapacity(pageSize)
        while true {
            errno = 0
            guard let entry = readdir(folder) else {
                if errno != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: UnsafeRawBufferPointer(rebasing: raw[0 ..< length]), as: UTF8.self)
            }
            guard !name.hasPrefix(".") else {
                continue
            }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            entries.append(Entry(name: name, bytes: Int64(info.st_blocks) * 512))
            if entries.count == pageSize {
                try page(entries)
                entries.removeAll(keepingCapacity: true)
            }
        }
        if !entries.isEmpty {
            try page(entries)
        }
    }

    /// The folder's top-level files with their allocated sizes, in one array: for a small
    /// folder (the retired Diagnostics folder, a test's).
    static func list(_ directory: URL) throws -> [Entry] {
        var all: [Entry] = []
        try stream(directory, pageSize: 1024) { all.append(contentsOf: $0) }
        return all
    }

    /// A derived name's storage key: the first 128 bits of the identity hash its name begins
    /// with. The three names of one identity share it.
    struct NameKey: Hashable, Sendable {
        let high: UInt64
        let low: UInt64

        init(digest: SHA256.Digest) {
            var high: UInt64 = 0
            var low: UInt64 = 0
            for (index, byte) in digest.prefix(16).enumerated() {
                if index < 8 {
                    high = high << 8 | UInt64(byte)
                } else {
                    low = low << 8 | UInt64(byte)
                }
            }
            self.high = high
            self.low = low
        }

        /// Nil for a name that does not begin with 32 hexadecimal digits.
        init?(name: String) {
            var high: UInt64 = 0
            var low: UInt64 = 0
            var count = 0
            for unit in name.utf8.prefix(32) {
                let value: UInt64
                switch unit {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"): value = UInt64(unit - UInt8(ascii: "0"))
                case UInt8(ascii: "a") ... UInt8(ascii: "f"): value = UInt64(unit - UInt8(ascii: "a") + 10)
                default: return nil
                }
                if count < 16 {
                    high = high << 4 | value
                } else {
                    low = low << 4 | value
                }
                count += 1
            }
            guard count == 32 else {
                return nil
            }
            self.high = high
            self.low = low
        }
    }

    /// Every name a file may hold while it belongs to a present row: each derived name a row
    /// holds, and each name a present row's identity derives, whether or not its column holds
    /// it now. A row that does not name its image yet writes exactly that name when it renders,
    /// so a file of a present row's identity is never taken for an orphan. Kept as storage
    /// keys, so the three names of a key are protected together; a name with no key is kept
    /// as itself.
    struct ProtectedNames: Sendable {
        private(set) var keys = Set<NameKey>()
        private(set) var others = Set<String>()

        mutating func insert(name: String) {
            if let key = NameKey(name: name) {
                keys.insert(key)
            } else {
                others.insert(name)
            }
        }

        mutating func insert(identity id: MediaAssetID) {
            keys.insert(NameKey(digest: ThumbnailStore.storageDigest(for: id)))
        }

        func protects(_ name: String) -> Bool {
            if let key = NameKey(name: name) {
                return keys.contains(key)
            }
            return others.contains(name)
        }

        var count: Int {
            keys.count + others.count
        }
    }

    /// One row's identity and derived names, as one page of the protected-names read holds it.
    struct NamedRow: Sendable {
        let rowID: Int64
        let id: MediaAssetID
        let names: [String]
    }

    /// The rows after `rowID`, at most `limit`, in rowid order: one short read.
    static func namedRows(after rowID: Int64, limit: Int, db: Database) throws -> [NamedRow] {
        // A walk of the whole library a page at a time: one statement per connection, each page
        // one buffer reserved at its limit.
        try Array(page: Row.fetchCursor(db.cachedStatement(sql: """
        SELECT a.rowid, r.path, a.relative_path, a.thumbnail_path, a.preview_path, a.face_frames_path
        FROM media_asset a JOIN library_root r ON r.id = a.library_root_id
        WHERE a.rowid > ? ORDER BY a.rowid LIMIT ?
        """), arguments: [rowID, limit]), atMost: limit) { row in
            NamedRow(
                rowID: row[0],
                id: MediaAssetID(
                    libraryRootPath: LibraryRootPath(rawValue: row[1]),
                    relativePath: MediaRelativePath(rawValue: row[2])
                ),
                names: [row[3], row[4], row[5]].compactMap { (name: String?) in name }
            )
        }
    }

    /// The journaled renames not yet moved, at most `limit`, in name order.
    static func pendingRenames(limit: Int, db: Database) throws -> [(old: String, new: String)] {
        try Row.fetchAll(
            db,
            sql: "SELECT old_name, new_name FROM derived_rename ORDER BY old_name LIMIT ?",
            arguments: [limit]
        ).map { ($0[0], $0[1]) }
    }

    /// Deletes `entries` from `directory`; returns what went.
    static func delete(_ entries: [Entry], in directory: URL) -> [Entry] {
        entries.filter { entry in
            do {
                try FileManager.default.removeItem(at: ThumbnailStore.url(for: entry.name, in: directory))
                return true
            } catch where ErrorDiagnostics.isMissingFile(error) {
                return false
            } catch {
                OtosLog.thumbnails.errorOperation("derived.reconcile", phase: "removeFailed", fields: [
                    "kind": Kind(name: entry.name).rawValue,
                    "error": String(describing: error),
                ])
                return false
            }
        }
    }

    /// The retired JSONL sink's folder beside the derived folder (`Diagnostics`), and its
    /// files' names: only those it wrote are removed, then the folder if that left it empty.
    static func removeRetiredDiagnostics(besides derivedDirectory: URL) -> (files: Int, bytes: Int64) {
        let folder = derivedDirectory.deletingLastPathComponent().appending(path: "Diagnostics", directoryHint: .isDirectory)
        let entries: [Entry]
        do {
            entries = try list(folder).filter { $0.name.hasPrefix("catalog-diagnostics-") && $0.name.hasSuffix(".jsonl") }
        } catch {
            OtosLog.thumbnails.errorOperation("derived.retiredDiagnostics", phase: "listFailed", fields: [
                "error": String(describing: error),
            ])
            return (0, 0)
        }
        let removed = delete(entries, in: folder)
        do {
            if !removed.isEmpty, try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            OtosLog.thumbnails.errorOperation("derived.retiredDiagnostics", phase: "folderRemoveFailed", fields: [
                "error": String(describing: error),
            ])
        }
        return (removed.count, removed.reduce(0) { $0 + $1.bytes })
    }
}

/// The derived folder's stored counters (`derived_folder`, one row per kind).
nonisolated enum DerivedFolderCounters {
    typealias Census = DerivedFileReconciliation.Census

    /// The counters, or nil while they are unknown (no census has set them).
    static func read(db: Database) throws -> Census? {
        let rows = try Row.fetchAll(db, sql: "SELECT kind, files, bytes FROM derived_folder")
        var census = Census()
        var kinds = Set<DerivedFileReconciliation.Kind>()
        for row in rows {
            guard let kind = DerivedFileReconciliation.Kind(rawValue: row[0]) else {
                continue
            }
            kinds.insert(kind)
            census.add(kind: kind, files: row[1], bytes: row[2])
        }
        return kinds.count == DerivedFileReconciliation.Kind.allCases.count ? census : nil
    }

    /// Adds `change` to the counters; nothing while they are unknown.
    static func apply(_ change: Census, db: Database) throws {
        for kind in DerivedFileReconciliation.Kind.allCases {
            let files = change.files[kind, default: 0]
            let bytes = change.bytes[kind, default: 0]
            guard files != 0 || bytes != 0 else {
                continue
            }
            try db.execute(
                sql: "UPDATE derived_folder SET files = files + ?, bytes = bytes + ? WHERE kind = ?",
                arguments: [files, bytes, kind.rawValue]
            )
        }
    }

    /// Sets the counters to `census`.
    static func replace(with census: Census, db: Database) throws {
        try db.execute(sql: "DELETE FROM derived_folder")
        for kind in DerivedFileReconciliation.Kind.allCases {
            try db.execute(
                sql: "INSERT INTO derived_folder (kind, files, bytes) VALUES (?, ?, ?)",
                arguments: [kind.rawValue, census.files[kind, default: 0], census.bytes[kind, default: 0]]
            )
        }
    }
}

/// The derived folder of one catalog, and the facts about its changes in this session: how
/// many are in flight, whether one rolled back, and the names written while a reconciliation
/// notes them. One per Store; its state lives in one `Mutex`, because the writes that change
/// the folder run on the database's writer queue and the quit that closes the session runs on
/// the main thread.
final nonisolated class DerivedFolder: Sendable {
    typealias Census = DerivedFileReconciliation.Census

    let directory: URL
    /// Present while a session that may leave leftovers is open: removed by a clean quit.
    let marker: URL

    private struct State {
        var previousSessionUnclean = false
        var inFlight = 0
        var rolledBack = false
        var noting = false
        var noted = Set<String>()
        /// Who waits for no change to be in flight (`untilSettled`).
        var settledWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init(directory: URL) {
        self.directory = directory
        marker = directory.deletingLastPathComponent().appending(path: "DerivedFolder.open", directoryHint: .notDirectory)
    }

    /// Opens this session: whether the previous one's marker is still there, then writes this
    /// one's. Once a launch, before anything changes the folder.
    @discardableResult
    func openSession() -> Bool {
        let path = marker.path(percentEncoded: false)
        let unclean = FileManager.default.fileExists(atPath: path)
        do {
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            OtosLog.thumbnails.errorOperation("derived.session", phase: "openFailed", fields: [
                "error": String(describing: error),
            ])
        }
        if !unclean, !FileManager.default.createFile(atPath: path, contents: Data()) {
            OtosLog.thumbnails.errorOperation("derived.session", phase: "markerWriteFailed")
        }
        state.withLock { $0.previousSessionUnclean = unclean }
        OtosLog.thumbnails.noticeOperation("derived.session", phase: "opened", fields: [
            "previousSession": unclean ? "unclean" : "clean",
        ])
        return unclean
    }

    var previousSessionUnclean: Bool {
        state.withLock { $0.previousSessionUnclean }
    }

    /// Closes the session at a quit: removes the marker when no change to the folder is in
    /// flight and none rolled back, so the next launch lists nothing. Otherwise the marker
    /// stays and the next launch reconciles. Synchronous: it runs as the process ends.
    @discardableResult
    func closeSession() -> Bool {
        let (inFlight, rolledBack) = state.withLock { ($0.inFlight, $0.rolledBack) }
        guard inFlight == 0, !rolledBack else {
            OtosLog.thumbnails.noticeOperation("derived.session", phase: "closedUnclean", fields: [
                "inFlight": "\(inFlight)", "rolledBack": "\(rolledBack)",
            ])
            return false
        }
        do {
            try FileManager.default.removeItem(at: marker)
        } catch where ErrorDiagnostics.isMissingFile(error) {
            // Never written (its folder could not be made): nothing to remove.
        } catch {
            OtosLog.thumbnails.errorOperation("derived.session", phase: "closeFailed", fields: [
                "error": String(describing: error),
            ])
            return false
        }
        OtosLog.thumbnails.noticeOperation("derived.session", phase: "closed")
        return true
    }

    private func begin() {
        state.withLock { $0.inFlight += 1 }
    }

    fileprivate func end(rolledBack: Bool) {
        let settled = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.inFlight -= 1
            state.rolledBack = state.rolledBack || rolledBack
            guard state.inFlight == 0 else { return [] }
            defer { state.settledWaiters = [] }
            return state.settledWaiters
        }
        settled.forEach { $0.resume() }
    }

    /// Returns once no change to the folder is in flight: at once when none is, else in the
    /// step that ends the last. A write's deletes run after it commits, off the Store's actor
    /// (`DerivedRemoval.perform`), so its rows can be read before its files are gone; a reader
    /// that compares the folder with them waits for this fact first.
    func untilSettled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let settled = state.withLock { state -> Bool in
                guard state.inFlight > 0 else { return true }
                state.settledWaiters.append(continuation)
                return false
            }
            if settled {
                continuation.resume()
            }
        }
    }

    /// Notes `names` as named, for a reconciliation running now.
    func noteNamed(_ names: some Sequence<String>) {
        state.withLock { state in
            guard state.noting else {
                return
            }
            state.noted.formUnion(names)
        }
    }

    func startNoting() {
        state.withLock { state in
            state.noting = true
            state.noted = []
        }
    }

    func noted() -> Set<String> {
        state.withLock { $0.noted }
    }

    func stopNoting() {
        state.withLock { state in
            state.noting = false
            state.noted = []
        }
    }

    /// Promotes `staged` inside the write transaction `db` and counts it in that transaction.
    /// The change is in flight until the transaction ends; a rollback leaves the promoted
    /// file unnamed, so it keeps this session's marker.
    @discardableResult
    func promote(_ staged: StagedDerivedImage, db: Database) throws -> String {
        let name = staged.finalRelativePath
        begin()
        db.afterNextTransaction(
            onCommit: { [self] _ in end(rolledBack: false) },
            onRollback: { [self] _ in end(rolledBack: true) }
        )
        noteNamed([name])
        let before = DerivedFileReconciliation.allocatedBytes(of: name, in: directory)
        try ThumbnailStore.promote(staged, in: directory)
        var change = Census()
        let after = DerivedFileReconciliation.allocatedBytes(of: name, in: directory) ?? 0
        change.add(kind: DerivedFileReconciliation.Kind(name: name), files: before == nil ? 1 : 0, bytes: after - (before ?? 0))
        try DerivedFolderCounters.apply(change, db: db)
        return name
    }

    /// Counts `names` out inside the write transaction `db` that stops naming them, and
    /// returns their removal, which the caller performs once that write commits. In flight
    /// from here until it is performed.
    func unname(_ names: some Sequence<String>, db: Database) throws -> DerivedRemoval {
        var entries: [DerivedFileReconciliation.Entry] = []
        for name in Set(names) {
            if let bytes = DerivedFileReconciliation.allocatedBytes(of: name, in: directory) {
                entries.append(DerivedFileReconciliation.Entry(name: name, bytes: bytes))
            }
        }
        guard !entries.isEmpty else {
            return DerivedRemoval(folder: nil, entries: [])
        }
        begin()
        db.afterNextTransaction(onCommit: { _ in }, onRollback: { [self] _ in end(rolledBack: false) })
        var change = Census()
        entries.forEach { change.remove($0) }
        try DerivedFolderCounters.apply(change, db: db)
        return DerivedRemoval(folder: self, entries: entries)
    }

    /// Journals each file's move to its new name inside the write transaction `db` that renames
    /// the rows naming it (a root whose path changed): the files move afterwards, a page at a
    /// time outside the writer (`CatalogStore.applyPendingDerivedRenames`), and a journaled name
    /// stays protected until its move is done, so a crash between the two loses no named file.
    func journalRenames(_ moves: [(old: String, new: String)], db: Database) throws {
        let moves = moves.filter { $0.old != $0.new }
        guard !moves.isEmpty else {
            return
        }
        noteNamed(moves.map(\.new))
        for move in moves {
            try db.execute(
                sql: "INSERT OR REPLACE INTO derived_rename (old_name, new_name) VALUES (?, ?)",
                arguments: [move.old, move.new]
            )
        }
    }

    /// Moves one page of journaled files, off any actor: what moved, and the counters' change
    /// (a file dropped onto one already at its new name is counted out). In flight from here
    /// until `endOutsideWrite`.
    func moveJournaled(_ moves: [(old: String, new: String)]) -> (change: Census, failures: Int) {
        begin()
        var change = Census()
        var failures = 0
        for move in moves {
            let sourceBytes = DerivedFileReconciliation.allocatedBytes(of: move.old, in: directory)
            let destinationExisted = DerivedFileReconciliation.allocatedBytes(of: move.new, in: directory) != nil
            do {
                try ThumbnailStore.move(move.old, to: move.new, in: directory)
            } catch {
                failures += 1
                OtosLog.thumbnails.errorOperation("derived.rename", phase: "failed", fields: [
                    "kind": DerivedFileReconciliation.Kind(name: move.new).rawValue,
                    "error": String(describing: error),
                ])
                continue
            }
            if let sourceBytes, destinationExisted {
                change.remove(DerivedFileReconciliation.Entry(name: move.old, bytes: sourceBytes))
            }
        }
        return (change, failures)
    }

    /// Ends a change `moveJournaled` began; a failed one keeps the session's marker.
    func endOutsideWrite(failed: Bool) {
        end(rolledBack: failed)
    }
}

/// The deletes a committed write owes: the files of the names it stopped holding, already
/// counted out in that write.
nonisolated struct DerivedRemoval: Sendable {
    fileprivate let folder: DerivedFolder?
    fileprivate let entries: [DerivedFileReconciliation.Entry]

    static let nothing = DerivedRemoval(folder: nil, entries: [])

    /// Deletes the files; once, after the write that counted them out committed. A delete
    /// that fails leaves a file the counters no longer hold, so it keeps the session's marker.
    /// The deletes run on the file-deletion queue (`FileDeletion`), never on the actor that
    /// awaits them.
    func perform() async {
        guard let folder else {
            return
        }
        let entries = entries
        await FileDeletion.run {
            var failed = false
            for entry in entries {
                do {
                    try FileManager.default.removeItem(at: ThumbnailStore.url(for: entry.name, in: folder.directory))
                } catch where ErrorDiagnostics.isMissingFile(error) {
                    failed = true
                } catch {
                    failed = true
                    OtosLog.thumbnails.errorOperation("thumbnail.cleanup", phase: "removeFailed", fields: [
                        "kind": DerivedFileReconciliation.Kind(name: entry.name).rawValue,
                        "error": String(describing: error),
                    ])
                }
            }
            folder.end(rolledBack: failed)
        }
    }
}

/// The queue Otos deletes its own files on: a write's superseded derived images
/// (`DerivedRemoval`) and a removed source's staging folder. A delete holds its thread for as
/// long as the volume takes — 160 ms for one write's derived files, 1.5 s for a staging folder
/// of 2,000 files (`docs/research/2026-11-19-store-change-facts-actor-hold-read-turns.md`) — so
/// it runs neither on the actor that asked for it nor on the cooperative pool, whose threads
/// are one per core (ADR 0032 rule 6). A dispatch queue's threads are its own.
nonisolated enum FileDeletion {
    private static let queue = DispatchQueue(
        label: "net.melisma.Otos.file-deletion",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Runs `delete`, blocking file-system work, on the deletion queue, and returns once it ran.
    static func run(_ delete: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                delete()
                continuation.resume()
            }
        }
    }
}
