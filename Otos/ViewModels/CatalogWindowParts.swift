import Observation

/// Catalog window parts guide
///
/// The window state the view model last applied, observed part by part: each part of a
/// `CatalogWindowState` — the libraries, the grid, the filter's options, the map, People,
/// and the rest (`Part`) — is its own observed property, and applying a publication notifies
/// only the parts it changed. A surface depends on the parts it reads and on nothing else, so
/// a one-tile hide re-renders what shows the grid, a choice what shows the choice, and a
/// republication that changed nothing re-renders nothing.
///
/// Why: with the whole state one observed value, every publication invalidated every view
/// that read any part of it — the sidebar, every pane, the toolbar, the inspector — and the
/// window then measured its whole tree again for its minimum size. While acts ran in a row
/// that was a 45–60 ms main-thread update per publication on an optimised build, and each
/// act's result waited behind one (`docs/research/2026-11-16-window-state-turns.md`).
///
/// A part counts as changed by the cheapest test that answers it: the grid by its content's
/// identity, its descriptor and its detail refresh (Projection hands an unchanged content on
/// as the last one's own, so its 158,000 identities are never compared on the main actor);
/// every other part by `==`, whose collections answer by identity when Projection shared
/// them (`CatalogWindowState.sharingUnchanged`). A part wrongly counted as changed costs one
/// render; none is ever counted unchanged when it changed.
@MainActor
final class CatalogWindowParts: Observable {
    /// What a surface can depend on. `pendingIdentityRemaps` is no part: the view model takes
    /// it in when it applies a publication, and no surface reads it.
    enum Part: CaseIterable, Sendable {
        case title
        case libraries
        case removableSources
        case importBatches
        case mediaGrid
        /// How the grid shows its stacks, apart from its order: what a target's stack acts read.
        case gridStacks
        case filterOptions
        case resolvedSidebarSelection
        case mediaEmptyState
        case deviceConnectionBanner
        case map
        case onThisDay
        case duplicates
        case people
        case searchPhase
        case queryGeneration

        /// Whether this part of `next` differs from `previous`'s.
        func changed(from previous: CatalogWindowState, to next: CatalogWindowState) -> Bool {
            switch self {
            case .title: previous.title != next.title
            case .libraries: previous.libraries != next.libraries
            case .removableSources: previous.removableSources != next.removableSources
            case .importBatches: previous.importBatches != next.importBatches
            case .mediaGrid:
                !previous.mediaGrid.sharesContent(with: next.mediaGrid)
                    || previous.mediaGrid.descriptor != next.mediaGrid.descriptor
                    || previous.mediaGrid.detailRefreshGeneration != next.mediaGrid.detailRefreshGeneration
            case .gridStacks:
                !previous.mediaGrid.sharesContent(with: next.mediaGrid) && previous.mediaGrid.stacks != next.mediaGrid.stacks
            case .filterOptions: previous.filterOptions != next.filterOptions
            case .resolvedSidebarSelection: previous.resolvedSidebarSelection != next.resolvedSidebarSelection
            case .mediaEmptyState: previous.mediaEmptyState != next.mediaEmptyState
            case .deviceConnectionBanner: previous.deviceConnectionBanner != next.deviceConnectionBanner
            case .map: previous.map != next.map
            case .onThisDay: previous.onThisDay != next.onThisDay
            case .duplicates: previous.duplicates != next.duplicates
            case .people: previous.people != next.people
            case .searchPhase: previous.searchPhase != next.searchPhase
            case .queryGeneration: previous.queryGeneration != next.queryGeneration
            }
        }
    }

    private let registrar = ObservationRegistrar()
    /// The applied state. Read through the parts, which register what they read.
    private var applied = CatalogWindowState.empty

    /// The whole state: a reader depends on every part.
    var state: CatalogWindowState {
        for part in Part.allCases {
            access(part)
        }
        return applied
    }

    var title: String {
        access(.title)
        return applied.title
    }

    var libraries: [CatalogLibraryState] {
        access(.libraries)
        return applied.libraries
    }

    var removableSources: [CatalogLibraryState] {
        access(.removableSources)
        return applied.removableSources
    }

    var importBatches: [ImportBatchSummary] {
        access(.importBatches)
        return applied.importBatches
    }

    var mediaGrid: CatalogMediaGridState {
        access(.mediaGrid)
        return applied.mediaGrid
    }

    var gridStacks: CatalogGridStacks {
        access(.gridStacks)
        return applied.mediaGrid.stacks
    }

    var filterOptions: CatalogFilterOptions {
        access(.filterOptions)
        return applied.filterOptions
    }

    var resolvedSidebarSelection: SidebarSelection {
        access(.resolvedSidebarSelection)
        return applied.resolvedSidebarSelection
    }

    var mediaEmptyState: CatalogMediaEmptyState? {
        access(.mediaEmptyState)
        return applied.mediaEmptyState
    }

    var deviceConnectionBanner: CatalogDeviceConnectionBanner? {
        access(.deviceConnectionBanner)
        return applied.deviceConnectionBanner
    }

    var map: CatalogMapState? {
        access(.map)
        return applied.map
    }

