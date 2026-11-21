import Foundation
@testable import OtosKit
import Testing

/// APP-029, `import-bar.md` "Where the user is standing": the import bar is
/// drawn only on a removable source's own row, and an import moves the selection
/// to its batch once, when the batch's row first exists. These tests exercise the ViewModel's public
/// `applyImportPresentations`/`applyState` entry points.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelMediaOperationsTests {
    private static let cardPath = LibraryRootPath(rawValue: "/Volumes/CARD")
    private static let otherPath = LibraryRootPath(rawValue: "/Volumes/OTHER")
    private static let libraryPath = LibraryRootPath(rawValue: "/Users/example/Pictures")
    private static let batchID = ImportBatchID(unixMilliseconds: 1_704_067_200_000)
    private static let executing = MediaOperationSourceState.executing(
        progress: MediaOperationProgress(
            completedCount: 1,
            totalCount: 2,
            completedBytes: 1,
            totalBytes: 2,
            elapsedMs: 0
        )
    )
    private static let stoppedTotals = MediaOperationPlanTotals(
        copyCount: 5,
        skipCount: 1,
        blockedCount: 0,
        companionCopyCount: 0,
        copyBytes: 0
    )

    private static func presentation(
        runBatchID: ImportBatchID?,
        state: MediaOperationSourceState = executing,
        copiedJustNow: Int? = nil,
        isFullyClean: Bool? = nil,
        stopReason: ImportStopReason? = nil,
        plannedCount: Int? = nil,
        sessionPreferences: ImportPreferences = .default
    ) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: cardPath,
            sourceKind: .removableVolume,
            destinationPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
            destinationDisplayName: "Pictures",
            state: state,
            attachToReadyMs: nil,
            runBatchID: runBatchID,
            copiedJustNow: copiedJustNow,
            isFullyClean: isFullyClean,
            stopReason: stopReason,
            plannedCount: plannedCount,
            sessionPreferences: sessionPreferences,
            incompleteItems: []
        )
    }

    /// The just-cancelled run of the 2026-10-01 report: stopped at 3 of 8,
    /// with the re-plan's remainder on the card. Its batch is still the
    /// attachment's latest run's.
    private static let cancelled = presentation(
        runBatchID: batchID,
        state: .ready(summary: stoppedTotals, generation: 1, skippedPackageCount: 0),
        copiedJustNow: 3,
        isFullyClean: false,
        stopReason: .user,
        plannedCount: 8
    )

    private func makeModel() -> CatalogWindowViewModel {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        return CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory),
            enrichmentCoordinator: nil,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: temp,
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
    }

    // MARK: - An import moves the user to its batch, once

    /// `import-bar.md` row 6: the selection leaves the card's row for the batch the run
    /// is copying into once the sidebar draws that batch's row. The presentation names the
    /// batch as soon as its first item is in the catalog; the row exists only once a window
    /// state carrying it is applied, which on a loaded machine came 20 s later (2026-11-15):
    /// selecting it before then highlighted nothing and kept the card's photos on screen
    /// without the bar.
    @Test func pressingImportMovesTheUserToTheBatchOnceItsRowExists() {
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: []))
        model.selectSidebar(.library(Self.cardPath))

        // Preparing and the first frames of the run have no batch yet.
        model.applyImportPresentations([Self.presentation(runBatchID: nil)])
        #expect(model.sidebarSelection == .library(Self.cardPath))

        // The run names its batch before the sidebar draws the batch's row.
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        #expect(model.sidebarSelection == .library(Self.cardPath))
        #expect(model.selectedImportPresentation?.runBatchID == Self.batchID)

        model.applyState(Self.attachedState(model, importBatches: [
            ImportBatchSummary(batchID: Self.batchID, photoCount: 1),
        ]))
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
        // The bar follows the run onto its batch row: progress and Cancel stay on screen.
        #expect(model.selectedImportPresentation?.state == Self.executing)
        #expect(model.selectedImportPresentation?.sourcePath == Self.cardPath)
    }

    /// A short run can finish before the batch's row is drawn; the row's first appearance
    /// still moves the user, and the bar's Done comes with them.
    @Test func aRunThatFinishesBeforeItsRowAppearsStillMovesTheUser() {
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: []))
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        let completed = MediaOperationSourceState.completed(
            summary: Self.stoppedTotals,
            skippedForeignCount: 0,
            failedCount: 0,
            incompleteItems: []
        )
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID, state: completed)])
        #expect(model.sidebarSelection == .library(Self.cardPath))

        model.applyState(Self.attachedState(model, importBatches: [
            ImportBatchSummary(batchID: Self.batchID, photoCount: 5),
        ]))
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
        #expect(model.selectedImportPresentation?.state == completed)
    }

    @Test func aUserWhoReturnsToTheCardIsNotPulledBackToTheBatch() {
        let model = makeModel()
        let withRow = [ImportBatchSummary(batchID: Self.batchID, photoCount: 1)]
        model.applyState(Self.attachedState(model, importBatches: withRow))
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
        model.selectSidebar(.library(Self.cardPath))

        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        model.applyState(Self.attachedState(model, importBatches: withRow))

        #expect(model.sidebarSelection == .library(Self.cardPath))
        #expect(model.selectedImportPresentation?.runBatchID == Self.batchID)
    }

    @Test func aUserElsewhereWhenTheRowAppearsStaysThereAndIsNeverPulledLater() {
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: []))
        model.selectSidebar(.library(Self.libraryPath))
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.libraryPath),
            importBatches: [ImportBatchSummary(batchID: Self.batchID, photoCount: 1)],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)],
            removableSources: [Self.card(Self.cardPath)]
        ))
        #expect(model.sidebarSelection == .library(Self.libraryPath))

        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        #expect(model.sidebarSelection == .library(Self.cardPath))
    }

    /// A batch whose row never appears (its items left the catalog first) is not waited on
    /// for ever: leaving the card's row ends the wait, and the row appearing later, with the
    /// user back on the card, does not pull them.
    @Test func leavingTheCardBeforeTheRowAppearsEndsTheWait() {
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: []))
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        #expect(model.importBatchesAwaitingTheirRow[Self.batchID] == Self.cardPath)

        model.selectSidebar(.library(Self.libraryPath))
        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.libraryPath),
            importBatches: [],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)],
            removableSources: [Self.card(Self.cardPath)]
        ))
        #expect(model.importBatchesAwaitingTheirRow.isEmpty)

        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        model.applyState(Self.attachedState(model, importBatches: [
            ImportBatchSummary(batchID: Self.batchID, photoCount: 1),
        ]))
        #expect(model.sidebarSelection == .library(Self.cardPath))
        #expect(model.importBatchesAwaitingTheirRow.isEmpty)
    }

    @Test func aRunThatIsNotCopyingDoesNotMoveTheUser() {
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: []))
        model.selectSidebar(.library(Self.cardPath))

        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID, state: .completed(
            summary: Self.stoppedTotals,
            skippedForeignCount: 0,
            failedCount: 0,
            incompleteItems: []
        ))])

        #expect(model.sidebarSelection == .library(Self.cardPath))
    }

    @Test func anExecutingImportDoesNotMoveTheUserFromAllImports() {
        let model = makeModel()
        model.selectSidebar(.allImports)
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        #expect(model.sidebarSelection == .allImports)
    }

    // MARK: - The bar is drawn on the card's row and on its latest run's batch row

    /// The 2026-10-01 report's run, seen from its batch: the batch a just-cancelled run
    /// produced draws that card's bar — the Stopped report and the remainder's Import —
    /// for as long as the card is attached, the same bar the card's own row draws.
    @Test func aJustCancelledRunsBatchRowShowsTheCardsBar() {
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: [
            ImportBatchSummary(batchID: Self.batchID, photoCount: 3),
        ]))
        model.applyImportPresentations([Self.cancelled])
        model.selectSidebar(.importBatch(Self.batchID))
        #expect(model.selectedImportPresentation == Self.cancelled)

        model.selectSidebar(.library(Self.cardPath))
        #expect(model.selectedImportPresentation == Self.cancelled)
    }

    /// Every run state — in flight, failed, settled incomplete — draws the bar on the
    /// run's batch row, where `Show them` is not offered: the items it names are on the
    /// card, not in the batch's grid. The card's row offers it.
    @Test func aRunsBatchRowShowsItsBarInEveryRunState() {
        let states: [MediaOperationSourceState] = [
            Self.executing,
            .failed(reason: .destinationUnavailable, publishedCount: 2),
            .completed(summary: Self.stoppedTotals, skippedForeignCount: 1, failedCount: 0, incompleteItems: []),
        ]
        for state in states {
            let model = makeModel()
            model.applyState(Self.attachedState(model, importBatches: [
                ImportBatchSummary(batchID: Self.batchID, photoCount: 2),
            ]))
            let presentation = Self.presentation(runBatchID: Self.batchID, state: state, isFullyClean: false)
            model.applyImportPresentations([presentation])
            model.selectSidebar(.importBatch(Self.batchID))
            #expect(model.selectedImportPresentation == presentation, "state=\(state)")
            #expect(!model.importBarRevealsCardItems, "state=\(state)")

            model.selectSidebar(.library(Self.cardPath))
            #expect(model.importBarRevealsCardItems, "state=\(state)")
        }
    }

    /// A batch row draws only its own run's bar: an older batch from the same card, once a
    /// newer run has started, and a batch whose card is gone draw none.
    @Test func aBatchRowThatIsNotTheCardsLatestRunShowsNoBar() {
        let older = ImportBatchID(unixMilliseconds: 1_600_000_000_000)
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: [
            ImportBatchSummary(batchID: Self.batchID, photoCount: 2),
            ImportBatchSummary(batchID: older, photoCount: 4),
        ]))
        model.applyImportPresentations([Self.presentation(runBatchID: Self.batchID)])
        model.selectSidebar(.importBatch(older))
        #expect(model.selectedImportPresentation == nil)

        // A new run that has landed nothing yet names no batch: its predecessor's row
        // is no longer the run in progress.
        model.applyImportPresentations([Self.presentation(runBatchID: nil)])
        model.selectSidebar(.importBatch(Self.batchID))
        #expect(model.selectedImportPresentation == nil)

        model.applyImportPresentations([])
        #expect(model.selectedImportPresentation == nil)
    }

    /// Ejecting the card the user is standing on resolves through the ordinary
    /// fallback; the selection does not jump to the batch that card produced.
    @Test func ejectingTheSelectedCardFallsBackNormally() {
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: [
            ImportBatchSummary(batchID: Self.batchID, photoCount: 42),
        ]))
        model.applyImportPresentations([Self.cancelled])
        model.selectSidebar(.library(Self.cardPath))

        model.applyImportPresentations([])
        // The projection resolves the vanished card's scope to its fallback;
        // the ViewModel must not override it with the card's batch.
        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.libraryPath),
            importBatches: [ImportBatchSummary(batchID: Self.batchID, photoCount: 42)],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)]
        ))
        #expect(model.sidebarSelection == .library(Self.libraryPath))
        #expect(model.selectedImportPresentation == nil)
    }

    /// APP-029: `sessionPreferences(for:)` reads straight off the live
    /// presentation. A second ViewModel-owned copy, wholesale-replaced from the
    /// coordinator on every frame, would race an optimistic write from
    /// `setSessionPreferences` and revert an in-flight toggle. With one owner there
    /// is nothing to race, so an interleaved frame that still carries the old value (the
    /// coordinator hasn't processed the toggle yet) cannot overwrite a
    /// confirmation that already landed, and a frame carrying the toggled
    /// value is reflected immediately once it does land.
    @Test func sessionPreferencesToggleSurvivesAnInterleavedFrame() {
        let model = makeModel()
        model.applyImportPresentations([Self.presentation(runBatchID: nil)])
        #expect(model.sessionPreferences(for: Self.cardPath) == .default)

        // An interleaved frame with nothing to do with the toggle (e.g. a
        // progress tick) still carries the coordinator's last-published,
        // pre-toggle value.
        model.applyImportPresentations([Self.presentation(runBatchID: nil)])
        #expect(model.sessionPreferences(for: Self.cardPath) == .default)

        // The coordinator's confirmation frame lands, carrying the toggled value.
        var toggled = ImportPreferences.default
        toggled.deleteSourceAfterImport = true
        model.applyImportPresentations([Self.presentation(runBatchID: nil, sessionPreferences: toggled)])
        #expect(model.sessionPreferences(for: Self.cardPath) == toggled)

        // A further interleaved frame after the toggle must not revert it.
        model.applyImportPresentations([Self.presentation(runBatchID: nil, sessionPreferences: toggled)])
        #expect(model.sessionPreferences(for: Self.cardPath) == toggled)
    }

    /// The 2026-09-13 shape: two runs refused before any copy, seconds apart.
    /// The bar stays on the card through both refusals.
    @Test func aSecondRefusedRunLeavesTheFooterMounted() {
        let model = makeModel()
        model.applyState(Self.attachedState(model, importBatches: []))
        model.selectSidebar(.library(Self.cardPath))
        for _ in 0 ..< 2 {
            model.applyImportPresentations([Self.presentation(
                runBatchID: nil,
                state: .failed(reason: .destinationUnavailable, publishedCount: 0)
            )])
        }
        #expect(model.sidebarSelection == .library(Self.cardPath))
        #expect(model.selectedImportPresentation?.state == .failed(reason: .destinationUnavailable, publishedCount: 0))
    }

    private static func attachedState(
        _ model: CatalogWindowViewModel,
        importBatches: [ImportBatchSummary]
    ) -> CatalogWindowState {
        state(
            resolvedSidebarSelection: .library(cardPath),
            importBatches: importBatches,
            queryGeneration: model.queryGeneration,
            libraries: [library(libraryPath)],
            removableSources: [card(cardPath)]
        )
    }

    private static func card(_ path: LibraryRootPath) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(path: path, kind: .removableVolume),
            availability: .available,
            activity: .idle
        )
    }

    private static func library(_ path: LibraryRootPath) -> CatalogLibraryState {
        CatalogLibraryState(root: LibraryRoot(path: path), availability: .available, activity: .idle)
    }

    private static func state(
        resolvedSidebarSelection: SidebarSelection,
        importBatches: [ImportBatchSummary],
        queryGeneration: UInt64,
        libraries: [CatalogLibraryState] = [],
        removableSources: [CatalogLibraryState] = []
    ) -> CatalogWindowState {
        CatalogWindowState(
            title: "Test",
            libraries: libraries,
            removableSources: removableSources,
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
