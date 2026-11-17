import Darwin
import Dispatch
import Foundation
import OSLog
import SQLite3

// Process resource checkpoints guide
//
// The app logs what it holds of the machine's scarce resources at the moments a user feels
// something, so a scorecard read from the log can say which resource was short and who held
// it (ADR 0015). A checkpoint is an EVENT, never a timer (ADR 0033): a launch milestone, a
// scope intent and its paint, a People build, the search index loading, a store stall, a
// tour step, and the system's own memory-pressure report. The peak between events needs no sampler: the kernel
// keeps it (`ri_lifetime_max_phys_footprint`).
//
// Each checkpoint writes, from one serial utility queue so nothing runs on the caller's
// thread and the lines stay in event order:
//
//   op=process.memory    footprint, its lifetime peak, resident size, SQLite's own heap,
//                        the asset identity table's pairs and bytes, and the system's
//                        free, compressed and swapped memory
//   op=process.usage     CPU time, disk bytes read and written, and page-ins since launch:
//                        a page-in is a fault the kernel served from disk, so a wait full
//                        of them is the machine paging the process back in, not Otos's work
//   op=catalog.store.use what the Store's connections were busy with and which kinds of
//                        fact its change notifications carried, since launch (when the
//                        caller can reach the Store)
//   op=catalog.store.reads
//                        the catalog page bytes each role and its heaviest operations read
//                        from the file, since launch: the catalog's share of the disk read.
//                        An original's bytes read whole are on each `op=contentHash` line.
//
// Every value is cumulative or instantaneous as named; a reader takes differences between
// two checkpoints. Reading them costs a few system calls and one lock, microseconds.

/// What the process and the system hold at one instant.
nonisolated struct ProcessResourceSample: Equatable, Sendable {
    /// What the kernel charges the process for (`phys_footprint`): what Activity Monitor shows.
    let footprintBytes: UInt64
    /// The highest footprint since launch, kept by the kernel.
    let peakFootprintBytes: UInt64?
    let residentBytes: UInt64
    /// Memory SQLite has allocated through its own allocator, page caches included.
    let sqliteBytes: Int64?
    let systemFreeBytes: UInt64?
    let systemCompressorBytes: UInt64?
    let swapUsedBytes: UInt64?
    /// User plus system CPU time since launch.
    let cpuMilliseconds: UInt64?
    let diskBytesRead: UInt64?
    let diskBytesWritten: UInt64?
    /// Faults served by reading a page from disk (`ri_pageins`), since launch: memory the
    /// system had pushed out under pressure, or a mapped file read for the first time.
    let pageIns: UInt64?
    /// The asset pairs the process's identity table names and the bytes it holds for them
    /// (`MediaAssetIdentityTable.usage`): it never frees, so a long session's growth shows here.
    let assetIdentities: Int
    let assetIdentityBytes: Int
    /// The most places one rebuild of the table's index moved under its lock: 4,096 or less
    /// while the session names no more pairs than the catalog sized it for (ADR 0005).
    let assetIdentityLargestRebuild: Int

    static func current() -> ProcessResourceSample {
        let task = taskVMInfo()
        let usage = rusage()
        let host = hostVMInfo()
        let identities = MediaAssetIdentityTable.shared.usage
        return ProcessResourceSample(
            footprintBytes: task?.footprint ?? 0,
            peakFootprintBytes: usage?.peakFootprint,
            residentBytes: task?.resident ?? 0,
            sqliteBytes: sqliteMemoryUsed(),
            systemFreeBytes: host?.free,
            systemCompressorBytes: host?.compressor,
            swapUsedBytes: swapUsed(),
            cpuMilliseconds: usage?.cpuMilliseconds,
            diskBytesRead: usage?.diskRead,
            diskBytesWritten: usage?.diskWritten,
            pageIns: usage?.pageIns,
            assetIdentities: identities.pairs,
            assetIdentityBytes: identities.bytes,
            assetIdentityLargestRebuild: identities.largestRebuild
        )
    }

    /// The footprint alone (`phys_footprint`), nil when the kernel does not answer: one
    /// `task_info` call, for a caller that needs no other figure.
    static func currentFootprintBytes() -> UInt64? {
        taskVMInfo()?.footprint
    }

    private static func taskVMInfo() -> (footprint: UInt64, resident: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return (info.phys_footprint, info.resident_size)
    }

    /// What `proc_pid_rusage` reports for a process since its launch.
    struct Usage: Equatable, Sendable {
        let peakFootprint: UInt64
        let cpuMilliseconds: UInt64
        let diskRead: UInt64
        let diskWritten: UInt64
        let pageIns: UInt64
    }

    /// What the kernel reports for `pid` since its launch: a helper process Otos started (the
    /// same user's, so readable), or this process. Nil once the process is gone.
    static func rusage(of pid: pid_t = getpid()) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else {
            return nil
        }
        // `ri_user_time` and `ri_system_time` count Mach absolute time units.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let units = info.ri_user_time &+ info.ri_system_time
        let nanoseconds = timebase.denom == 0 ? units : units &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return Usage(
            peakFootprint: info.ri_lifetime_max_phys_footprint,
            cpuMilliseconds: nanoseconds / 1_000_000,
            diskRead: info.ri_diskio_bytesread,
            diskWritten: info.ri_diskio_byteswritten,
            pageIns: info.ri_pageins
        )
    }

    private static func hostVMInfo() -> (free: UInt64, compressor: UInt64)? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        let page = UInt64(getpagesize())
        return (UInt64(info.free_count) * page, UInt64(info.compressor_page_count) * page)
    }

    private static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return usage.xsu_used
    }

    /// Nil when SQLite was built without memory statistics, which report zero.
    private static func sqliteMemoryUsed() -> Int64? {
        var current: Int64 = 0
        var highwater: Int64 = 0
        guard sqlite3_status64(SQLITE_STATUS_MEMORY_USED, &current, &highwater, 0) == SQLITE_OK, current > 0 else {
            return nil
        }
        return current
    }

    /// The `op=process.memory` fields, in megabytes.
    var memoryFields: [String: String] {
        var fields = [
            "footprintMB": Self.megabytes(footprintBytes),
            "residentMB": Self.megabytes(residentBytes),
        ]
        fields["peakFootprintMB"] = peakFootprintBytes.map(Self.megabytes) ?? "unknown"
        fields["sqliteMB"] = sqliteBytes.map { Self.megabytes(UInt64(max(0, $0))) } ?? "unknown"
        fields["freeMB"] = systemFreeBytes.map(Self.megabytes) ?? "unknown"
        fields["compressorMB"] = systemCompressorBytes.map(Self.megabytes) ?? "unknown"
        fields["swapUsedMB"] = swapUsedBytes.map(Self.megabytes) ?? "unknown"
        fields["assetIdentities"] = "\(assetIdentities)"
        fields["assetIdentityMB"] = Self.megabytes(UInt64(assetIdentityBytes))
        fields["assetIdentityLargestRebuild"] = "\(assetIdentityLargestRebuild)"
        return fields
    }

    /// The `op=process.usage` fields: CPU in milliseconds, disk in megabytes, page-ins as a count.
    var usageFields: [String: String] {
        [
            "cpuMs": cpuMilliseconds.map { "\($0)" } ?? "unknown",
            "diskReadMB": diskBytesRead.map(Self.megabytes) ?? "unknown",
            "diskWrittenMB": diskBytesWritten.map(Self.megabytes) ?? "unknown",
            "pageIns": pageIns.map { "\($0)" } ?? "unknown",
        ]
    }

    static func megabytes(_ bytes: UInt64) -> String {
        "\(bytes / 1_048_576)"
    }
}