    var onThisDay: CatalogOnThisDayState? {
        access(.onThisDay)
        return applied.onThisDay
    }

    var duplicates: CatalogDuplicatesState? {
        access(.duplicates)
        return applied.duplicates
    }

    var people: CatalogPeopleState? {
        access(.people)
        return applied.people
    }

    var searchPhase: CatalogSearchPhase? {
        access(.searchPhase)
        return applied.searchPhase
    }

    var queryGeneration: UInt64 {
        access(.queryGeneration)
        return applied.queryGeneration
    }

    /// Whether the catalog's first load has applied (`CatalogWindowState.isCatalogLoaded`).
    var isCatalogLoaded: Bool {
        mediaEmptyState != .loadingCatalog
    }

    /// Takes in `next` and notifies the parts it changed, which it returns.
    @discardableResult
    func apply(_ next: CatalogWindowState) -> [Part] {
        let changed = Part.allCases.filter { $0.changed(from: applied, to: next) }
        for part in changed {
            willSet(part)
        }
        applied = next
        for part in changed {
            didSet(part)
        }
        return changed
    }

    private func access(_ part: Part) {
        switch part {
        case .title: registrar.access(self, keyPath: \.title)
        case .libraries: registrar.access(self, keyPath: \.libraries)
        case .removableSources: registrar.access(self, keyPath: \.removableSources)
        case .importBatches: registrar.access(self, keyPath: \.importBatches)
        case .mediaGrid: registrar.access(self, keyPath: \.mediaGrid)
        case .gridStacks: registrar.access(self, keyPath: \.gridStacks)
        case .filterOptions: registrar.access(self, keyPath: \.filterOptions)
        case .resolvedSidebarSelection: registrar.access(self, keyPath: \.resolvedSidebarSelection)
        case .mediaEmptyState: registrar.access(self, keyPath: \.mediaEmptyState)
        case .deviceConnectionBanner: registrar.access(self, keyPath: \.deviceConnectionBanner)
        case .map: registrar.access(self, keyPath: \.map)
        case .onThisDay: registrar.access(self, keyPath: \.onThisDay)
        case .duplicates: registrar.access(self, keyPath: \.duplicates)
        case .people: registrar.access(self, keyPath: \.people)
        case .searchPhase: registrar.access(self, keyPath: \.searchPhase)
        case .queryGeneration: registrar.access(self, keyPath: \.queryGeneration)
        }
    }

    private func willSet(_ part: Part) {
        switch part {
        case .title: registrar.willSet(self, keyPath: \.title)
        case .libraries: registrar.willSet(self, keyPath: \.libraries)
        case .removableSources: registrar.willSet(self, keyPath: \.removableSources)
        case .importBatches: registrar.willSet(self, keyPath: \.importBatches)
        case .mediaGrid: registrar.willSet(self, keyPath: \.mediaGrid)
        case .gridStacks: registrar.willSet(self, keyPath: \.gridStacks)
        case .filterOptions: registrar.willSet(self, keyPath: \.filterOptions)
        case .resolvedSidebarSelection: registrar.willSet(self, keyPath: \.resolvedSidebarSelection)
        case .mediaEmptyState: registrar.willSet(self, keyPath: \.mediaEmptyState)
        case .deviceConnectionBanner: registrar.willSet(self, keyPath: \.deviceConnectionBanner)
        case .map: registrar.willSet(self, keyPath: \.map)
        case .onThisDay: registrar.willSet(self, keyPath: \.onThisDay)
        case .duplicates: registrar.willSet(self, keyPath: \.duplicates)
        case .people: registrar.willSet(self, keyPath: \.people)
        case .searchPhase: registrar.willSet(self, keyPath: \.searchPhase)
        case .queryGeneration: registrar.willSet(self, keyPath: \.queryGeneration)
        }
    }

    private func didSet(_ part: Part) {
        switch part {
        case .title: registrar.didSet(self, keyPath: \.title)
        case .libraries: registrar.didSet(self, keyPath: \.libraries)
        case .removableSources: registrar.didSet(self, keyPath: \.removableSources)
        case .importBatches: registrar.didSet(self, keyPath: \.importBatches)
        case .mediaGrid: registrar.didSet(self, keyPath: \.mediaGrid)
        case .gridStacks: registrar.didSet(self, keyPath: \.gridStacks)
        case .filterOptions: registrar.didSet(self, keyPath: \.filterOptions)
        case .resolvedSidebarSelection: registrar.didSet(self, keyPath: \.resolvedSidebarSelection)
        case .mediaEmptyState: registrar.didSet(self, keyPath: \.mediaEmptyState)
        case .deviceConnectionBanner: registrar.didSet(self, keyPath: \.deviceConnectionBanner)
        case .map: registrar.didSet(self, keyPath: \.map)
        case .onThisDay: registrar.didSet(self, keyPath: \.onThisDay)
        case .duplicates: registrar.didSet(self, keyPath: \.duplicates)
        case .people: registrar.didSet(self, keyPath: \.people)
        case .searchPhase: registrar.didSet(self, keyPath: \.searchPhase)
        case .queryGeneration: registrar.didSet(self, keyPath: \.queryGeneration)
        }
    }
}
