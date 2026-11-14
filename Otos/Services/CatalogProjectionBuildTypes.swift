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

/// The order a detail-only publication may reuse instead of re-running the ordered-asset
/// query, with the descriptor it was built for.
nonisolated struct CatalogProjectionOrderReuse {
    let orderedAssetIDs: [MediaAssetID]?
    let dayBuckets: [Date?]?
    /// The map's coordinates, reused only by an expansion: a detail-only change can move a
    /// location, so it re-reads them where they are shown.
    var coordinates: [PlaceCoordinate]?
    /// The stacks the order was read with (ADR 0052); the order is the uncollapsed one.
    var stacks: CatalogStacks = .empty
    /// Reused with the order it was read with: the order is unchanged, so no identity in
    /// it needs a batch the previous read did not carry.
    let pendingIdentityRemaps: [CatalogIdentityRemapBatch]?
    let descriptor: CatalogQueryDescriptor?

    static let none = CatalogProjectionOrderReuse(
        orderedAssetIDs: nil,
        dayBuckets: nil,
        pendingIdentityRemaps: nil,
        descriptor: nil
    )
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
    case built(CatalogWindowState, CatalogProjectionBuildMetrics)
    case queryBeingRead
}
