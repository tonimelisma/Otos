import Foundation

/// Catalog window policy guide
///
/// These helpers are pure rules for turning Store query results into window
/// meaning. They do not subscribe to Store changes, touch SQLite, spawn tasks, or
/// publish UI state; `CatalogProjection` calls them from its actor-owned
/// publication loop.
nonisolated enum CatalogWindowPolicy {
    /// Library-kind roots preserve the caller's incoming order — `sort_index`
    /// order from `CatalogStore.currentLibraries()`, user-owned via Settings →
    /// Libraries. Removable sources have no user-facing
    /// order to preserve, so they keep the previous display-name rule.
    static func sortLibraries(_ libraries: [CatalogLibraryState]) -> [CatalogLibraryState] {
        let fixed = libraries.filter(\.kind.isInLibrariesSection)
        let removable = libraries.filter { !$0.kind.isInLibrariesSection }.sorted { left, right in
            let displayComparison = left.displayName.localizedStandardCompare(right.displayName)
            if displayComparison == .orderedSame {
                return left.path.rawValue.localizedStandardCompare(right.path.rawValue) == .orderedAscending
            }
            return displayComparison == .orderedAscending
        }
        return fixed + removable
    }

    static func sourceRows(
        from roots: [CatalogLibraryState]
    ) -> (libraries: [CatalogLibraryState], removableSources: [CatalogLibraryState]) {
        (
            libraries: roots.filter(\.kind.isInLibrariesSection),
            removableSources: roots.filter { !$0.kind.isInLibrariesSection }
        )
    }

    static func availablePaths(from roots: [CatalogLibraryState]) -> Set<LibraryRootPath> {
        Set(roots.filter(\.isAvailable).map(\.path))
    }

    static func rootsByPath(from roots: [CatalogLibraryState]) -> [LibraryRootPath: CatalogLibraryState] {
        Dictionary(uniqueKeysWithValues: roots.map { ($0.path, $0) })
    }

    static func resolvedSidebarSelection(
        _ sidebarSelection: SidebarSelection,
        libraries: [CatalogLibraryState],
        removableSources: [CatalogLibraryState],
        importBatches: [ImportBatchSummary] = []
    ) -> SidebarSelection {
        switch sidebarSelection {
        case .allMedia:
            if SidebarSelectionPolicy.showsAllMedia(libraries: libraries) {
                return .allMedia
            } else {
                return SidebarSelectionPolicy.defaultSelection(
                    libraries: libraries,
                    removableSources: removableSources
                )
            }
        case .places, .mapArea, .onThisDay, .duplicates, .duplicateGroup, .people, .peopleReview, .person, .reviewPhotos:
            // Places, On This Day, Duplicates and People exist with the fixed libraries they
            // span; a leaf under any of them goes with it. Each resolves to the default once the last fixed
            // library is removed.
            if SidebarSelectionPolicy.showsPlaces(libraries: libraries) {
                return sidebarSelection
            }
            return SidebarSelectionPolicy.selectionOnSelectedSourceRemoved(
                libraries: libraries,
                removableSources: removableSources
            )
        case let .library(path):
            let pathIsValid = libraries.contains { $0.path == path }
                || removableSources.contains { $0.path == path }
            if pathIsValid {
                return sidebarSelection
            } else {
                return SidebarSelectionPolicy.selectionOnSelectedSourceRemoved(
                    libraries: libraries,
                    removableSources: removableSources
                )
            }
        case let .importBatch(batchID):
            if importBatches.contains(where: { $0.batchID == batchID }) {
                return sidebarSelection
            }
            return SidebarSelectionPolicy.selectionOnSelectedSourceRemoved(
                libraries: libraries,
                removableSources: removableSources
            )
        case .allImports:
            if importBatches.isEmpty {
                return SidebarSelectionPolicy.defaultSelection(
                    libraries: libraries,
                    removableSources: removableSources
                )
            }
            return .allImports
        }
    }

    static func resolvedDescriptor(
        _ descriptor: CatalogQueryDescriptor,
        libraries: [CatalogLibraryState],
        removableSources: [CatalogLibraryState],
        importBatches: [ImportBatchSummary] = []
    ) -> CatalogQueryDescriptor {
        CatalogQueryDescriptor(
            scope: resolvedSidebarSelection(
                descriptor.scope,
                libraries: libraries,
                removableSources: removableSources,
                importBatches: importBatches
            ),
            filter: descriptor.filter,
            sort: descriptor.sort,
            search: descriptor.search
        )
    }

    /// The scope narrowed to what a search matched (ADR 0048), with its index-paired
    /// companions. Ordered by `order`: best match first (ties keep the scope's order, and
    /// the grid is one ungrouped section, so `dayBuckets` comes back empty), or the scope's
    /// own order.
    static func searched(
        ids: [MediaAssetID],
        dayBuckets: [Date?],
        coordinates: [PlaceCoordinate],
        scores: [MediaAssetID: Float]?,
        allowed: Set<MediaAssetID>? = nil,
        order: CatalogSearch.Order
    ) -> (ids: [MediaAssetID], dayBuckets: [Date?], coordinates: [PlaceCoordinate]) {
        var kept = ids.indices.filter { index in
            (scores.map { $0[ids[index]] != nil } ?? true) && (allowed.map { $0.contains(ids[index]) } ?? true)
        }
        // Relevance needs a picture to be relevant to: a query of facts only keeps the scope's
        // order and its day sections.
        let byRelevance = order == .relevance && scores != nil
        if byRelevance, let scores {
            kept.sort { left, right in
                let a = scores[ids[left]]!, b = scores[ids[right]]!
                return a != b ? a > b : left < right
            }
        }
        return (
            kept.map { ids[$0] },
            byRelevance || dayBuckets.isEmpty ? [] : kept.map { dayBuckets[$0] },
            coordinates.isEmpty ? [] : kept.map { coordinates[$0] }
        )
    }

    /// `dayBuckets` is the grid's day-grouping key (DES-069) — empty under any
    /// sort but `.bestDate` (see `CatalogMediaGridState.dayBuckets`), otherwise
    /// paired index-for-index with `orderedAssetIDs`; `coordinates` is the map's key,
    /// empty unless the scope requires a location (ADR 0040), otherwise paired the
    /// same way. Both are filtered in the same pass as the IDs so none can desync; an
    /// empty companion in means an empty companion out, regardless of how many IDs
    /// survive the filter.
    static func assetIDs(
        for sidebarSelection: SidebarSelection,
        orderedAssetIDs: [MediaAssetID],
        dayBuckets: [Date?],
        coordinates: [PlaceCoordinate] = [],
        availableLibraryPaths: Set<LibraryRootPath>,
        rootsByPath: [LibraryRootPath: CatalogLibraryState]
    ) -> (ids: [MediaAssetID], dayBuckets: [Date?], coordinates: [PlaceCoordinate]) {
        func keeps(_ id: MediaAssetID) -> Bool {
            guard availableLibraryPaths.contains(id.libraryRootPath) else {
                return false
            }
            switch sidebarSelection {
            case .allMedia, .places, .mapArea, .onThisDay, .importBatch, .allImports, .duplicates, .duplicateGroup,
                 .people, .peopleReview, .person, .reviewPhotos:
                // These scopes span the fixed libraries. Batch and location *membership*
                // are applied by Store.orderedAssetIDs; this pass only re-applies the
                // root-kind rule, which also holds for IDs carried over from a reused
                // order (ADR 0007).
                return rootsByPath[id.libraryRootPath]?.kind.isMemberOfAllMedia == true
            case let .library(path):
                return id.libraryRootPath == path
            }
        }
        let pairsBuckets = dayBuckets.count == orderedAssetIDs.count
        let pairsCoordinates = coordinates.count == orderedAssetIDs.count
        var filteredIDs: [MediaAssetID] = []
        var filteredBuckets: [Date?] = []
        var filteredCoordinates: [PlaceCoordinate] = []
        filteredIDs.reserveCapacity(orderedAssetIDs.count)
        if pairsBuckets {
            filteredBuckets.reserveCapacity(orderedAssetIDs.count)
        }
        if pairsCoordinates {
            filteredCoordinates.reserveCapacity(orderedAssetIDs.count)
        }
        for (index, id) in orderedAssetIDs.enumerated() where keeps(id) {
            filteredIDs.append(id)
            if pairsBuckets {
                filteredBuckets.append(dayBuckets[index])
            }
            if pairsCoordinates {
                filteredCoordinates.append(coordinates[index])
            }
        }
        return (filteredIDs, filteredBuckets, filteredCoordinates)
    }

    /// The Places map's content for a resolved `.places` scope: the scoped IDs paired
    /// with their coordinates, and how many items the same libraries and filter hold
    /// without a location. Nil for every other scope.
    static func mapState(
        for descriptor: CatalogQueryDescriptor,
        scopedAssetIDs: [MediaAssetID],
        scopedCoordinates: [PlaceCoordinate],
        filteredFixedAssetCount: Int
    ) -> CatalogMapState? {
        guard descriptor.scope == .places, scopedCoordinates.count == scopedAssetIDs.count else {
            return nil
        }
        return CatalogMapState(
            located: zip(scopedAssetIDs, scopedCoordinates).map { LocatedAsset(id: $0, coordinate: $1) },
            unlocatedCount: max(0, filteredFixedAssetCount - scopedAssetIDs.count)
        )
    }

    /// On This Day's years for a resolved `.onThisDay` scope, from the scoped IDs and
    /// their day buckets. Nil for every other scope, and when the buckets do not pair.
    static func onThisDayState(
        for descriptor: CatalogQueryDescriptor,
        scopedAssetIDs: [MediaAssetID],
        scopedDayBuckets: [Date?]
    ) -> CatalogOnThisDayState? {
        guard case let .onThisDay(day) = descriptor.scope,
              let years = OnThisDayYearPolicy.years(
                  day: day,
                  orderedIDs: scopedAssetIDs,
                  dayBuckets: scopedDayBuckets
              )
        else {
            return nil
        }
        return CatalogOnThisDayState(day: day, years: years)
    }

    static func title(for sidebarSelection: SidebarSelection, libraries: [CatalogLibraryState]) -> String {
        switch sidebarSelection {
        case .allMedia:
            "All Media"
        case .onThisDay:
            "On This Day"
        case .places, .mapArea:
            "Places"
        case .duplicates, .duplicateGroup:
            "Duplicates"
        case .people, .peopleReview, .person, .reviewPhotos:
            // A person's scope is titled with their name, which People knows
            // (`CatalogWindowViewModel.windowTitle`).
            "People"
        case let .library(path):
            libraries.first { $0.path == path }?.displayName ?? "Library"
        case let .importBatch(batchID):
            ImportBatchFormatting.sidebarTitle(for: batchID)
        case .allImports:
            "All Imports"
        }
    }

    static func mediaEmptyState(
        for descriptor: CatalogQueryDescriptor,
        libraries: [CatalogLibraryState],
        allAssetCount: Int,
        unfilteredVisibleAssetCount: Int,
        selectedAssetCount: Int,
        search: CatalogSearchOutcome? = nil
    ) -> CatalogMediaEmptyState {
        guard selectedAssetCount == 0 else { return .noMedia }
        if let search, let text = descriptor.search?.text, search.unsearchedScopeCount > 0 {
            return .noSearchResults(text, stillReading: search.stillReadingCount)
        }
        if descriptor.filter.isActive, unfilteredVisibleAssetCount > 0 {
            return .noFilterMatches
        }
        let sidebarSelection = descriptor.scope
        switch sidebarSelection {
        case .person:
            // A person whose every confirmed face was taken away (`docs/design/people.md`);
            // a person is never removed implicitly.
            let fixedLibraries = libraries.filter(\.kind.isMemberOfAllMedia)
            if fixedLibraries.contains(where: { $0.availability == .unknown }) {
                return .checkingLibraries
            }
            return .noPersonPhotos(nil)
        case .allMedia, .importBatch, .allImports, .duplicates, .duplicateGroup, .people, .peopleReview, .reviewPhotos:
            // These span the fixed libraries, so they answer emptiness the same way: a
            // batch whose rows exist but whose libraries are offline is unreachable,
            // not absent.
            let fixedLibraries = libraries.filter(\.kind.isMemberOfAllMedia)
            if fixedLibraries.contains(where: { $0.availability == .unknown }) {
                return .checkingLibraries
            }
            return allAssetCount == 0 ? .noMedia : .noAvailableMedia
        case .places, .mapArea:
            // The map spans the fixed libraries too. An empty map with reachable
            // libraries means no item carries a location — enrichment may still be
            // finding them — never that there is no media.
            let fixedLibraries = libraries.filter(\.kind.isMemberOfAllMedia)
            if fixedLibraries.contains(where: { $0.availability == .unknown }) {
                return .checkingLibraries
            }
            if allAssetCount > 0, !fixedLibraries.contains(where: \.isAvailable) {
                return .noAvailableMedia
            }
            return .noLocatedMedia
        case let .onThisDay(day):
            // The fixed libraries again: reachable libraries with nothing on this day mean
            // no earlier year holds a match, never that there is no media.
            let fixedLibraries = libraries.filter(\.kind.isMemberOfAllMedia)
            if fixedLibraries.contains(where: { $0.availability == .unknown }) {
                return .checkingLibraries
            }
            if allAssetCount > 0, !fixedLibraries.contains(where: \.isAvailable) {
                return .noAvailableMedia
            }
            return .nothingOnThisDay(day)
        case let .library(path):
            let library = libraries.first { $0.path == path }
            switch library?.kind {
            case .deviceMTP where library?.isEnumerating == true:
                return .deviceEnumerating(library?.displayName ?? "this camera")
            case .removableVolume where library?.isScanning == true:
                return .cardReading(library?.displayName ?? "this card")
            case .library, .removableVolume, .deviceMTP, .immichAccount, nil:
                break
            }
            switch library?.availability {
            case .unknown:
                return .libraryChecking
            case .unavailable:
                return .libraryUnavailable
            case .available, .none:
                return .noMedia
            }
        }
    }

    static func catalogWindowState(
        _ parts: CatalogProjectionWindowStateParts,
        detailRefreshGeneration: UInt64
    ) -> CatalogWindowState {
        CatalogWindowState(
            title: parts.title,
            libraries: parts.libraries,
            removableSources: parts.removableSources,
            importBatches: parts.importBatches,
            mediaGrid: CatalogMediaGridState(
                descriptor: parts.resolvedDescriptor,
                orderedAssetIDs: parts.scopedAssetIDs,
                dayBuckets: parts.scopedDayBuckets,
                detailRefreshGeneration: detailRefreshGeneration
            ),
            filterOptions: parts.filterOptions,
            resolvedSidebarSelection: parts.resolvedDescriptor.scope,
            mediaEmptyState: parts.mediaEmptyState,
            deviceConnectionBanner: deviceConnectionBanner(
                for: parts.resolvedDescriptor.scope,
                roots: parts.removableSources
            ),
            map: parts.map,
            onThisDay: parts.onThisDay,
            queryGeneration: parts.queryGeneration
        )
    }

    private static func deviceConnectionBanner(
        for selection: SidebarSelection,
        roots: [CatalogLibraryState]
    ) -> CatalogDeviceConnectionBanner? {
        guard case let .library(path) = selection,
              let root = roots.first(where: { $0.path == path }),
              let identity = root.deviceIdentity
        else {
            return nil
        }
        // The advice is about a camera's USB transfer mode, so only a camera shows it.
        switch root.kind {
        case .deviceMTP:
            break
        case .library, .removableVolume, .immichAccount:
            return nil
        }
        return CatalogDeviceConnectionBanner(
            identity: identity,
            message: """
            Browsing is faster when this camera's memory card is inserted directly, \
            or when the camera's USB setting is Mass Storage.
            """
        )
    }
}
