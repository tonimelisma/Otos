import Foundation
@testable import OtosKit
import Testing

struct SidebarSelectionPolicyTests {
    private let pictures = CatalogLibraryState(
        root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
        availability: .available,
        activity: .idle
    )
    private let archive = CatalogLibraryState(
        root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive")),
        availability: .available,
        activity: .idle
    )

    // Validates: APP-002
    @Test func showsAllMediaRequiresTwoFixedLibraries() {
        #expect(!SidebarSelectionPolicy.showsAllMedia(libraries: []))
        #expect(!SidebarSelectionPolicy.showsAllMedia(libraries: [pictures]))
        #expect(SidebarSelectionPolicy.showsAllMedia(libraries: [pictures, archive]))
    }

    // Validates: APP-057
    /// Places needs one fixed library to map and never a located item: the row is
    /// there to be found, and the sidebar does not reflow as enrichment finds places.
    @Test func showsPlacesRequiresOneFixedLibrary() {
        let card = removableSource(path: "/Volumes/CARD", identity: .volume(uuid: "card"))
        #expect(!SidebarSelectionPolicy.showsPlaces(libraries: []))
        #expect(!SidebarSelectionPolicy.showsPlaces(libraries: [card]))
        #expect(SidebarSelectionPolicy.showsPlaces(libraries: [pictures]))
        #expect(SidebarSelectionPolicy.showsPlaces(libraries: [pictures, archive]))
    }

    // Validates: ARC-005, APP-002
    @Test func defaultSelectionPrefersConnectedRemovable() {
        let older = removableSource(
            path: "/Volumes/OLD",
            identity: .volume(uuid: "old"),
            lastSeenAt: Date(timeIntervalSince1970: 1)
        )
        let newer = removableSource(
            path: "/Volumes/NEW",
            identity: .volume(uuid: "new"),
            lastSeenAt: Date(timeIntervalSince1970: 2)
        )
        let selection = SidebarSelectionPolicy.defaultSelection(
            libraries: [pictures, archive],
            removableSources: [older, newer]
        )
        #expect(selection == .library(newer.path))
    }

    @Test func defaultSelectionUsesSingleLibraryWhenNoRemovable() {
        let selection = SidebarSelectionPolicy.defaultSelection(
            libraries: [pictures],
            removableSources: []
        )
        #expect(selection == .library(pictures.path))
    }

    @Test func defaultSelectionUsesAllMediaWithMultipleLibrariesAndNoRemovable() {
        let selection = SidebarSelectionPolicy.defaultSelection(
            libraries: [pictures, archive],
            removableSources: []
        )
        #expect(selection == .allMedia)
    }

    // Validates: ARC-005
    @Test func selectionOnSelectedSourceRemovedMatchesDefault() {
        let card = removableSource(path: "/Volumes/CARD", identity: .volume(uuid: "card"))
        let removed = SidebarSelectionPolicy.selectionOnSelectedSourceRemoved(
            libraries: [pictures],
            removableSources: [card]
        )
        let defaultSelection = SidebarSelectionPolicy.defaultSelection(
            libraries: [pictures],
            removableSources: [card]
        )
        #expect(removed == defaultSelection)
    }

    @Test func sidebarVisibleRemovableSourcesFiltersUnavailable() {
        let available = removableSource(path: "/Volumes/CARD", identity: .volume(uuid: "card"))
        var unavailable = removableSource(path: "/Volumes/GONE", identity: .volume(uuid: "gone"))
        unavailable = CatalogLibraryState(
            root: unavailable.root,
            availability: .unavailable,
            activity: .idle,
            isEjectable: unavailable.isEjectable
        )
        let visible = SidebarSelectionPolicy.sidebarVisibleRemovableSources([available, unavailable])
        #expect(visible == [available])
    }

    // MARK: - Selection on attach (APP-002)

    // Validates: ARC-005
    @Test func selectionOnAttachSelectsANewlyAttachedCard() {
        let card = removableSource(path: "/Volumes/CARD", identity: .volume(uuid: "card"), attachmentGeneration: 1)
        #expect(SidebarSelectionPolicy.selectionOnAttach(previous: [], next: [card]) == .library(card.path))
    }

