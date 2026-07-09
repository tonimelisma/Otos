import Foundation

/// Root registry guide
///
/// Actor-confined bookkeeping for known catalog roots. `CatalogStore` owns one
/// `RootRegistry` and calls it synchronously inside its isolation — this is not a
/// second actor. Maps stay consistent only through `upsert` / `remove`.
///
/// `.scanning` is not stored here; the Store overlays it from `activeScan` when
/// building `CatalogLibraryState`.
nonisolated struct RootRegistry {
    private(set) var statesByPath: [LibraryRootPath: RootRuntimeState] = [:]
    private(set) var pathsByRowID: [Int64: LibraryRootPath] = [:]

    var keys: Dictionary<LibraryRootPath, RootRuntimeState>.Keys {
        statesByPath.keys
    }

    var values: Dictionary<LibraryRootPath, RootRuntimeState>.Values {
        statesByPath.values
    }

    var isEmpty: Bool {
        statesByPath.isEmpty
    }

    subscript(path: LibraryRootPath) -> RootRuntimeState? {
        statesByPath[path]
    }

    func path(forRowID rowID: Int64) -> LibraryRootPath? {
        pathsByRowID[rowID]
    }

    mutating func upsert(_ state: RootRuntimeState) {
        if let previousPath = pathsByRowID[state.rowID], previousPath != state.path {
            statesByPath.removeValue(forKey: previousPath)
        }
        if let existing = statesByPath[state.path], existing.rowID != state.rowID {
            pathsByRowID.removeValue(forKey: existing.rowID)
        }
        statesByPath[state.path] = state
        pathsByRowID[state.rowID] = state.path
    }

    /// Removes the path-keyed record and its row-ID index entry. Does not touch
    /// Store orchestration state (device scans, watchers, tasks).
    @discardableResult
    mutating func remove(path: LibraryRootPath) -> RootRuntimeState? {
        guard let state = statesByPath.removeValue(forKey: path) else {
            return nil
        }
        if pathsByRowID[state.rowID] == path {
            pathsByRowID.removeValue(forKey: state.rowID)
        }
        return state
    }

    mutating func removeAll() {
        statesByPath = [:]
        pathsByRowID = [:]
    }

    @discardableResult
    mutating func setAvailability(_ availability: LibraryAvailability, for path: LibraryRootPath) -> Bool {
        guard var state = statesByPath[path],
              state.availability != availability
        else {
            return false
        }
        state.availability = availability
        upsert(state)
        return true
    }

    func rootForDeviceIdentity(_ identity: String) -> LibraryRoot? {
        statesByPath.values.map(\.root).first { $0.deviceIdentity == identity }
    }

    func rowIDSnapshot() -> [LibraryRootPath: Int64] {
        Dictionary(uniqueKeysWithValues: statesByPath.map { ($0.key, $0.value.rowID) })
    }

    func rootIDsForQuery(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) -> [Int64] {
        switch selection {
        case .allMedia:
            return availableLibraryPaths.compactMap { path in
                guard statesByPath[path]?.root.kind == .library else {
                    return nil
                }
                return statesByPath[path]?.rowID
            }.sorted()
        case let .library(path):
            guard availableLibraryPaths.contains(path),
                  let rootID = statesByPath[path]?.rowID
            else {
                return []
            }
            return [rootID]
        }
    }

    func availableRootIDsByRemovablePriority() -> (removable: [Int64], fixed: [Int64]) {
        var removable: [Int64] = []
        var fixed: [Int64] = []
        for state in statesByPath.values where state.availability == .available {
            if state.root.kind == .library {
                fixed.append(state.rowID)
            } else {
                removable.append(state.rowID)
            }
        }
        return (removable.sorted(), fixed.sorted())
    }

    func validateNoOverlap(_ path: LibraryRootPath, ignoring existingRootRowID: Int64? = nil) throws {
        for state in statesByPath.values {
            if let existingRootRowID, state.rowID == existingRootRowID {
                continue
            }
            if let relationship = CatalogPath.relationship(candidate: path, existing: state.path) {
                throw CatalogStoreError.overlappingRoot(existingPath: state.path, relationship: relationship)
            }
        }
    }

    var watchedRootPaths: [LibraryRootPath] {
        statesByPath.values.compactMap { state in
            switch state.root.kind {
            case .library:
                state.path
            case .removableVolume:
                state.availability == .available ? state.path : nil
            case .deviceMTP:
                nil
            }
        }
    }

    func ownsLease(rootPath: LibraryRootPath, rootRowID: Int64) -> Bool {
        statesByPath[rootPath]?.rowID == rootRowID && pathsByRowID[rootRowID] == rootPath
    }
}
