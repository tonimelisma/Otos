import Accelerate
import Darwin
import Foundation

/// Search vector file guide (ADR 0048, "The index")
///
/// Every embedding the search index holds, as one file pair in Application Support
/// (`CatalogStore.searchIndexDirectory`), mapped read-only: the vectors' pages are clean and
/// file-backed, so the kernel may drop and re-read them and they never count in the process's
/// footprint. Derived overlay: `search_embedding` keeps every vector at full precision and is
/// what a file is rebuilt from; the file is never in a media folder.
///
/// - **`<id>.vectors`:** a 4,096-byte header (`SearchVectorFormat`: magic, format, dimensions,
///   binary16, `SearchEmbedding.revision`, the file's id, a checksum), then one slot of
///   `dimensions` little-endian Float16 values per embedding, in the order they were appended.
///   Float16 keeps every cosine within 5.1e-5 of Float32 on the reference library's 165,653 embeddings
///   (`docs/research/2026-11-16-search-vector-file.md`).
/// - **`<id>.keys`:** a 64-byte header, then records: a root's path or a label's name the first
///   time a slot names it, and each slot's asset and loose scene labels, numbered names with the
///   confidence the stored text gives, so the gate decides exactly as over the parsed text.
///
/// **Currency.** The catalog names the file and how many slots its embeddings commit
/// (`search_vector_file`, v70), in the same commit as the rows (`applySearchEmbeddings`,
/// `addSearchVectorSlots`); the index appends them right after. A file is opened only when its
/// headers are intact, its revision is the model's, and it holds at least the committed slots;
/// anything past them was never committed and is cut off. A crash between the commit and the
/// append leaves a file short of the count, which is rebuilt, never trusted. A later slot for an
/// asset supersedes an earlier one; a slot whose asset left memory is dead until compaction
/// writes the live slots into a new file the catalog then names.
///
/// One owner: the `PhotoSearchIndex` actor holds the open file and is its only writer. An
/// append is encoded against the file as it stands (`encode`), its bytes reach the disk off the
/// actor (`write`), and the file takes it in one synchronous step that checks it was encoded
/// against the file as it still stands and maps the new length before it lets the old go. The
/// file memory holds (`SearchIndexMemory`) takes an append or loses a slot only through
/// `SearchIndexMemory`, which moves the index's revision in that same step; `append` and
/// `appendLive` are for a file being built, which memory does not hold yet.
final nonisolated class SearchVectorFile {
    typealias AvailableBytes = @Sendable (URL) -> Int64?

    let id: UUID
    let directory: URL
    /// The free space the volume of a URL reports (`FreeSpaceFloor.availableBytes`); a test's
    /// own figure when it fills the disk at a chosen step.
    private let availableBytes: AvailableBytes
    /// Every slot's asset and labels, and the roots and label names they number.
    private(set) var keys: SearchVectorKeys
    /// The live slot of each asset memory holds: the last appended for it, until it leaves.
    private(set) var rowOf: [MediaAssetID: Int32]
    private let vectorsDescriptor: Int32
    private let keysDescriptor: Int32
    private var vectorMap: SearchVectorMapping?
    private var keysMap: SearchVectorMapping?
    /// Whether `SearchIndexMemory` holds this file: then only it changes the file's slots.
    fileprivate(set) var held = false

    var slots: Int {
        keys.slotIDs.count
    }

    var live: Int {
        rowOf.count
    }

    var dead: Int {
        slots - live
    }

    /// Owns `vectors` and `keyFile` from here on: they close with it.
    private init(
        id: UUID, directory: URL, keys: SearchVectorKeys, vectors: Int32, keyFile: Int32, availableBytes: @escaping AvailableBytes
    ) {
        self.id = id
        self.directory = directory
        self.availableBytes = availableBytes
        self.keys = keys
        vectorsDescriptor = vectors
        keysDescriptor = keyFile
        var rowOf: [MediaAssetID: Int32] = [:]
        rowOf.reserveCapacity(keys.slotIDs.count)
        for (slot, asset) in keys.slotIDs.enumerated() {
            rowOf[asset] = Int32(slot)
        }
        self.rowOf = rowOf
    }

    deinit {
        vectorMap?.unmap()
        keysMap?.unmap()
        close(vectorsDescriptor)
        close(keysDescriptor)
    }

    // MARK: Opening and creating

    /// The file pair `state` names in `directory`, checked against it: intact headers of this
    /// model revision and at least `state.slots` slots of keys and vectors. Bytes past the
    /// committed slots are cut off. Throws `SearchVectorFileInvalid` naming why it is not
    /// current.
    static func open(
        directory: URL, state: SearchVectorFileState, availableBytes: @escaping AvailableBytes = FreeSpaceFloor.availableBytes(onVolumeOf:)
    ) throws -> SearchVectorFile {
        let urls = SearchVectorFormat.urls(directory: directory, id: state.id)
        let vectors = Darwin.open(urls.vectors.path(percentEncoded: false), O_RDWR | O_CLOEXEC)
        guard vectors >= 0 else { throw SearchVectorFileInvalid.missing }
        let keyFile = Darwin.open(urls.keys.path(percentEncoded: false), O_RDWR | O_CLOEXEC)
        guard keyFile >= 0 else {
            close(vectors)
            throw SearchVectorFileInvalid.missing
        }
        let file: SearchVectorFile
        do {
            try SearchVectorFormat.checkVectorsHeader(read(vectors, count: SearchVectorFormat.headerBytes), id: state.id)
            try SearchVectorFormat.checkKeysHeader(read(keyFile, count: SearchVectorFormat.keysHeaderBytes), id: state.id)
            let vectorsNeeded = SearchVectorFormat.vectorsLength(slots: state.slots)
            guard try size(vectors) >= vectorsNeeded else { throw SearchVectorFileInvalid.short }
            let keysSize = try size(keyFile)
            let parsing = ContinuousClock.now
            defer {
                OtosLog.thumbnails.noticeOperation("search.vectors", phase: "parsed", fields: [
                    "slots": "\(state.slots)", "keysKB": "\(keysSize / 1024)", "ms": "\(DiagnosticsTiming.milliseconds(since: parsing))",
                ])
            }
            let parsed = try SearchVectorMapping.map(keyFile, length: keysSize).map { mapping in
                defer { mapping.unmap() }
                return try SearchVectorKeys(parsing: mapping.base, length: keysSize, slots: state.slots)
            } ?? SearchVectorKeys(parsing: nil, length: keysSize, slots: state.slots)
            guard ftruncate(vectors, off_t(vectorsNeeded)) == 0, ftruncate(keyFile, off_t(parsed.length)) == 0 else {
                throw SearchVectorFileInvalid.io(errno)
            }
            file = SearchVectorFile(
                id: state.id, directory: directory, keys: parsed, vectors: vectors, keyFile: keyFile, availableBytes: availableBytes
            )
        } catch {
            close(vectors)
            close(keyFile)
            throw error
        }
        try file.remap()
        return file
    }

    /// A new, empty file pair of id `id` in `directory`, not yet named by the catalog.
    static func create(
        directory: URL, id: UUID, availableBytes: @escaping AvailableBytes = FreeSpaceFloor.availableBytes(onVolumeOf:)
    ) throws -> SearchVectorFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = SearchVectorFormat.urls(directory: directory, id: id)
        let flags = O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC
        let vectors = Darwin.open(urls.vectors.path(percentEncoded: false), flags, 0o644)
        guard vectors >= 0 else { throw SearchVectorFileInvalid.io(errno) }
        let keyFile = Darwin.open(urls.keys.path(percentEncoded: false), flags, 0o644)
        guard keyFile >= 0 else {
            let code = errno
            close(vectors)
            throw SearchVectorFileInvalid.io(code)
        }
        let file = SearchVectorFile(
            id: id, directory: directory, keys: SearchVectorKeys(), vectors: vectors, keyFile: keyFile, availableBytes: availableBytes
        )
        try writeAll(SearchVectorFormat.vectorsHeader(id: id), to: vectors, at: 0)
        try writeAll(SearchVectorFormat.keysHeader(id: id), to: keyFile, at: 0)
        try file.remap()
        return file
    }

    /// Removes every file in `directory` but the pair of `keeping`: files of a rebuilt or
    /// compacted generation, and any a crash left behind.
    static func removeOthers(in directory: URL, keeping: UUID?) {
        var kept: Set<String> = []
        if let keeping {
            let urls = SearchVectorFormat.urls(directory: directory, id: keeping)
            kept = [urls.vectors.lastPathComponent, urls.keys.lastPathComponent]
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            OtosLog.thumbnails.errorOperation("search.vectors", phase: "listFailed", fields: ["error": String(describing: error)])
            return
        }
        for name in names where !kept.contains(name) {
            do {
                try FileManager.default.removeItem(at: directory.appending(path: name))
            } catch {
                OtosLog.thumbnails.errorOperation("search.vectors", phase: "removeFailed", fields: [
                    "file": name, "error": String(describing: error),
                ])
            }
        }
    }

    /// Removes the pair of `id` in `directory`: a build that failed removes its own file and
    /// nothing else.
    static func remove(_ id: UUID, in directory: URL) {
        let urls = SearchVectorFormat.urls(directory: directory, id: id)
        for url in [urls.vectors, urls.keys] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                OtosLog.thumbnails.errorOperation("search.vectors", phase: "removeFailed", fields: [
                    "file": url.lastPathComponent, "error": String(describing: error),
                ])
            }
        }
    }

    // MARK: Appending

    /// `rows` as the next slots, in order, encoded against the file as it stands: the vectors
    /// as Float16, the keys with any root or label name not numbered yet. Nothing changes until
    /// the append is written (`write`) and taken.
    func encode(_ rows: [StoredSearchEmbeddingRow]) throws -> SearchVectorAppend {
        try encode(
            vectors: SearchVectorFormat.halves(of: rows),
            entries: rows.map { (id: $0.id, labels: SearchVectorKeys.labels(fromText: $0.labels)) }
        )
    }

    private func encode(vectors: Data, entries: [(id: MediaAssetID, labels: [(name: String, confidence: Float)])]) throws -> SearchVectorAppend {
        var next = keys
        let keyBytes = try next.encode(entries)
        return SearchVectorAppend(file: id, fromSlots: slots, fromKeysLength: keys.length, vectorBytes: vectors, keyBytes: keyBytes, next: next)
    }

    /// Appends `rows` as the next slots of a file being built: encoded, written and taken.
    /// The free-space floor (ADR 0027) is asked first: no catalog commit counts these slots.
    func append(_ rows: [StoredSearchEmbeddingRow]) async throws {
        precondition(!held, "a file memory holds takes appends through SearchIndexMemory")
        guard !rows.isEmpty else { return }
        let pending = try encode(rows)
        try checkFloor(for: pending)
        try await write(pending)
        try take(pending)
    }

    /// Appends the live slots of `old`, in their order, `batch` at a time, to a file being
    /// built: what compaction writes.
    func appendLive(of old: SearchVectorFile, batch: Int = 4096) async throws {
        precondition(!held, "a file memory holds takes appends through SearchIndexMemory")
        let live = old.rowOf.values.sorted()
        var start = 0
        while start < live.count {
            let slots = live[start ..< min(start + batch, live.count)]
            start += slots.count
            var vectorBytes = Data(capacity: slots.count * SearchVectorFormat.slotBytes)
            var entries: [(id: MediaAssetID, labels: [(name: String, confidence: Float)])] = []
            entries.reserveCapacity(slots.count)
            for slot in slots {
                vectorBytes.append(old.vectorBytes(slot: Int(slot)))
                entries.append((old.keys.slotIDs[Int(slot)], old.labels(slot: Int(slot))))
            }
            let pending = try encode(vectors: vectorBytes, entries: entries)
            try checkFloor(for: pending)
            try await write(pending)
            try take(pending)
        }
    }

    /// Throws `floorReached` when writing `pending` would take the volume below the floor:
    /// what a file being built asks before each write, since no commit waits on it.
    private func checkFloor(for pending: SearchVectorAppend) throws {
        let needed = Int64(pending.vectorBytes.count + pending.keyBytes.count)
        guard FreeSpaceFloor.admits(needed, available: availableBytes(directory)) else {
            throw SearchVectorFileInvalid.floorReached
        }
    }

    /// Whether `rows` more slots keep the volume at the free-space floor (ADR 0027): asked
    /// before the catalog commits slots for a file memory holds, and only then — the write
    /// that follows the commit is never refused for the floor, so a disk that fills between
    /// the two leaves the file and the catalog agreeing rather than a file short of the count.
    /// A row's keys are counted at `estimatedKeyBytes`.
    func admits(rows: Int) -> Bool {
        let needed = Int64(rows * (SearchVectorFormat.slotBytes + Self.estimatedKeyBytes))
        return FreeSpaceFloor.admits(needed, available: availableBytes(directory))
    }

    /// A generous slot record: path, root number and about eighteen labels.
    static let estimatedKeyBytes = 512

    /// Writes `pending`'s bytes past the file's end, off the actor: the vectors ordered to the
    /// disk before the keys that name them (`F_BARRIERFSYNC`). The floor is the caller's to ask
    /// before it commits (`admits(rows:)`) or builds (`checkFloor`); a full disk here is the
    /// write's own `ENOSPC`. Changes nothing the file answers from: a read of it during the
    /// write reads the slots it had, and the file takes the append afterwards (`take`).
    func write(_ pending: SearchVectorAppend) async throws {
        guard pending.file == id, pending.fromSlots == slots, pending.fromKeysLength == keys.length else {
            throw SearchVectorFileInvalid.stale
        }
        try await Self.write(pending.vectorBytes, to: vectorsDescriptor, at: SearchVectorFormat.vectorsLength(slots: pending.fromSlots))
        try await Self.write(pending.keyBytes, to: keysDescriptor, at: pending.fromKeysLength)
    }

    /// Takes a written append in one step: throws, changing nothing, when it was not encoded
    /// against the file as it stands or its new length does not map; the new mappings are made
    /// before the old ones go.
    fileprivate func take(_ pending: SearchVectorAppend) throws {
        guard pending.file == id, pending.fromSlots == slots, pending.fromKeysLength == keys.length else {
            throw SearchVectorFileInvalid.stale
        }
        let vectors = try SearchVectorMapping.map(vectorsDescriptor, length: SearchVectorFormat.vectorsLength(slots: pending.next.slotIDs.count))
        let keyMapping: SearchVectorMapping?
        do {
            keyMapping = try SearchVectorMapping.map(keysDescriptor, length: pending.next.length)
        } catch {
            vectors?.unmap()
            throw error
        }
        vectorMap?.unmap()
        keysMap?.unmap()
        vectorMap = vectors
        keysMap = keyMapping
        keys = pending.next
        for slot in pending.fromSlots ..< pending.next.slotIDs.count {
            rowOf[pending.next.slotIDs[slot]] = Int32(slot)
        }
    }

    /// Takes `ids` out of the file's live slots: their slots are dead until compaction.
    fileprivate func forget(_ ids: some Sequence<MediaAssetID>) {
        for id in ids {
            rowOf.removeValue(forKey: id)
        }
    }

    /// Writes all of `data` at `offset` and orders it to the disk before any later write on the
    /// device (`F_BARRIERFSYNC`), on the caller's executor's behalf off it.
    @concurrent
    static func write(_ data: Data, to descriptor: Int32, at offset: Int) async throws {
        try writeAll(data, to: descriptor, at: offset)
        guard fcntl(descriptor, F_BARRIERFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw SearchVectorFileInvalid.io(errno)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, at offset: Int) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = pwrite(descriptor, buffer.baseAddress! + written, buffer.count - written, off_t(offset + written))
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SearchVectorFileInvalid.io(errno)
                }
                written += result
            }
        }
    }

    /// Orders every byte written to both files to the disk: what a build or a compaction does
    /// before the catalog names the file.
    @concurrent
    static func synchronize(_ descriptors: [Int32]) async throws {
        for descriptor in descriptors where fcntl(descriptor, F_FULLFSYNC) != 0 && fsync(descriptor) != 0 {
            throw SearchVectorFileInvalid.io(errno)
        }
    }

    var descriptors: [Int32] {
        [vectorsDescriptor, keysDescriptor]
    }

    private func remap() throws {
        vectorMap?.unmap()
        keysMap?.unmap()
        vectorMap = nil
        keysMap = nil
        vectorMap = try SearchVectorMapping.map(vectorsDescriptor, length: SearchVectorFormat.vectorsLength(slots: slots))
        keysMap = try SearchVectorMapping.map(keysDescriptor, length: keys.length)
    }

    // MARK: Reading

    /// Every slot's cosine with `query`, dead slots included: the vectors widened from Float16
    /// a chunk at a time (`vImageConvert_Planar16FtoPlanarF`, exact) and multiplied by the
    /// query in Float32 (`vDSP_mmul`). About 14 ms over 165,000 slots whose pages are resident.
    func scores(_ query: [Float]) -> [Float] {
        let count = slots, dimensions = SearchEmbedding.dimensions
        var scores = [Float](repeating: 0, count: count)
        guard count > 0, let base = vectorMap?.base, query.count == dimensions else { return scores }
        let chunk = Self.scoreChunk
        let widened = UnsafeMutablePointer<Float>.allocate(capacity: chunk * dimensions)
        defer { widened.deallocate() }
        scores.withUnsafeMutableBufferPointer { out in
            query.withUnsafeBufferPointer { query in
                var start = 0
                while start < count {
                    let rows = min(chunk, count - start)
                    let elements = vImagePixelCount(rows * dimensions)
                    var source = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: base + SearchVectorFormat.vectorsLength(slots: start)),
                        height: 1, width: elements, rowBytes: rows * dimensions * 2
                    )
                    var destination = vImage_Buffer(data: widened, height: 1, width: elements, rowBytes: rows * dimensions * 4)
                    vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
                    vDSP_mmul(widened, 1, query.baseAddress!, 1, out.baseAddress! + start, 1, vDSP_Length(rows), 1, vDSP_Length(dimensions))
                    start += rows
                }
            }
        }
        return scores
    }

    /// Asks the kernel to read the mapped vectors in ahead of the first query
    /// (`MADV_WILLNEED`): it starts the reads and returns; the pages stay clean and
    /// file-backed, outside the footprint, and the kernel may drop them again.
    func adviseWillNeed() {
        guard let vectorMap else { return }
        if madvise(UnsafeMutableRawPointer(mutating: vectorMap.base), vectorMap.length, MADV_WILLNEED) != 0 {
            OtosLog.thumbnails.errorOperation("search.vectors", phase: "adviseFailed", fields: ["errno": "\(errno)"])
        }
    }

    /// Slots widened per step: 3 MB of Float32, so the step stays in cache.
    static let scoreChunk = 1024

    /// Slot `slot`'s confidence in the label `name`, nil when it has none.
    func confidence(slot: Int, of name: String) -> Float? {
        guard let number = keys.labelNumbers[name], let base = keysMap?.base else { return nil }
        let offset = Int(keys.labelOffsets[slot])
        let count = Int(SearchVectorFormat.uint16(base, offset))
        for entry in 0 ..< count {
            let at = offset + 2 + entry * SearchVectorFormat.labelEntryBytes
            if SearchVectorFormat.uint16(base, at) == number {
                return Float(bitPattern: SearchVectorFormat.uint32(base, at + 2))
            }
        }
        return nil
    }

    /// Slot `slot`'s labels as numbered names and confidences.
    private func labels(slot: Int) -> [(name: String, confidence: Float)] {
        guard let base = keysMap?.base else { return [] }
        let offset = Int(keys.labelOffsets[slot])
        let count = Int(SearchVectorFormat.uint16(base, offset))
        return (0 ..< count).compactMap { entry in
            let at = offset + 2 + entry * SearchVectorFormat.labelEntryBytes
            let number = Int(SearchVectorFormat.uint16(base, at))
            guard number < keys.labelNames.count else { return nil }
            return (keys.labelNames[number], Float(bitPattern: SearchVectorFormat.uint32(base, at + 2)))
        }
    }

    /// Slot `slot`'s vector widened to Float32: what a test compares.
    func vector(slot: Int) -> [Float] {
        let halves = vectorBytes(slot: slot)
        return halves.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt16.self).map { Float(Float16(bitPattern: UInt16(littleEndian: $0))) }
        }
    }

    private func vectorBytes(slot: Int) -> Data {
        guard let base = vectorMap?.base else { return Data() }
        return Data(bytes: base + SearchVectorFormat.vectorsLength(slots: slot), count: SearchVectorFormat.slotBytes)
    }

    private static func read(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!, count, 0) }
        guard got == count else { throw SearchVectorFileInvalid.malformed("header") }
        return data
    }

    private static func size(_ descriptor: Int32) throws -> Int {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw SearchVectorFileInvalid.io(errno) }
        return Int(info.st_size)
    }
}

