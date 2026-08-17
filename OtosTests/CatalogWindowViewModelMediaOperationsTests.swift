import Foundation
@testable import Otos
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

    private static func presentation(batchID: ImportBatchID?) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: cardPath,
            destinationPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
            destinationDisplayName: "Pictures",
            state: .executing(progress: MediaOperationProgress(completedCount: 1, totalCount: 2, completedBytes: 1, totalBytes: 2, elapsedMs: 0)),
            attachToReadyMs: nil,
            batchID: batchID,
            cardStillExists: true,
            copiedJustNow: nil,
            isFullyClean: nil,
            incompleteItems: []
        )
    }

    private func makeModel() -> CatalogWindowViewModel {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        return CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            enrichmentCoordinator: nil,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: temp.domain
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
