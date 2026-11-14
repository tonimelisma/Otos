import Foundation

/// Small value carriers used while `CatalogProjection` builds a window state.
///
/// These are kept outside the actor file so the actor's source stays focused on
/// publication ownership rather than local tuple plumbing.
nonisolated struct CatalogProjectionWindowStateParts {
    let title: String
    let libraries: [CatalogLibraryState]
    let removableSources: [CatalogLibraryState]
    let importBatches: [ImportBatchSummary]
    let resolvedDescriptor: CatalogQueryDescriptor
    let queryGeneration: UInt64
    let scopedAssetIDs: [MediaAssetID]
    /// DES-069 day-grouping key, index-paired with `scopedAssetIDs`; empty
    /// under any sort but `.bestDate`. See `CatalogMediaGridState.dayBuckets`.
    let scopedDayBuckets: [Date?]
    let filterOptions: CatalogFilterOptions
    let mediaEmptyState: CatalogMediaEmptyState
    /// The Places map's content; nil for every other scope (ADR 0040).
    let map: CatalogMapState?
    /// On This Day's years; nil for every other scope (ADR 0049).
    let onThisDay: CatalogOnThisDayState?
    /// How the scoped order shows its stacks (ADR 0052).
    var gridStacks: CatalogGridStacks = .empty
}

/// How many times the Store has said each kind of fact changed (`CatalogChangedFacts`),
/// counted by the projection as each change arrives. A read records the counts it started
/// from, and a later pass repeats it only when a count it depends on has moved since: a
/// revision per kind, never a flag a finished read clears (ADR 0032).
nonisolated struct CatalogFactRevisions: Equatable, Sendable {
    private var counts = [UInt64](repeating: 0, count: CatalogChangedFacts.bitCount)

    mutating func record(_ facts: CatalogChangedFacts) {
        for bit in 0 ..< CatalogChangedFacts.bitCount where facts.rawValue & (1 << bit) != 0 {
            counts[bit] &+= 1
        }
    }

    /// Whether any kind in `facts` changed between `earlier` and these counts.
    func moved(_ facts: CatalogChangedFacts, since earlier: CatalogFactRevisions) -> Bool {
        (0 ..< CatalogChangedFacts.bitCount).contains { bit in
            facts.rawValue & (1 << bit) != 0 && counts[bit] != earlier.counts[bit]
        }
    }
}

nonisolated extension CatalogChangedFacts {
    /// What the ordered-asset read for `descriptor` depends on: which rows are shown, their
    /// dates, kinds and formats, how they group and the user's choices, always; their places where the scope or
    /// the filter is by place; faces where it is by person or by likeness; copies in the
    /// Duplicates rows; and On This Day's labels there. Search is applied after the read,
    /// from the index's own answer, so it is not among them.
    static func orderInputs(of descriptor: CatalogQueryDescriptor) -> CatalogChangedFacts {
        var facts: CatalogChangedFacts = [.membership, .captureDate, .kindAndFormat, .grouping, .choices]
        facts.formUnion(scopeInputs(of: descriptor.scope))
        if descriptor.filter.places != nil {
            facts.formUnion([.location, .placeNames])
        }
        if descriptor.filter.filtersPeople || descriptor.effectiveSort.field == .likeness {
            facts.insert(.faces)
        }
        return facts
    }

    /// What the filter's options for the sidebar row `row` depend on: which rows the row
    /// shows, their kinds and formats, and the places named for them.
    static func filterOptionsInputs(of row: SidebarSelection) -> CatalogChangedFacts {
        var facts: CatalogChangedFacts = [.membership, .kindAndFormat, .grouping, .location, .placeNames]
        facts.formUnion(scopeInputs(of: row))
        return facts
    }

    /// What decides which rows a scope holds, beyond the rows themselves.
    private static func scopeInputs(of scope: SidebarSelection) -> CatalogChangedFacts {
        switch scope {
        case .allMedia, .library, .importBatch, .allImports:
            []
        case .places, .mapArea, .mapStack:
            [.location, .placeNames]
        case .onThisDay:
            [.captureDate, .grouping, .choices, .searchReadings]
        case .duplicates, .duplicateGroup:
            .copies
        case .people, .person:
            .faces
        }
    }
}

