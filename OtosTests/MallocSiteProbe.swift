import Darwin
import Foundation

/// Malloc site probe guide
///
/// Which code makes the blocks of 4 KB and up that a stretch of work allocates and frees:
/// the blocks whose freed pages stay in the footprint on macOS 27
/// (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). It installs libmalloc's
/// `malloc_logger` hook (the one malloc stack logging uses) for the stretch, and records each
/// allocation of `minimumBlock` bytes or more by its call stack: bytes and blocks allocated,
/// bytes freed again before the stretch ends, and the largest block. A test tool, never the
/// app's: one probe at a time in a process, and only around work the test drives.
///
/// The hook runs inside `malloc` and `free` on any thread, so it allocates nothing: its tables
/// are their own mapped regions, guarded by one `os_unfair_lock`, and it reads the stack with
/// `backtrace(3)`, which does not allocate. A table that fills stops recording and says so
/// (`overflowed`), rather than allocating.
nonisolated enum MallocSiteProbe {
    static let minimumBlock = 4096
    private static let depth = 40
    private static let siteCapacity = 1 << 16
    private static let liveCapacity = 1 << 21

    private struct Site {
        var hash: UInt64
        var allocatedBytes: Int
        var allocations: Int
        var freedBytes: Int
        var largest: Int
    }

    private struct Live {
        var address: UInt
        var size: Int
        var site: Int
    }

    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    private struct Header {
        var lock: os_unfair_lock
        var recording: Bool
        var overflow: Bool
    }

    private static let headerBytes = 256
    private static let sitesBytes = siteCapacity * MemoryLayout<Site>.stride
    private static let framesBytes = siteCapacity * depth * MemoryLayout<UInt>.stride
    private static let liveBytes = liveCapacity * MemoryLayout<Live>.stride
    private static let regionBytes = headerBytes + depth * MemoryLayout<UInt>.stride + sitesBytes + framesBytes + liveBytes
    /// The probe's one region, mapped once for the process: its header, the stack being
    /// recorded, the sites, each site's frames, then the live blocks. Held by address, so no
    /// mutable global crosses threads.
    private static let region: UInt = {
        let mapped = mmap(nil, regionBytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)!
        return UInt(bitPattern: mapped)
    }()

    /// Set on a thread while its call is in the hook: an allocation the hook's own calls make
    /// on that thread is not recorded, and never takes the lock twice.
    private static let inHook: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    private static var header: UnsafeMutablePointer<Header> {
        UnsafeMutablePointer(bitPattern: region)!
    }

    private static var scratch: UnsafeMutablePointer<UInt> {
        UnsafeMutablePointer(bitPattern: region + UInt(headerBytes))!
    }

    private static var sites: UnsafeMutablePointer<Site> {
        UnsafeMutablePointer(bitPattern: region + UInt(headerBytes + depth * MemoryLayout<UInt>.stride))!
    }

    private static var frames: UnsafeMutablePointer<UInt> {
        UnsafeMutablePointer(bitPattern: region + UInt(headerBytes + depth * MemoryLayout<UInt>.stride + sitesBytes))!
    }

    private static var live: UnsafeMutablePointer<Live> {
        UnsafeMutablePointer(bitPattern: region + UInt(regionBytes - liveBytes))!
    }

    private static var lock: UnsafeMutablePointer<os_unfair_lock> {
        UnsafeMutableRawPointer(header).assumingMemoryBound(to: os_unfair_lock.self)
    }

    /// One call stack's blocks over the stretch.
    struct Report: Sendable {
        let frames: [String]
        let allocatedBytes: Int
        let allocations: Int
        let freedBytes: Int
        let largest: Int

        /// Whether the blocks are an array's outgrown buffers (it reallocated as it grew by
        /// appending)
        /// while the code held a catalog connection: a read or write building its result by
        /// appending to an array with no capacity.
        var growsAnArrayInADatabaseAccess: Bool {
            // An append that outgrew its buffer (`Array.append`, `append(contentsOf:)`, the
            // stdlib's `filter` and `compactMap`), not a `reserveCapacity` made once.
            frames.contains { $0.contains("consumeAndCreateNew") } && frames.contains { $0.contains("6append") }
                && frames.contains { $0.contains("4GRDB14DatabaseReader") || $0.contains("4GRDB14DatabaseWriter") || $0.contains("4GRDB18SerializedDatabase") }
        }
    }

    private static var hook: UnsafeMutablePointer<Logger?> {
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")!
        return symbol.assumingMemoryBound(to: Logger?.self)
    }

    /// Records the blocks `body` and every thread meanwhile allocate, by call stack; returns the
    /// sites ordered by bytes freed, most first.
    static func record<T>(_ body: () async throws -> T) async rethrows -> (value: T, sites: [Report], overflowed: Bool) {
        _ = inHook
        memset(UnsafeMutableRawPointer(bitPattern: region)!, 0, regionBytes)
        header.pointee = Header(lock: os_unfair_lock(), recording: true, overflow: false)
        hook.pointee = { type, _, arg2, arg3, result, _ in MallocSiteProbe.log(type: type, arg2: arg2, arg3: arg3, result: result) }
        let value: T
        do {
            value = try await body()
        } catch {
            stop()
            throw error
        }
        stop()
        return (value, collect(), header.pointee.overflow)
    }

    /// Clears the hook, then stops recording under the lock: a call that read the hook before
    /// it was cleared finishes first.
    private static func stop() {
        hook.pointee = nil
        os_unfair_lock_lock(lock)
        header.pointee.recording = false
        os_unfair_lock_unlock(lock)
    }

    // libmalloc's event bits (`MALLOC_LOG_TYPE_*`).
    private static let allocate: UInt32 = 2
    private static let deallocate: UInt32 = 4

    private static func log(type: UInt32, arg2: UInt, arg3: UInt, result: UInt) {
        guard pthread_getspecific(inHook) == nil else { return }
        pthread_setspecific(inHook, UnsafeRawPointer(bitPattern: 1))
        defer { pthread_setspecific(inHook, nil) }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard header.pointee.recording else { return }
        if type & deallocate != 0 {
            // A free names its block in arg2; a realloc names the old block in arg2 too.
            forget(arg2)
        }
        guard type & allocate != 0 else { return }
        let size = Int(type & deallocate != 0 ? arg3 : arg2)
        guard size >= minimumBlock, result != 0 else { return }
        scratch.update(repeating: 0, count: depth)
        let count = UnsafeMutableRawPointer(scratch).withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: depth) {
            Int(backtrace($0, Int32(depth)))
        }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for index in 0 ..< count {
            hash = (hash ^ UInt64(scratch[index])) &* 1_099_511_628_211
        }
        guard let site = siteIndex(hash: hash) else {
            header.pointee.overflow = true
            return
        }
        sites[site].allocatedBytes += size
        sites[site].allocations += 1
        sites[site].largest = max(sites[site].largest, size)
        remember(Live(address: result, size: size, site: site))
    }

    /// The site of the stack in `scratch`, made when it is new.
    private static func siteIndex(hash: UInt64) -> Int? {
        let key = hash == 0 ? 1 : hash
        var index = Int(truncatingIfNeeded: key) & (siteCapacity - 1)
        for _ in 0 ..< siteCapacity {
            if sites[index].hash == key {
                return index
            }
            if sites[index].hash == 0 {
                sites[index] = Site(hash: key, allocatedBytes: 0, allocations: 0, freedBytes: 0, largest: 0)
                (frames + index * depth).update(from: scratch, count: depth)
                return index
            }
            index = (index + 1) & (siteCapacity - 1)
        }
        return nil
    }

    private static func slot(of address: UInt) -> Int {
        Int(truncatingIfNeeded: (UInt64(address) >> 4) &* 0x9E37_79B9_7F4A_7C15 >> 43) & (liveCapacity - 1)
    }

    private static func remember(_ entry: Live) {
        var index = slot(of: entry.address)
        for _ in 0 ..< liveCapacity {
            if live[index].address == 0 || live[index].address == entry.address {
                live[index] = entry
                return
            }
            index = (index + 1) & (liveCapacity - 1)
        }
        header.pointee.overflow = true
    }

    /// Linear probing with backward-shift deletion: no tombstones, so a long stretch of
    /// allocations and frees never fills the table with dead slots.
    private static func forget(_ address: UInt) {
        guard address != 0 else { return }
        var index = slot(of: address)
        while live[index].address != 0 {
            if live[index].address == address {
                sites[live[index].site].freedBytes += live[index].size
                var hole = index
                var next = (index + 1) & (liveCapacity - 1)
                while live[next].address != 0 {
                    let home = slot(of: live[next].address)
                    // The entry at `next` may move into the hole when its home is not in (hole, next].
                    let between = hole <= next ? (home > hole && home <= next) : (home > hole || home <= next)
                    if !between {
                        live[hole] = live[next]
                        hole = next
                    }
                    next = (next + 1) & (liveCapacity - 1)
                }
                live[hole] = Live(address: 0, size: 0, site: 0)
                return
            }
            index = (index + 1) & (liveCapacity - 1)
        }
    }

    private static func collect() -> [Report] {
        var reports: [Report] = []
        for index in 0 ..< siteCapacity where sites[index].hash != 0 {
            let site = sites[index]
            // The probe's own frames and the allocator's say nothing about the site.
            let names = UnsafeBufferPointer(start: frames + index * depth, count: depth).filter { $0 != 0 }.map(symbol(at:))
                .filter { !$0.contains("MallocSiteProbe") && !$0.hasPrefix("libsystem_malloc") && !$0.contains("withMemoryRebound") }
            reports.append(Report(
                frames: names, allocatedBytes: site.allocatedBytes, allocations: site.allocations,
                freedBytes: site.freedBytes, largest: site.largest
            ))
        }
        return reports.sorted { $0.freedBytes > $1.freedBytes }
    }

    private static func symbol(at address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return "?" }
        let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "" } ?? "?"
        let name = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image) \(name)"
    }
}
