import CoreGraphics
import Foundation
import Synchronization
import UniformTypeIdentifiers

// Catalog model guide
//
// These value types are the Sendable boundary between the catalog actors and
// MainActor UI state. Paths are domain identity, not display-only strings:
// library roots are identified by normalized absolute paths and media assets by
// a root plus a relative path. Runtime facts such as reachability and scanning
// stay separate from durable root identity because the filesystem can change
// independently of SQLite.
//
// `LibraryRootPath` and `MediaRelativePath` carry a derived FNV-1a `fingerprint`
// so Hashable / ObjC-bridged diffable hashing is O(1) after construction; a
// `MediaAssetID` is its pair's place in the identity table and hashes that. A
// fingerprint is never persisted, never logged as identity, and never substitutes
// for string equality (colliding fingerprints still compare the full path strings).
//
// Store owns durable truth in SQLite and exposes small immutable values at query
// boundaries. `CatalogWindowState` is the UI-ready value built by Projection.

/// Stable FNV-1a 64-bit over UTF-8. Used only as derived Hashable state for path
/// identity types — never persisted, never logged as identity, never a substitute
/// for string equality (collisions fall back to full string compare).
nonisolated enum PathFingerprint {
    static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    static let prime: UInt64 = 1_099_511_628_211

    static func fnv1a64(_ bytes: some Sequence<UInt8>) -> UInt64 {
        fnv1a64(offsetBasis, bytes)
    }

    static func fnv1a64(_ seed: UInt64, _ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// `text`'s UTF-8, read from its contiguous storage: the same value as over `text.utf8`,
    /// without a generic iterator, which an unoptimized build pays per byte (2.4 µs for a
    /// 55-byte path against 1.0 µs).
    static func fnv1a64(_ seed: UInt64, _ text: String) -> UInt64 {
        var text = text
        return text.withUTF8 { bytes in
            var hash = seed
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            return hash
        }
    }

    /// A media asset's fingerprint from its two paths' own: mixed, so making an ID reads
    /// neither path's bytes again (an order of 164,762 IDs hashed every path twice) —
    /// process-independent, like both.
    static func mediaAsset(root: UInt64, relative: UInt64) -> UInt64 {
        var hash = (root &* 0x9E37_79B9_7F4A_7C15) ^ relative
        hash = (hash ^ (hash >> 30)) &* 0xBF58_476D_1CE4_E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D0_49BB_1331_11EB
        return hash ^ (hash >> 31)
    }
}

/// Typed filesystem paths keep domain roles visible at call sites. A library
/// root path and a media relative path are both text under the hood, but mixing
/// them up would be a real catalog bug, so they are not plain Strings.
nonisolated struct LibraryRootPath: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String
    /// Derived FNV-1a of `rawValue` UTF-8. Cheap Hashable only — not identity.
    let fingerprint: UInt64

    init(rawValue: String) {
        self.rawValue = rawValue
        fingerprint = PathFingerprint.fnv1a64(PathFingerprint.offsetBasis, rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String {
        rawValue
    }

    var url: URL {
        URL(fileURLWithPath: rawValue, isDirectory: true)
    }

    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? rawValue : name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fingerprint)
    }

    static func == (lhs: LibraryRootPath, rhs: LibraryRootPath) -> Bool {
        if lhs.fingerprint != rhs.fingerprint {
            return false
        }
        return lhs.rawValue == rhs.rawValue
    }
}

nonisolated struct MediaRelativePath: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String
    /// Derived FNV-1a of `rawValue` UTF-8. Cheap Hashable only — not identity.
    let fingerprint: UInt64

    init(rawValue: String) {
        self.rawValue = rawValue
        fingerprint = PathFingerprint.fnv1a64(PathFingerprint.offsetBasis, rawValue)
    }

    /// A path whose fingerprint is already known: the identity table's own copy.
    fileprivate init(rawValue: String, fingerprint: UInt64) {
        self.rawValue = rawValue
        self.fingerprint = fingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String {
        rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fingerprint)
    }

    static func == (lhs: MediaRelativePath, rhs: MediaRelativePath) -> Bool {
        if lhs.fingerprint != rhs.fingerprint {
            return false
        }
        return lhs.rawValue == rhs.rawValue
    }
}

