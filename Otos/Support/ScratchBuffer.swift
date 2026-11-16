import Darwin

/// Scratch buffer guide
///
/// **The rule: a transient buffer of 4 KB or more that is freed before the process ends goes
/// here, not into a Swift array or `malloc`.** On macOS 27 what `malloc` frees stays in the
/// process's footprint until `malloc` reuses it: freed blocks of 4 KB to 16 MB were all still
/// counted after `free`, and `malloc_zone_pressure_relief` returned nothing for any zone
/// (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). A pass that builds a
/// few hundred megabytes of scratch and frees it leaves all of it in the footprint. A
/// `ScratchBuffer` is its own virtual-memory region: mapped when made, unmapped when its last
/// reference goes, so the footprint goes back down when the work ends.
///
/// - **What belongs here:** matrices, products and per-row tables a pass fills and drops, of a
///   size known when the work starts (`FaceAssignmentPolicy`'s blocks and products,
///   `BlockedSimilarity`'s transposed columns).
/// - **What does not:** what is kept between passes (held state is resident by design, and a
///   growing buffer is better as an array that is reused), and anything small.
/// - **Use:** fresh pages read as zero. The buffer is a plain region of `count` elements at
///   `base`; it is not thread-safe and is used by one task at a time, never shared across
///   actors, so it is not `Sendable`. Elements are `BitwiseCopyable`: nothing in it is
///   retained or released.
final nonisolated class ScratchBuffer<Element: BitwiseCopyable> {
    let count: Int
    let base: UnsafeMutablePointer<Element>
    private let bytes: Int

    /// Maps a region for `count` elements, rounded up to whole pages; a mapping that fails is
    /// the process out of address space, which nothing can recover from.
    init(count: Int) {
        self.count = count
        let page = Int(getpagesize())
        let needed = max(count, 1) * MemoryLayout<Element>.stride
        bytes = (needed + page - 1) / page * page
        let region = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let region, region != MAP_FAILED else {
            fatalError("op=scratch.map phase=failed bytes=\(bytes) errno=\(errno)")
        }
        base = region.bindMemory(to: Element.self, capacity: max(count, 1))
    }

    deinit {
        munmap(UnsafeMutableRawPointer(base), bytes)
    }

    /// Sets every element to `value`.
    func fill(with value: Element) {
        base.update(repeating: value, count: count)
    }

    var buffer: UnsafeMutableBufferPointer<Element> {
        UnsafeMutableBufferPointer(start: base, count: count)
    }
}
