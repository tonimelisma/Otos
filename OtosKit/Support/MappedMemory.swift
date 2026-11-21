import Darwin

/// Mapped memory guide (ADR 0056)
///
/// **The one place Otos maps anonymous memory.** `ScratchBuffer`, `MappedArrayBuilder` and
/// `MediaAssetIdentityTable` keep what they hold in regions of their own, outside the malloc
/// heap, so what they free goes back to the system instead of staying in the footprint
/// (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). Each maps and unmaps
/// through here, under one policy.
///
/// **A mapping that fails traps.** `mmap` of private anonymous memory reserves address space
/// only: its pages are zero-filled on first touch and backed by the compressor and swap, so
/// memory pressure never fails the call. It fails with `ENOMEM` when the process's address
/// space, or its map's entry limit, is exhausted — the condition in which `malloc` fails too,
/// and with it every Swift array, string and object the process makes, which trap. A read that
/// threw instead would survive only until its next allocation, so no read handles it: the
/// trap names the size and errno (`op=mappedMemory.map phase=failed`).
nonisolated enum MappedMemory {
    /// The system's page: what a region is rounded up to.
    static var pageSize: Int {
        Int(getpagesize())
    }

    /// `bytes` rounded up to whole pages.
    static func pages(for bytes: Int) -> Int {
        let page = pageSize
        return (max(bytes, 1) + page - 1) / page * page
    }

    /// A zeroed private region of `bytes`, which the caller unmaps with the same size.
    static func map(_ bytes: Int) -> UnsafeMutableRawPointer {
        let region = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let region, region != MAP_FAILED else {
            fatalError("op=mappedMemory.map phase=failed bytes=\(bytes) errno=\(errno)")
        }
        return region
    }

    /// A zeroed region for `count` elements of `Element`.
    static func map<Element>(_ count: Int, of _: Element.Type) -> UnsafeMutablePointer<Element> {
        map(count * MemoryLayout<Element>.stride).bindMemory(to: Element.self, capacity: count)
    }

    /// Gives a region `map` made back to the system.
    static func unmap(_ base: UnsafeMutableRawPointer, _ bytes: Int) {
        munmap(base, bytes)
    }
}
