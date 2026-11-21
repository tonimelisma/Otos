import Foundation

/// Root registry guide
///
/// Actor-confined bookkeeping for known catalog roots. `CatalogStore` owns one
/// `RootRegistry` and calls it synchronously inside its isolation — this is not a
/// second actor. Maps stay consistent only through `upsert` / `remove`.
///
/// `.scanning` is not stored here; the Store overlays it from the scan leases when
/// building `CatalogLibraryState`.
nonisolated struct RootRegistry {
    private(set) var statesByPath: [LibraryRootPath: RootRuntimeState] = [:]
    private(set) var pathsByRowID: [Int64: LibraryRootPath] = [:]
    /// Moves whenever which paths a fixed library occupies, or their sizes and dates, may
    /// have changed: a library's `namespaceRevision` moved, or a library came or went. What
    /// an account's mirror pairing reads of the libraries (ADR 0054), so a sync pass that
    /// sees it unmoved and brought no listing owes no pairing walk. Never reset, so a
    /// library removed and added again cannot repeat an earlier value.
    private(set) var libraryNamespaceRevision: UInt64 = 0

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
        let previous = statesByPath[state.path]
        if state.root.kind == .library,
           previous?.rowID != state.rowID || previous?.namespaceRevision != state.namespaceRevision
        {
            libraryNamespaceRevision &+= 1
        }
        if let previousPath = pathsByRowID[state.rowID], previousPath != state.path {
            if statesByPath.removeValue(forKey: previousPath)?.root.kind == .library {
                libraryNamespaceRevision &+= 1
            }
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
        if state.root.kind == .library {
            libraryNamespaceRevision &+= 1
        }
        return state
    }

    mutating func removeAll() {
        statesByPath = [:]
        pathsByRowID = [:]
        libraryNamespaceRevision &+= 1
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

    /// Items by root row id and path; an item whose root is gone is no member.
    private func memberKeys(_ members: [MediaAssetID]) -> [CatalogScopePredicate.MemberKey] {
        members.compactMap { id in
            statesByPath[id.libraryRootPath].map {
                CatalogScopePredicate.MemberKey(rootID: $0.rowID, relativePath: id.relativePath.rawValue)
            }
        }
    }

    /// Resolves a sidebar selection into the one predicate every scoped catalog read
    /// consumes. This is the sole translation from product scope to SQL scope, so
    /// ordered IDs and counts cannot disagree about what a selection means.
    func scopePredicate(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>,
        duplicatesReach: DuplicatesReach
    ) -> CatalogScopePredicate {
        var predicate = rowsPredicate(
            selection: selection,
            availableLibraryPaths: availableLibraryPaths,
            duplicatesReach: duplicatesReach
        )
        predicate.showsOneCopy = selection.showsOneCopy
        let scopeRoots = Set(predicate.rootIDs)
        predicate.holdsEveryCopyRoot = statesByPath.values.allSatisfy { state in
            !state.root.kind.isMemberOfAllMedia || scopeRoots.contains(state.rowID)
        }
        return predicate
    }

    /// The rows the selection holds, before one copy is chosen of identical copies.
    private func rowsPredicate(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>,
        duplicatesReach: DuplicatesReach
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
        case let .mapArea(area):
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                location: .within(area)
            )
        case let .mapStack(stack):
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                content: .members(memberKeys(stack.members))
            )
        case let .onThisDay(day):
            // The fixed libraries like All Media; membership is the extra day-bucket
            // dimension (ADR 0049).
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                date: .anniversary(day)
            )
        case .duplicates:
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                content: .duplicated(duplicatesReach)
            )
        case let .duplicateGroup(.identical(digest, library: nil)):
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                content: .identical(digest)
            )
        case let .duplicateGroup(.identical(digest, library: library?)):
            // A group within one library holds only that library's copies of the digest.
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths.intersection([library])),
                content: .identical(digest)
            )
        case let .duplicateGroup(.samePhoto(members)):
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                content: .members(memberKeys(members))
            )
        case .people:
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                content: .withPerson
            )
        case let .person(person):
            return CatalogScopePredicate(
                rootIDs: fixedLibraryRootIDs(in: availableLibraryPaths),
                content: .person(person.rawValue)
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

    /// Row ids of every source in `availableLibraryPaths`, fixed or removable, ascending.
    func rootIDs(in availableLibraryPaths: Set<LibraryRootPath>) -> [Int64] {
        availableLibraryPaths.compactMap { statesByPath[$0]?.rowID }.sorted()
    }

    private func fixedLibraryRootIDs(in availableLibraryPaths: Set<LibraryRootPath>) -> [Int64] {
        availableLibraryPaths.compactMap { path in
            guard let state = statesByPath[path], state.root.kind.isMemberOfAllMedia else {
                return nil
            }
            return state.rowID
        }.sorted()
    }

    /// Row ids of the fixed libraries that are available now — reachable and scanned — whose
    /// digests an import may trust as "already in a library".
    func availableFixedLibraryRowIDs() -> [Int64] {
        statesByPath.values
            .filter { $0.root.kind.isImportDestination && $0.availability == .available }
            .map(\.rowID)
            .sorted()
    }

    /// Enrichable roots whose rows get a rendering-and-digest pass after their metadata
    /// (ADR 0009, ADR 0018).
    func enrichableCardRootIDs() -> [Int64] {
        statesByPath.values.filter { $0.isEnrichable && $0.root.producesAfterMetadata }.map(\.rowID).sorted()
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

    /// Partitions enrichable roots by the claim their rows are first enriched under
    /// (ADR 0018, `LibraryRoot.firstClaim`): a library's every product at once, an Immich
    /// account's metadata and video faces, or metadata first. Orthogonal to `enrichableRootIDsByRemovablePriority`, which partitions by claim
    /// *priority*. A card's later rendering-and-digest pass is `enrichableCardRootIDs`.
    func enrichableRootIDsByFirstClaim() -> (library: Set<Int64>, account: Set<Int64>, metadataFirst: Set<Int64>) {
        var library: Set<Int64> = []
        var account: Set<Int64> = []
        var metadataFirst: Set<Int64> = []
        for state in statesByPath.values where state.isEnrichable {
            switch state.root.firstClaim {
            case .library:
                library.insert(state.rowID)
            case .account:
                account.insert(state.rowID)
            case .metadata, .products:
                metadataFirst.insert(state.rowID)
            }
        }
        return (library, account, metadataFirst)
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
            case .deviceMTP, .immichAccount:
                nil
            }
        }
    }

    func ownsLease(rootPath: LibraryRootPath, rootRowID: Int64) -> Bool {
        statesByPath[rootPath]?.rowID == rootRowID && pathsByRowID[rootRowID] == rootPath
    }
}
