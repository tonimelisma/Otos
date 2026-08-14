import AppKit
import Foundation

/// Recoverable deletion intent guide
///
/// The ViewModel resolves the same current target model as curation, snapshots the
/// visible context, and hands filesystem ownership to `MediaTrashCoordinator`. Store
/// reconciliation is always applied for paths the filesystem reports moved; only
/// navigation is rejected when the user changed mode, query, or pane ownership while
/// the command was suspended.
extension CatalogWindowViewModel {
    var canMoveTargetedMediaToTrash: Bool {
        guard mediaTrashTask == nil else {
            return false
        }
        let ids = mediaChoiceTargetIDs(.current)
        guard !ids.isEmpty else {
            return false
        }
        let roots = Dictionary(
            uniqueKeysWithValues: (state.libraries + state.removableSources).map { ($0.path, $0.root) }
        )
        return ids.allSatisfy { roots[$0.libraryRootPath]?.kind != .deviceMTP }
    }

    func moveTargetedMediaToTrash() {
        guard canMoveTargetedMediaToTrash else {
            return
        }
        let ids = mediaChoiceTargetIDs(.current)
        let orderedIDs = state.mediaGrid.orderedAssetIDs
        let removed = Set(ids)
        let successor = ids
            .compactMap { orderedIDs.firstIndex(of: $0) }
            .max()
            .flatMap { index in
                orderedIDs.dropFirst(index + 1).first { !removed.contains($0) }
            }
        let mode = viewMode
        let descriptor = queryDescriptor
        let pair = comparePair
        let pane = activeComparePane
        let coordinator = mediaTrashCoordinator ?? MediaTrashCoordinator(store: catalogStore)
        mediaTrashCoordinator = coordinator
        mediaTrashTask = Task { [weak self, store = catalogStore, coordinator] in
            do {
                let result = try await coordinator.moveToTrash(for: ids)
                await store.reconcileTrashedPaths(result.successfulPaths)
                guard let self else { return }
                finishMediaTrash(
                    result,
                    originalIDs: ids,
                    mode: mode,
                    descriptor: descriptor,
                    comparePair: pair,
                    comparePane: pane,
                    successor: successor
                )
                mediaTrashTask = nil
            } catch {
                guard let self else { return }
                trashAlertMessage = ids.count == 1
                    ? "This Item Couldn't Be Moved to Trash"
                    : "Some Items Couldn't Be Moved to Trash"
                trashFailedIDs = ids
                mediaTrashTask = nil
            }
        }
    }

    private func finishMediaTrash(
        _ result: MediaTrashBatchResult,
        originalIDs: [MediaAssetID],
        mode: BrowserViewMode,
        descriptor: CatalogQueryDescriptor,
        comparePair: ComparePair,
        comparePane: PanePosition,
        successor: MediaAssetID?
    ) {
        let failedIDs = result.failedItems.map(\.id)
        trashFailedIDs = failedIDs
        if !failedIDs.isEmpty {
            trashAlertMessage = failedIDs.count == 1
                ? "This Item Couldn't Be Moved to Trash"
                : "Some Items Couldn't Be Moved to Trash"
        }
        guard failedIDs.isEmpty,
              viewMode == mode,
              queryDescriptor == descriptor
        else {
            return
        }

        let movedIDs = Set(result.successfulPaths.map(\.id))
        let survivors = state.mediaGrid.orderedAssetIDs.filter { !movedIDs.contains($0) }
        switch mode {
        case .grid:
            if let successor, survivors.contains(successor) {
                gridSelection = gridSelection.plainClick(successor)
            } else {
                clearGridSelection(reason: "trashCompleted")
            }
        case .loupe:
            setFocus(successor.flatMap { survivors.contains($0) ? $0 : survivors.first })
            if let focusedAssetID {
                gridSelection = gridSelection.plainClick(focusedAssetID)
            }
            refreshPanePreviews()
        case .compare:
            guard self.comparePair == comparePair, activeComparePane == comparePane else {
                return
            }
            let next = ComparePairPolicy.prune(
                pair: comparePair,
                previousOrderedIDs: orderedIDsBeforeTrash(originalIDs: originalIDs),
                survivingOrderedIDs: survivors
            )
            applyComparePair(next, orderedIDs: survivors)
        }
    }

    private func orderedIDsBeforeTrash(originalIDs: [MediaAssetID]) -> [MediaAssetID] {
        state.mediaGrid.orderedAssetIDs + originalIDs.filter { !state.mediaGrid.orderedAssetIDs.contains($0) }
    }

    func showFailedTrashItemsInFinder() {
        let urls = trashFailedIDs.map(\.fileURL)
        guard let first = urls.first else { return }
        NSWorkspace.shared.selectFile(first.path, inFileViewerRootedAtPath: first.deletingLastPathComponent().path)
        trashAlertMessage = nil
    }

    func dismissTrashAlert() {
        trashAlertMessage = nil
    }
}