/// What the catalog records of the search vector file (v70): which pair it is and how many of
/// its slots the catalog's embeddings commit.
nonisolated struct SearchVectorFileState: Equatable, Sendable {
    let id: UUID
    let slots: Int

    static let addSlotsSQL = "UPDATE search_vector_file SET slots = slots + ?"

    static let fileSQL = "SELECT file_id, slots FROM search_vector_file"

    static let deleteFileSQL = "DELETE FROM search_vector_file"

    static let insertFileSQL = "INSERT INTO search_vector_file (file_id, slots) VALUES (?, ?)"
}

/// Why a vector file is not current, and is rebuilt.
nonisolated enum SearchVectorFileInvalid: Error, Equatable {
    /// No file is named, or a named one is not there.
    case missing
    /// A header or a record that does not read as written.
    case malformed(String)
    /// The model revision the file was written for is not the current one.
    case revision
    /// Fewer slots than the catalog commits: a crash between a commit and its append.
    case short
    /// The free-space floor would be crossed (ADR 0027).
    case floorReached
    /// An append encoded against a file that has changed since, or one memory no longer holds.
    case stale
    /// A system call failed, with its `errno`.
    case io(Int32)

    var reason: String {
        switch self {
        case .missing: "missing"
        case let .malformed(part): "malformed:\(part)"
        case .revision: "revision"
        case .short: "short"
        case .floorReached: "floorReached"
        case .stale: "stale"
        case let .io(code): "io:\(code)"
        }
    }
}

