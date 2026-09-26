import Foundation
@testable import OtosKit
import Testing

/// APP-029, `import-bar.md` "Where the user is standing": the
/// sidebar selection follows a new import batch once, and only if the user
/// hasn't already navigated elsewhere. These tests exercise the ViewModel's
/// public `applyImportPresentations`/`applyState` entry points rather than the
/// private `followNewBatchesOnce` helper directly.
@MainActor
struct CatalogWindowViewModelMediaOperationsTests {
    private static let cardPath = LibraryRootPath(rawValue: "/Volumes/CARD")
    private static let otherPath = LibraryRootPath(rawValue: "/Volumes/OTHER")
    private static let libraryPath = LibraryRootPath(rawValue: "/Users/example/Pictures")
    private static let batchID = ImportBatchID(unixMilliseconds: 1_704_067_200_000)

    private static func presentation(
        batchID: ImportBatchID?,
        state: MediaOperationSourceState = .executing(
            progress: MediaOperationProgress(
                completedCount: 1,
                totalCount: 2,
                completedBytes: 1,
                totalBytes: 2,
                elapsedMs: 0
            )
        ),
        cardStillExists: Bool = true,
        copiedJustNow: Int? = nil,
        isFullyClean: Bool? = nil,
        sessionPreferences: ImportPreferences = .default,
        // The production default for an exposed `.executing` batch: the
        // coordinator withholds the ID until the first asset has landed.
        batchHasPublishedAssets: Bool = true
    ) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: cardPath,
            sourceKind: .removableVolume,
            destinationPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
            destinationDisplayName: "Pictures",
            state: state,
            attachToReadyMs: nil,
            batchID: batchID,
            batchHasPublishedAssets: batchID != nil && batchHasPublishedAssets,
            cardStillExists: cardStillExists,
            copiedJustNow: copiedJustNow,
            isFullyClean: isFullyClean,
            stopReason: nil,
            plannedCount: nil,
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