    // Validates: APP-002
    @Test func selectionOnAttachSelectsAReinsertedCardAgain() {
        let detached = removableSource(
            path: "/Volumes/CARD", identity: .volume(uuid: "card"), availability: .unavailable, attachmentGeneration: 1
        )
        let reinserted = removableSource(path: "/Volumes/CARD", identity: .volume(uuid: "card"), attachmentGeneration: 2)
        let selection = SidebarSelectionPolicy.selectionOnAttach(previous: [detached], next: [reinserted])
        #expect(selection == .library(reinserted.path))
    }

    // Validates: APP-002
    /// An availability or activity change is not an attach: the generation is the
    /// Store's proof that a mount happened, so a flap never moves the user again.
    @Test func selectionOnAttachIgnoresASourceWhoseAttachmentIsUnchanged() {
        let flapped = removableSource(
            path: "/Volumes/CARD", identity: .volume(uuid: "card"), availability: .unavailable, attachmentGeneration: 1
        )
        let card = removableSource(path: "/Volumes/CARD", identity: .volume(uuid: "card"), attachmentGeneration: 1)
        #expect(SidebarSelectionPolicy.selectionOnAttach(previous: [card], next: [card]) == nil)
        #expect(SidebarSelectionPolicy.selectionOnAttach(previous: [flapped], next: [card]) == nil)
    }

    @Test func selectionOnAttachIgnoresSourcesThatAreNotConnectedOrNeverAttached() {
        let unattached = removableSource(path: "/Volumes/OLD", identity: .volume(uuid: "old"))
        let unavailable = removableSource(
            path: "/Volumes/GONE", identity: .volume(uuid: "gone"), availability: .unavailable, attachmentGeneration: 3
        )
        #expect(SidebarSelectionPolicy.selectionOnAttach(previous: [], next: [unattached, unavailable]) == nil)
    }

    @Test func selectionOnAttachPrefersTheMostRecentlyAttached() {
        let older = removableSource(
            path: "/Volumes/OLD", identity: .volume(uuid: "old"), lastSeenAt: Date(timeIntervalSince1970: 1),
            attachmentGeneration: 1
        )
        let newer = removableSource(
            path: "/Volumes/NEW", identity: .volume(uuid: "new"), lastSeenAt: Date(timeIntervalSince1970: 2),
            attachmentGeneration: 1
        )
        #expect(SidebarSelectionPolicy.selectionOnAttach(previous: [], next: [older, newer]) == .library(newer.path))
    }

