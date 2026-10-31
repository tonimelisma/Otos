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

    func rootForDeviceIdentity(_ identity: DeviceIdentity) -> LibraryRoot? {
        statesByPath.values.map(\.root).first { $0.deviceIdentity == identity }
    }

    func rowIDSnapshot() -> [LibraryRootPath: Int64] {
        Dictionary(uniqueKeysWithValues: statesByPath.map { ($0.key, $0.value.rowID) })
    }

    /// Resolves a sidebar selection into the one predicate every scoped catalog read
    /// consumes. This is the sole translation from product scope to SQL scope, so
    /// ordered IDs, counts, and filter options cannot disagree about what a
    /// selection means.
    func scopePredicate(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) -> CatalogScopePredicate {
        switch selection {
        case .allMedia:
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths)
            )
        case .places:
            // The map spans the fixed libraries exactly like All Media; membership is
            // the extra "has a location" dimension (ADR 0040).
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                location: .located
            )
        case let .place(coordinate):
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                location: .at(coordinate)
            )
        case let .library(path):
            guard availableLibraryPaths.contains(path),
                  let rootID = statesByPath[path]?.rowID
            else {
                return .nothing
            }
            return CatalogScopePredicate(rootIDs: [rootID])
        case let .importBatch(batchID):
            // A batch spans the fixed libraries exactly like All Media; membership is
            // the extra `import_batch_unix_ms` dimension, not a narrower root set. A
            // batch names imported copies, so removable sources never belong to one.
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                importBatchUnixMs: batchID.unixMilliseconds
            )
        case .allImports:
            // All Imports is a browsing affordance, not a filter — show all media.
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths)
            )
        }
    }

    private func fixedLibraryRootIDs(in availableLibraryPaths: Set<LibraryRootPath>) -> [Int64] {
        availableLibraryPaths.compactMap { path in
            guard let state = statesByPath[path], state.root.kind == .library else {
                return nil
            }
            return state.rowID
        }.sorted()
    }

    func enrichableRootIDsByRemovablePriority() -> (removable: [Int64], fixed: [Int64]) {
        var removable: [Int64] = []
        var fixed: [Int64] = []
        for state in statesByPath.values where state.isEnrichable {
            if state.root.isRemovableSource {
                removable.append(state.rowID)
            } else {
                fixed.append(state.rowID)
            }
        }
        return (removable.sorted(), fixed.sorted())
    }

    /// Partitions enrichable roots by whether enrichment on them ever produces a
    /// content hash (ADR 0018): every kind except `.removableVolume`, which is read
    /// in place and would otherwise force a full read of the whole volume merely to
    /// checksum it. Orthogonal to `enrichableRootIDsByRemovablePriority`, which
    /// partitions by claim *priority* — `.deviceMTP` is removable-priority but still
    /// hash-required, so the two partitions do not coincide.
    func enrichableRootIDsByHashRequirement() -> (hashRequired: Set<Int64>, hashNotRequired: Set<Int64>) {
        var hashRequired: Set<Int64> = []
        var hashNotRequired: Set<Int64> = []
        for state in statesByPath.values where state.isEnrichable {
            if state.root.isContentHashRequired {
                hashRequired.insert(state.rowID)
            } else {
                hashNotRequired.insert(state.rowID)
            }
        }
        return (hashRequired, hashNotRequired)
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
