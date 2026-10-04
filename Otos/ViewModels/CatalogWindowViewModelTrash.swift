import AppKit
import Foundation
import OSLog

/// Recoverable deletion intent guide
///
/// The ViewModel resolves the same current target model as curation, snapshots the
/// visible context, and hides the targets by marking them pending in the Store; the
/// durable queue in `MediaTrashCoordinator` owns every filesystem move from there.
/// Navigation after hiding is rejected when the user changed mode, query, or pane
/// ownership while the mark was suspended.
///
/// Every surface — Photo menu, ⌘⌫, context menu — calls `requestMoveTargetedMediaToTrash()`,
/// which publishes a `TrashConfirmation` the window renders as a confirmation dialog;
/// only its confirm action runs `moveTargetedMediaToTrash()`. The targets are resolved
/// again at confirmation so a selection changed under an open dialog is never trashed.
///
/// The queue reports back through one event stream consumed here: its state feeds the
/// bottom status bar, its decisions queue as prompts (D3/D4 of Plan 0104), and a move
/// that failed after download re-shows the existing failure alert.
extension CatalogWindowViewModel {
    /// Photo ▸ Move to Trash, ⌘⌫, and the context menu item.
    func requestMoveTargetedMediaToTrash() {
        guard canMoveTargetedMediaToTrash else {
            return
        }
        let ids = mediaChoiceTargetIDs(.current)
        pendingTrashConfirmation = TrashConfirmation(ids: ids)
        OtosLog.ui.notice("op=trash.confirm phase=ask count=\(ids.count, privacy: .public)")
    }

    func confirmMoveToTrash() {
        guard let pending = pendingTrashConfirmation else {
            return
        }
        pendingTrashConfirmation = nil
        OtosLog.ui.notice("op=trash.confirm phase=confirmed count=\(pending.count, privacy: .public)")
        moveTargetedMediaToTrash()
    }

    func cancelMoveToTrash() {
        guard let pending = pendingTrashConfirmation else {
            return
        }
        pendingTrashConfirmation = nil
        OtosLog.ui.notice("op=trash.confirm phase=cancelled count=\(pending.count, privacy: .public)")
    }

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