/// A process's exclusive claim on a vector folder: the one writer of its files. Two Otos
/// processes over one Application Support (a second copy started with `open -n`) would both
/// cut files the other maps (`ftruncate` under a mapping faults the reader) and remove each
/// other's pairs; the text-reading child (`Otos --read-text`) never opens the folder, since
/// `main.swift` serves readings before the app starts. The claim is a `flock` on the folder
/// itself, which `removeOthers` never removes, and the kernel releases it however the holder
/// ends, so a crashed owner leaves nothing to clear.
final nonisolated class SearchVectorDirectoryClaim {
    private let descriptor: Int32

    /// Claims `directory`, making it if needed; throws `SearchVectorDirectoryHeld` when
    /// another process holds it.
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SearchVectorFileInvalid.io(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw SearchVectorDirectoryHeld()
            }
            throw SearchVectorFileInvalid.io(code)
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Another process holds the vector folder (`SearchVectorDirectoryClaim`): this one reads and
/// writes no vector file until it is free, and asks again after the backoff.
nonisolated struct SearchVectorDirectoryHeld: Error, Equatable {}

/// An append encoded against one file at one length (`SearchVectorFile.encode`): written off
/// the actor, then taken by the file only while it still stands where the append was encoded.
nonisolated struct SearchVectorAppend: Sendable {
    let file: UUID
    let fromSlots: Int
    let fromKeysLength: Int
    let vectorBytes: Data
    let keyBytes: Data
    let next: SearchVectorKeys
}

/// What the search index answers a query's picture from (`PhotoSearchIndex`): the vector file
/// it maps, and the revision that names it. Every change to it is a method here, and each
/// moves `revision` in the same synchronous step, so an equal revision is the same
/// memory: slots read at one revision (`PhotoSearchIndex.ScopedRows`) are slots of the file
/// that answers at it. A file memory holds gains or loses slots only here, because only this
/// file can make it take an append or forget an asset.
nonisolated struct SearchIndexMemory {
    private(set) var vectors: SearchVectorFile?
    /// Never reset, so an equal revision means the same memory.
    private(set) var revision: UInt64 = 0

    /// Memory maps `file` from here on, or nothing: a file loaded, built or compacted, or one
    /// let go.
    mutating func replaceVectors(with file: SearchVectorFile?) {
        vectors?.held = false
        file?.held = true
        vectors = file
        revision &+= 1
    }

    /// `file`, the one memory holds, takes `pending` (already written, `SearchVectorFile.write`)
    /// and lets `gone` go. Throws, changing nothing, when memory holds another file or the
    /// append was encoded against this one as it no longer stands.
    mutating func changeVectors(of file: SearchVectorFile, taking pending: SearchVectorAppend?, removing gone: some Sequence<MediaAssetID>) throws {
        guard let vectors, vectors === file else { throw SearchVectorFileInvalid.stale }
        if let pending {
            try vectors.take(pending)
        }
        vectors.forget(gone)
        revision &+= 1
    }
}

/// One read-only, shared mapping of a file's first `length` bytes.
nonisolated struct SearchVectorMapping {
    let base: UnsafeRawPointer
    let length: Int

    /// Nil for an empty length, which maps nothing.
    static func map(_ descriptor: Int32, length: Int) throws -> SearchVectorMapping? {
        guard length > 0 else { return nil }
        guard let pointer = mmap(nil, length, PROT_READ, MAP_SHARED | MAP_FILE, descriptor, 0), pointer != MAP_FAILED else {
            throw SearchVectorFileInvalid.io(errno)
        }
        return SearchVectorMapping(base: UnsafeRawPointer(pointer), length: length)
    }

    func unmap() {
        munmap(UnsafeMutableRawPointer(mutating: base), length)
    }
}

/// The byte layout of the vector file pair (little-endian throughout).
nonisolated enum SearchVectorFormat {
    static let headerBytes = 4096
    static let keysHeaderBytes = 64
    static let slotBytes = SearchEmbedding.dimensions * 2
    static let labelEntryBytes = 6
    static let version: UInt32 = 1
    static let binary16: UInt32 = 1
    private static let vectorsMagic = Array("OTOSVEC1".utf8)
    private static let keysMagic = Array("OTOSKEY1".utf8)

    enum Record: UInt8 {
        case root = 1
        case label = 2
        case slot = 3
    }

    static func urls(directory: URL, id: UUID) -> (vectors: URL, keys: URL) {
        let name = id.uuidString.lowercased()
        return (directory.appending(path: "\(name).vectors"), directory.appending(path: "\(name).keys"))
    }

    static func vectorsLength(slots: Int) -> Int {
        headerBytes + slots * slotBytes
    }

    static func vectorsHeader(id: UUID) -> Data {
        var bytes = vectorsMagic
        append(version, to: &bytes)
        append(UInt32(SearchEmbedding.dimensions), to: &bytes)
        append(binary16, to: &bytes)
        append(UInt32(SearchEmbedding.revision), to: &bytes)
        append(id, to: &bytes)
        append(checksum(bytes), to: &bytes)
        bytes += [UInt8](repeating: 0, count: headerBytes - bytes.count)
        return Data(bytes)
    }

    static func keysHeader(id: UUID) -> Data {
        var bytes = keysMagic
        append(id, to: &bytes)
        append(checksum(bytes), to: &bytes)
        bytes += [UInt8](repeating: 0, count: keysHeaderBytes - bytes.count)
        return Data(bytes)
    }

    static func checkVectorsHeader(_ header: Data, id: UUID) throws {
        let bytes = [UInt8](header.prefix(48))
        guard Array(bytes[0 ..< 8]) == vectorsMagic, checksum(Array(bytes[0 ..< 40])) == uint64(bytes, 40) else {
            throw SearchVectorFileInvalid.malformed("vectorsHeader")
        }
        guard uint32(bytes, 8) == version, uint32(bytes, 12) == UInt32(SearchEmbedding.dimensions),
              uint32(bytes, 16) == binary16, uuid(bytes, 24) == id
        else {
            throw SearchVectorFileInvalid.malformed("vectorsHeader")
        }
        guard uint32(bytes, 20) == UInt32(SearchEmbedding.revision) else {
            throw SearchVectorFileInvalid.revision
        }
    }

    static func checkKeysHeader(_ header: Data, id: UUID) throws {
        let bytes = [UInt8](header.prefix(32))
        guard Array(bytes[0 ..< 8]) == keysMagic, checksum(Array(bytes[0 ..< 24])) == uint64(bytes, 24), uuid(bytes, 8) == id else {
            throw SearchVectorFileInvalid.malformed("keysHeader")
        }
    }

    /// The rows' vectors as little-endian Float16, rounded to nearest
    /// (`vImageConvert_PlanarFtoPlanar16F`).
    static func halves(of rows: [StoredSearchEmbeddingRow]) throws -> Data {
        let dimensions = SearchEmbedding.dimensions
        var floats = [Float]()
        floats.reserveCapacity(rows.count * dimensions)
        for row in rows {
            guard row.vector.count == dimensions * 4 else { throw SearchVectorFileInvalid.malformed("vector") }
            row.vector.withUnsafeBytes { floats.append(contentsOf: $0.bindMemory(to: Float.self)) }
        }
        var halves = Data(count: floats.count * 2)
        halves.withUnsafeMutableBytes { out in
            floats.withUnsafeMutableBufferPointer { input in
                var source = vImage_Buffer(data: input.baseAddress, height: 1, width: vImagePixelCount(input.count), rowBytes: input.count * 4)
                var destination = vImage_Buffer(data: out.baseAddress, height: 1, width: vImagePixelCount(input.count), rowBytes: input.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&source, &destination, vImage_Flags(kvImageNoFlags))
            }
        }
        return halves
    }

    static func append(_ value: some FixedWidthInteger, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes += $0 }
    }

    private static func append(_ id: UUID, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: id.uuid) { bytes += $0 }
    }

    /// FNV-1a over `bytes`.
    static func checksum(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private static func uint64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0 ..< 8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }

    private static func uuid(_ bytes: [UInt8], _ offset: Int) -> UUID {
        UUID(uuid: (
            bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3], bytes[offset + 4], bytes[offset + 5],
            bytes[offset + 6], bytes[offset + 7], bytes[offset + 8], bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
            bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15]
        ))
    }

    static func uint16(_ base: UnsafeRawPointer, _ offset: Int) -> UInt16 {
        UInt16(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    static func uint32(_ base: UnsafeRawPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

/// The keys file as memory holds it: each slot's asset and where its labels begin, and the
/// roots and label names the records number. A value: an append encodes into a copy, and the
/// file takes the copy once its bytes are written.
nonisolated struct SearchVectorKeys: Sendable {
    private(set) var roots: [LibraryRootPath] = []
    private(set) var rootNumbers: [LibraryRootPath: UInt16] = [:]
    private(set) var labelNames: [String] = []
    private(set) var labelNumbers: [String: UInt16] = [:]
    private(set) var slotIDs: [MediaAssetID] = []
    /// Per slot, the keys file offset of its label count.
    private(set) var labelOffsets: [UInt32] = []
    /// The keys file's length through its last slot record.
    private(set) var length = SearchVectorFormat.keysHeaderBytes

    init() {}

    /// The records of `entries` as the next slots, appended to this value; the bytes to write
    /// at the old `length`.
    mutating func encode(_ entries: [(id: MediaAssetID, labels: [(name: String, confidence: Float)])]) throws -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(entries.count * 200)
        for entry in entries {
            let root = try number(ofRoot: entry.id.libraryRootPath, into: &bytes)
            let labels = try entry.labels.map { try (number: number(ofLabel: $0.name, into: &bytes), confidence: $0.confidence) }
            let path = Array(entry.id.relativePath.rawValue.utf8)
            guard labels.count <= Int(UInt16.max) else { throw SearchVectorFileInvalid.malformed("labels") }
            bytes.append(SearchVectorFormat.Record.slot.rawValue)
            SearchVectorFormat.append(root, to: &bytes)
            SearchVectorFormat.append(UInt32(path.count), to: &bytes)
            bytes += path
            labelOffsets.append(UInt32(length + bytes.count))
            SearchVectorFormat.append(UInt16(labels.count), to: &bytes)
            for label in labels {
                SearchVectorFormat.append(label.number, to: &bytes)
                SearchVectorFormat.append(label.confidence.bitPattern, to: &bytes)
            }
            slotIDs.append(entry.id)
        }
        length += bytes.count
        guard length <= Int(UInt32.max) else { throw SearchVectorFileInvalid.malformed("keysLength") }
        return Data(bytes)
    }

    private mutating func number(ofRoot root: LibraryRootPath, into bytes: inout [UInt8]) throws -> UInt16 {
        if let number = rootNumbers[root] {
            return number
        }
        guard let number = UInt16(exactly: roots.count) else { throw SearchVectorFileInvalid.malformed("roots") }
        Self.define(.root, number: number, name: root.rawValue, into: &bytes)
        roots.append(root)
        rootNumbers[root] = number
        return number
    }

    private mutating func number(ofLabel name: String, into bytes: inout [UInt8]) throws -> UInt16 {
        if let number = labelNumbers[name] {
            return number
        }
        guard let number = UInt16(exactly: labelNames.count) else { throw SearchVectorFileInvalid.malformed("labelNames") }
        Self.define(.label, number: number, name: name, into: &bytes)
        labelNames.append(name)
        labelNumbers[name] = number
        return number
    }

    private static func define(_ record: SearchVectorFormat.Record, number: UInt16, name: String, into bytes: inout [UInt8]) {
        let utf8 = Array(name.utf8)
        bytes.append(record.rawValue)
        SearchVectorFormat.append(number, to: &bytes)
        SearchVectorFormat.append(UInt32(utf8.count), to: &bytes)
        bytes += utf8
    }

    /// The first `slots` slot records of a keys file of `length` bytes at `base`, with the
    /// definitions before them; `length` becomes the end of the last. Throws when they do not
    /// read as written or end early.
    init(parsing base: UnsafeRawPointer?, length fileLength: Int, slots: Int) throws {
        var offset = SearchVectorFormat.keysHeaderBytes
        slotIDs.reserveCapacity(slots)
        labelOffsets.reserveCapacity(slots)
        func need(_ bytes: Int) throws {
            guard offset + bytes <= fileLength else { throw SearchVectorFileInvalid.short }
        }
        func string(_ count: Int) throws -> String {
            try need(count)
            guard let base else { throw SearchVectorFileInvalid.short }
            defer { offset += count }
            return String(decoding: UnsafeRawBufferPointer(start: base + offset, count: count), as: UTF8.self)
        }
        while slotIDs.count < slots {
            try need(1)
            guard let base, let record = SearchVectorFormat.Record(rawValue: base.load(fromByteOffset: offset, as: UInt8.self)) else {
                throw SearchVectorFileInvalid.malformed("record")
            }
            offset += 1
            try need(6)
            let number = SearchVectorFormat.uint16(base, offset)
            let count = Int(SearchVectorFormat.uint32(base, offset + 2))
            offset += 6
            switch record {
            case .root:
                guard Int(number) == roots.count else { throw SearchVectorFileInvalid.malformed("root") }
                let root = try LibraryRootPath(rawValue: string(count))
                roots.append(root)
                rootNumbers[root] = number
            case .label:
                guard Int(number) == labelNames.count else { throw SearchVectorFileInvalid.malformed("label") }
                let name = try string(count)
                labelNames.append(name)
                labelNumbers[name] = number
            case .slot:
                guard Int(number) < roots.count else { throw SearchVectorFileInvalid.malformed("slotRoot") }
                let path = try MediaRelativePath(rawValue: string(count))
                try need(2)
                labelOffsets.append(UInt32(offset))
                let labels = Int(SearchVectorFormat.uint16(base, offset))
                offset += 2
                // A label's number is checked where it is read (`confidence`, `labels`), not
                // here: 18 a slot, 3 million on the reference library, were most of an open.
                try need(labels * SearchVectorFormat.labelEntryBytes)
                offset += labels * SearchVectorFormat.labelEntryBytes
                slotIDs.append(MediaAssetID(libraryRootPath: roots[Int(number)], relativePath: path))
            }
        }
        length = offset
    }

    /// The labels of `text` (`SearchEmbeddingStorage.labelsText`'s form) as
    /// `SearchEmbeddingStorage.labels(from:)` reads them: a pair that does not parse is
    /// skipped, and a label read twice keeps its last confidence.
    static func labels(fromText text: String?) -> [(name: String, confidence: Float)] {
        var labels: [(name: String, confidence: Float)] = []
        var position: [String: Int] = [:]
        for pair in (text ?? "").split(separator: ",") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let confidence = Float(parts[1]) {
                let name = String(parts[0])
                if let at = position[name] {
                    labels[at].confidence = confidence
                } else {
                    position[name] = labels.count
                    labels.append((name, confidence))
                }
            }
        }
        return labels
    }
}
