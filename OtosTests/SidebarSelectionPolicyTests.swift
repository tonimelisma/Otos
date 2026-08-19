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

    @Test func showsAllMediaRequiresTwoFixedLibraries() {
        #expect(!SidebarSelectionPolicy.showsAllMedia(libraries: []))
        #expect(!SidebarSelectionPolicy.showsAllMedia(libraries: [pictures]))
        #expect(SidebarSelectionPolicy.showsAllMedia(libraries: [pictures, archive]))
    }

    @Test func defaultSelectionPrefersConnectedRemovable() {
        let older = removableSource(
            path: "/Volumes/OLD",
            identity: "volume:old",
            lastSeenAt: Date(timeIntervalSince1970: 1)
        )
        let newer = removableSource(
            path: "/Volumes/NEW",
            identity: "volume:new",
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

    @Test func selectionOnAttachReturnsLibraryForRemovable() {
        let card = removableSource(path: "/Volumes/CARD", identity: "volume:card")
        #expect(SidebarSelectionPolicy.selectionOnAttach(attached: card) == .library(card.path))
        #expect(SidebarSelectionPolicy.selectionOnAttach(attached: pictures) == nil)
    }

    @Test func selectionOnSelectedSourceRemovedMatchesDefault() {
        let card = removableSource(path: "/Volumes/CARD", identity: "volume:card")
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
        let available = removableSource(path: "/Volumes/CARD", identity: "volume:card")
        var unavailable = removableSource(path: "/Volumes/GONE", identity: "volume:gone")
        unavailable = CatalogLibraryState(
            root: unavailable.root,
            availability: .unavailable,
            activity: .idle,
            isEjectable: unavailable.isEjectable
        )
        let visible = SidebarSelectionPolicy.sidebarVisibleRemovableSources([available, unavailable])
        #expect(visible == [available])
    }

    private func removableSource(
        path: String,
        identity: String,
        lastSeenAt: Date = Date()
    ) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(
                path: LibraryRootPath(rawValue: path),
                kind: .removableVolume,
                deviceIdentity: identity,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                lastSeenAt: lastSeenAt
            ),
            availability: .available,
            activity: .idle,
            isEjectable: true
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
            batchID: batchID,
            cardStillExists: true,
            copiedJustNow: nil,
            isFullyClean: nil,
            sessionPreferences: .default,
            incompleteItems: []
        )
    }

    @Test func barOwnsStatusMatchesLibrarySelection() {
        let pres = Self.presentation(state: .inventory)
        #expect(SidebarSelectionPolicy.barOwnsStatus(sidebarSelection: .library(Self.cardPath), presentation: pres))
        #expect(!SidebarSelectionPolicy.barOwnsStatus(sidebarSelection: .allMedia, presentation: pres))
    }

    @Test func barOwnsStatusMatchesBatchSelection() {
        let pres = Self.presentation(
            state: .executing(progress: MediaOperationProgress(completedCount: 1, totalCount: 2, completedBytes: 1, totalBytes: 2, elapsedMs: 0)),
            batchID: Self.batchID
        )
        #expect(SidebarSelectionPolicy.barOwnsStatus(sidebarSelection: .importBatch(Self.batchID), presentation: pres))
        // A batch row's presentation shares its source's sourcePath, so the
        // removable-row selection form also matches — one operation, either row.
        #expect(SidebarSelectionPolicy.barOwnsStatus(sidebarSelection: .library(Self.cardPath), presentation: pres))
        #expect(!SidebarSelectionPolicy.barOwnsStatus(
            sidebarSelection: .importBatch(ImportBatchID(unixMilliseconds: 999)),
            presentation: pres
        ))
    }

    @Test func removableIndicatorShowsIndeterminateBeforeBatchExists() {
        let pres = Self.presentation(state: .inventory)
        #expect(SidebarSelectionPolicy.removableIndicator(presentation: pres, sidebarSelection: .allMedia) == .indeterminate)
    }

    @Test func removableIndicatorShowsDeterminateCountWhilePreparing() {
        let pres = Self.presentation(state: .waitingForMetadata(done: 3, total: 10))
        #expect(SidebarSelectionPolicy.removableIndicator(presentation: pres, sidebarSelection: .allMedia) == .determinate(completed: 3, total: 10))
    }

    @Test func removableIndicatorHidesWhenBarOwnsStatus() {
        let pres = Self.presentation(state: .inventory)
        #expect(SidebarSelectionPolicy.removableIndicator(presentation: pres, sidebarSelection: .library(Self.cardPath)) == .none)
    }

    @Test func removableIndicatorHidesOnceBatchIDExists() {
        // Ownership has moved to the batch row — the removable row shows
        // nothing even though the user is looking elsewhere.
        let pres = Self.presentation(
            state: .executing(progress: MediaOperationProgress(completedCount: 1, totalCount: 2, completedBytes: 1, totalBytes: 2, elapsedMs: 0)),
            batchID: Self.batchID
        )
        #expect(SidebarSelectionPolicy.removableIndicator(presentation: pres, sidebarSelection: .allMedia) == .none)
    }

    @Test func removableIndicatorHidesWithNoPresentation() {
        #expect(SidebarSelectionPolicy.removableIndicator(presentation: nil, sidebarSelection: .allMedia) == .none)
    }

    @Test func batchIndicatorShowsDeterminateWhileExecuting() {
        let pres = Self.presentation(
            state: .executing(progress: MediaOperationProgress(completedCount: 4, totalCount: 9, completedBytes: 1, totalBytes: 2, elapsedMs: 0)),
            batchID: Self.batchID
        )
        let indicator = SidebarSelectionPolicy.batchIndicator(
            batchID: Self.batchID,
            presentations: [pres],
            sidebarSelection: .allMedia
        )
        #expect(indicator == .determinate(completed: 4, total: 9))
    }

    @Test func batchIndicatorHidesWhenBarOwnsStatus() {
        let pres = Self.presentation(
            state: .executing(progress: MediaOperationProgress(completedCount: 4, totalCount: 9, completedBytes: 1, totalBytes: 2, elapsedMs: 0)),
            batchID: Self.batchID
        )
        let indicator = SidebarSelectionPolicy.batchIndicator(
            batchID: Self.batchID,
            presentations: [pres],
            sidebarSelection: .importBatch(Self.batchID)
        )
        #expect(indicator == .none)
        let indicatorFromLibraryRow = SidebarSelectionPolicy.batchIndicator(
            batchID: Self.batchID,
            presentations: [pres],
            sidebarSelection: .library(Self.cardPath)
        )
        #expect(indicatorFromLibraryRow == .none)
    }

    @Test func batchIndicatorHidesForTerminalStates() {
        let pres = Self.presentation(
            state: .completed(summary: MediaOperationPlanTotals(copyCount: 5, skipCount: 0, blockedCount: 0, companionCopyCount: 0, copyBytes: 0)),
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
