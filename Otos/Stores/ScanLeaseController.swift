import Foundation

/// Scan lease controller guide
///
/// Actor-confined bookkeeping for filesystem-scan and device-enumeration leases,
/// the pending scan queue, and "rescan after current scan" deferrals.
/// `CatalogStore` owns one `ScanLeaseController`, keeps one scan task per lane, and
/// performs all spawn/await/DB work. This type only answers lease ownership and
/// queue mutations synchronously inside Store isolation — not a second actor.
///
/// A filesystem lease belongs to a lane (`ScanLane`). Fixed libraries share one lane:
/// they live on the system disk or behind a file provider, and walking two at once
/// only makes both slower. Each card is a separate device, so it has a lane of its own
/// and is read the moment it attaches, never queued behind a library rescan.
///
/// `ActiveScan` remains nested on `CatalogStore` so the public device-enumeration
/// API surface stays unchanged.
nonisolated struct ScanLeaseController {
    /// Which filesystem walks may run at once: one per lane.
    enum ScanLane: Hashable {
        case fixedLibraries
        case removableSource(LibraryRootPath)

        var diagnosticName: String {
            switch self {
            case .fixedLibraries: "fixedLibraries"
            case .removableSource: "removableSource"
            }
        }
    }

    private(set) var pendingScanPaths: [LibraryRootPath] = []
    private(set) var activeScans: [ScanLane: CatalogStore.ActiveScan] = [:]
    private(set) var activeDeviceScans: [LibraryRootPath: CatalogStore.ActiveScan] = [:]
    private(set) var rescanAfterCurrentScan: Set<LibraryRootPath> = []
    private var nextLeaseGeneration: UInt64 = 0

    enum QueuePriority {
        case normal
        case front
    }

    func hasActiveFilesystemScan(for path: LibraryRootPath) -> Bool {
        activeScans.values.contains { $0.rootPath == path }
    }

    func isLaneBusy(_ lane: ScanLane) -> Bool {
        activeScans[lane] != nil
    }

    func isCurrentFilesystemScan(_ scan: CatalogStore.ActiveScan) -> Bool {
        activeScans.values.contains(scan)
    }

    func isCurrentDeviceScan(_ scan: CatalogStore.ActiveScan) -> Bool {
        activeDeviceScans[scan.rootPath] == scan
    }

    func owns(
        _ scan: CatalogStore.ActiveScan,
        rootRowIDMatches: (LibraryRootPath, Int64) -> Bool
    ) -> Bool {
        let isCurrentFilesystem = isCurrentFilesystemScan(scan)
        let isCurrentDevice = isCurrentDeviceScan(scan)
        return (isCurrentFilesystem || isCurrentDevice)
            && rootRowIDMatches(scan.rootPath, scan.rootRowID)
    }

    mutating func makeActiveScan(
        rootPath: LibraryRootPath,
        rootRowID: Int64,
        startNamespaceMutationEpoch: UInt64 = 0
    ) -> CatalogStore.ActiveScan {
        nextLeaseGeneration &+= 1
        return CatalogStore.ActiveScan(
            rootPath: rootPath,
            rootRowID: rootRowID,
            leaseGeneration: nextLeaseGeneration,
            startNamespaceMutationEpoch: startNamespaceMutationEpoch
        )
    }

    /// Enqueues paths that still exist in `knownRoots`. Skips paths already
    /// active or already pending. Does not start work — the Store calls
    /// `startNextScanIfNeeded` after this returns.
    mutating func enqueue(
        _ paths: [LibraryRootPath],
        priority: QueuePriority = .normal,
        knownRoots: (LibraryRootPath) -> Bool
    ) {
        for path in paths where knownRoots(path) {
            if hasActiveFilesystemScan(for: path) || pendingScanPaths.contains(path) {
                continue
            }
            switch priority {
            case .normal:
                pendingScanPaths.append(path)
            case .front:
                pendingScanPaths.insert(path, at: 0)
            }
        }
    }

    mutating func removePending(_ path: LibraryRootPath) {
        pendingScanPaths.removeAll { $0 == path }
    }

    mutating func removeRescanDeferral(_ path: LibraryRootPath) {
        rescanAfterCurrentScan.remove(path)
    }

    mutating func markRescanAfterCurrentScan(_ path: LibraryRootPath) {
        rescanAfterCurrentScan.insert(path)
    }

    @discardableResult
    mutating func takeRescanAfterCurrentScan(_ path: LibraryRootPath) -> Bool {
        rescanAfterCurrentScan.remove(path) != nil
    }

    mutating func beginFilesystemScan(_ scan: CatalogStore.ActiveScan, lane: ScanLane) {
        activeScans[lane] = scan
    }

    /// Clears the filesystem lease when `scan` is still current. Returns the lane it
    /// held, and whether a deferred rescan was pending for that root; `nil` when the
    /// scan no longer holds a lease.
    @discardableResult
    mutating func clearFilesystemScan(_ scan: CatalogStore.ActiveScan) -> (lane: ScanLane, needsRescan: Bool)? {
        guard let lane = activeScans.first(where: { $0.value == scan })?.key else {
            return nil
        }
        activeScans.removeValue(forKey: lane)
        return (lane, takeRescanAfterCurrentScan(scan.rootPath))
    }

    mutating func beginDeviceScan(_ scan: CatalogStore.ActiveScan) {
        activeDeviceScans[scan.rootPath] = scan
    }

    mutating func endDeviceScan(_ scan: CatalogStore.ActiveScan) {
        guard activeDeviceScans[scan.rootPath] == scan else {
            return
        }
        activeDeviceScans.removeValue(forKey: scan.rootPath)
    }

    mutating func removeDeviceScan(for path: LibraryRootPath) {
        activeDeviceScans.removeValue(forKey: path)
    }

    /// Cancels lease bookkeeping for a removed root. Returns the lane whose filesystem
    /// scan was reading this path, if one was (Store must cancel that lane's task).
    @discardableResult
    mutating func cancelWork(for path: LibraryRootPath) -> ScanLane? {
        removeRescanDeferral(path)
        removePending(path)
        removeDeviceScan(for: path)
        guard let lane = activeScans.first(where: { $0.value.rootPath == path })?.key else {
            return nil
        }
        activeScans.removeValue(forKey: lane)
        return lane
    }

    mutating func resetAll() {
        activeScans.removeAll()
        activeDeviceScans.removeAll()
        pendingScanPaths.removeAll()
        rescanAfterCurrentScan.removeAll()
    }

    /// Takes the first pending path `canStart` admits — one whose lane is free — and
    /// leaves the rest queued in order. Store performs availability and row-ID checks
    /// before starting work.
    mutating func takeFirstPending(where canStart: (LibraryRootPath) -> Bool) -> LibraryRootPath? {
        guard let index = pendingScanPaths.firstIndex(where: canStart) else {
            return nil
        }
        return pendingScanPaths.remove(at: index)
    }
}