    /// `import-bar.md` state F, "Dismissal": a run that finished with skips or
    /// failures keeps its bar on the batch row — the `Show them` reveal lives
    /// there — however long the card has been gone.
    @Test func nonCleanSettleKeepsTheBarOnTheBatchRow() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([
            Self.presentation(
                batchID: Self.batchID,
                state: .completed(
                    summary: MediaOperationPlanTotals(
                        copyCount: 5,
                        skipCount: 1,
                        blockedCount: 0,
                        companionCopyCount: 0,
                        copyBytes: 0
                    )
                ),
                cardStillExists: false,
                isFullyClean: false
            ),
        ])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
        #expect(model.selectedImportPresentation != nil)
    }

    /// A fully clean live settle leaves the batch row immediately. A clean
    /// detached snapshot is not an unresolved outcome and must not navigate to
    /// that transient row.
    @Test func cleanSettleLeavesTheBatchRowImmediatelyAndKeepsTheCardRow() {
        for cardStillExists in [false, true] {
            let model = makeModel()
            model.selectSidebar(.library(Self.cardPath))
            let settled = Self.presentation(
                batchID: Self.batchID,
                state: .completed(
                    summary: MediaOperationPlanTotals(
                        copyCount: 5,
                        skipCount: 0,
                        blockedCount: 0,
                        companionCopyCount: 0,
                        copyBytes: 0
                    )
                ),
                cardStillExists: cardStillExists,
                isFullyClean: true
            )
            model.applyImportPresentations([settled])
            #expect(
                model.sidebarSelection == (cardStillExists ? .importBatch(Self.batchID) : .library(Self.cardPath)),
                "cardStillExists=\(cardStillExists)"
            )
            #expect(model.selectedImportPresentation == nil, "cardStillExists=\(cardStillExists)")

            guard cardStillExists else { continue }
            model.applyState(Self.state(
                resolvedSidebarSelection: .library(Self.cardPath),
                importBatches: [ImportBatchSummary(batchID: Self.batchID, assetCount: 5)],
                queryGeneration: model.queryGeneration,
                libraries: [Self.library(Self.libraryPath)],
                removableSources: [Self.card(Self.cardPath)]
            ))
            model.selectSidebar(.library(Self.cardPath))
            #expect(model.sidebarSelection == .library(Self.cardPath))
            #expect(model.selectedImportPresentation == settled)
        }
    }

    // MARK: - Following the items when the card's own row disappears

    /// `import-bar.md` "Where the user is standing": ejecting after an import
    /// removes the row the user is standing on, and the forced re-resolution
    /// lands on the batch holding the items that source just produced rather
    /// than on `defaultSelection`'s unrelated answer. This is what makes the
    /// card-gone Done bar honest without a `Show These Items` button.
    @Test func ejectingTheSelectedCardFollowsItsImportBatch() {
        let model = makeModel()
        // The user walked back to the card's own row after the import.
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        model.selectSidebar(.library(Self.cardPath))

        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.cardPath),
            importBatches: [ImportBatchSummary(batchID: Self.batchID, assetCount: 42)],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)],
            removableSources: []
        ))
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
    }

    /// The batch ID is read from the ViewModel's own memory of that source's
    /// run, not from `importPresentations`, so a detach frame that clears the
    /// coordinator's presentations before the catalog publish arrives cannot
    /// change where the user lands.
    @Test func ejectFollowsTheBatchEvenWhenPresentationsAreAlreadyGone() {
        let model = makeModel()
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([])

        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.cardPath),
            importBatches: [ImportBatchSummary(batchID: Self.batchID, assetCount: 42)],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)]
        ))
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
    }

    /// Nothing was imported from this card, so there is no batch to follow and
    /// the ordinary fallback stands.
    @Test func ejectingACardThatImportedNothingFallsBackNormally() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))

        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.libraryPath),
            importBatches: [],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)]
        ))
        #expect(model.sidebarSelection == .library(Self.libraryPath))
    }

    /// Adversarial: the same card comes back, and this time nothing is
    /// imported from it. The remembered batch belongs to the *previous*
    /// attachment, so ejecting again must fall back normally rather than drag
    /// the user to a batch this attachment did not produce.
    @Test func aReattachedCardThatImportsNothingDoesNotFollowThePreviousBatch() {
        let model = makeModel()
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        // Ejected: the live session is gone and only the detached snapshot,
        // which still carries that batch under the same source path, remains.
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID, cardStillExists: false)])
        // Re-inserted: a fresh session with no batch of its own.
        model.applyImportPresentations([
            Self.presentation(batchID: nil, state: .inventory),
            Self.presentation(batchID: Self.batchID, cardStillExists: false),
        ])
        model.selectSidebar(.library(Self.cardPath))

        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.libraryPath),
            importBatches: [ImportBatchSummary(batchID: Self.batchID, assetCount: 42)],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)]
        ))
        #expect(model.sidebarSelection == .library(Self.libraryPath))
    }

    /// The card is still attached, so nothing is forced: the user stays where
    /// they chose to stand (rule 2, "never move them twice").
    @Test func theStillAttachedCardRowIsNeverPulledToItsBatch() {
        let model = makeModel()
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID)])
        model.selectSidebar(.library(Self.cardPath))

        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.cardPath),
            importBatches: [ImportBatchSummary(batchID: Self.batchID, assetCount: 42)],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)],
            removableSources: [Self.card(Self.cardPath)]
        ))
        #expect(model.sidebarSelection == .library(Self.cardPath))
    }

    // MARK: - A batch is followed only once it has something to show (APP-029)

    /// A run refused before any copy still carries its batch — identity, for
    /// state G and detach — but its row has nothing in it. Moving the user
    /// there leaves the sidebar and the grid disagreeing, so the selection
    /// stays where the user was standing.
    @Test func autoSelectDoesNotFollowABatchWithNothingInIt() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(
            batchID: Self.batchID,
            state: .failed(reason: .destinationUnavailable, publishedCount: 0),
            batchHasPublishedAssets: false
        )])
        #expect(model.sidebarSelection == .library(Self.cardPath))
    }

    /// A source-removal failure with no published assets keeps its batch-level
    /// facts available to an already selected batch, but never navigates from
    /// the vanished card to an empty batch row.
    @Test func detachedZeroPublishedFailureDoesNotFollowAnEmptyBatch() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(
            batchID: Self.batchID,
            state: .failed(reason: .sourceRemoved, publishedCount: 0),
            cardStillExists: false,
            batchHasPublishedAssets: false
        )])
        #expect(model.sidebarSelection == .library(Self.cardPath))
    }

    /// An empty batch is not "spent" by being seen: the first frame that
    /// proves it non-empty still gets the once-only move, which is how a live
    /// execution's first landed asset pulls the user to the batch row.
    @Test func anEmptyBatchStillFollowsOnceItHasSomethingToShow() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID, batchHasPublishedAssets: false)])
        #expect(model.sidebarSelection == .library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(batchID: Self.batchID, batchHasPublishedAssets: true)])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
    }

    /// A settled run that copied something is followed as before.
    @Test func autoSelectFollowsASettledBatchThatCopiedSomething() {
        let model = makeModel()
        model.selectSidebar(.library(Self.cardPath))
        model.applyImportPresentations([Self.presentation(
            batchID: Self.batchID,
            state: .completed(summary: MediaOperationPlanTotals(
                copyCount: 5,
                skipCount: 0,
                blockedCount: 0,
                companionCopyCount: 0,
                copyBytes: 5
            )),
            copiedJustNow: 5,
            isFullyClean: true,
            batchHasPublishedAssets: true
        )])
        #expect(model.sidebarSelection == .importBatch(Self.batchID))
    }

    /// The 2026-09-13 shape: two runs refused before any copy, seconds apart.
    /// Each mints its own batch; neither has anything to show. With the
    /// selection left on the card, the footer keeps matching by source path
    /// and stays mounted through the second refusal instead of unmounting
    /// until the next catalog publish resolves a dangling batch selection.
    @Test func aSecondRefusedRunLeavesTheFooterMounted() {
        let model = makeModel()
        model.applyState(Self.state(
            resolvedSidebarSelection: .library(Self.cardPath),
            importBatches: [],
            queryGeneration: model.queryGeneration,
            libraries: [Self.library(Self.libraryPath)],
            removableSources: [Self.card(Self.cardPath)]
        ))
        model.selectSidebar(.library(Self.cardPath))
        let first = ImportBatchID(unixMilliseconds: 1_789_344_644_250)
        let second = ImportBatchID(unixMilliseconds: 1_789_344_656_054)
        for batch in [first, second] {
            model.applyImportPresentations([Self.presentation(
                batchID: batch,
                state: .failed(reason: .destinationUnavailable, publishedCount: 0),
                batchHasPublishedAssets: false
            )])
        }
        #expect(model.sidebarSelection == .library(Self.cardPath))
        #expect(model.selectedImportPresentation?.batchID == second)
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