    private func removableSource(
        path: String,
        identity: DeviceIdentity,
        lastSeenAt: Date = Date(),
        availability: LibraryAvailability = .available,
        attachmentGeneration: UInt64 = 0
    ) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(
                path: LibraryRootPath(rawValue: path),
                kind: .removableVolume,
                deviceIdentity: identity,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                lastSeenAt: lastSeenAt
            ),
            availability: availability,
            activity: .idle,
            isEjectable: true,
            attachmentGeneration: attachmentGeneration
        )
    }

    // MARK: - Status ownership (`import-bar.md` "Ownership of status")

    private static let cardPath = LibraryRootPath(rawValue: "/Volumes/CARD")
    private static let batchID = ImportBatchID(unixMilliseconds: 1_704_067_200_000)

    private static func presentation(
        state: MediaOperationSourceState,
        batchID: ImportBatchID? = nil
    ) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: cardPath,
            sourceKind: .removableVolume,
            destinationPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
            destinationDisplayName: "Pictures",
            state: state,
            attachToReadyMs: nil,
            runBatchID: batchID,
            copiedJustNow: nil,
            isFullyClean: nil,
            stopReason: nil,
            plannedCount: nil,
            sessionPreferences: .default,
            incompleteItems: []
        )
    }

    // Validates: APP-002, APP-029
    @Test func barOwnsStatusOnTheCardRowAndItsRunsBatchRow() {
        let pres = Self.presentation(
            state: .executing(progress: MediaOperationProgress(
                completedCount: 1,
                totalCount: 2,
                completedBytes: 1,
                totalBytes: 2,
                elapsedMs: 0
            )),
            batchID: Self.batchID
        )
        // The bar is drawn on the card's row and on its run's batch row; any other
        // batch row, and any other row, leaves it off screen.
        #expect(SidebarSelectionPolicy.barOwnsStatus(sidebarSelection: .importBatch(Self.batchID), presentation: pres))
        #expect(SidebarSelectionPolicy.barOwnsStatus(sidebarSelection: .library(Self.cardPath), presentation: pres))
        #expect(!SidebarSelectionPolicy.barOwnsStatus(
            sidebarSelection: .importBatch(ImportBatchID(unixMilliseconds: 1)),
            presentation: pres
        ))
        #expect(!SidebarSelectionPolicy.barOwnsStatus(sidebarSelection: .allMedia, presentation: pres))
    }

    @Test func removableIndicatorShowsIndeterminateBeforeBatchExists() {
        let pres = Self.presentation(state: .inventory)
        #expect(SidebarSelectionPolicy.removableIndicator(presentation: pres, sidebarSelection: .allMedia)
            == .indeterminate)
    }

    @Test func removableIndicatorShowsDeterminateCountWhilePreparing() {
        let pres = Self.presentation(state: .waitingForMetadata(done: 3, total: 10))
        #expect(SidebarSelectionPolicy.removableIndicator(presentation: pres, sidebarSelection: .allMedia)
            == .determinate(completed: 3, total: 10))
    }

    // Validates: APP-002
    @Test func removableIndicatorHidesWhenBarOwnsStatus() {
        let pres = Self.presentation(state: .inventory)
        #expect(SidebarSelectionPolicy.removableIndicator(
            presentation: pres,
            sidebarSelection: .library(Self.cardPath)
        ) == .none)
    }

    @Test func removableIndicatorHidesWhileExecuting() {
        // A run's progress is the batch row's indicator — the removable row
        // shows nothing even though the user is looking elsewhere.
        let pres = Self.presentation(
            state: .executing(progress: MediaOperationProgress(
                completedCount: 1,
                totalCount: 2,
                completedBytes: 1,
                totalBytes: 2,
                elapsedMs: 0
            )),
            batchID: Self.batchID
        )
        #expect(SidebarSelectionPolicy.removableIndicator(presentation: pres, sidebarSelection: .allMedia) == .none)
    }

    // Validates: APP-002
    @Test func batchIndicatorHidesWhereverTheBarIsDrawn() {
        let pres = Self.presentation(
            state: .executing(progress: MediaOperationProgress(
                completedCount: 4,
                totalCount: 9,
                completedBytes: 1,
                totalBytes: 2,
                elapsedMs: 0
            )),
            batchID: Self.batchID
        )
        // Elsewhere the bar is off screen, so the batch row carries the progress;
        // on the batch row itself and on the card's row the bar does.
        let indicator = SidebarSelectionPolicy.batchIndicator(
            batchID: Self.batchID,
            presentations: [pres],
            sidebarSelection: .allMedia
        )
        #expect(indicator == .determinate(completed: 4, total: 9))
        let indicatorFromItsOwnRow = SidebarSelectionPolicy.batchIndicator(
            batchID: Self.batchID,
            presentations: [pres],
            sidebarSelection: .importBatch(Self.batchID)
        )
        #expect(indicatorFromItsOwnRow == .none)
        let indicatorFromLibraryRow = SidebarSelectionPolicy.batchIndicator(
            batchID: Self.batchID,
            presentations: [pres],
            sidebarSelection: .library(Self.cardPath)
        )
        #expect(indicatorFromLibraryRow == .none)
    }

    @Test func batchIndicatorHidesForTerminalStates() {
        let pres = Self.presentation(
            state: .completed(summary: MediaOperationPlanTotals(
                copyCount: 5,
                skipCount: 0,
                blockedCount: 0,
                companionCopyCount: 0,
                copyBytes: 0
            )),
            batchID: Self.batchID
        )
        let indicator = SidebarSelectionPolicy.batchIndicator(
            batchID: Self.batchID,
            presentations: [pres],
            sidebarSelection: .allMedia
        )
        #expect(indicator == .none)
    }
}