/// The last answer of each of the window's catalog reads, with what it was read for and the
/// fact revisions it started from (ADR 0005). A pass reuses an answer while its inputs are
/// what they were and no kind of fact it depends on has changed, and reads it again
/// otherwise; nothing else decides it. A pass takes these as a value and returns the ones it
/// built with its state, which the projection keeps only once that state is published.
nonisolated struct CatalogProjectionReads: Sendable {
    struct Order: Sendable {
        let descriptor: CatalogQueryDescriptor
        let availableLibraryPaths: Set<LibraryRootPath>
        let revisions: CatalogFactRevisions
        let answer: CatalogOrderedAssets
    }

    struct FilterOptions: Sendable {
        let row: SidebarSelection
        let availableLibraryPaths: Set<LibraryRootPath>
        let placeNameLanguages: Set<PlaceNameLanguage>
        let revisions: CatalogFactRevisions
        let answer: CatalogFilterOptions
    }

    /// The last stack collapse (ADR 0052), a pure step over the scoped order: the same
    /// order, stacks and expansions collapse the same way.
    struct Collapse: Sendable {
        let ids: [MediaAssetID]
        let dayBuckets: [Date?]
        let coordinates: [PlaceCoordinate]
        let stacks: CatalogStacks
        let expanded: Set<PhotoStackID>
        let result: PhotoStackCollapse.Result
    }

    var order: Order?
    var filterOptions: FilterOptions?
    var collapse: Collapse?

    /// No answer yet: every read is made.
    static let none = CatalogProjectionReads()

    /// The last order, when it answers `descriptor` over `paths` and nothing it depends on
    /// changed after `revisions`.
    func order(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths paths: Set<LibraryRootPath>,
        at revisions: CatalogFactRevisions
    ) -> CatalogOrderedAssets? {
        guard let order, order.descriptor == descriptor, order.availableLibraryPaths == paths,
              !revisions.moved(.orderInputs(of: descriptor), since: order.revisions)
        else {
            return nil
        }
        return order.answer
    }

    /// The last options, when they answer `row` over `paths` in `languages` and nothing they
    /// depend on changed after `revisions`.
    func filterOptions(
        for row: SidebarSelection,
        availableLibraryPaths paths: Set<LibraryRootPath>,
        placeNameLanguages languages: Set<PlaceNameLanguage>,
        at revisions: CatalogFactRevisions
    ) -> CatalogFilterOptions? {
        guard let filterOptions, filterOptions.row == row, filterOptions.availableLibraryPaths == paths,
              filterOptions.placeNameLanguages == languages,
              !revisions.moved(.filterOptionsInputs(of: row), since: filterOptions.revisions)
        else {
            return nil
        }
        return filterOptions.answer
    }
}

/// Which of its reads a pass answered from the last answer instead of reading again.
/// Logged with the pass (`reused=`).
nonisolated struct CatalogProjectionReuse: Equatable {
    var order = false
    var filterOptions = false
    var collapse = false

    var diagnosticDescription: String {
        let reused = [("order", order), ("filterOptions", filterOptions), ("collapse", collapse)]
            .filter(\.1).map(\.0)
        return reused.isEmpty ? "none" : reused.joined(separator: ",")
    }
}

/// Everything a window state is derived from once the Store has been read. Production
/// reads these facts from the Store; the one-shot test entry supplies them directly.
nonisolated struct CatalogProjectionBuildFacts {
    /// Display-ordered roots (`CatalogWindowPolicy.sortLibraries`).
    let allRoots: [CatalogLibraryState]
    let request: CatalogQueryRequest
    let resolvedDescriptor: CatalogQueryDescriptor
    let importBatches: [ImportBatchSummary]
    let orderedAssetIDs: [MediaAssetID]
    let availableLibraryPaths: Set<LibraryRootPath>
    var scopedAssetIDs: [MediaAssetID]
    var scopedDayBuckets: [Date?]
    /// Each scoped ID's location, index-paired; empty unless the scope requires one.
    var scopedCoordinates: [PlaceCoordinate]
    let orderQueryMs: Int
    /// Set when a search answered for the scope, or could not.
    var search: CatalogSearchOutcome?
    /// The stacks read with the order (ADR 0052), and how the scoped order shows them once
    /// collapsed.
    var stacks: CatalogStacks = .empty
    var gridStacks: CatalogGridStacks = .empty
}

/// What a search made of a scope, for the empty state (ADR 0048). `unsearchedScopeCount` is
/// the scope's items before the search: a scope that holds none keeps its own empty state.
nonisolated enum CatalogSearchOutcome: Equatable {
    /// The query was read and narrowed the scope to its matches. `stillReadingCount`: items
    /// whose thumbnails search has not read yet, counted only when nothing matched.
    case read(unsearchedScopeCount: Int, stillReadingCount: Int)
    /// The query could not be read: the scope shows none of its items rather than all of
    /// them unsearched.
    case failed(unsearchedScopeCount: Int)

    var unsearchedScopeCount: Int {
        switch self {
        case let .read(count, _), let .failed(count):
            count
        }
    }

    var phase: CatalogSearchPhase {
        switch self {
        case .read: .read
        case .failed: .failed
        }
    }
}

/// What a build made: the window state, or nothing yet because the shown search's query is
/// still being read (`SearchQueryReader`), whose report rings the loop when it ends.
nonisolated enum CatalogProjectionBuild {
    /// The state, what the build cost, and the reads it was built from, for the next pass.
    case built(CatalogWindowState, CatalogProjectionBuildMetrics, CatalogProjectionReads)
    case queryBeingRead
}