    /// Hides the targets behind one pending Move to Trash and hands them to the queue.
    /// `mediaTrashTask` covers only the Store mark, so a second command waits for the
    /// first to be recorded rather than racing it.
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
        let context = TrashNavigationContext(
            mode: viewMode,
            descriptor: queryDescriptor,
            comparePair: comparePair,
            comparePane: activeComparePane,
            successor: successor
        )
        startMediaTrash()
        let coordinator = mediaTrashCoordinator
        mediaTrashTask = Task { [weak self, store = catalogStore, coordinator] in
            let batch = MediaTrashBatchID()
            let hidden = await (try? store.markPendingTrash(ids, batch: batch)) ?? []
            await coordinator.start()
            coordinator.kick()
            guard let self else { return }
            OtosLog.ui.notice(
                """
                op=trash.queue phase=hidden batch=\(batch.unixMilliseconds, privacy: .public) \
                requested=\(ids.count, privacy: .public) hidden=\(hidden.count, privacy: .public)
                """
            )
            navigateAfterHiding(Set(hidden), originalIDs: ids, context: context)
            mediaTrashTask = nil
        }
    }

    /// Starts the queue (resuming pending items from an earlier run) and consumes its
    /// events. The consumer holds the ViewModel weakly across each indefinite wait.
    func startMediaTrash() {
        let coordinator = mediaTrashCoordinator
        if mediaTrashEventTask == nil {
            let events = coordinator.events
            mediaTrashEventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { break }
                    applyMediaTrashEvent(event)
                }
            }
        }
        Task { await coordinator.start() }
    }

    func applyMediaTrashEvent(_ event: MediaTrashCoordinator.Event) {
        switch event {
        case let .state(queueState):
            trashQueueState = queueState
        case let .decision(decision):
            enqueueTrashDecision(decision)
        case let .moveFailed(ids):
            trashFailedIDs = ids
            trashAlertMessage = ids.count == 1
                ? "This Item Couldn't Be Moved to Trash"
                : "Some Items Couldn't Be Moved to Trash"
            selectAssets(ids)
        }
    }

    /// Merges a decision into a queued one of the same kind so a burst of failures
    /// becomes one question, not one alert per item.
    private func enqueueTrashDecision(_ decision: MediaTrashCoordinator.Decision) {
        if let index = trashDecisions.lastIndex(where: { $0.isSameKind(as: decision) }) {
            trashDecisions[index] = trashDecisions[index].merging(decision)
        } else {
            trashDecisions.append(decision)
        }
        OtosLog.ui.notice(
            "op=trash.decision phase=ask kind=\(decision.kindName, privacy: .public) count=\(decision.ids.count, privacy: .public)"
        )
    }

    /// The user chose Delete in a decision prompt: the items are deleted immediately.
    func answerTrashDecisionDelete() {
        guard let decision = trashDecisions.first else { return }
        trashDecisions.removeFirst()
        OtosLog.ui.notice(
            "op=trash.decision phase=delete kind=\(decision.kindName, privacy: .public) count=\(decision.ids.count, privacy: .public)"
        )
        let coordinator = mediaTrashCoordinator
        Task { await coordinator.deleteImmediately(decision.ids) }
    }

    /// The user chose Cancel: a failed download's items reappear; items blocked by the
    /// free-space floor keep waiting for room.
    func answerTrashDecisionCancel() {
        guard let decision = trashDecisions.first else { return }
        trashDecisions.removeFirst()
        OtosLog.ui.notice(
            "op=trash.decision phase=cancel kind=\(decision.kindName, privacy: .public) count=\(decision.ids.count, privacy: .public)"
        )
        let coordinator = mediaTrashCoordinator
        switch decision {
        case let .downloadFailed(ids):
            Task { await coordinator.restore(ids) }
        case let .diskFloor(ids):
            Task { await coordinator.keepWaitingForSpace(ids) }
        }
    }

    private func navigateAfterHiding(
        _ hidden: Set<MediaAssetID>,
        originalIDs: [MediaAssetID],
        context: TrashNavigationContext
    ) {
        guard !hidden.isEmpty,
              viewMode == context.mode,
              queryDescriptor == context.descriptor
        else {
            return
        }
        let survivors = state.mediaGrid.orderedAssetIDs.filter { !hidden.contains($0) }
        switch context.mode {
        case .grid:
            if let successor = context.successor, survivors.contains(successor) {
                gridSelection = gridSelection.plainClick(successor)
            } else {
                clearGridSelection(reason: "trashCompleted")
            }
        case .loupe:
            setFocus(context.successor.flatMap { survivors.contains($0) ? $0 : survivors.first })
            if let focusedAssetID {
                gridSelection = gridSelection.plainClick(focusedAssetID)
            }
            refreshPanePreviews()
        case .compare:
            guard comparePair == context.comparePair, activeComparePane == context.comparePane else {
                return
            }
            let next = ComparePairPolicy.prune(
                pair: context.comparePair,
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

/// The browsing context captured when Move to Trash was issued, so navigation after
/// the Store mark lands only if the user is still where they were.
struct TrashNavigationContext {
    let mode: BrowserViewMode
    let descriptor: CatalogQueryDescriptor
    let comparePair: ComparePair
    let comparePane: PanePosition
    let successor: MediaAssetID?
}

extension MediaTrashCoordinator.Decision {
    var ids: [MediaAssetID] {
        switch self {
        case let .downloadFailed(ids), let .diskFloor(ids): ids
        }
    }

    var kindName: String {
        switch self {
        case .downloadFailed: "downloadFailed"
        case .diskFloor: "diskFloor"
        }
    }

    func isSameKind(as other: Self) -> Bool {
        kindName == other.kindName
    }

    func merging(_ other: Self) -> Self {
        let merged = ids + other.ids.filter { !ids.contains($0) }
        switch self {
        case .downloadFailed: return .downloadFailed(merged)
        case .diskFloor: return .diskFloor(merged)
        }
    }
}
