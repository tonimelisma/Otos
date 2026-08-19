import Foundation
@testable import OtosKit
import Testing

/// Plan 0092 increment 6, `import-bar.md` "Where the user is standing": the
/// sidebar selection follows a new import batch once, and only if the user
/// hasn't already navigated elsewhere. These tests exercise the ViewModel's
/// public `applyImportPresentations`/`applyState` entry points rather than the
/// private `followNewBatchesOnce` helper directly.
@MainActor
struct CatalogWindowViewModelMediaOperationsTests {
    private static let cardPath = LibraryRootPath(rawValue: "/Volumes/CARD")
    private static let otherPath = LibraryRootPath(rawValue: "/Volumes/OTHER")
    private static let batchID = ImportBatchID(unixMilliseconds: 1_704_067_200_000)

    private static func presentation(
        batchID: ImportBatchID?,
        state: MediaOperationSourceState = .executing(
            progress: MediaOperationProgress(completedCount: 1, totalCount: 2, completedBytes: 1, totalBytes: 2, elapsedMs: 0)
        ),
        cardStillExists: Bool = true,
        copiedJustNow: Int? = nil,
        isFullyClean: Bool? = nil,
        settledAt: Date? = nil,
        sessionPreferences: ImportPreferences = .default
    ) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: cardPath,
            sourceKind: .removableVolume,
            destinationPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
            destinationDisplayName: "Pictures",
            state: state,
            attachToReadyMs: nil,
            batchID: batchID,
            cardStillExists: cardStillExists,
            copiedJustNow: copiedJustNow,
            isFullyClean: isFullyClean,
            settledAt: settledAt,
            sessionPreferences: sessionPreferences,
            incompleteItems: []
        )
    }

    private func makeModel() -> CatalogWindowViewModel {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        return CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            enrichmentCoordinator: nil,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: temp
        )
    }

    @Test func autoSelectFollowsNewBatchWhenStillOnSourceRow() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
    }

    @Test func autoSelectFollowsFromAllImports() {
        let model = makeModel()
        model.selectSidebar(.allImports)
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
    }

    @Test func autoSelectDoesNotFollowWhenNavigatedToOtherLibrary() {
        let model = makeModel()
        model.selectSidebar(.library(Self.otherPath))
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        #expect(model.sidebarSelection == .library(Self.otherPath))
    }

    @Test func autoSelectDoesNotFollowFromAllMedia() {
        let model = makeModel()
        model.selectSidebar(.allMedia)
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        #expect(model.sidebarSelection == .allMedia)
    }

    @Test func autoSelectNeverFiresTwiceForSameBatch() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))

        // User navigates away after the auto-move; a repeated frame for the
        // same batch (the coordinator republishes on every progress tick)
        // must not move them back.
        model.selectSidebar(.library(Self.otherPath))
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        #expect(model.sidebarSelection == .library(Self.otherPath))
    }

    @Test func resolvedSidebarSelectionKeepsFreshBatchSelection() {
        // The bounce-back race: `resolvedSidebarSelection` bounces an
        // `.importBatch` scope away until the batch has a journaled asset,
        // but the bar shows the batch from the moment execution starts.
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))

        let bouncedState = Self.state(
            resolvedSidebarSelection: .allMedia,
            importBatches: [],
            queryGeneration: model.queryGeneration
        )
        model.applyState(bouncedState)
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
    }

    @Test func resolvedSidebarSelectionAppliesOnceBatchIsJournaled() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])

        let settledState = Self.state(
            resolvedSidebarSelection: .importBatch(Self.batchID),
            importBatches: [ImportBatchSummary(batchID: Self.batchID, assetCount: 1)],
            queryGeneration: model.queryGeneration
        )
        model.applyState(settledState)
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
    }

    @Test func resolvedSidebarSelectionDoesNotStayPinnedWithoutALiveBatchPresentation() {
        // Selection is `.importBatch` but the coordinator never published a
        // presentation for it (no `applyImportPresentations` call) — the
        // keep-selection exception must not fire, and a genuinely stale batch
        // scope resolves normally instead of pinning forever.
        let model = makeModel()
        model.selectSidebar(.importBatch(Self.batchID))

        let bouncedState = Self.state(
            resolvedSidebarSelection: .allMedia,
            importBatches: [],
            queryGeneration: model.queryGeneration
        )
        model.applyState(bouncedState)
        #expect(model.sidebarSelection == .allMedia)
    }

    /// Plan 0095 D7: `sessionPreferences` used to live in a second
    /// ViewModel-owned dictionary (`sessionPreferencesBySource`) that a
    /// per-frame `Task` wholesale-replaced from the coordinator on every
    /// presentation, racing an optimistic write from `setSessionPreferences`
    /// and reverting an in-flight toggle. Now `sessionPreferences(for:)` reads
    /// straight off the live presentation — there is no second dictionary left
    /// to race, so an interleaved frame that still carries the old value (the
    /// coordinator hasn't processed the toggle yet) cannot overwrite a
    /// confirmation that already landed, and a frame carrying the toggled
    /// value is reflected immediately once it does land.
    @Test func sessionPreferencesToggleSurvivesAnInterleavedFrame() {
        let model = makeModel()
        model.applyImportPresentations([Self.presentation(batchID: nil)])
        #expect(model.sessionPreferences(for: Self.cardPath) == .default)

        // An interleaved frame with nothing to do with the toggle (e.g. a
        // progress tick) still carries the coordinator's last-published,
        // pre-toggle value.
        model.applyImportPresentations([Self.presentation(batchID: nil)])
        #expect(model.sessionPreferences(for: Self.cardPath) == .default)

        // The coordinator's confirmation frame lands, carrying the toggled value.
        var toggled = ImportPreferences.default
        toggled.deleteSourceAfterImport = true
        model.applyImportPresentations([Self.presentation(batchID: nil, sessionPreferences: toggled)])
        #expect(model.sessionPreferences(for: Self.cardPath) == toggled)

        // A further interleaved frame after the toggle must not revert it.
        model.applyImportPresentations([Self.presentation(batchID: nil, sessionPreferences: toggled)])
        #expect(model.sessionPreferences(for: Self.cardPath) == toggled)
    }

    /// Plan 0095 D20: a run that finished with skips/failures must never
    /// auto-dismiss (`import-bar.md` "Done bar auto-dismisses after ~6 s only
    /// on a fully clean run; otherwise persists") — `isFullyClean == false`
    /// must never schedule a dismissal, however long the card has been gone.
    @Test func nonCleanSettleDoesNotAutoDismiss() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([
            Self.presentation(
                batchID: Self.batchID,
                state: .completed(
                    summary: MediaOperationPlanTotals(copyCount: 5, skipCount: 1, blockedCount: 0, companionCopyCount: 0, copyBytes: 0)
                ),
                cardStillExists: false,
                isFullyClean: false,
                settledAt: Date()
            ),
        ])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
        #expect(model.selectedImportPresentation != nil)
    }

    /// Plan 0095 D20, positive path: a fully clean run whose card is gone
    /// dismisses the bar once its `settledAt + 6s` deadline passes, but
    /// leaves the batch selected — "Batch stays selected; the user is
    /// looking at exactly what they just imported" (`import-bar.md`, state
    /// F row 8). `settledAt` is seeded already 10s in the past so the
    /// deadline has already elapsed, avoiding a real 6s sleep in the test.
    @Test func cleanSettleWithCardGoneAutoDismissesAfterDeadline() async throws {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([
            Self.presentation(
                batchID: Self.batchID,
                state: .completed(
                    summary: MediaOperationPlanTotals(copyCount: 5, skipCount: 0, blockedCount: 0, companionCopyCount: 0, copyBytes: 0)
                ),
                cardStillExists: false,
                isFullyClean: true,
                settledAt: Date().addingTimeInterval(-10)
            ),
        ])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
        #expect(model.selectedImportPresentation != nil)

        try await Task.sleep(for: .milliseconds(100))

        #expect(model.sidebarSelection == .importBatch(Self.batchID))
        #expect(model.selectedImportPresentation == nil)
    }

    private static func state(
        resolvedSidebarSelection: SidebarSelection,
        importBatches: [ImportBatchSummary],
        queryGeneration: UInt64
    ) -> CatalogWindowState {
        CatalogWindowState(
            title: "Test",
            libraries: [],
            removableSources: [],
            importBatches: importBatches,
            mediaGrid: .empty,
            filterOptions: .empty,
            resolvedSidebarSelection: resolvedSidebarSelection,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil,
            queryGeneration: queryGeneration
        )
    }
}
