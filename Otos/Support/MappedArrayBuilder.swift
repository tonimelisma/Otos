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
///   appends an unknown number of values of a result that can be owner-scale. A build that
///   stays small never maps: its first elements go in one heap buffer of 2 KB, well under
///   the 4 KB from which a freed block stays in the footprint (`smallBytes`), and only a build that outgrows
///   it moves to mapped regions, so a result whose scale varies (a root of ten photos or of
///   160,000) pays for a mapping only when it is large.
/// - **What does not:** a result whose length, or bound, is known before it is built. A
///   bounded page (a page of a walk, a batch of keys, a `LIMIT`) is one buffer reserved at its
///   bound (`Array(page:atMost:)`), and a result of known length says it once
///   (`reserveCapacity`, `Array(unsafeUninitializedCapacity:)`).
/// - **Use:** one builder per build, by one task, never shared; `finish()` ends it. Elements
///   may be any type: they are moved, never copied bitwise, and a builder dropped unfinished
///   releases what it holds. A mapping that fails is the process out of address space, where an
///   array's own allocation traps too, so it traps (as `ScratchBuffer` and
///   `MediaAssetIdentityTable` do).
nonisolated struct MappedArrayBuilder<Element>: ~Copyable {
    /// The elements: a small heap buffer (`bytes == 0`) until the build outgrows it, then a
    /// mapped region of `bytes`.
    private var base: UnsafeMutablePointer<Element>?
    private var capacity = 0
    private var bytes = 0
    private(set) var count = 0

    /// The most a small build's heap buffer holds: 2 KB, half the size from which a freed block
    /// stays dirty in the footprint whole, so malloc's size classes never round it up to one.
    static var smallBytes: Int {
        2048
    }

    private static var smallCapacity: Int {
        max(1, smallBytes / max(MemoryLayout<Element>.stride, 1))
    }

    init() {}

    deinit {
        guard let base else { return }
        base.deinitialize(count: count)
        Self.release(base, bytes: bytes)
    }

    mutating func append(_ element: consuming Element) {
        if base == nil {
            base = .allocate(capacity: Self.smallCapacity)
            capacity = Self.smallCapacity
        } else if count == capacity {
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

    /// The elements in the order appended, in an array of exactly `count`; the small buffer or
    /// the regions are released.
    consuming func finish() -> [Element] {
        let (base, count, bytes) = (base, count, bytes)
        discard self
        guard let base else { return [] }
        let result = [Element](unsafeUninitializedCapacity: count) { buffer, initialized in
            buffer.baseAddress!.moveInitialize(from: base, count: count)
            initialized = count
        }
        Self.release(base, bytes: bytes)
        return result
    }

    /// The small buffer goes back to malloc, a region to the system.
    private static func release(_ base: UnsafeMutablePointer<Element>, bytes: Int) {
        if bytes == 0 {
            base.deallocate()
        } else {
            munmap(UnsafeMutableRawPointer(base), bytes)
        }
    }

    /// Doubles into a new mapping, moves the elements over and releases the old buffer: what
    /// an array would free into malloc goes back to the system.
    private mutating func grow() {
        let page = Int(getpagesize())
        let stride = max(MemoryLayout<Element>.stride, 1)
        let wanted = max(count * 2 * stride, page)
        let newBytes = (wanted + page - 1) / page * page
        let region = mmap(nil, newBytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let region, region != MAP_FAILED else {
            fatalError("op=mappedArray.map phase=failed bytes=\(newBytes) errno=\(errno)")
        }
        let newBase = region.bindMemory(to: Element.self, capacity: newBytes / stride)
        if let base {
            newBase.moveInitialize(from: base, count: count)
            Self.release(base, bytes: bytes)
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

nonisolated extension Array {
    /// A bounded page's values — `transform` of each of `elements`, a nil one left out — in one
    /// buffer reserved for `bound` (the guide's "what does not belong here").
    init<S: Sequence>(page elements: S, atMost bound: Int, _ transform: (S.Element) throws -> Element?) rethrows {
        self.init()
        reserveCapacity(bound)
        for element in elements {
            if let value = try transform(element) {
                append(value)
            }
        }
    }

    /// A bounded read's values — `transform` of each of `cursor`'s rows, a nil one left out —
    /// in one buffer reserved for `bound`, the read's `LIMIT`.
    init<C: Cursor>(page cursor: C, atMost bound: Int, _ transform: (C.Element) throws -> Element?) throws {
        self.init()
        reserveCapacity(bound)
        while let row = try cursor.next() {
            if let value = try transform(row) {
                append(value)
            }
        }
    }
}

nonisolated extension Dictionary {
    /// `elements` grouped by `key`, each group an array made at its length: what
    /// `Dictionary(grouping:by:)` builds by appending, group by group, without the buffers each
    /// group outgrows (`MappedArrayBuilder`). `key` is asked once per element, and each
    /// element's group is kept in one array of the elements' length. The index of the groups
    /// grows with the groups found, since how many there are is known only once every key is
    /// read; the result is that index's own table (`mapValues` keeps its layout).
    init<S: Collection>(exactlyGrouping elements: S, by key: (S.Element) throws -> Key) rethrows
        where Value == [S.Element]
    {
        var groupOf: [Int] = []
        groupOf.reserveCapacity(elements.count)
        var index: [Key: Int] = [:]
        var sizes: [Int] = []
        for element in elements {
            let group = try key(element)
            let number: Int
            if let found = index[group] {
                number = found
            } else {
                number = sizes.count
                index[group] = number
                sizes.append(0)
            }
            sizes[number] += 1
            groupOf.append(number)
        }
        var members = sizes.map { size in
            var group: [S.Element] = []
            group.reserveCapacity(size)
            return group
        }
        for (element, number) in zip(elements, groupOf) {
            members[number].append(element)
        }
        self = index.mapValues { members[$0] }
    }
}
