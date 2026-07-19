import Foundation

/// Scan lease controller guide
///
/// Actor-confined bookkeeping for filesystem-scan and device-enumeration leases,
/// the pending scan queue, and "rescan after current scan" deferrals.
/// `CatalogStore` owns one `ScanLeaseController`, keeps `currentScanTask`, and
/// performs all spawn/await/DB work. This type only answers lease ownership and
/// queue mutations synchronously inside Store isolation — not a second actor.
///
/// `ActiveScan` remains nested on `CatalogStore` so the public device-enumeration
/// API surface stays unchanged.
nonisolated struct ScanLeaseController {
    private(set) var pendingScanPaths: [LibraryRootPath] = []
    private(set) var activeScan: CatalogStore.ActiveScan?
    private(set) var activeDeviceScans: [LibraryRootPath: CatalogStore.ActiveScan] = [:]
    private(set) var rescanAfterCurrentScan: Set<LibraryRootPath> = []
    private var nextLeaseGeneration: UInt64 = 0

    enum QueuePriority {
        case normal
        case front
    }

    func hasActiveFilesystemScan(for path: LibraryRootPath) -> Bool {
        activeScan?.rootPath == path
    }

    func isCurrentFilesystemScan(_ scan: CatalogStore.ActiveScan) -> Bool {
        activeScan == scan
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
            if activeScan?.rootPath == path || pendingScanPaths.contains(path) {
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

    mutating func beginFilesystemScan(_ scan: CatalogStore.ActiveScan) {
        activeScan = scan
    }

    /// Clears the filesystem lease when `scan` is still current. Returns whether
    /// a deferred rescan was pending for that root.
    @discardableResult
    mutating func clearFilesystemScan(_ scan: CatalogStore.ActiveScan) -> Bool {
        guard activeScan == scan else {
            return false
        }
        let rootPath = scan.rootPath
        activeScan = nil
        return takeRescanAfterCurrentScan(rootPath)
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

    /// Cancels lease bookkeeping for a removed root. Returns whether the
    /// filesystem scan for this path was active (Store must cancel the task).
    @discardableResult
    mutating func cancelWork(for path: LibraryRootPath) -> Bool {
        removeRescanDeferral(path)
        removePending(path)
        removeDeviceScan(for: path)
        if activeScan?.rootPath == path {
            activeScan = nil
            return true
        }
        return false
    }

    mutating func resetAll() {
        activeScan = nil
        activeDeviceScans.removeAll()
        pendingScanPaths.removeAll()
        rescanAfterCurrentScan.removeAll()
    }

    /// Pops the next pending path without validating the root. Store performs
    /// availability and row-ID checks before starting work.
    mutating func popPending() -> LibraryRootPath? {
        guard !pendingScanPaths.isEmpty else {
            return nil
        }
        return pendingScanPaths.removeFirst()
    }
}