/// The parts of a root-relative path, split on "/" as text. Never through
/// `URL(fileURLWithPath:)`: a relative path handed to it resolves against the process's
/// working directory, so its folder comes back absolute.
nonisolated extension MediaRelativePath {
    /// Joins a folder ("" at the root) and a file name.
    init(folder: String, fileName: String) {
        self.init(rawValue: folder.isEmpty ? fileName : "\(folder)/\(fileName)")
    }

    /// The folder part, "" at the root.
    var folder: String {
        guard let slash = rawValue.lastIndex(of: "/") else { return "" }
        return String(rawValue[..<slash])
    }

    var fileName: String {
        guard let slash = rawValue.lastIndex(of: "/") else { return rawValue }
        return String(rawValue[rawValue.index(after: slash)...])
    }

    /// The file name without its last extension. A leading dot does not start an
    /// extension (".hidden" has stem ".hidden").
    var stem: String {
        let name = fileName
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// The last extension without its dot, "" when there is none.
    var fileExtension: String {
        let name = fileName
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// Every folder above this path, outermost first: "a/b/c.jpg" → ["a", "a/b"].
    var ancestorFolders: [String] {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return [] }
        return (1 ..< parts.count).map { parts[0 ..< $0].joined(separator: "/") }
    }
}

/// Media identity is the natural filesystem identity inside Otos: which library
/// root the file belongs to plus its path inside that root. Keeping this as a
/// pair avoids ambiguous string concatenation and avoids generated IDs.
///
/// The value is the pair's place in the process's identity table
/// (`MediaAssetIdentityTable`), which holds each distinct pair's bytes once: equal pairs are
/// one place, so an ID is 4 bytes, compares and hashes as an integer, and an order of
/// 165,000 IDs holds no string. The place is never persisted, logged or sent anywhere:
/// what names the asset is still its two paths, read back from the table.
///
/// Ordering by path never makes a string: `relativePathPrecedes`, `pathPrecedes` and
/// `relativePathThenRootOrder` compare the table's bytes under one lock acquisition, in exactly
/// the order `String`'s `<` gives the paths.
nonisolated struct MediaAssetID: Hashable, CustomReflectable {
    /// The pair's place in the identity table that made it (`MediaAssetIdentityTable.shared`
    /// for every ID but a test's own table's), the same for equal pairs in this process and
    /// meaningless outside it.
    fileprivate let place: UInt32

    init(libraryRootPath: LibraryRootPath, relativePath: MediaRelativePath) {
        place = MediaAssetIdentityTable.shared.place(of: libraryRootPath, relativePath)
    }

    /// The ID of `place` in the table that made it.
    fileprivate init(place: UInt32) {
        self.place = place
    }

    var libraryRootPath: LibraryRootPath {
        MediaAssetIdentityTable.shared.root(at: place)
    }

    /// A new string of the relative path, made from the table's bytes. A comparator or a
    /// per-row loop asks `relativePathPrecedes` or `pathPrecedes` instead, which make none.
    var relativePath: MediaRelativePath {
        MediaAssetIdentityTable.shared.relativePath(at: place)
    }

    /// The number of each ID's library root in the identity table, in the order of `ids`,
    /// read under one lock acquisition for the whole sequence: equal for IDs of one root and
    /// different for IDs of two, never persisted. What a pass that only tells libraries
    /// apart — a grouping or a bucket by library — reads instead of each ID's root path, which
    /// takes the lock and copies the path per row.
    static func rootNumbers(of ids: some Sequence<MediaAssetID>) -> [UInt32] {
        MediaAssetIdentityTable.shared.rootNumbers(of: ids.map(\.place))
    }

    /// Derived from both paths' FNV-1a fingerprints (`PathFingerprint.mediaAsset`), never
    /// persisted or logged as identity.
    var fingerprint: UInt64 {
        MediaAssetIdentityTable.shared.fingerprint(at: place)
    }

    /// Whether this ID's relative path sorts before `other`'s, as
    /// `relativePath.rawValue < other.relativePath.rawValue` would answer, from the table's
    /// bytes: one lock acquisition, no string.
    func relativePathPrecedes(_ other: MediaAssetID) -> Bool {
        MediaAssetIdentityTable.shared.relativePathPrecedes(place, other.place)
    }

    /// Whether this ID's relative path's UTF-8 sorts before `other`'s, byte by byte, as
    /// SQLite's binary collation orders paths: one lock acquisition, no string.
    func relativePathBytesPrecede(_ other: MediaAssetID) -> Bool {
        MediaAssetIdentityTable.shared.relativePathBytesPrecede(place, other.place)
    }

    /// Whether this ID sorts before `other` by library root, then by relative path, each as
    /// `String`'s `<` orders them: the total order of a duplicate group's copies and of the
    /// keeper rule's last tiebreak.
    func pathPrecedes(_ other: MediaAssetID) -> Bool {
        MediaAssetIdentityTable.shared.pathOrder(place, other.place, rootFirst: true) < 0
    }

    /// The order of this ID and `other` by relative path, then by library root, each as
    /// `String`'s `<` orders it: negative when this one comes first, zero when they compare
    /// equal. One lock acquisition, no string.
    func relativePathThenRootOrder(_ other: MediaAssetID) -> Int {
        MediaAssetIdentityTable.shared.pathOrder(place, other.place, rootFirst: false)
    }

    /// The two paths, as the stored pair printed them: a test's message and a diagnostic
    /// name the asset, not its place.
    var customMirror: Mirror {
        Mirror(self, children: [
            "libraryRootPath": libraryRootPath,
            "relativePath": relativePath,
        ], displayStyle: .struct)
    }

    /// The absolute filesystem URL of the original file this identity names. Built
    /// from identity alone — no Store round-trip and no byte read — so the clipboard
    /// copy path and enrichment share one asset→URL construction rather than two that
    /// could disagree. `directoryHint: .notDirectory` avoids a stat: a media asset is
    /// always a file.
    var fileURL: URL {
        libraryRootPath.url.appending(path: relativePath.rawValue, directoryHint: .notDirectory)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(place)
    }
}

/// Media asset identity table guide (ADR 0005, "One identity table for the process")
///
/// Every `MediaAssetID` the process makes is a place in this one table, which holds each
/// distinct (library root, relative path) pair once: the root as one of a few hundred
/// `LibraryRootPath`s, the relative path as its UTF-8 bytes in the table's own regions. The
/// window's orders, collapses, stacks, People's and Duplicates' structures hold 4 bytes per
/// asset, and a read of an order makes no copy of any path that outlives the read
/// (`docs/research/2026-11-17-asset-identity-memory.md`).
///
/// - **One table for the process.** IDs are made wherever a path is read — the Store's
///   decoding, scans, file events, imports, Immich syncs, tests — and an ID from one must equal
///   the same pair's ID from any other, so the place is a value-level fact, like an interned
///   string, not any owner's state (ADR 0005).
/// - **Equality is the bytes.** A pair is found by its root and its relative path's UTF-8,
///   byte for byte, as `MediaRelativePath` and `LibraryRootPath` compare (their fingerprints
///   are FNV-1a over the bytes, so two spellings are two paths there too).
/// - **Order is `String`'s.** Each entry also keeps its relative path's NFC form (the same
///   bytes when the path is already NFC, as every ASCII path is), and `relativePathPrecedes`
///   compares those bytes: `String`'s `<` is the lexicographic order of the NFC form's
///   scalars, which UTF-8 preserves, so the order is exactly the one sorting the decoded
///   strings gave, canonically equivalent spellings comparing equal.
/// - **Nothing in it dies.** A place, once made, names its pair for the rest of the process:
///   an ID held anywhere stays valid, and a pair seen again (a re-read, a rename back) is the
///   same place. It grows by one entry per distinct pair the process ever names — the
///   catalog's rows, and the paths renames, reorganizations, imports and new Immich asset
///   folders add — about 110 bytes each (`usage`, logged in every `op=process.memory` sample).
/// - **Not the malloc heap.** Entries and bytes live in mapped regions (`MappedMemory`, ADR
///   0056) that are never freed, so what the table keeps is never scattered among the freed
///   blocks of the reads that made its pairs; a table of `String`s raises the footprint by
///   about 90 MB that way (`docs/research/2026-11-16-shared-path-strings.md`).
/// - **One lock, held for a rebuild only past the catalog's size.** Finding or adding a pair,
///   reading a place's paths or fingerprint, and comparing two places' paths each take the lock
///   once, for a lookup, a copy or a byte comparison. The index that finds a pair's place is
///   sized at catalog open from the catalog's rows plus a quarter (`reserve(_:)`), so a session
///   that names no more pairs than that never rebuilds it while it holds the lock. Past that —
///   a first Immich sync into an empty catalog, a reorganization of most of a library — it
///   doubles into a new mapping under the lock each time it fills half, moving every place made
///   so far, and the old one is unmapped (ADR 0005).
/// - **Never persisted.** A place is this process's alone; the catalog's key is the pair.
/// - **Steps counted only where a test asks.** A table made with `countingSteps` counts its
///   lock acquisitions and the strings it decodes (`steps`), under the lock it already holds,
///   so a test bounds what a sort or a screenful of tiles costs on a table of its own; the
///   process's table counts nothing.
final nonisolated class MediaAssetIdentityTable: Sendable {
    static let shared = MediaAssetIdentityTable()

    /// What a table made with `countingSteps` has paid: its lock acquisitions and the strings
    /// it has decoded.
    struct Steps: Equatable, Sendable {
        var lockAcquisitions = 0
        var decodes = 0
    }

    private struct Entry {
        let bytes: UnsafePointer<UInt8>
        /// The NFC form's bytes, `bytes` itself when the path is NFC already.
        let orderBytes: UnsafePointer<UInt8>
        let count: UInt32
        let orderCount: UInt32
        let root: UInt32
        let relativeFingerprint: UInt64
    }

    private static let entriesPerChunkShift = 16
    private static let entriesPerChunk = 1 << entriesPerChunkShift
    private static let chunkLimit = 1 << 16
    private static let byteRegionSize = 1 << 20

    /// Everything the table holds, owned by its lock.
    private struct Storage {
        var count: UInt32 = 0
        /// The entries' chunks, by place >> 16; the chunk table is mapped once at its full
        /// size (only touched pages count) and a chunk once it is first needed.
        let chunks: UnsafeMutablePointer<UnsafeMutablePointer<Entry>?>
        var roots: [LibraryRootPath] = []
        var rootIndex: [LibraryRootPath: UInt32] = [:]
        /// Open addressing: each slot is a place + 1, 0 when empty; capacity a power of two,
        /// kept at most half full.
        var slots: UnsafeMutablePointer<UInt32>
        var slotCapacity: Int
        var bytesNext: UnsafeMutablePointer<UInt8>?
        var bytesLeft = 0
        var regions: [UnsafeMutableRawBufferPointer] = []
        /// The most slots one rebuild of the index moved under the lock: the longest anyone
        /// waited behind it.
        var largestRebuild = 0
        let countsSteps: Bool
        var steps = Steps()

        init(countsSteps: Bool) {
            self.countsSteps = countsSteps
            chunks = MappedMemory.map(MediaAssetIdentityTable.chunkLimit, of: UnsafeMutablePointer<Entry>?.self)
            slotCapacity = 1 << 12
            slots = MappedMemory.map(slotCapacity, of: UInt32.self)
        }

        /// One acquisition of the lock, and a string decoded under it when `decodes`.
        mutating func noteLock(decodes: Bool = false) {
            guard countsSteps else { return }
            steps.lockAcquisitions += 1
            if decodes {
                steps.decodes += 1
            }
        }

        func entry(at place: UInt32) -> Entry {
            chunks[Int(place) >> MediaAssetIdentityTable.entriesPerChunkShift]!
                .advanced(by: Int(place) & (MediaAssetIdentityTable.entriesPerChunk - 1)).pointee
        }

        func hash(of entry: Entry) -> UInt64 {
            PathFingerprint.mediaAsset(root: roots[Int(entry.root)].fingerprint, relative: entry.relativeFingerprint)
        }
    }

    private let storage: Mutex<Storage>

    /// A table of its own; `countingSteps` for a test that bounds what it pays (`steps`).
    init(countingSteps: Bool = false) {
        storage = Mutex(Storage(countsSteps: countingSteps))
    }

    /// What this table has paid, when made `countingSteps`; nothing otherwise.
    var steps: Steps {
        storage.withLock { $0.steps }
    }

    /// Only a table a test makes goes: the process's lives as long as the process.
    deinit {
        storage.withLock { storage in
            for chunk in 0 ..< Self.chunkLimit {
                guard let stored = storage.chunks[chunk] else { continue }
                MappedMemory.unmap(UnsafeMutableRawPointer(stored), Self.entriesPerChunk * MemoryLayout<Entry>.stride)
            }
            MappedMemory.unmap(UnsafeMutableRawPointer(storage.chunks), Self.chunkLimit * MemoryLayout<UnsafeMutablePointer<Entry>?>.stride)
            for region in storage.regions {
                region.baseAddress.map { MappedMemory.unmap($0, region.count) }
            }
            MappedMemory.unmap(UnsafeMutableRawPointer(storage.slots), storage.slotCapacity * MemoryLayout<UInt32>.stride)
        }
    }

    /// The place of the pair, made now if the process has not named it before.
    func place(of root: LibraryRootPath, _ relativePath: MediaRelativePath) -> UInt32 {
        let text = relativePath.rawValue
        let relativeFingerprint = relativePath.fingerprint
        let hash = PathFingerprint.mediaAsset(root: root.fingerprint, relative: relativeFingerprint)
        return storage.withLock { storage in
            storage.noteLock()
            // The bytes are read inside the lock, from the path's own string: nothing outside the
            // lock's region reaches the storage.
            var text = text
            return text.withUTF8 { utf8 in
                let rootIndex = storage.rootIndex[root] ?? Self.addRoot(root, to: &storage)
                var slot = Int(truncatingIfNeeded: hash) & (storage.slotCapacity - 1)
                while true {
                    let stored = storage.slots[slot]
                    if stored == 0 {
                        break
                    }
                    let entry = storage.entry(at: stored - 1)
                    if entry.root == rootIndex, entry.relativeFingerprint == relativeFingerprint,
                       Int(entry.count) == utf8.count,
                       utf8.isEmpty || memcmp(entry.bytes, utf8.baseAddress, utf8.count) == 0
                    {
                        return stored - 1
                    }
                    slot = (slot + 1) & (storage.slotCapacity - 1)
                }
                let place = storage.count
                precondition(Int(place) < Self.chunkLimit * Self.entriesPerChunk, "op=assetIdentity.table phase=full")
                let chunkIndex = Int(place) >> Self.entriesPerChunkShift
                if storage.chunks[chunkIndex] == nil {
                    storage.chunks[chunkIndex] = MappedMemory.map(Self.entriesPerChunk, of: Entry.self)
                }
                let bytes = Self.copy(utf8, into: &storage)
                let order = Self.orderForm(of: utf8, bytes: bytes, into: &storage)
                storage.chunks[chunkIndex]!.advanced(by: Int(place) & (Self.entriesPerChunk - 1)).initialize(to: Entry(
                    bytes: bytes,
                    orderBytes: order.bytes,
                    count: UInt32(utf8.count),
                    orderCount: order.count,
                    root: rootIndex,
                    relativeFingerprint: relativeFingerprint
                ))
                storage.slots[slot] = place + 1
                storage.count = place + 1
                if Int(storage.count) * 2 > storage.slotCapacity {
                    Self.rebuild(&storage, capacity: storage.slotCapacity * 2)
                }
                return place
            }
        }
    }

    /// Sizes the index for `count` pairs, so a session that names no more never rebuilds it.
    /// The catalog calls it at open with its rows, before its first read makes their IDs.
    func reserve(_ count: Int) {
        storage.withLock { storage in
            storage.noteLock()
            var capacity = storage.slotCapacity
            while count * 2 > capacity {
                capacity *= 2
            }
            if capacity > storage.slotCapacity {
                Self.rebuild(&storage, capacity: capacity)
            }
        }
    }

    func root(at place: UInt32) -> LibraryRootPath {
        storage.withLock { storage in
            storage.noteLock()
            return storage.roots[Int(storage.entry(at: place).root)]
        }
    }

    /// The root number of each of `places`, in order, under one lock acquisition.
    func rootNumbers(of places: [UInt32]) -> [UInt32] {
        var roots = places
        storage.withLock { storage in
            storage.noteLock()
            for index in roots.indices {
                roots[index] = storage.entry(at: roots[index]).root
            }
        }
        return roots
    }

    func relativePath(at place: UInt32) -> MediaRelativePath {
        storage.withLock { storage in
            storage.noteLock(decodes: true)
            let entry = storage.entry(at: place)
            let text = String(decoding: UnsafeBufferPointer(start: entry.bytes, count: Int(entry.count)), as: UTF8.self)
            return MediaRelativePath(rawValue: text, fingerprint: entry.relativeFingerprint)
        }
    }

    func fingerprint(at place: UInt32) -> UInt64 {
        storage.withLock { storage in
            storage.noteLock()
            return storage.hash(of: storage.entry(at: place))
        }
    }

    /// Whether the relative path at `place` sorts before the one at `other` by `String`'s `<`:
    /// their NFC bytes compared under one lock acquisition, no string (see the guide).
    func relativePathPrecedes(_ place: UInt32, _ other: UInt32) -> Bool {
        guard place != other else { return false }
        return storage.withLock { storage in
            storage.noteLock()
            let left = storage.entry(at: place)
            let right = storage.entry(at: other)
            return Self.precedes(left.orderBytes, Int(left.orderCount), right.orderBytes, Int(right.orderCount))
        }
    }

    /// Whether the relative path at `place` sorts before the one at `other` by its UTF-8
    /// bytes, as SQLite's binary collation compares them.
    func relativePathBytesPrecede(_ place: UInt32, _ other: UInt32) -> Bool {
        guard place != other else { return false }
        return storage.withLock { storage in
            storage.noteLock()
            let left = storage.entry(at: place)
            let right = storage.entry(at: other)
            return Self.precedes(left.bytes, Int(left.count), right.bytes, Int(right.count))
        }
    }

    /// The order of the pairs at `place` and `other` by library root and by relative path, each
    /// as `String`'s `<` orders it, root first when `rootFirst`: negative when `place` comes
    /// first, zero when they compare equal, from one lock acquisition and no string.
    func pathOrder(_ place: UInt32, _ other: UInt32, rootFirst: Bool) -> Int {
        guard place != other else { return 0 }
        return storage.withLock { storage in
            storage.noteLock()
            let left = storage.entry(at: place)
            let right = storage.entry(at: other)
            let relative = Self.precedes(left.orderBytes, Int(left.orderCount), right.orderBytes, Int(right.orderCount)) ? -1
                : Self.precedes(right.orderBytes, Int(right.orderCount), left.orderBytes, Int(left.orderCount)) ? 1 : 0
            var root = 0
            if left.root != right.root {
                let (leftRoot, rightRoot) = (storage.roots[Int(left.root)].rawValue, storage.roots[Int(right.root)].rawValue)
                root = leftRoot < rightRoot ? -1 : rightRoot < leftRoot ? 1 : 0
            }
            return rootFirst ? (root != 0 ? root : relative) : (relative != 0 ? relative : root)
        }
    }

    private static func precedes(_ left: UnsafePointer<UInt8>, _ leftCount: Int, _ right: UnsafePointer<UInt8>, _ rightCount: Int) -> Bool {
        let shorter = min(leftCount, rightCount)
        let compared = shorter == 0 ? 0 : memcmp(left, right, shorter)
        return compared != 0 ? compared < 0 : leftCount < rightCount
    }

    /// The pairs the process has named.
    var count: Int {
        storage.withLock { Int($0.count) }
    }

    /// What the table holds, for `op=process.memory`: its pairs, the bytes its entries, path
    /// bytes and index occupy, and the most slots one rebuild of the index has moved under the
    /// lock, the longest anyone waited behind it (a session past the catalog's size shows it).
    var usage: (pairs: Int, bytes: Int, largestRebuild: Int) {
        storage.withLock { storage in
            let entries = Int(storage.count) * MemoryLayout<Entry>.stride
            let regions = storage.regions.reduce(0) { $0 + $1.count }
            return (
                Int(storage.count), entries + regions + storage.slotCapacity * MemoryLayout<UInt32>.stride,
                storage.largestRebuild
            )
        }
    }

    private static func addRoot(_ root: LibraryRootPath, to storage: inout Storage) -> UInt32 {
        let index = UInt32(storage.roots.count)
        storage.roots.append(root)
        storage.rootIndex[root] = index
        return index
    }

    /// A stable copy of `utf8` in the table's byte regions.
    private static func copy(_ utf8: UnsafeBufferPointer<UInt8>, into storage: inout Storage) -> UnsafePointer<UInt8> {
        if storage.bytesNext == nil || storage.bytesLeft < utf8.count {
            let size = max(byteRegionSize, utf8.count)
            let region = MappedMemory.map(size, of: UInt8.self)
            storage.bytesNext = region
            storage.bytesLeft = size
            storage.regions.append(UnsafeMutableRawBufferPointer(start: region, count: size))
        }
        let destination = storage.bytesNext!
        if let source = utf8.baseAddress, !utf8.isEmpty {
            destination.update(from: source, count: utf8.count)
        }
        storage.bytesNext = destination.advanced(by: utf8.count)
        storage.bytesLeft -= utf8.count
        return UnsafePointer(destination)
    }

    /// The NFC form of a path for ordering: `bytes` itself when the path is ASCII or already
    /// NFC, else a copy of its NFC form's bytes.
    private static func orderForm(
        of utf8: UnsafeBufferPointer<UInt8>, bytes: UnsafePointer<UInt8>, into storage: inout Storage
    ) -> (bytes: UnsafePointer<UInt8>, count: UInt32) {
        guard utf8.contains(where: { $0 >= 0x80 }) else {
            return (bytes, UInt32(utf8.count))
        }
        var composed = String(decoding: utf8, as: UTF8.self).precomposedStringWithCanonicalMapping
        return composed.withUTF8 { nfc in
            if nfc.elementsEqual(utf8) {
                return (bytes, UInt32(utf8.count))
            }
            return (copy(nfc, into: &storage), UInt32(nfc.count))
        }
    }

    /// Moves every place into an index of `capacity` slots and unmaps the old one.
    private static func rebuild(_ storage: inout Storage, capacity: Int) {
        let slots = MappedMemory.map(capacity, of: UInt32.self)
        for old in 0 ..< storage.slotCapacity {
            let stored = storage.slots[old]
            guard stored != 0 else { continue }
            var slot = Int(truncatingIfNeeded: storage.hash(of: storage.entry(at: stored - 1))) & (capacity - 1)
            while slots[slot] != 0 {
                slot = (slot + 1) & (capacity - 1)
            }
            slots[slot] = stored
        }
        storage.largestRebuild = max(storage.largestRebuild, storage.slotCapacity)
        MappedMemory.unmap(UnsafeMutableRawPointer(storage.slots), storage.slotCapacity * MemoryLayout<UInt32>.stride)
        storage.slots = slots
        storage.slotCapacity = capacity
    }
}

extension MediaAssetIdentityTable {
    /// The ID of the pair in this table: for an owner made with a table of its own (a test's
    /// `TileContentStore`), whose IDs it reads back through the same table.
    func id(_ root: LibraryRootPath, _ relativePath: MediaRelativePath) -> MediaAssetID {
        MediaAssetID(place: place(of: root, relativePath))
    }

    func libraryRootPath(of id: MediaAssetID) -> LibraryRootPath {
        root(at: id.place)
    }

    func relativePath(of id: MediaAssetID) -> MediaRelativePath {
        relativePath(at: id.place)
    }
}

/// Who a removable source is, as its monitor identified it: a volume by its UUID, or by
/// where it is mounted when it reports none; a camera by its persistent id, or by its name
/// when it reports none. The text is what the catalog and the import journal persist, so
/// it is built and read only here. An identity from a mount path or a name is transient: it
/// names one attachment, not the device, so the catalog does not keep a root for it.
/// The one rule for what names an Immich server (ADR 0046 §2).
nonisolated enum ImmichServerAddress {
    /// `scheme://host[:port][/path]`, scheme and host lowercased, a default port and any
    /// trailing slash, query or fragment dropped. Nil unless the scheme is http or https
    /// and there is a host.
    static func normalized(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}

nonisolated struct DeviceIdentity: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: String

    /// Reads persisted text back. Monitors build identities with the constructors below.
    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func volume(uuid: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "volume:\(uuid)")
    }

    static func volume(mountPath: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "volume:path:\(mountPath)")
    }

    static func camera(id: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "camera:\(id)")
    }

    static func camera(name: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "camera:transient:\(name)")
    }

    /// One user on one Immich server (ADR 0046 §2): `immich:<server>#<user id>`. The
    /// server is normalized so one server typed two ways is one account: the scheme and
    /// host lowercased, a default port and a trailing slash dropped. Nil for a URL that
    /// is not http or https with a host.
    static func immichAccount(server: URL, userID: String) -> DeviceIdentity? {
        guard let normalized = ImmichServerAddress.normalized(server) else {
            return nil
        }
        return DeviceIdentity(rawValue: "immich:\(normalized.absoluteString)#\(userID)")
    }

    /// Two attached volumes that report one identity: each after the first is told apart
    /// by where it is mounted, which makes it transient.
    func disambiguated(mountPath: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "\(rawValue)#path:\(mountPath)")
    }

    var isTransient: Bool {
        rawValue.hasPrefix("volume:path:")
            || rawValue.contains("#path:")
            || rawValue.hasPrefix("camera:transient:")
    }

    var description: String {
        rawValue
    }

    static func < (lhs: DeviceIdentity, rhs: DeviceIdentity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Durable saved library identity. This intentionally contains no scan status
/// and no SQLite rowid: the path is the product identity, while storage keys stay
/// private to persistence.
/// How long a card or camera may go unseen before Otos forgets it (ADR 0013). A product rule, not a stand-in for a fact: no
/// report can say that an absent device will never return.
nonisolated enum RemovableSourceRetention {
    static let unseenPeriod: TimeInterval = 90 * 24 * 60 * 60
}

nonisolated struct LibraryRoot: Identifiable, Hashable {
    let path: LibraryRootPath
    let kind: LibraryRootKind
    let deviceIdentity: DeviceIdentity?
    let displayNameOverride: String?
    let lastSeenAt: Date?
    /// The server an Immich account reads from (ADR 0046 §2); nil for every other kind.
    let remoteBaseURL: URL?

    init(
        path: LibraryRootPath,
        kind: LibraryRootKind = .library,
        deviceIdentity: DeviceIdentity? = nil,
        displayName: String? = nil,
        lastSeenAt: Date? = nil,
        remoteBaseURL: URL? = nil
    ) {
        self.path = path
        self.kind = kind
        self.deviceIdentity = deviceIdentity
        displayNameOverride = displayName
        self.lastSeenAt = lastSeenAt
        self.remoteBaseURL = remoteBaseURL
    }

    var id: LibraryRootPath {
        path
    }

    var displayName: String {
        displayNameOverride?.isEmpty == false ? displayNameOverride ?? path.displayName : path.displayName
    }

    /// Where the root's originals live, as Settings names it: an account's server, or
    /// the folder's path.
    var locationDescription: String {
        remoteBaseURL?.absoluteString ?? path.rawValue
    }

    /// A card or camera (`LibraryRootKind.isRemovable`).
    var isRemovableSource: Bool {
        kind.isRemovable
    }

    /// `LibraryRootKind.claimsEveryProductTogether`.
    var claimsEveryProductTogether: Bool {
        kind.claimsEveryProductTogether
    }

    /// `LibraryRootKind.firstClaim`.
    var firstClaim: EnrichmentClaim {
        kind.firstClaim
    }

    /// `LibraryRootKind.producesAfterMetadata`.
    var producesAfterMetadata: Bool {
        kind.producesAfterMetadata
    }
}

/// The catalog stores every source as a root because the filesystem path remains
/// the asset identity boundary. Kind only changes ownership semantics: fixed
/// libraries participate in All Media and launch scans, while removable sources
/// are event-driven and are scoped to their own sidebar rows.
///
/// Every question a caller asks about a kind is one named capability below, each an
/// exhaustive `switch`, so a new kind does not compile until it answers every question
/// (ADR 0046). No caller compares kinds directly: a bare `kind == .library` answers a
/// different question at each call site, and a new kind would be wrong in most of them.
nonisolated enum LibraryRootKind: String, CaseIterable, Hashable, Codable {
    case library
    case removableVolume
    case deviceMTP
    /// One user's assets on an Immich server, read only (ADR 0046).
    case immichAccount

    /// A folder on this Mac the user chose as a library (ADR 0003): its stored path is
    /// normalized at load, it is scanned at launch and by integrity scans on the fixed
    /// libraries' lane, and `MetadataRefresher` re-reads its rows from local bytes.
    var isUserChosenFolder: Bool {
        switch self {
        case .library: true
        case .removableVolume, .deviceMTP, .immichAccount: false
        }
    }

    /// Listed in the sidebar's Libraries section, in the user's order, rather than in
    /// Removable while connected.
    var isInLibrariesSection: Bool {
        switch self {
        case .library, .immichAccount: true
        case .removableVolume, .deviceMTP: false
        }
    }

    /// Spanned by All Media, Places, Imports and Duplicates (ADR 0013 decision 3).
    var isMemberOfAllMedia: Bool {
        switch self {
        case .library, .immichAccount: true
        case .removableVolume, .deviceMTP: false
        }
    }

    /// Its stills are read for faces, from their stored previews (ADR 0047). A card's or a
    /// camera's are read once imported into a library, where their overlay lives on.
    /// Its videos are read for faces from their frames (ADR 0047): a library's from local
    /// bytes, an Immich account's in byte ranges from its server. A card's or a camera's are
    /// read once imported into a library.
    var readsVideoFaces: Bool {
        switch self {
        case .library, .immichAccount: true
        case .removableVolume, .deviceMTP: false
        }
    }

    var readsFaces: Bool {
        switch self {
        case .library, .immichAccount: true
        case .removableVolume, .deviceMTP: false
        }
    }

    /// Where an import may copy media to, and whose digests an import trusts as
    /// "already in a library".
    var isImportDestination: Bool {
        switch self {
        case .library: true
        case .removableVolume, .deviceMTP, .immichAccount: false
        }
    }

    /// Library reorganization may move its originals within it (ADR 0003, ARC-051): a
    /// folder the user chose, whose files Otos may move only when told to.
    var supportsReorganization: Bool {
        switch self {
        case .library: true
        case .removableVolume, .deviceMTP, .immichAccount: false
        }
    }

    /// An import copies from it (ADR 0013): a card or camera. Its inventory and capture walls
    /// are what a plan copies and names, so its namespace and naming revisions wake the
    /// import coordinator.
    var isImportSource: Bool {
        isRemovable
    }

    /// An import plans against it, as its source or its destination, so a change to the
    /// paths it occupies wakes the import coordinator. An Immich account is neither.
    var isImportPlanned: Bool {
        isImportSource || isImportDestination
    }

    /// A card or camera (ADR 0013): it attaches and detaches, starts each launch
    /// unavailable, is an import source, is enriched ahead of fixed libraries while
    /// connected, holds rows awaiting presence on attach, and is forgotten after the
    /// retention period unseen.
    var isRemovable: Bool {
        switch self {
        case .removableVolume, .deviceMTP: true
        case .library, .immichAccount: false
        }
    }

    /// Has a filesystem namespace Otos walks and watches: a library, or a mounted card.
    var hasFilesystemNamespace: Bool {
        switch self {
        case .library, .removableVolume: true
        case .deviceMTP, .immichAccount: false
        }
    }

    /// Move to Trash applies to its originals (ADR 0022). A camera's files are not on a
    /// filesystem the Trash can reach.
    var supportsMoveToTrash: Bool {
        switch self {
        case .library, .removableVolume: true
        case .deviceMTP, .immichAccount: false
        }
    }

    /// Rows come from the source's own listing under an enumeration lease, not from a
    /// filesystem walk (ADR 0013 decision 5).
    var rowsComeFromSourceListing: Bool {
        switch self {
        case .deviceMTP, .immichAccount: true
        case .library, .removableVolume: false
        }
    }

    /// The Otos staging container this kind's originals are copied into on demand, or nil
    /// when they are read in place. The staging folder and its files are Otos's to release.
    var stagingContainer: StagingContainer? {
        switch self {
        case .deviceMTP: .device
        case .immichAccount: .remote
        case .library, .removableVolume: nil
        }
    }

    /// Originals are copied into an Otos staging folder rather than read in place.
    var stagesOriginals: Bool {
        stagingContainer != nil
    }

    /// Its source sends an original only for work the user is waiting on, never to enrich a
    /// library (ADR 0046 §4, owner 2026-11-09): an Immich account's originals are read in
    /// ranges for enrichment and downloaded only for a zoom, an edit, an export or a
    /// hand-off. A card's or a camera's are copied for any work.
    var sendsOriginalsOnlyForUserWork: Bool {
        switch self {
        case .immichAccount: true
        case .library, .removableVolume, .deviceMTP: false
        }
    }

    /// An import reads this source's own files in place, so enrichment leaves the source
    /// alone while one runs rather than competing for its bandwidth.
    var pausesEnrichmentWhileImporting: Bool {
        switch self {
        case .removableVolume: true
        case .library, .deviceMTP, .immichAccount: false
        }
    }

    /// Whether enrichment claims this kind's rows for every stale product at once —
    /// metadata, rendering and digest from one read (ADR 0009, ADR 0018). A fixed library
    /// does: its files may be cloud-only, and a download is paid once for all of them.
    ///
    /// A removable volume is claimed for metadata first, which is what an import waits on,
    /// and for its renderings and digests in a pass of its own once every row of the card
    /// has its metadata (`producesAfterMetadata`): its bytes are local, so reading it twice
    /// downloads nothing.
    ///
    /// `.deviceMTP` is claimed for metadata only: a camera row is enriched from a few
    /// kilobytes of ranged reads, and a rendering or digest would force the whole-file
    /// transfer. Those rows get both at import, from the staged copy's local bytes.
    var claimsEveryProductTogether: Bool {
        switch self {
        case .library: true
        case .removableVolume, .deviceMTP, .immichAccount: false
        }
    }

    /// The claim a row of this kind is first enriched under (ADR 0018, ADR 0047): a fixed
    /// library's every product, a video's faces included; an Immich account's metadata and
    /// a video's faces, read in ranges; or metadata first. A card's renderings and digests
    /// come later, under `EnrichmentClaim.products`.
    var firstClaim: EnrichmentClaim {
        if claimsEveryProductTogether {
            return .library
        }
        return readsVideoFaces ? .account : .metadata
    }

    /// The kinds that have `capability`, as a SQL list of quoted `library_root.kind`
    /// values, so a query states the same rule the Swift callers ask. Raw values are
    /// fixed identifiers with no quotes, so they need no escaping.
    static func sqlLiteralList(_ capability: KeyPath<Self, Bool>) -> String {
        allCases.filter { $0[keyPath: capability] }.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    /// Whether this kind's rows get a rendering-and-digest pass once metadata is current.
    var producesAfterMetadata: Bool {
        switch self {
        case .removableVolume: true
        case .library, .deviceMTP, .immichAccount: false
        }
    }

    var sidebarSystemImage: String {
        switch self {
        case .library:
            "folder"
        case .removableVolume:
            "sdcard"
        case .deviceMTP:
            "camera"
        case .immichAccount:
            "server.rack"
        }
    }

    /// Its rows stay in the grid while its source cannot be reached: the catalog holds the
    /// source's last listing, and its thumbnails and previews are stored (ADR 0046 §6). A
    /// folder or card that is gone shows nothing, because its filesystem is its truth.
    var showsRowsWhileUnreachable: Bool {
        switch self {
        case .immichAccount: true
        case .library, .removableVolume, .deviceMTP: false
        }
    }

    /// What a launch knows of a saved root before any source has answered. A fixed
    /// library is what one `stat` of its folder says (`folderIsReachable`), asked as the
    /// catalog loads, so its rows show at once and its launch scan only reconciles them. A
    /// card or camera is unavailable until a monitor attaches it. An account's stored listing
    /// is its truth until its server reports otherwise, so it is available at once; whether
    /// the server answers is a separate fact (ADR 0046 §6).
    func availabilityAtLaunch(folderIsReachable: () -> Bool) -> LibraryAvailability {
        switch self {
        case .library: folderIsReachable() ? .available : .unavailable
        case .removableVolume, .deviceMTP: .unavailable
        case .immichAccount: .available
        }
    }
}

/// The one authored curation value for a cataloged image or video. It is overlay
/// state, not a filesystem fact: originals and useful companions remain untouched.
nonisolated enum MediaChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case liked
    case notRated
    case disliked

    static let `default` = MediaChoice.notRated

    var label: String {
        switch self {
        case .liked: "Liked"
        case .notRated: "Not Rated"
        case .disliked: "Disliked"
        }
    }

    var actionLabel: String {
        switch self {
        case .liked: "Like"
        case .notRated: "Mark as Not Rated"
        case .disliked: "Dislike"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .liked: "liked"
        case .notRated: "not rated"
        case .disliked: "disliked"
        }
    }

    var accessibilityActionLabel: String {
        switch self {
        case .liked: "Like item"
        case .notRated: "Mark item as not rated"
        case .disliked: "Dislike item"
        }
    }

    /// The flat glyph that names this value where all three are listed at once
    /// (the filter popover). The hover control does not use it: there the two
    /// acts are toggles with an outline/filled pair, which `MediaChoiceToggle`
    /// owns.
    var systemImage: String {
        switch self {
        case .liked: "hand.thumbsup"
        case .notRated: "minus"
        case .disliked: "hand.thumbsdown"
        }
    }

    init?(keyCharacter: String) {
        switch keyCharacter.lowercased() {
        case "p": self = .liked
        case "u": self = .notRated
        case "x": self = .disliked
        default: return nil
        }
    }
}

/// The two acts the hover control offers. Neutral is deliberately not a button:
/// pressing the act an item already carries returns it to `.notRated`, so the
/// control is two toggles rather than three mutually exclusive states (DES-066).
/// `MediaChoice` keeps all three values — the neutral one is still reachable by
/// keyboard (`u`), by menu, and as a VoiceOver action; it just has no button.
nonisolated enum MediaChoiceToggle: String, CaseIterable, Hashable, Sendable {
    case like
    case dislike

    var choice: MediaChoice {
        switch self {
        case .like: .liked
        case .dislike: .disliked
        }
    }

    /// Outline at rest, filled when the item carries this act's choice. Shape,
    /// not tint, is what carries the selected state, so it survives grayscale
    /// and Increase Contrast (DES-068).
    func symbol(isOn: Bool) -> String {
        switch self {
        case .like: isOn ? "hand.thumbsup.fill" : "hand.thumbsup"
        case .dislike: isOn ? "hand.thumbsdown.fill" : "hand.thumbsdown"
        }
    }

    /// The one resolution every surface shares. The grid tile (AppKit) and the
    /// Loupe/Compare control (SwiftUI) are two renderers of one user intent, so
    /// neither re-derives "pressing the active act clears it" for itself.
    func resolved(from current: MediaChoice) -> MediaChoice {
        current == choice ? .notRated : choice
    }

    var actionLabel: String {
        choice.actionLabel
    }
}

/// Availability is the most recent reachability observation for a saved root.
/// Loaded roots begin unknown because SQLite proves only that the path was saved;
/// the pre-scan filesystem check is what proves available or unavailable. This
/// state is deliberately transient because a mounted volume can disappear
/// without any catalog mutation.
nonisolated enum LibraryAvailability: Hashable {
    case unknown
    case available
    case unavailable
}

/// Scan activity is separate from availability: an available library can be
/// idle or scanning, while an unavailable library preserves catalog rows without
/// pretending a scan is in progress.
nonisolated enum CatalogLibraryActivity: Hashable {
    case idle
    case scanning
    case enumerating
}

/// One projected library row. The durable root remains pure identity; this row
/// adds transient runtime facts needed by the current UI surfaces.
nonisolated struct CatalogLibraryState: Identifiable, Hashable {
    let root: LibraryRoot
    /// User-controlled order, durable on the root row.
    /// Authoritative for library-kind roots: the first available one, in this
    /// order, is the deterministic import destination, and Settings → Libraries
    /// shows and reorders exactly this order. Removable sources carry a value
    /// too but are sorted by display name at query time regardless
    /// (`CatalogWindowPolicy.sortLibraries`).
    let sortIndex: Int64
    let availability: LibraryAvailability
    let activity: CatalogLibraryActivity
    let isEjectable: Bool
    /// Store-owned process-local identity of the current removable attachment.
    /// It is never persisted and is zero for roots constructed outside the live
    /// attachment owner.
    let attachmentGeneration: UInt64

    var id: LibraryRootPath {
        root.id
    }

    var path: LibraryRootPath {
        root.path
    }

    var displayName: String {
        root.displayName
    }

    var kind: LibraryRootKind {
        root.kind
    }

    var deviceIdentity: DeviceIdentity? {
        root.deviceIdentity
    }

    var lastSeenAt: Date? {
        root.lastSeenAt
    }

    var isScanning: Bool {
        activity == .scanning
    }

    var isEnumerating: Bool {
        activity == .enumerating
    }

    var isAvailable: Bool {
        availability == .available
    }

    init(
        root: LibraryRoot,
        sortIndex: Int64 = 0,
        availability: LibraryAvailability,
        activity: CatalogLibraryActivity,
        isEjectable: Bool = false,
        attachmentGeneration: UInt64 = 0
    ) {
        self.root = root
        self.sortIndex = sortIndex
        self.availability = availability
        self.activity = activity
        self.isEjectable = isEjectable
        self.attachmentGeneration = attachmentGeneration
    }
}

/// One cataloged file and the hot facts the grid can read by identity. Library
/// display text is intentionally absent: it is derived from `LibraryRootPath`, so
/// storing it on every asset would create a second value that could disagree with
/// root identity.
nonisolated struct MediaAsset: Identifiable, Hashable {
    let libraryRootPath: LibraryRootPath
    let relativePath: MediaRelativePath
    let name: String?
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?
    /// Precomputed display-order key. Sorting the catalog by comparing these cheap
    /// keys replaces a localized collation call per comparison, which a 25k-asset
    /// sort measured at roughly 500 ms. The key is derived from identity, so it is
    /// constant for an asset and never disagrees with it.
    let sortKey: String

    // Enrichment overlay and SQLite-derived best values. The best date/kind/format
    // fields are generated in SQLite from scan and enrichment facts, so query,
    // sort, filter, and the video badge use the same policy without a Swift
    // fallback chain. Capture dates remain catalog facts, not tile labels.
    // Full parsed metadata lives in the `asset_metadata` companion table as queryable
    // scalar columns plus JSON for long-tail fields, and is not loaded by the grid.
    //
    // Filesystem facts (scan) and enrichment overlay have disjoint writers: the scan
    // refreshes facts and preserves these fields, while enrichment writes these and
    // preserves facts. Staleness is derived, never stored, per product (ADR 0009): the
    // metadata, the rendering, the digest and the faces each record the
    // `(size, mtime-seconds)` they were made from, and each is stale when the file's
    // current pair differs.
    let thumbnailPath: String?
    let captureLocalTime: CaptureLocalTime?
    let bestKind: MediaKind?
    let bestFormat: MediaFormatToken?
    let durationSeconds: Double?
    let metadataSourceSize: Int64?
    let metadataSourceMTimeSeconds: Int?
    let renderedSourceSize: Int64?
    let renderedSourceMTimeSeconds: Int?
    let contentHash: ContentDigest?
    let contentHashSourceSize: Int64?
    let contentHashSourceMTimeSeconds: Int?
    let facesSourceSize: Int64?
    let facesSourceMTimeSeconds: Int?
    let mediaChoice: MediaChoice

    init(
        libraryRootPath: LibraryRootPath,
        relativePath: MediaRelativePath,
        name: String?,
        contentTypeIdentifier: String?,
        byteSize: Int64?,
        createdAt: Date?,
        contentModifiedAt: Date?,
        thumbnailPath: String? = nil,
        captureLocalTime: CaptureLocalTime? = nil,
        bestKind: MediaKind? = nil,
        bestFormat: MediaFormatToken? = nil,
        durationSeconds: Double? = nil,
        metadataSourceSize: Int64? = nil,
        metadataSourceMTimeSeconds: Int? = nil,
        renderedSourceSize: Int64? = nil,
        renderedSourceMTimeSeconds: Int? = nil,
        contentHash: ContentDigest? = nil,
        contentHashSourceSize: Int64? = nil,
        contentHashSourceMTimeSeconds: Int? = nil,
        facesSourceSize: Int64? = nil,
        facesSourceMTimeSeconds: Int? = nil,
        mediaChoice: MediaChoice = .default
    ) {
        self.libraryRootPath = libraryRootPath
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.name = name
        self.contentTypeIdentifier = contentTypeIdentifier
        self.createdAt = createdAt
        self.contentModifiedAt = contentModifiedAt
        self.thumbnailPath = thumbnailPath
        self.captureLocalTime = captureLocalTime
        self.bestKind = bestKind
        self.bestFormat = bestFormat
        self.durationSeconds = durationSeconds
        self.metadataSourceSize = metadataSourceSize
        self.metadataSourceMTimeSeconds = metadataSourceMTimeSeconds
        self.renderedSourceSize = renderedSourceSize
        self.renderedSourceMTimeSeconds = renderedSourceMTimeSeconds
        self.contentHash = contentHash
        self.contentHashSourceSize = contentHashSourceSize
        self.contentHashSourceMTimeSeconds = contentHashSourceMTimeSeconds
        self.facesSourceSize = facesSourceSize
        self.facesSourceMTimeSeconds = facesSourceMTimeSeconds
        self.mediaChoice = mediaChoice
        sortKey = MediaSortKey.make(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    var id: MediaAssetID {
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    /// Whole-seconds form of a filesystem date for the staleness signature. Whole
    /// seconds avoid the `Double` epsilon that would otherwise make a reloaded date
    /// look different from a freshly scanned one (see ARC-038/ARC-039).
    static func mtimeSeconds(_ date: Date?) -> Int {
        date.map { Int($0.timeIntervalSince1970.rounded(.down)) } ?? -1
    }

    /// True when the metadata stamp (parsed metadata, kind, format, capture-wall facts) is
    /// not valid for the current filesystem signature.
    var metadataStale: Bool {
        !stampIsCurrent(size: metadataSourceSize, mtimeSeconds: metadataSourceMTimeSeconds)
    }

    /// True when the rendering stamp (the thumbnail and preview made from one development,
    /// ADR 0035) is not valid for the current filesystem signature. A provisional
    /// thumbnail — QuickLook's on a card's first pass, a camera's embedded one — is not a
    /// rendering and leaves this true.
    var renderingStale: Bool {
        !stampIsCurrent(size: renderedSourceSize, mtimeSeconds: renderedSourceMTimeSeconds)
    }

    /// True when the persisted content hash is missing, malformed, or does not match
    /// the current filesystem signature. Meaningless on its own: a root that never
    /// hashes (`.removableVolume`, see ADR 0018) must not be judged stale by this
    /// alone. Callers gate it behind the claim.
    var hashStale: Bool {
        contentHash == nil
            || contentHashSourceSize == nil
            || contentHashSourceMTimeSeconds == nil
            || !stampIsCurrent(size: contentHashSourceSize, mtimeSeconds: contentHashSourceMTimeSeconds)
    }

    /// True when a video's faces stamp (its frames' reading, ADR 0047) is not valid for the
    /// current filesystem signature. A still's faces are read from its stored preview, never
    /// by enrichment, so a still never owes them here. Owed only by a row claimed under
    /// `EnrichmentClaim.library`; callers gate it behind the claim.
    var videoFacesStale: Bool {
        bestKind == .video && !stampIsCurrent(size: facesSourceSize, mtimeSeconds: facesSourceMTimeSeconds)
    }

    /// Whether a product's stamp names the file's current `(size, mtime-seconds)`: the one
    /// staleness rule every product shares (ADR 0009).
    private func stampIsCurrent(size: Int64?, mtimeSeconds: Int?) -> Bool {
        size == (byteSize ?? -1) && mtimeSeconds == Self.mtimeSeconds(contentModifiedAt)
    }

    /// True when a product `claim` covers is stale. The claim is the one the Store chose for
    /// the row's root and pass (ADR 0018); this pure value type never derives it itself, so a
    /// caller cannot forget to supply it and silently fall back to a wrong default. The Swift
    /// twin of `EnrichmentClaimGateway.stalenessSQLPredicate(_:)`.
    func needsEnrichment(_ claim: EnrichmentClaim) -> Bool {
        switch claim {
        case .metadata: metadataStale
        case .products: metadataStale || renderingStale || hashStale
        case .library: metadataStale || renderingStale || hashStale || videoFacesStale
        case .account: metadataStale || videoFacesStale
        }
    }
}

nonisolated extension MediaAsset {
    /// Its tile shows a placeholder until a thumbnail is made: none yet, and rendering has not
    /// found that none can be. The Swift twin of `EnrichmentClaimGateway.placeholderSQL`.
    var showsPlaceholder: Bool {
        thumbnailPath == nil && renderedSourceMTimeSeconds == nil
    }
}

/// The narrow detail value a visible grid tile needs after structure publishes
/// only identities. It intentionally omits filename and capture-date facts so the
/// thumbnail boundary cannot accidentally keep rendering removed labels.
nonisolated struct MediaTileDetail: Identifiable, Hashable {
    let libraryRootPath: LibraryRootPath
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let thumbnailPath: String?
    /// The stored loupe preview, which the loupe and compare decode instead of the
    /// original (ADR 0035); nil until enrichment rendered one, and for videos.
    let previewPath: String?
    /// The original's oriented pixel size from stored metadata, so the loupe can size its
    /// 100% document without reading the original's header (which would download a
    /// cloud-only file); nil until metadata is known.
    let nativePixelWidth: Int?
    let nativePixelHeight: Int?
    /// The photo's saved edit (ADR 0036); nil when never edited.
    let editRecipe: EditRecipe?
    /// The edit revision the stored thumbnail and preview were rendered from. It changes
    /// with every rendered edit, so it keys every cached image of them.
    let renderedRevision: Int64
    let bestKind: MediaKind?
    let durationSeconds: Double?
    /// The `(size, mtime)` the stored thumbnail and preview were rendered from (ADR 0009):
    /// nil while the row has no rendering, including while a provisional thumbnail shows.
    let renderedSourceSize: Int64?
    let renderedSourceMTimeSeconds: Int?
    let mediaChoice: MediaChoice
    /// The key the row's copies share (ADR 0054, `media_asset.copy_key`), nil for a row that is
    /// no copy of any photo: the relation a choice
    /// is written through (`media_asset_choice_made`), so the window shows a held choice on
    /// every copy it holds (`MediaChoiceOverlay`).
    let copyKey: PhotoCopyKey?

    /// This detail with another choice: what a tile shows while a choice the catalog has not
    /// recorded yet is held (`MediaChoiceOverlay`).
    func with(mediaChoice choice: MediaChoice) -> MediaTileDetail {
        MediaTileDetail(
            libraryRootPath: libraryRootPath,
            relativePath: relativePath,
            byteSize: byteSize,
            thumbnailPath: thumbnailPath,
            previewPath: previewPath,
            nativePixelWidth: nativePixelWidth,
            nativePixelHeight: nativePixelHeight,
            editRecipe: editRecipe,
            renderedRevision: renderedRevision,
            bestKind: bestKind,
            durationSeconds: durationSeconds,
            renderedSourceSize: renderedSourceSize,
            renderedSourceMTimeSeconds: renderedSourceMTimeSeconds,
            mediaChoice: choice,
            copyKey: copyKey
        )
    }

    init(
        libraryRootPath: LibraryRootPath,
        relativePath: MediaRelativePath,
        byteSize: Int64? = nil,
        thumbnailPath: String? = nil,
        previewPath: String? = nil,
        nativePixelWidth: Int? = nil,
        nativePixelHeight: Int? = nil,
        editRecipe: EditRecipe? = nil,
        renderedRevision: Int64 = 0,
        bestKind: MediaKind? = nil,
        durationSeconds: Double? = nil,
        renderedSourceSize: Int64? = nil,
        renderedSourceMTimeSeconds: Int? = nil,
        mediaChoice: MediaChoice = .default,
        copyKey: PhotoCopyKey? = nil
    ) {
        self.libraryRootPath = libraryRootPath
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.thumbnailPath = thumbnailPath
        self.previewPath = previewPath
        self.nativePixelWidth = nativePixelWidth
        self.nativePixelHeight = nativePixelHeight
        self.editRecipe = editRecipe
        self.renderedRevision = renderedRevision
        self.bestKind = bestKind
        self.durationSeconds = durationSeconds
        self.renderedSourceSize = renderedSourceSize
        self.renderedSourceMTimeSeconds = renderedSourceMTimeSeconds
        self.mediaChoice = mediaChoice
        self.copyKey = copyKey
    }

    var id: MediaAssetID {
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    var nativePixelSize: CGSize? {
        guard let nativePixelWidth, let nativePixelHeight else {
            return nil
        }
        return CGSize(width: nativePixelWidth, height: nativePixelHeight)
    }

    /// Rendering ran and could not produce a real thumbnail (icon fallback is never
    /// stored). Distinguishes "broken/unsupported media" from "not yet rendered" (both
    /// have `thumbnailPath == nil`).
    var thumbnailUnavailable: Bool {
        renderedSourceMTimeSeconds != nil && thumbnailPath == nil
    }
}

/// Builds the cheap, precomputed display-order key for a media asset. Digit runs
/// are zero-padded so a plain string comparison still orders them numerically
/// ("img2" before "img10") without a locale-aware comparison on every sort step.
nonisolated enum MediaSortKey {
    static func make(libraryRootPath: LibraryRootPath, relativePath: MediaRelativePath) -> String {
        // The library segment groups a library's assets together; the relative
        // path orders within it. U+0001 keeps the two segments from
        // ordering across the boundary.
        naturalKey(libraryRootPath.rawValue) + "\u{1}" + naturalKey(relativePath.rawValue)
    }

    static func naturalKey(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count + 8)
        var digitRun = ""
        for character in string.lowercased() {
            if character.isNumber {
                digitRun.append(character)
            } else {
                if !digitRun.isEmpty {
                    result += paddedDigits(digitRun)
                    digitRun = ""
                }
                result.append(character)
            }
        }
        if !digitRun.isEmpty {
            result += paddedDigits(digitRun)
        }
        return result
    }

    private static func paddedDigits(_ digits: String) -> String {
        // 19 digits covers any Int64-range counter or timestamp in a filename. A
        // longer run, not expected in real media names, falls back to plain order.
        let width = 19
        guard digits.count < width else {
            return digits
        }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

/// The collection view consumes identity order plus a scalar detail-refresh
/// generation. Visible cell details are faulted through the Store-backed detail
/// reader owned by the AppKit grid boundary, so publishing a window state never
/// copies every asset's detail (thumbnail, kind, size, …).
///
/// `dayBuckets` is the one deliberate exception, and it is not detail: it is a
/// single lightweight grouping key per asset (DES-069's day headers), computed
/// once per catalog change at the same cadence `orderedAssetIDs` already is —
/// not per scroll, not per visible window. Empty under any sort but `.bestDate`
/// (day-contiguity only holds under that sort; `.name`/`.size` render one
/// ungrouped section, same as before this field existed). When populated it is
/// always the same length as `orderedAssetIDs`, index-for-index; an individual
/// entry is `nil` when that asset has no known capture date (still grouped —
/// into a single "no date" section, per `MediaGridBridge`'s section grouping).
///
/// The library-sized part — the order, its day buckets and its stacks — is one immutable
/// `CatalogGridContent` held by reference. Projection hands the previous publication's
/// content on whenever a pass rebuilt an equal one (`CatalogWindowState.sharingUnchanged`),
/// so "did the grid's content change?" is `sharesContent(with:)`, one pointer comparison,
/// and the main actor never compares or walks the order to learn it.
nonisolated struct CatalogMediaGridState: Equatable {
    var descriptor: CatalogQueryDescriptor
    var detailRefreshGeneration: UInt64 = 0
    /// The order, its day buckets and its stacks, shared by every publication that holds
    /// the same ones.
    private(set) var content: CatalogGridContent

    var orderedAssetIDs: [MediaAssetID] {
        content.orderedAssetIDs
    }

    var dayBuckets: [Date?] {
        content.dayBuckets
    }

    /// How `orderedAssetIDs` shows each stack it holds (ADR 0052).
    var stacks: CatalogGridStacks {
        content.stacks
    }

    var scope: SidebarSelection {
        descriptor.scope
    }

    static let empty = CatalogMediaGridState(
        descriptor: .default,
        orderedAssetIDs: []
    )

    init(
        scope: SidebarSelection,
        orderedAssetIDs: [MediaAssetID],
        dayBuckets: [Date?] = [],
        detailRefreshGeneration: UInt64 = 0
    ) {
        self.init(
            descriptor: CatalogQueryDescriptor(scope: scope),
            orderedAssetIDs: orderedAssetIDs,
            dayBuckets: dayBuckets,
            detailRefreshGeneration: detailRefreshGeneration
        )
    }

    init(
        descriptor: CatalogQueryDescriptor,
        orderedAssetIDs: [MediaAssetID],
        dayBuckets: [Date?] = [],
        stacks: CatalogGridStacks = .empty,
        detailRefreshGeneration: UInt64 = 0
    ) {
        self.descriptor = descriptor
        content = CatalogGridContent(orderedAssetIDs: orderedAssetIDs, dayBuckets: dayBuckets, stacks: stacks)
        self.detailRefreshGeneration = detailRefreshGeneration
    }

    /// Whether `other` holds this very content — the same publication of it, not merely an
    /// equal one. Constant time; a content Projection rebuilt equal is handed on as the same
    /// one, so on published states this answers whether the order, days or stacks changed.
    func sharesContent(with other: CatalogMediaGridState) -> Bool {
        content === other.content
    }

    /// Whether `other` holds this very order and days, whatever its stacks: constant time,
    /// and on published states it answers whether the order or days changed.
    func sharesOrder(with other: CatalogMediaGridState) -> Bool {
        content.sharesOrder(with: other.content)
    }

    /// This grid without `hidden`: the same grid, content and all, when it holds none of them.
    func hiding(_ hidden: Set<MediaAssetID>) -> CatalogMediaGridState {
        guard let removed = content.removing(hidden) else {
            return self
        }
        var shown = self
        shown.content = removed
        return shown
    }

    /// This grid, its descriptor and detail refresh kept, showing `content`: another
    /// collapse of its stacks (`CatalogProjection.expanding`).
    func replacingContent(_ content: CatalogGridContent) -> CatalogMediaGridState {
        var shown = self
        shown.content = content
        return shown
    }

    /// This grid as Projection publishes it after `previous`: holding `previous`'s content
    /// when its own is equal to it, or `previous`'s order with its own stacks when only the
    /// stacks differ, and otherwise made from `previous`'s order by an edit (ADR 0006).
    ///
    /// An order already made by edits — a hide, a Put Back, a stack expanding, a read's
    /// publication with the acts held on it — is told from `previous`'s by the edit between
    /// them (`CatalogGridContent.edit(from:)`, through an order both were made from), at the
    /// edit's cost, and linked to `previous` by it, so the grid showing `previous` follows it
    /// whichever order it was made from. A new order of the same query is published as an
    /// edit of `previous`'s (`CatalogGridContent.Edit.between`): the walk that tells two
    /// orders equal tells where they differ too, and its index is `previous`'s carried
    /// through that edit, so the publication writes no table of the order. A new query's
    /// order, which the grid reloads, is published whole.
    func sharingContent(of previous: CatalogMediaGridState) -> CatalogMediaGridState {
        guard !sharesContent(with: previous) else {
            return self
        }
        if let edit = content.edit(from: previous.content) {
            var shared = self
            if edit.changesNothing(from: previous.content, to: content) {
                shared.content = content.stacks == previous.content.stacks
                    ? previous.content
                    : previous.content.replacing(stacks: content.stacks)
            } else if !content.isMadeDirectly(from: previous.content) {
                shared.content = content.descending(from: previous.content, by: edit)
            }
            return shared
        }
        let sameDays = content.dayBuckets.count == previous.content.dayBuckets.count
        if sameDays, content.orderedAssetIDs == previous.content.orderedAssetIDs,
           content.dayBuckets == previous.content.dayBuckets
        {
            var shared = self
            shared.content = content.stacks == previous.content.stacks
                ? previous.content
                : previous.content.replacing(stacks: content.stacks)
            return shared
        }
        guard descriptor == previous.descriptor else {
            return self
        }
        previous.content.prepareIndex()
        let walked = CatalogGridContent.Edit.walk(previous.content, content)
        var edited = self
        edited.content = content.descending(
            from: previous.content,
            by: walked.edit,
            work: CatalogGridContent.Work(visited: walked.visited)
        )
        return edited
    }
}

/// The questions the selection, focus and compare policies ask of a display order. A plain
/// array answers them by walking itself; `CatalogGridContent` answers from its index, so a
/// policy run on the window's order costs in what it asks about, not in the order's size.
nonisolated protocol MediaDisplayOrder: MediaMembership {
    var orderedIDs: [MediaAssetID] { get }
    func position(of id: MediaAssetID) -> Int?
    /// `ids` that the order holds, in its order.
    func inDisplayOrder(_ ids: Set<MediaAssetID>) -> [MediaAssetID]
}

/// Which identities a collection holds: an order, or a set of survivors.
nonisolated protocol MediaMembership {
    func contains(_ id: MediaAssetID) -> Bool
}

extension Set<MediaAssetID>: MediaMembership {}

extension [MediaAssetID]: MediaMembership {}

extension [MediaAssetID]: MediaDisplayOrder {
    var orderedIDs: [MediaAssetID] {
        self
    }

    func position(of id: MediaAssetID) -> Int? {
        firstIndex(of: id)
    }

    func inDisplayOrder(_ ids: Set<MediaAssetID>) -> [MediaAssetID] {
        ids.isEmpty ? [] : filter(ids.contains)
    }
}

/// One publication of the grid's library-sized content: the order, its day buckets
/// (index-paired, or empty) and how it shows its stacks. Immutable and shared by reference,
/// so a window state copies a pointer, not 158,000 identities, and two publications of the
/// same content are told apart from two of different content by identity alone.
///
/// Each identity's position is indexed (`Positions`): an order made by an edit of another
/// (a hide, a Put Back, a stack expanding, a read published as an edit) takes the other's
/// index with the edit applied, at the edit's cost; an order made whole writes its table once,
/// the first time a position or membership is asked. Projection asks at publication
/// (`prepareIndex`), off the main actor, so the window's selection and focus checks are
/// lookups. A content Projection rebuilt equal to the last one is dropped before that.
final nonisolated class CatalogGridContent: Equatable, Sendable, MediaDisplayOrder {
    let orderedAssetIDs: [MediaAssetID]
    let dayBuckets: [Date?]
    let stacks: CatalogGridStacks
    private let index: Mutex<Positions?>
    /// Shared by every content holding this very order and days (`replacing(stacks:)`).
    private let order: Order
    /// What making this content cost before its index (`work`).
    private let made: Work

    /// What making one content and its position index cost, counted: the deterministic twin
    /// of its time, which a publication's line carries (`gridWork=`) and the tests bound.
    struct Work: Equatable, Sendable, CustomStringConvertible {
        /// Items visited one at a time: a walk of an order, or a look-up.
        var visited = 0
        /// Position-index entries written.
        var indexed = 0
        /// Items copied in runs: an order's storage moved whole between edits.
        var copied = 0

        var description: String {
            "visited:\(visited),indexed:\(indexed),copied:\(copied)"
        }
    }

    /// The positions the index's edit names, from the table it shares to this order: what each
    /// look-up searches and what the index holds beyond the table. Zero for an order read whole
    /// and for one whose index is not built. Every publication of one query adds its edit to
    /// it, a read's as an act's, until it names as many positions as the order holds and the
    /// table is written again (`Positions.editing(by:into:)`).
    var indexEditSize: Int {
        index.withLock { $0?.edit.size ?? 0 }
    }

    /// What making this content cost, its position index included once it is built.
    var work: Work {
        var work = made
        work.indexed += index.withLock { $0?.written ?? 0 }
        return work
    }

    /// How an order was made from another by dropping and adding items, survivors keeping
    /// their relative order and their days: a Move to Trash's removal (`removing`), a Put
    /// Back or a stack expanding or collapsing (`edited`), a read that moved photos
    /// (`descending(from:)`). An item that left one place and came back at another is both
    /// removed and inserted: a move. A grid showing the other order takes this one in by
    /// these positions alone (`MediaGridStructure.init(grid:following:)`).
    struct Edit: Equatable, Sendable {
        /// The other order's positions this one dropped, ascending.
        let removed: [Int]
        /// This order's positions that the other does not hold at its place, ascending.
        let inserted: [Int]

        var isEmpty: Bool {
            removed.isEmpty && inserted.isEmpty
        }

        /// The positions the edit names: what applying it costs.
        var size: Int {
            removed.count + inserted.count
        }

        /// Whether this edit, which makes `new` from `old`, leaves the order and its days as
        /// they were: it names nothing, or every position it names it removes and inserts
        /// again with the same item and day, as an item taken out and put back by composed
        /// edits is. The survivors then stand where they stood, so the two are equal; the cost
        /// is the edit's.
        func changesNothing(from old: CatalogGridContent, to new: CatalogGridContent) -> Bool {
            guard !isEmpty else {
                return true
            }
            guard removed == inserted, old.orderedAssetIDs.count == new.orderedAssetIDs.count else {
                return false
            }
            let comparesDays = old.dayBuckets.count == old.orderedAssetIDs.count
                && new.dayBuckets.count == new.orderedAssetIDs.count
            return removed.allSatisfy { position in
                old.orderedAssetIDs[position] == new.orderedAssetIDs[position]
                    && (!comparesDays || old.dayBuckets[position] == new.dayBuckets[position])
            }
        }

        /// The edit that makes the other order from this one's result: what this one removed
        /// is inserted, what it inserted is removed.
        var inverse: Edit {
            Edit(removed: inserted, inserted: removed)
        }

        /// This edit and then `next`, as one edit from this one's source to `next`'s result:
        /// what applying the two in turn makes, at the cost of the two edits, never the
        /// order. An item this edit inserted and `next` removed is in neither; one this edit
        /// removed and `next` put back is removed and inserted, a move.
        func followed(by next: Edit) -> Edit {
            // This edit's result is `next`'s source: a position in it that this edit did not
            // insert is a survivor of this edit's source; one `next` did not remove survives
            // into `next`'s result.
            let removedLater = Self.positions(next.removed, notIn: inserted)
            let insertedEarlier = Self.positions(inserted, notIn: next.removed)
            return Edit(
                removed: Self.merged(
                    removed,
                    Self.select(Self.ranks(of: removedLater, excluding: inserted), complementOf: removed)
                ),
                inserted: Self.merged(
                    next.inserted,
                    Self.select(Self.ranks(of: insertedEarlier, excluding: next.removed), complementOf: next.inserted)
                )
            )
        }

        /// How `new` is made from `old`: one walk of the two orders side by side, and a look-up
        /// of each item only where they differ. Two items that match stay; where they do not,
        /// an item the other order does not hold is removed or inserted, and of two that both
        /// orders hold elsewhere, the one going further is moved, so a few photos moving between
        /// days cost a few look-ups. A photo whose day changed without moving is moved in place,
        /// so every item an edit keeps keeps its day. The old order's index is read; the new
        /// order needs none: the runs the two share at their start and at their end are told
        /// equal item by item, and only the items between them are looked up, in an index of
        /// that stretch alone, so a read's publication writes no table of its order.
        static func between(_ old: CatalogGridContent, _ new: CatalogGridContent) -> Edit {
            walk(old, new).edit
        }

        /// `between`, with the items the walk visited.
        static func walk(_ old: CatalogGridContent, _ new: CatalogGridContent) -> (edit: Edit, visited: Int) {
            let oldIDs = old.orderedAssetIDs
            let newIDs = new.orderedAssetIDs
            let oldDays = old.dayBuckets
            let newDays = new.dayBuckets
            let comparesDays = oldDays.count == oldIDs.count && newDays.count == newIDs.count
            func same(_ oldPosition: Int, _ newPosition: Int) -> Bool {
                oldIDs[oldPosition] == newIDs[newPosition]
                    && (!comparesDays || oldDays[oldPosition] == newDays[newPosition])
            }
            // The shared runs at either end stay as they are.
            var start = 0
            while start < oldIDs.count, start < newIDs.count, same(start, start) {
                start += 1
            }
            var oldEnd = oldIDs.count
            var newEnd = newIDs.count
            while oldEnd > start, newEnd > start, same(oldEnd - 1, newEnd - 1) {
                oldEnd -= 1
                newEnd -= 1
            }
            // Where each item between them stands in the new order.
            var newPositions: [MediaAssetID: Int] = [:]
            newPositions.reserveCapacity(newEnd - start)
            for position in start ..< newEnd where newPositions[newIDs[position]] == nil {
                newPositions[newIDs[position]] = position
            }
            var removed: [Int] = []
            var inserted: [Int] = []
            // Items already taken out of the old order ahead of their new place, and items
            // already put into the new order ahead of their old place.
            var leftEarly = Set<MediaAssetID>()
            var cameEarly = Set<MediaAssetID>()
            var oldPosition = start
            var newPosition = start
            while oldPosition < oldEnd, newPosition < newEnd {
                let oldID = oldIDs[oldPosition]
                let newID = newIDs[newPosition]
                if oldID == newID {
                    if comparesDays, oldDays[oldPosition] != newDays[newPosition] {
                        removed.append(oldPosition)
                        inserted.append(newPosition)
                    }
                    oldPosition += 1
                    newPosition += 1
                } else if cameEarly.contains(oldID) {
                    removed.append(oldPosition)
                    oldPosition += 1
                } else if leftEarly.contains(newID) {
                    inserted.append(newPosition)
                    newPosition += 1
                } else if let oldIDInNew = newPositions[oldID] {
                    guard let newIDInOld = old.position(of: newID) else {
                        inserted.append(newPosition)
                        newPosition += 1
                        continue
                    }
                    // Both are held further on in the other order: the one going further
                    // moves, so the one that stays where it was matches next.
                    if oldIDInNew - newPosition >= newIDInOld - oldPosition {
                        removed.append(oldPosition)
                        leftEarly.insert(oldID)
                        oldPosition += 1
                    } else {
                        inserted.append(newPosition)
                        cameEarly.insert(newID)
                        newPosition += 1
                    }
                } else {
                    removed.append(oldPosition)
                    oldPosition += 1
                }
            }
            let visited = oldPosition + newPosition + (oldIDs.count - oldEnd) + (newIDs.count - newEnd)
            removed.append(contentsOf: oldPosition ..< oldEnd)
            inserted.append(contentsOf: newPosition ..< newEnd)
            return (Edit(removed: removed, inserted: inserted), visited)
        }

        /// `positions` (ascending) that `excluded` (ascending) does not hold.
        private static func positions(_ positions: [Int], notIn excluded: [Int]) -> [Int] {
            var result: [Int] = []
            result.reserveCapacity(positions.count)
            var next = 0
            for position in positions {
                while next < excluded.count, excluded[next] < position {
                    next += 1
                }
                if next == excluded.count || excluded[next] != position {
                    result.append(position)
                }
            }
            return result
        }

        /// Each of `positions` (ascending, none in `excluded`) as its place among the
        /// positions `excluded` (ascending) does not hold.
        private static func ranks(of positions: [Int], excluding excluded: [Int]) -> [Int] {
            var next = 0
            return positions.map { position in
                while next < excluded.count, excluded[next] < position {
                    next += 1
                }
                return position - next
            }
        }

        /// The position of each of `ranks` (ascending) among the positions `excluded`
        /// (ascending) does not hold.
        private static func select(_ ranks: [Int], complementOf excluded: [Int]) -> [Int] {
            var next = 0
            return ranks.map { rank in
                while next < excluded.count, excluded[next] <= rank + next {
                    next += 1
                }
                return rank + next
            }
        }

        /// Two disjoint ascending lists as one.
        private static func merged(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
            guard !lhs.isEmpty else {
                return rhs
            }
            guard !rhs.isEmpty else {
                return lhs
            }
            var result: [Int] = []
            result.reserveCapacity(lhs.count + rhs.count)
            var left = 0
            var right = 0
            while left < lhs.count, right < rhs.count {
                if lhs[left] < rhs[right] {
                    result.append(lhs[left])
                    left += 1
                } else {
                    result.append(rhs[right])
                    right += 1
                }
            }
            result.append(contentsOf: lhs[left...])
            result.append(contentsOf: rhs[right...])
            return result
        }
    }

    /// The identity of one publication of an order and its days, and, for one made by
    /// edits, how it was made from each earlier order still held anywhere: the window may
    /// skip publications (it applies only the newest, ADR 0004), so the grid shows an older
    /// order than the one an act's publication was made from, and takes the act in by the
    /// edit from the order it shows.
    private final class Order: Sendable {
        /// One earlier order and the edit from it to this one, the edits of every
        /// publication between composed (`Edit.followed(by:)`).
        struct Link: Sendable {
            /// Held weakly: an order never keeps an earlier one alive, and once nothing holds
            /// that order, nothing can ask about it, so its link is dropped at the next edit.
            weak let order: Order?
            let edit: Edit
        }

        /// Nearest first; empty for an order that was not made by an edit.
        let lineage: [Link]

        init() {
            lineage = []
        }

        /// The order `edit` makes from `source`: linked to `source` and, by the edit composed,
        /// to each earlier order `source` is linked to that is still held. The composing costs
        /// the edits, a few held orders at a time, and is done where the order is made, off
        /// the main actor.
        init(source: Order, edit: Edit) {
            var lineage = [Link(order: source, edit: edit)]
            for link in source.lineage {
                guard let order = link.order else {
                    continue
                }
                lineage.append(Link(order: order, edit: link.edit.followed(by: edit)))
            }
            self.lineage = lineage
        }

        /// The edit from `other` when this order was made from it, or is it.
        func directEdit(from other: Order) -> Edit? {
            other === self ? Edit(removed: [], inserted: []) : lineage.first { $0.order === other }?.edit
        }

        /// The edit from `other`: directly, or through the nearest order this one was made from
        /// that `other` was made from too (or is), `other`'s edits from it undone first.
        func edit(from other: Order) -> Edit? {
            if let edit = directEdit(from: other) {
                return edit
            }
            if let back = other.directEdit(from: self) {
                return back.inverse
            }
            for link in lineage {
                guard let ancestor = link.order, let toOther = other.directEdit(from: ancestor) else {
                    continue
                }
                return toOther.inverse.followed(by: link.edit)
            }
            return nil
        }
    }

    init(orderedAssetIDs: [MediaAssetID], dayBuckets: [Date?], stacks: CatalogGridStacks) {
        self.orderedAssetIDs = orderedAssetIDs
        self.dayBuckets = dayBuckets
        self.stacks = stacks
        index = Mutex(nil)
        order = Order()
        made = Work()
    }

    /// `orderedAssetIDs`, which `edit` made from `source`'s order: its index is `source`'s
    /// with the edit applied (`Positions.editing`), when `source`'s is built, so it costs the
    /// edit, and is built whole on first use otherwise.
    private init(
        orderedAssetIDs: [MediaAssetID],
        dayBuckets: [Date?],
        stacks: CatalogGridStacks,
        edit: Edit,
        from source: CatalogGridContent,
        work: Work
    ) {
        self.orderedAssetIDs = orderedAssetIDs
        self.dayBuckets = dayBuckets
        self.stacks = stacks
        var made = work
        let positions = source.index.withLock { $0 }.map { positions in
            let edited = positions.editing(by: edit, into: orderedAssetIDs)
            made.visited += edited.visited
            return edited.positions
        }
        index = Mutex(positions)
        order = Order(source: source.order, edit: edit)
        self.made = made
    }

    private init(_ content: CatalogGridContent, stacks: CatalogGridStacks) {
        orderedAssetIDs = content.orderedAssetIDs
        dayBuckets = content.dayBuckets
        self.stacks = stacks
        index = Mutex(content.index.withLock { $0 }.map(\.carried))
        order = content.order
        made = Work()
    }

    /// `content` as made from `source` by `edit`: its own index when it has one, else
    /// `source`'s carried through the edit, at the edit's cost.
    private init(_ content: CatalogGridContent, edit: Edit, from source: CatalogGridContent, work: Work) {
        orderedAssetIDs = content.orderedAssetIDs
        dayBuckets = content.dayBuckets
        stacks = content.stacks
        var made = content.work
        made.visited += work.visited
        if let own = content.index.withLock({ $0 }) {
            index = Mutex(own.carried)
        } else if let edited = source.index.withLock({ $0 })?.editing(by: edit, into: content.orderedAssetIDs) {
            made.visited += edited.visited
            index = Mutex(edited.positions)
        } else {
            index = Mutex(nil)
        }
        order = Order(source: source.order, edit: edit)
        self.made = made
    }

    /// The same order and days with other stacks: the same order (`sharesOrder`), and its
    /// index, if built, still holds.
    func replacing(stacks: CatalogGridStacks) -> CatalogGridContent {
        CatalogGridContent(self, stacks: stacks)
    }

    /// Whether `other` holds this very order and days: the same publication of them, not
    /// merely equal ones. Constant time.
    func sharesOrder(with other: CatalogGridContent) -> Bool {
        order === other.order
    }

    /// This content without `hidden`, or nil when it holds none of them. A tile's stack goes
    /// with its tile, and a hidden file that was shown for a stack takes that stack's other
    /// files' mapping with it; the files of a collapsed stack are hidden together, since Move
    /// to Trash moves them together (`CatalogGridStacks.files(reachedThrough:)`).
    func removing(_ hidden: Set<MediaAssetID>) -> CatalogGridContent? {
        let positions = hidden.compactMap { position(of: $0) }.sorted()
        guard !positions.isEmpty else {
            return nil
        }
        return CatalogGridContent(
            orderedAssetIDs: orderedAssetIDs.editing(removing: positions, inserting: []),
            dayBuckets: dayBuckets.isEmpty ? [] : dayBuckets.editing(removing: positions, inserting: []),
            stacks: stacks.removing(hidden),
            edit: Edit(removed: positions, inserted: []),
            from: self,
            work: Work(visited: hidden.count, copied: orderedAssetIDs.count - positions.count)
        )
    }

    /// `orderedAssetIDs` and `dayBuckets`, which `edit` made from this content's, showing
    /// `stacks`: a content of its own that remembers the edit, so a grid showing this one
    /// follows it by the edit alone (a Put Back, a stack expanding or collapsing,
    /// `CatalogProjection.expanding`). `work` is what making the order cost its maker.
    func edited(
        by edit: Edit,
        to orderedAssetIDs: [MediaAssetID],
        dayBuckets: [Date?],
        stacks: CatalogGridStacks,
        work: Work = Work()
    ) -> CatalogGridContent {
        CatalogGridContent(
            orderedAssetIDs: orderedAssetIDs,
            dayBuckets: dayBuckets,
            stacks: stacks,
            edit: edit,
            from: self,
            work: work
        )
    }

    /// This content with `inserted` (ascending positions in the result) added, survivors
    /// keeping their order and days, showing `stacks`: a Put Back. The runs between the
    /// insertions are copied whole, and the index is this one's with the insertions applied.
    func inserting(
        _ inserted: [(position: Int, id: MediaAssetID, day: Date?)],
        stacks: CatalogGridStacks,
        work: Work
    ) -> CatalogGridContent {
        var made = work
        made.copied += orderedAssetIDs.count
        return edited(
            by: Edit(removed: [], inserted: inserted.map(\.position)),
            to: orderedAssetIDs.editing(removing: [], inserting: inserted.map { ($0.position, $0.id) }),
            dayBuckets: dayBuckets.isEmpty ? [] : dayBuckets.editing(removing: [], inserting: inserted.map { ($0.position, $0.day) }),
            stacks: stacks,
            work: made
        )
    }

    /// This content's order, days and stacks, its index kept, as an order made from
    /// `previous`'s by `edit` (`Edit.between`, or an edit found through an order both were
    /// made from): what Projection publishes, so a grid showing `previous`, or any order
    /// `previous` was made from, takes it in by the edit.
    func descending(from previous: CatalogGridContent, by edit: Edit, work: Work = Work()) -> CatalogGridContent {
        CatalogGridContent(self, edit: edit, from: previous, work: work)
    }

    /// Whether this content's order was made from `other`'s, or is it, so that the edit
    /// between them is held without going through another order.
    func isMadeDirectly(from other: CatalogGridContent) -> Bool {
        order.directEdit(from: other.order) != nil
    }

    /// How this content's order was made from `other`'s by edits (`removing`, `edited`,
    /// `descending`), through any publications between: directly, when it was made from that
    /// very order, or through an order both were made from that is still held, by undoing
    /// `other`'s edits back to it and making this one's (`Edit.inverse`). Nil when they share
    /// no held order: a new query's order, or one whose sources are gone.
    func edit(from other: CatalogGridContent) -> Edit? {
        order.edit(from: other.order)
    }

    var orderedIDs: [MediaAssetID] {
        orderedAssetIDs
    }

    /// Builds the position index now, if it is not built yet.
    func prepareIndex() {
        withPositions { _ in () }
    }

    func position(of id: MediaAssetID) -> Int? {
        withPositions { $0.position(of: id) }
    }

    func contains(_ id: MediaAssetID) -> Bool {
        position(of: id) != nil
    }

    func inDisplayOrder(_ ids: Set<MediaAssetID>) -> [MediaAssetID] {
        guard !ids.isEmpty else {
            return []
        }
        return withPositions { positions in
            ids.compactMap { id in positions.position(of: id).map { (id, $0) } }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }
    }

    /// `body` over the position index, built whole on first use when no edit made it.
    private func withPositions<Result: Sendable>(_ body: (Positions) -> Result) -> Result {
        index.withLock { index in
            let positions = index ?? Positions(whole: orderedAssetIDs)
            index = positions
            return body(positions)
        }
    }

    /// Equal content: the same one; an order made from the other by an edit that changes
    /// nothing, with the same stacks; or the same order, days and stacks item by item.
    static func == (lhs: CatalogGridContent, rhs: CatalogGridContent) -> Bool {
        if lhs === rhs {
            return true
        }
        if let edit = lhs.order.directEdit(from: rhs.order) {
            return edit.changesNothing(from: rhs, to: lhs) && lhs.stacks == rhs.stacks
        }
        if let edit = rhs.order.directEdit(from: lhs.order) {
            return edit.changesNothing(from: lhs, to: rhs) && lhs.stacks == rhs.stacks
        }
        return lhs.orderedAssetIDs == rhs.orderedAssetIDs
            && lhs.dayBuckets == rhs.dayBuckets
            && lhs.stacks == rhs.stacks
    }

    /// Where each identity of one order stands: a table of each identity's first position in
    /// an order this one was made from by edits, and the edit from that order to this one,
    /// with this order's inserted items by identity. A position is the table's, moved past
    /// the edit's removals and insertions (two binary searches), so an order made by an edit
    /// of a few positions is indexed in those positions, never in the order's size; only an
    /// order made whole (a read, a new query) writes a table, once, on first use.
    private struct Positions: Sendable {
        /// Each identity's first position in the order the table was written for, shared by
        /// every order edited from it.
        final class Table: Sendable {
            let positions: [MediaAssetID: Int]

            init(_ positions: [MediaAssetID: Int]) {
                self.positions = positions
            }
        }

        let table: Table
        /// From the table's order to this one; empty for the table's own order.
        let edit: Edit
        /// This order's item at each of `edit.inserted`, by identity.
        let inserted: [MediaAssetID: Int]
        /// The entries writing these positions cost: the table's, or the inserted items'.
        let written: Int

        /// The table of `ids`, written whole.
        init(whole ids: [MediaAssetID]) {
            var positions: [MediaAssetID: Int] = [:]
            positions.reserveCapacity(ids.count)
            for (position, id) in ids.enumerated() where positions[id] == nil {
                positions[id] = position
            }
            table = Table(positions)
            edit = Edit(removed: [], inserted: [])
            inserted = [:]
            written = positions.count
        }

        private init(table: Table, edit: Edit, inserted: [MediaAssetID: Int], written: Int) {
            self.table = table
            self.edit = edit
            self.inserted = inserted
            self.written = written
        }

        /// The same positions, written by another content: nothing written for this one.
        var carried: Positions {
            Positions(table: table, edit: edit, inserted: inserted, written: 0)
        }

        /// The positions of `ids`, which `next` made from this order: the table kept, its edit
        /// followed by `next`, and the inserted items of the two looked up in `ids`. Costs the
        /// two edits. Once the composed edit names as many positions as `ids` holds, carrying
        /// it would cost what a table of `ids` costs, so the table is written whole instead:
        /// an index's edit never outgrows its order, however many edits a run publishes.
        func editing(by next: Edit, into ids: [MediaAssetID]) -> (positions: Positions, visited: Int) {
            let composed = edit.isEmpty ? next : edit.followed(by: next)
            guard composed.size < ids.count else {
                return (Positions(whole: ids), edit.size + next.size)
            }
            var inserted: [MediaAssetID: Int] = [:]
            inserted.reserveCapacity(composed.inserted.count)
            for position in composed.inserted where inserted[ids[position]] == nil {
                inserted[ids[position]] = position
            }
            return (
                Positions(table: table, edit: composed, inserted: inserted, written: inserted.count),
                edit.size + next.size
            )
        }

        func position(of id: MediaAssetID) -> Int? {
            if let position = inserted[id] {
                return position
            }
            guard let tablePosition = table.positions[id] else {
                return nil
            }
            guard !edit.isEmpty else {
                return tablePosition
            }
            // Its place among the table order's survivors, then that survivor's position here:
            // the rank-th position the edit did not insert.
            let removedBefore = Self.count(of: edit.removed, below: tablePosition)
            if removedBefore < edit.removed.count, edit.removed[removedBefore] == tablePosition {
                return nil
            }
            let rank = tablePosition - removedBefore
            // `inserted[i] - i` counts the survivors ahead of the i-th insertion; those ahead of
            // the survivor of `rank` are the ones with at most `rank` survivors ahead.
            var low = 0
            var high = edit.inserted.count
            while low < high {
                let middle = (low + high) / 2
                if edit.inserted[middle] - middle <= rank {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return rank + low
        }

        /// How many of `sorted` (ascending) are below `value`.
        private static func count(of sorted: [Int], below value: Int) -> Int {
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle] < value {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }
    }
}

extension Array {
    /// This array without the elements at `removed` (ascending positions in it) and with
    /// `inserted` added (ascending positions in the result), the rest keeping their order.
    /// The runs between edits are copied whole.
    nonisolated func editing(removing removed: [Int], inserting inserted: [(position: Int, element: Element)]) -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(count - removed.count + inserted.count)
        var source = 0
        var nextRemoved = 0
        /// Appends the next `survivors` elements of this array that are not removed.
        func copy(_ survivors: Int) {
            var remaining = survivors
            while remaining > 0 {
                while nextRemoved < removed.count, removed[nextRemoved] == source {
                    source += 1
                    nextRemoved += 1
                }
                let runEnd = Swift.min(nextRemoved < removed.count ? removed[nextRemoved] : count, source + remaining)
                result.append(contentsOf: self[source ..< runEnd])
                remaining -= runEnd - source
                source = runEnd
            }
        }
        for (position, element) in inserted {
            copy(position - result.count)
            result.append(element)
        }
        copy(count - source - (removed.count - nextRemoved))
        return result
    }
}

/// The collection the browser shows: a sidebar row, or the one place reached by
/// drilling into the Places map. Media selection is modeled separately because it
/// answers a different question.
///
/// `.places` is every located item across the fixed libraries, presented as a map
/// (ADR 0040). `.mapArea` and `.mapStack` are the leaves under it — the items in the area
/// the map showed, or the items one stack counted — presented in the ordinary view modes;
/// the sidebar keeps the Places row highlighted for them.
///
/// `.duplicates` is every copy in a duplicate group across the fixed libraries,
/// presented as the duplicates list (ADR 0042); `.duplicateGroup` is the leaf under it —
/// one group's copies in the ordinary Compare, Loupe or grid.
///
/// `.onThisDay` is every item in the fixed libraries captured on the day's month and day
/// in an earlier year — or, when no earlier year holds one, on the day's day of the month in
/// an earlier month — presented as its anniversaries and played as a story (ADR 0049). The day is
/// today, which the ViewModel owns; when today changes, the ViewModel selects the new day.
///
/// `.people` is the People gallery (ADR 0047, `docs/design/people.md`); `.person` is the
/// leaf under it — one person's photos across the fixed libraries, in the ordinary view
/// modes, with the People row highlighted.
nonisolated enum SidebarSelection: Hashable {
    case allMedia
    case places
    case mapArea(MapArea)
    case mapStack(MapStack)
    case onThisDay(CalendarDay)
    case duplicates
    case duplicateGroup(DuplicateGroupID)
    case people
    case person(PersonID)
    case library(LibraryRootPath)
    case importBatch(ImportBatchID)
    case allImports

    /// The row the sidebar highlights for this scope: a leaf has no row of its own and
    /// highlights the row it was reached from.
    var sidebarRow: SidebarSelection {
        switch self {
        case .mapArea, .mapStack: .places
        case .duplicateGroup: .duplicates
        case .person: .people
        default: self
        }
    }

    /// The scope shows one copy of each set of identical copies (ADR 0054): it spans the
    /// libraries and accounts. One library's, an import's, Duplicates' and a map stack's
    /// named members show every file they hold.
    var showsOneCopy: Bool {
        switch self {
        case .allMedia, .places, .mapArea, .onThisDay, .people, .person, .allImports:
            true
        case .mapStack, .duplicates, .duplicateGroup, .library, .importBatch:
            false
        }
    }

    /// The person whose photos the scope is: the leaf under People.
    var person: PersonID? {
        if case let .person(person) = self {
            return person
        }
        return nil
    }

    /// The order a scope fixes for itself, whatever the sort control says: On This Day plays
    /// newest anniversary first and newest item first within one (ADR 0049), so its sort is not
    /// the user's to choose. Nil for every scope the user sorts.
    var fixedSort: MediaSortOrder? {
        switch self {
        case .onThisDay: .dateNewest
        default: nil
        }
    }

    /// The People gallery: it shows people, not items (ADR 0047), so the window reads no
    /// order, stacks, search or filter options for it.
    var isPeopleGallery: Bool {
        if case .people = self {
            return true
        }
        return false
    }

    var diagnosticDescription: String {
        switch self {
        case .allMedia:
            "allMedia"
        case .places:
            "places"
        case let .mapArea(area):
            "mapArea:\(area.diagnosticDescription)"
        case let .mapStack(stack):
            "mapStack:\(stack.diagnosticDescription)"
        case let .onThisDay(day):
            "onThisDay:\(day.diagnosticDescription)"
        case .duplicates:
            "duplicates"
        case let .duplicateGroup(group):
            "duplicateGroup:\(group.kindName)"
        case .people:
            "people"
        case let .person(person):
            "person:\(person.rawValue)"
        case let .library(path):
            "library:\(path.rawValue)"
        case let .importBatch(batchID):
            "importBatch:\(batchID.unixMilliseconds)"
        case .allImports:
            "allImports"
        }
    }
}

nonisolated struct ScannedMediaFile: Hashable {
    let relativePath: MediaRelativePath
    let name: String?
    let contentTypeIdentifier: String?
    let kind: MediaKind?
    let format: MediaFormatToken?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?
    /// The file's identifier on its volume (its inode), read with the other filesystem
    /// facts and never used as identity: it is the move witness's evidence that a file
    /// at a new path is the one an absent row described (ADR 0008). `nil` where the
    /// source has no filesystem, such as a camera.
    let fileIdentifier: UInt64?

    init(
        relativePath: MediaRelativePath,
        name: String?,
        contentTypeIdentifier: String?,
        byteSize: Int64?,
        createdAt: Date?,
        contentModifiedAt: Date?,
        kind: MediaKind? = nil,
        format: MediaFormatToken? = nil,
        fileIdentifier: UInt64? = nil
    ) {
        let contentType = contentTypeIdentifier.flatMap(UTType.init)
        self.relativePath = relativePath
        self.name = name
        self.contentTypeIdentifier = contentTypeIdentifier
        self.kind = kind ?? MediaKind.classify(contentType)
        self.format = format ?? MediaFormatToken.normalize(contentType: contentType)
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.contentModifiedAt = contentModifiedAt
        self.fileIdentifier = fileIdentifier
    }
}

/// An item a source's change stream reports it holds (ADR 0046 §5).
nonisolated struct SourceListedItem: Hashable, Sendable {
    /// The item's facts. A nil size is one this report does not carry, and leaves the
    /// size the catalog already holds.
    let file: ScannedMediaFile
    /// The source's own ID for the item (an Immich asset's ID), which every later report
    /// and request about it uses.
    let sourceItemID: String
    /// The item is in its source's trash: an Immich asset in Immich's trash. The source hides it
    /// then, and also while its server has not read it (`AssetRowSQL.sourceHiddenSQL`, v84).
    let isInSourceTrash: Bool
    /// The source holds its own thumbnail and preview of the item (ADR 0046 §7); false
    /// for one it has none of, which is not asked for them.
    let sourceHasProducts: Bool
    /// The source's own digest of the item's bytes (an uploaded Immich asset's SHA-1,
    /// ADR 0054), which the row takes as its digest; nil when the source states none.
    var sourceDigest: ContentDigest?
    /// The source's checksum of the item's path on its server (an external library's
    /// Immich asset, ADR 0054), by which the library file it mirrors finds it; nil when the
    /// source states none.
    var sourcePathChecksum: ImmichPathChecksum?
}

/// A full resync a source owes (`library_root.resync_owed`, ADR 0046 §5): the revision of
/// the newest request. A resync settles the revision it started from, never a newer one.
nonisolated struct SourceResyncDebt: Equatable, Sendable {
    let revision: Int64
}

/// Where an item its source names by ID already lives, and whether it is in its source's trash.
nonisolated struct SourceItemRow: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let isInSourceTrash: Bool
}

/// A row whose source's own thumbnail and preview are missing or older than its file
/// (ADR 0046 §7).
nonisolated struct SourceProductCandidate: Equatable, Sendable {
    let id: MediaAssetID
    /// The source's own ID for the item, which its images are asked for by.
    let sourceItemID: String
    let kind: MediaKind?
    let byteSize: Int64
    let contentModifiedAtSeconds: Int?
}

/// One batch of a source's change stream, applied in one transaction. Each item is named
/// by the source's own ID for it (an Immich asset's ID, ADR 0046 §2); a size or a
/// permanent deletion the source reports apart from an item's facts names only that ID.
nonisolated struct SourceListingChanges: Sendable, Equatable {
    var listed: [SourceListedItem] = []
    /// Folders listed in full: each holds exactly the items this batch lists in it, so a
    /// row there that the batch does not list — a Live Photo motion part its still no
    /// longer links — is purged.
    var completeFolders: [String] = []
    /// Sizes reported apart from the item's own facts, by the source's ID for the item.
    var sizesBySourceItem: [String: Int64] = [:]
    /// Items the source proves deleted, by its ID. Their rows and overlay are purged, and
    /// so is every row in a deleted item's own folder: a deleted still takes its motion
    /// part with it.
    var deletedSourceItems: [String] = []

    var isEmpty: Bool {
        listed.isEmpty && completeFolders.isEmpty && sizesBySourceItem.isEmpty && deletedSourceItems.isEmpty
    }
}

nonisolated enum RemovableSourceDetachReason: String {
    case unmounted
    case ejected
    case disconnected
    case forgotten
    case transientIdentityEnded
}

nonisolated enum CatalogStoreError: LocalizedError, Equatable {
    case notDirectory
    case overlappingRoot(existingPath: LibraryRootPath, relationship: LibraryRootRelationship)
    case catalogUnavailable
    case unsupportedCatalogSchema(CatalogSchemaCompatibility)
    case importOperationMissing(ActiveFileOperationKey)
    /// A durable journal or settlement write SQLite refused because the disk is full
    /// (`SQLITE_FULL`): the floor reached the hard way (ADR 0027).
    case outOfSpace
    /// An Immich server address that is not an http or https URL with a host.
    case invalidRemoteServer
    /// A stored face whose landmarks or embedding are not the size the catalog writes.
    case malformedFaceRow(MediaAssetID)
    /// A stored person whose birthday is neither `YYYY` nor `YYYY-MM-DD`, which no write
    /// produces.
    case malformedPersonRow(PersonID)

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "Choose a folder."
        case let .overlappingRoot(existingPath, relationship):
            switch relationship {
            case .duplicate:
                "That library is already saved."
            case .ancestor:
                "That folder contains an existing library at \(existingPath.rawValue)."
            case .descendant:
                "That folder is already inside an existing library at \(existingPath.rawValue)."
            }
        case .catalogUnavailable:
            "The catalog is unavailable."
        case let .unsupportedCatalogSchema(problem):
            problem.errorDescription
        case let .importOperationMissing(key):
            "The import journal operation \(key.rawValue) is no longer present."
        case .outOfSpace:
            "The disk is full."
        case .invalidRemoteServer:
            "Enter the server’s web address, starting with http:// or https://."
        case .malformedFaceRow:
            "A face stored in the catalog could not be read."
        case .malformedPersonRow:
            "A person stored in the catalog could not be read."
        }
    }
}

/// What asking to remove a library did.
nonisolated enum LibraryRemovalOutcome: Equatable, Sendable {
    /// The library and its catalog rows are gone.
    case removed
    /// No library is cataloged at that path; nothing changed.
    case notInCatalog
    /// Another owner is changing the library's files. It is removed as soon as that owner
    /// releases it — or, when the owner is a removal already, by that removal.
    case waiting(for: RootNamespaceMutationOwner)
}

/// A removal the user asked for that waits for the library to be free: which library,
/// and the work it waits for. The alert wording is `LibraryRemovalNoticePresentation`'s.
nonisolated struct LibraryRemovalNotice: Equatable, Sendable {
    let displayName: String
    let waitingFor: RootNamespaceMutationOwner
}

/// What the catalog's open is doing, reported by the Store as it opens the file
/// (`CatalogStore.openings`) and shown by the window while it waits (DES-121, APP-090).
nonisolated struct CatalogOpening: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        /// The file is opening, or its load is reading what the window shows first.
        case opening
        /// Schema update `step` of the `of` this open applies is running.
        case updating(step: Int, of: Int)
        /// The file is being rewritten without its free pages (`CatalogCompaction`).
        case compacting
    }

    var phase: Phase = .opening

    var diagnosticDescription: String {
        let roots = memberRootCount.map { "\($0)" } ?? "unknown"
        switch phase {
        case .opening:
            return "opening,roots:\(roots)"
        case let .updating(step, total):
            return "updating:\(step)/\(total),roots:\(roots)"
        case .compacting:
            return "compacting,roots:\(roots)"
        }
    }

    /// How many libraries and accounts the catalog holds — the roots All Media is made of
    /// (`LibraryRootKind.isMemberOfAllMedia`) — read before any update runs, so the sidebar
    /// rows that stand for them can show while the catalog updates. Nil until read.
    var memberRootCount: Int?
}

/// Result of the pre-migration catalog schema compatibility check.
nonisolated enum CatalogSchemaCompatibility: Equatable, Sendable {
    /// Empty database or a known partial/current schema that additive migrations can advance.
    case readyToMigrate
    /// Applied migration identifiers include ones this build does not know: a newer Otos
    /// wrote it, or one from before the schema baseline. Which is not recorded, so not said.
    case writtenByOtherOtos
    /// User tables exist but no known migration identifiers are present.
    case unrecognized

    var errorDescription: String {
        switch self {
        case .readyToMigrate:
            "The catalog schema is compatible."
        case .writtenByOtherOtos:
            "This catalog was written by a different version of Otos."
        case .unrecognized:
            "This catalog is not compatible with this version of Otos."
        }
    }

    var isSupported: Bool {
        if case .readyToMigrate = self {
            return true
        }
        return false
    }
}

/// The Unix-millisecond identities this process mints for its acts: an import's batch
/// and a Move to Trash command. Each is the time it was minted, or one past the last
/// identity minted when the clock has not moved past it, so two acts begun in one
/// millisecond — two cards whose imports start together, a second Move to Trash right
/// after the first — never share an identity that a dictionary, a hold, an undo entry or
/// the catalog's rows key on.
nonisolated enum UnixMillisecondIdentity {
    private static let lastMinted = Mutex<Int64>(0)

    static func mint() -> Int64 {
        let now = Int64((Date().timeIntervalSince1970 * 1000.0).rounded(.down))
        return lastMinted.withLock { last in
            last = max(now, last + 1)
            return last
        }
    }
}

/// Typed UTC epoch milliseconds shared by every asset newly published in one import.
/// Rendered in the user's locale/time zone only in the sidebar.
nonisolated struct ImportBatchID: Hashable, Sendable, Comparable {
    let unixMilliseconds: Int64

    init(unixMilliseconds: Int64) {
        self.unixMilliseconds = unixMilliseconds
    }

    /// A new import's batch: when it started, unique within this process
    /// (`UnixMillisecondIdentity`).
    init() {
        unixMilliseconds = UnixMillisecondIdentity.mint()
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1000.0)
    }

    static func < (lhs: ImportBatchID, rhs: ImportBatchID) -> Bool {
        lhs.unixMilliseconds < rhs.unixMilliseconds
    }
}

/// One nonempty import batch for Store history queries and the Imports sidebar.
nonisolated struct ImportBatchSummary: Equatable, Sendable {
    let batchID: ImportBatchID
    /// The photos the batch's grid shows, a stack counting once (ADR 0052); nil for a batch
    /// the window does not show, whose count was not read (`ImportBatchCounting`).
    let photoCount: Int?
}

/// Which import batches the window shows, and so which are counted: counting a batch stacks
/// its folders' files, a few hundred milliseconds for the reference library's 45 batches and 11,401
/// imported rows on every pass a membership or stack fact moved, against tens for the five
/// the sidebar shows (`docs/research/2026-11-15-import-batch-photo-counts.md`).
nonisolated enum ImportBatchListing {
    /// How many of the newest batches the Imports section lists before All Imports….
    static let sidebarRowCount = 5

    /// The batches the Imports section lists: the newest `sidebarRowCount`, and the selected
    /// batch after them when it is older. `batches` is newest first.
    static func sidebarRows(_ batches: [ImportBatchID], selection: SidebarSelection) -> [ImportBatchID] {
        ImportBatchCounting.newest(sidebarRowCount, and: selectedBatch(selection)).batches(batches)
    }

    /// The batches whose photos are counted for `selection`: every batch while All Imports
    /// lists them, else the sidebar's rows. What the Store is asked to count.
    static func counting(for selection: SidebarSelection) -> ImportBatchCounting {
        selection == .allImports ? .every : .newest(sidebarRowCount, and: selectedBatch(selection))
    }

    private static func selectedBatch(_ selection: SidebarSelection) -> ImportBatchID? {
        if case let .importBatch(selected) = selection {
            return selected
        }
        return nil
    }
}

/// Which import batches the Store counts photos for (`CatalogStore.importBatches(counting:)`):
/// a fact about batches, so the Store answers it without knowing what the window shows.
nonisolated enum ImportBatchCounting: Hashable, Sendable {
    /// Every batch.
    case every
    /// The newest `count` batches, and `batch` after them when it is older.
    case newest(Int, and: ImportBatchID?)

    /// The batches of `batches` (newest first) this counts, in their order.
    func batches(_ batches: [ImportBatchID]) -> [ImportBatchID] {
        switch self {
        case .every:
            return batches
        case let .newest(count, and: batch):
            let newest = Array(batches.prefix(count))
            if let batch, !newest.contains(batch), batches.contains(batch) {
                return newest + [batch]
            }
            return newest
        }
    }
}

/// The motion movie of a Live Photo, the member its still's item carries (ADR 0041).
nonisolated struct LivePhotoMotion: Equatable, Sendable {
    let relativePath: MediaRelativePath
    /// Cataloged size, a filesystem fact.
    let byteSize: Int64?

    func id(in root: LibraryRootPath) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: relativePath)
    }
}
