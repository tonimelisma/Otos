import Darwin
import GRDB

/// Mapped array builder guide
///
/// **The rule: a read that builds an owner-scale array whose length it learns only as it reads
/// builds it here.** An array that grows by appending reallocates as it doubles, and every
/// buffer it outgrows is freed into malloc, which keeps it in the process's footprint on macOS
/// 27 (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`): a 16 MB result left
/// up to 16 MB of freed blocks behind it. This builder grows in its own mapped regions instead
/// (`mmap`, like `ScratchBuffer`), unmaps each one it outgrows, and hands back an array of
/// exactly its length, so the only malloc block the build leaves is the result itself.
///
/// - **What belongs here:** a cursor's rows mapped to values (`collect`), and any loop that
///   appends an unknown number of values of an owner-scale result.
/// - **What does not:** a result whose length is known before it is built (`reserveCapacity`
///   or `Array(unsafeUninitializedCapacity:)` says it once), and a small one: the first region
///   is a page, so a bounded read (a page of a walk, a few rows by key) costs a page.
/// - **Use:** one builder per build, by one task, never shared; `finish()` ends it. Elements
///   may be any type: they are moved, never copied bitwise, and a builder dropped unfinished
///   releases what it holds.
nonisolated struct MappedArrayBuilder<Element>: ~Copyable {
    private var base: UnsafeMutablePointer<Element>?
    private var capacity = 0
    private var bytes = 0
    private(set) var count = 0

    init() {}

    deinit {
        guard let base else { return }
        base.deinitialize(count: count)
        munmap(UnsafeMutableRawPointer(base), bytes)
    }

    mutating func append(_ element: consuming Element) {
        if count == capacity {
            grow()
        }
        (base! + count).initialize(to: element)
        count += 1
    }

    /// The elements appended so far, in order, read in place: what a build that groups or
    /// counts them before it makes its result reads, so the ungrouped rows never become a
    /// malloc block of their own.
    func withElements<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: base, count: count))
    }

    /// The elements in the order appended, in an array of exactly `count`; the regions are
    /// unmapped.
    consuming func finish() -> [Element] {
        let (base, count, bytes) = (base, count, bytes)
        discard self
        guard let base else { return [] }
        let result = [Element](unsafeUninitializedCapacity: count) { buffer, initialized in
            buffer.baseAddress!.moveInitialize(from: base, count: count)
            initialized = count
        }
        munmap(UnsafeMutableRawPointer(base), bytes)
        return result
    }

    /// Doubles into a new mapping, moves the elements over and unmaps the old one: what an
    /// array would free into malloc goes back to the system.
    private mutating func grow() {
        let page = Int(getpagesize())
        let stride = max(MemoryLayout<Element>.stride, 1)
        let wanted = max(capacity * 2 * stride, page)
        let newBytes = (wanted + page - 1) / page * page
        let region = mmap(nil, newBytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let region, region != MAP_FAILED else {
            fatalError("op=mappedArray.map phase=failed bytes=\(newBytes) errno=\(errno)")
        }
        let newBase = region.bindMemory(to: Element.self, capacity: newBytes / stride)
        if let base {
            newBase.moveInitialize(from: base, count: count)
            munmap(UnsafeMutableRawPointer(base), bytes)
        }
        base = newBase
        bytes = newBytes
        capacity = newBytes / stride
    }
}

nonisolated extension MappedArrayBuilder {
    /// Every value `transform` makes of `cursor`'s elements, a nil one left out, built as the
    /// guide says: what an owner-scale read collects from its cursor.
    static func collect<C: Cursor>(_ cursor: C, _ transform: (C.Element) throws -> Element?) throws -> [Element] {
        var builder = MappedArrayBuilder()
        while let row = try cursor.next() {
            if let value = try transform(row) {
                builder.append(value)
            }
        }
        return builder.finish()
    }

    /// Every value `transform` makes of `elements`, a nil one left out: an owner-scale
    /// `filter` or `compactMap`, whose length is known only once it is made.
    static func collect<S: Sequence>(_ elements: S, _ transform: (S.Element) throws -> Element?) rethrows -> [Element] {
        var builder = MappedArrayBuilder()
        for element in elements {
            if let value = try transform(element) {
                builder.append(value)
            }
        }
        return builder.finish()
    }
}

nonisolated extension Dictionary {
    /// `elements` grouped by `key`, each group an array made at its length: what
    /// `Dictionary(grouping:by:)` builds by appending, group by group, without the buffers each
    /// group outgrows (`MappedArrayBuilder`).
    init<S: Collection>(exactlyGrouping elements: S, by key: (S.Element) throws -> Key) rethrows
        where Value == [S.Element]
    {
        var counts: [Key: Int] = [:]
        for element in elements {
            try counts[key(element), default: 0] += 1
        }
        var groups: [Key: [S.Element]] = Dictionary(minimumCapacity: counts.count)
        for (group, count) in counts {
            var members: [S.Element] = []
            members.reserveCapacity(count)
            groups[group] = members
        }
        for element in elements {
            try groups[key(element)]?.append(element)
        }
        self = groups
    }
}
