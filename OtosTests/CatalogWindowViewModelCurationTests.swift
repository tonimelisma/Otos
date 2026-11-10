import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Every choice travels the view model's one media-choice lane, so
/// `hasSettledMediaChoices` is the fact that it has been written or refused; each test
/// waits for that and then asserts the exact outcome.
@Suite(.testDirectory)
@MainActor
struct CatalogWindowViewModelCurationTests {
    @Test func rapidChoicesRemainLosslessAndOrdered() async throws {
        try await withCatalogedLibrary(fileCount: 1) { library in
            let model = makeCurationModel()
            model.applyState(curationWindowState(ids: library.ids))
            _ = model.applyGridClick(hit: library.ids[0], modifiers: [], orderedIDs: library.ids)
            model.startMediaChoiceForwarding(store: library.store)
            defer { model.mediaChoiceForwardingTask?.cancel() }

            model.submitMediaChoice(.liked, origin: .keyboard)
            model.submitMediaChoice(.notRated, origin: .keyboard)
            model.submitMediaChoice(.disliked, origin: .keyboard)

            try await waitUntil { model.hasSettledMediaChoices }
            let choice = try await library.store.mediaAssets(for: library.ids)[library.ids[0]]?.mediaChoice
            #expect(choice == .disliked)
            #expect(model.gridSelection.selection == [library.ids[0]])
        }
    }

    @Test func acceptedSameValueChoiceAdvancesOnlyWhenEnabled() async throws {
        try await withCatalogedLibrary(fileCount: 2) { library in
            let model = makeCurationModel()
            model.applyState(curationWindowState(ids: library.ids))
            _ = model.applyGridClick(hit: library.ids[0], modifiers: [], orderedIDs: library.ids)
            model.setAdvanceAfterMediaChoice(true)
            model.startMediaChoiceForwarding(store: library.store)
            defer { model.mediaChoiceForwardingTask?.cancel() }

            model.submitMediaChoice(.notRated, origin: .keyboard)

            try await waitUntil { model.hasSettledMediaChoices }
            #expect(model.gridSelection.selection == [library.ids[1]])
            let choice = try await library.store.mediaAssets(for: library.ids)[library.ids[0]]?.mediaChoice
            #expect(choice == .notRated)
        }
    }

    @Test func acceptedChoiceAtEndDoesNotWrap() async throws {
        try await withCatalogedLibrary(fileCount: 2) { library in
            let model = makeCurationModel()
            model.applyState(curationWindowState(ids: library.ids))
            _ = model.applyGridClick(hit: library.ids[1], modifiers: [], orderedIDs: library.ids)
            model.setAdvanceAfterMediaChoice(true)
            model.startMediaChoiceForwarding(store: library.store)
            defer { model.mediaChoiceForwardingTask?.cancel() }

            model.submitMediaChoice(.liked, origin: .keyboard)

            try await waitUntil { model.hasSettledMediaChoices }
            let choice = try await library.store.mediaAssets(for: library.ids)[library.ids[1]]?.mediaChoice
            #expect(choice == .liked)
            #expect(model.gridSelection.selection == [library.ids[1]])
        }
    }

    @Test func toolbarChoiceReflectsTheTargetsSharedValue() async throws {
        try await withCatalogedLibrary(fileCount: 3) { library in
            let model = CatalogWindowViewModel(
                catalogStore: library.store,
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            let ids = library.ids
            model.applyState(curationWindowState(ids: ids))
            model.startMediaChoiceForwarding(store: library.store)
            defer { model.mediaChoiceForwardingTask?.cancel() }

            _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
            try await waitUntil { model.currentTargetChoice == .notRated }
            #expect(model.currentTargetChoice == .notRated)

            model.submitMediaChoice(.liked, origin: .toolbar)
            try await waitUntil { model.currentTargetChoice == .liked }
            #expect(model.currentTargetChoice == .liked)

            // A mixed selection shares no value; a uniform one does.
            _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
            try await waitUntil { model.currentTargetChoice == nil }
            #expect(model.currentTargetChoice == nil)
            model.submitMediaChoice(.liked, origin: .toolbar)
            try await waitUntil { model.currentTargetChoice == .liked }
            #expect(model.currentTargetChoice == .liked)

            model.deselectAll()
            try await waitUntil { model.currentTargetChoice == nil }
            #expect(model.currentTargetChoice == nil)
        }
    }

    @Test func rejectedStoreMutationNeverAdvances() async throws {
        let model = makeCurationModel()
        let ids = ["choice-0.jpg", "choice-1.jpg"].map {
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/missing"),
                relativePath: MediaRelativePath(rawValue: $0)
            )
        }
        model.applyState(curationWindowState(ids: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        model.setAdvanceAfterMediaChoice(true)
        model.startMediaChoiceForwarding(store: model.catalogStore)
        defer { model.mediaChoiceForwardingTask?.cancel() }

        model.submitMediaChoice(.liked, origin: .keyboard)
        try await waitUntil { model.hasSettledMediaChoices }

        #expect(model.gridSelection.selection == [ids[0]])
    }
}

@MainActor
private func makeCurationModel() -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
}

private func curationWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Curation",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
