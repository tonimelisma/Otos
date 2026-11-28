import Foundation
@testable import OtosKit
import Testing

/// ADR 0048 and DES-108: what the window says for each state of a shown search. The states are
/// applied by hand and the model's projection is never started, so nothing races them.
@Suite(.testScope)
@MainActor
struct SearchPhaseWindowTests {
    // Validates: APP-068
    /// While the query is read the subtitle says so, beside `Filtered` when a filter narrows
    /// the scope; once it is read or has failed, or the search has ended, it says nothing of
    /// search.
    @Test func theSubtitleSaysSearchingOnlyWhileTheQueryIsRead() {
        let model = makeModel()
        let lake = CatalogQueryDescriptor(scope: .allMedia, search: CatalogSearch(text: "järvi"))
        model.applyState(state(lake, phase: .reading))
        #expect(model.windowSubtitle == "Searching\u{2026}")
        model.applyState(state(lake, phase: .read))
        #expect(model.windowSubtitle == "")
        model.applyState(state(lake, phase: .failed))
        #expect(model.windowSubtitle == "")

        let filtered = CatalogQueryDescriptor(
            scope: .allMedia, filter: MediaFilter(kinds: [.image]), search: CatalogSearch(text: "järvi")
        )
        model.applyState(state(filtered, phase: .reading))
        #expect(model.windowSubtitle == "Filtered \u{00B7} Searching\u{2026}")
        model.applyState(state(filtered, phase: .read))
        #expect(model.windowSubtitle == "Filtered")
    }

    // Validates: APP-068
    /// A query that cannot be read says so in the grid's empty state, never as the results.
    @Test func aFailedSearchSaysItCouldNotSearch() {
        let failed = CatalogMediaEmptyState.searchFailed("järvi")
        #expect(failed.title == "Couldn\u{2019}t Search for \u{201C}järvi\u{201D}")
        #expect(failed.message == "Otos tries again on its own. The results appear here when it succeeds.")
        #expect(failed.systemImage == "exclamationmark.magnifyingglass")
        #expect(failed.title != CatalogMediaEmptyState.noSearchResults("järvi", stillReading: 0).title)
    }

    private func makeModel() -> CatalogWindowViewModel {
        CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
    }

    /// A state for the model's current request, so the model takes its descriptor.
    private func state(_ descriptor: CatalogQueryDescriptor, phase: CatalogSearchPhase) -> CatalogWindowState {
        var state = CatalogWindowState(
            title: "All Media",
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(descriptor: descriptor, orderedAssetIDs: []),
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil,
            queryGeneration: CatalogQueryRequest.initial.generation
        )
        state.searchPhase = phase
        return state
    }
}