/// Writes the checkpoint lines for one event, off the caller's thread.
nonisolated enum ResourceCheckpoint {
    /// One serial queue: lines leave in the order events were recorded, and no caller, the
    /// main thread least of all, waits for a system call.
    private static let queue = DispatchQueue(label: "net.melisma.Otos.resourceCheckpoint", qos: .utility)

    /// `event` names what just happened (`firstGrid`, `paintStart`, `paint`, `memoryPressure`);
    /// `fields` adds what the caller knows about it, on both the memory and the usage line, so
    /// either is matched to its event alone (a paint's `scope`); `storeUse` reads the Store's
    /// cumulative use when the caller can reach it.
    static func record(
        _ event: String,
        fields: [String: String] = [:],
        storeUse: (@Sendable () -> CatalogStoreUse)? = nil
    ) {
        queue.async {
            let sample = ProcessResourceSample.current()
            var memory = sample.memoryFields.merging(fields) { mine, _ in mine }
            memory["event"] = event
            OtosLog.performance.noticeOperation("process.memory", phase: "sample", fields: memory)
            var usage = sample.usageFields.merging(fields) { mine, _ in mine }
            usage["event"] = event
            OtosLog.performance.noticeOperation("process.usage", phase: "sample", fields: usage)
            if let use = storeUse?() {
                var store = use.fields
                store["event"] = event
                OtosLog.performance.noticeOperation("catalog.store.use", phase: "sample", fields: store)
                var reads = use.readFields
                reads["event"] = event
                OtosLog.performance.noticeOperation("catalog.store.reads", phase: "sample", fields: reads)
            }
        }
    }

    /// Returns once every checkpoint recorded before it has written its lines: a process
    /// about to quit calls it so its last checkpoint is not lost.
    static func flush() {
        queue.sync {}
    }
}

/// What the kernel says of the machine's memory now (ADR 0057): its pressure level and the
/// share of memory it counts available.
nonisolated struct KernelMemoryPressure: Equatable, Sendable {
    var level: MachineConditions.Memory
    /// `kern.memorystatus_level`, or nil when unread.
    var availablePercent: Int32?

    /// The kernel's own numbers, for a log line: `systemLevel` 1, 2 or 4, `availablePercent`.
    var logFields: [String: String] {
        [
            "systemLevel": "\(SystemPressure.kernelValue(level))",
            "availablePercent": availablePercent.map { "\($0)" } ?? "unknown",
        ]
    }
}

/// Reads the machine's memory state from the kernel: two `sysctl` reads at the moment a
/// caller needs them, no sampling.
nonisolated enum SystemPressure {
    /// `kern.memorystatus_vm_pressure_level` and `kern.memorystatus_level` now, or nil when the
    /// level cannot be read or is a value the kernel does not define.
    ///
    /// The level is the kernel's current one, the value it converts to the memory-pressure
    /// notes (`NOTE_MEMORYSTATUS_PRESSURE_NORMAL` 1, `_WARN` 2, `_CRITICAL` 4, the same bits as
    /// `DISPATCH_MEMORYPRESSURE_*`); readable by any process on macOS, with no privilege check
    /// (ADR 0057).
    static func kernelMemory() -> KernelMemoryPressure? {
        guard let value = sysctlInt("kern.memorystatus_vm_pressure_level"), let level = memory(kernelValue: value) else {
            return nil
        }
        return KernelMemoryPressure(level: level, availablePercent: sysctlInt("kern.memorystatus_level"))
    }

    /// The kernel's level by the source's names; nil for a value it does not define.
    static func memory(kernelValue: Int32) -> MachineConditions.Memory? {
        switch kernelValue {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }

    static func kernelValue(_ memory: MachineConditions.Memory) -> Int32 {
        switch memory {
        case .normal: 1
        case .warning: 2
        case .critical: 4
        }
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }
}
