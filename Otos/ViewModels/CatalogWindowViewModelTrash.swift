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
/// Every surface — Photo menu, ⌘⌫, context menu, toolbar Action menu — calls
/// `moveTargetedMediaToTrash()`, which acts at once: the act is undoable, so it asks
/// nothing first (HIG: no alerts for common, undoable actions; Plan 0104 D1).
///
/// Undo (APP-039). Once the Store has hidden the items, `Undo Move to Trash` is
/// registered on the window's one undo manager. Undo and redo register their opposite
/// entry synchronously at fire time, as curation's do, then hand the work to the
/// queue: undo asks `MediaTrashCoordinator.undo` to withdraw what is still pending and
/// put back what is in the Trash; redo marks the restored items pending again under a
/// new command identity.
///
/// The queue reports back through one event stream consumed here: its state feeds the
/// bottom status bar, its decisions queue as prompts (D3/D4 of Plan 0104), and a move
/// that failed after download re-shows the failure alert.
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

    /// Hides the targets behind one pending Move to Trash and hands them to the queue.
    /// `mediaTrashTask` covers only the Store mark, so a second command waits for the
    /// first to be recorded rather than racing it.
    func moveTargetedMediaToTrash() {
        guard canMoveTargetedMediaToTrash else {
            return
        }
        let ids = mediaChoiceTargetIDs(.current)
        guard asksBeforeLargeTrashDownload else {
            performMoveToTrash(ids)
            return
        }
        // Sizing reads member status off the MainActor; `mediaTrashTask` keeps a second
        // command from starting until this one has either asked or moved.
        let coordinator = mediaTrashCoordinator
        mediaTrashTask = Task { [weak self, coordinator] in
            let bytes = await coordinator.downloadBytes(for: ids)
            guard let self else { return }
            mediaTrashTask = nil
            if LargeTrashDownloadPrompt.asks(bytes: bytes, preference: asksBeforeLargeTrashDownload) {
                largeTrashDownloadPrompt = LargeTrashDownloadPrompt(ids: ids, bytes: bytes)
                OtosLog.ui.notice(
                    "op=mediaTrash.prompt phase=shown count=\(ids.count, privacy: .public) bytes=\(bytes, privacy: .public)"
                )
            } else {
                performMoveToTrash(ids)
            }
        }
    }

    /// `Download and Move to Trash`: the items the user was asked about are moved.
    func confirmLargeTrashDownload() {
        guard let prompt = largeTrashDownloadPrompt else { return }
        largeTrashDownloadPrompt = nil
        OtosLog.ui.notice("op=mediaTrash.prompt phase=confirmed count=\(prompt.ids.count, privacy: .public)")
        performMoveToTrash(prompt.ids)
    }

    func cancelLargeTrashDownload() {
        guard let prompt = largeTrashDownloadPrompt else { return }
        largeTrashDownloadPrompt = nil
        OtosLog.ui.notice("op=mediaTrash.prompt phase=cancelled count=\(prompt.ids.count, privacy: .public)")
    }

    /// The one writer of the large-download preference: Settings ▸ General and the
    /// prompt's `Do not ask again` both call it.
    func setAsksBeforeLargeTrashDownload(_ asks: Bool) {
        guard asksBeforeLargeTrashDownload != asks else { return }
        asksBeforeLargeTrashDownload = asks
        preferences.set(asks, forKey: Self.asksBeforeLargeTrashDownloadDefaultsKey)
        OtosLog.ui.notice("op=mediaTrash.prompt phase=\(asks ? "enabled" : "suppressed", privacy: .public)")
    }

    private func performMoveToTrash(_ ids: [MediaAssetID]) {
        guard mediaTrashTask == nil, !ids.isEmpty else {
            return
        }
        let context = TrashNavigationContext(
            mode: viewMode,
            descriptor: queryDescriptor,
            comparePair: comparePair,
            comparePane: activeComparePane,
            orderedIDs: state.mediaGrid.orderedAssetIDs
        )
        startMediaTrash()
        let coordinator = mediaTrashCoordinator
        OtosLog.ui.notice("op=trash.move phase=start count=\(ids.count, privacy: .public)")
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
            if !hidden.isEmpty {
                registerTrashUndo(batch: batch, ids: hidden)
            }
            navigateAfterHiding(Set(hidden), context: context)
            mediaTrashTask = nil
        }
    }

    // MARK: - Undo

    static let moveToTrashActionName = "Move to Trash"

    private func registerTrashUndo(batch: MediaTrashBatchID, ids: [MediaAssetID]) {
        // Explicit group: registration happens after a Store await, outside any event.
        curationUndoManager.beginUndoGrouping()
        curationUndoManager.registerUndo(withTarget: self) { model in
            model.undoMoveToTrash(batch: batch, ids: ids)
        }
        curationUndoManager.setActionName(Self.moveToTrashActionName)
        curationUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()`: files redo synchronously, then asks the queue
    /// to withdraw or put back the command's items.
    private func undoMoveToTrash(batch: MediaTrashBatchID, ids: [MediaAssetID]) {
        curationUndoManager.registerUndo(withTarget: self) { model in
            model.redoMoveToTrash(ids: ids)
        }
        curationUndoManager.setActionName(Self.moveToTrashActionName)
        let coordinator = mediaTrashCoordinator
        OtosLog.ui.notice("op=trash.undo phase=start count=\(ids.count, privacy: .public)")
        Task { [weak self] in
            let outcome = await coordinator.undo(batch: batch, ids: ids)
            guard let self else { return }
            OtosLog.ui.notice(
                """
                op=trash.undo phase=finish restored=\(outcome.restored.count, privacy: .public) \
                failed=\(outcome.failed.count, privacy: .public)
                """
            )
            if !outcome.failed.isEmpty {
                trashFailedIDs = outcome.failed
                trashAlertDetail = TrashAlertCopy.putBackDetail
                trashAlertMessage = outcome.failed.count == 1
                    ? TrashAlertCopy.putBackFailedOne
                    : TrashAlertCopy.putBackFailedMany
            }
        }
    }

    /// Runs inside `UndoManager.redo()`: files undo synchronously under a new command
    /// identity, then hides the items again for the queue.
    private func redoMoveToTrash(ids: [MediaAssetID]) {
        let batch = MediaTrashBatchID()
        curationUndoManager.registerUndo(withTarget: self) { model in
            model.undoMoveToTrash(batch: batch, ids: ids)
        }
        curationUndoManager.setActionName(Self.moveToTrashActionName)
        let coordinator = mediaTrashCoordinator
        OtosLog.ui.notice("op=trash.redo phase=start count=\(ids.count, privacy: .public)")
        Task { [store = catalogStore] in
            _ = try? await store.markPendingTrash(ids, batch: batch)
            coordinator.kick()
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
            trashAlertDetail = TrashAlertCopy.moveDetail
            trashAlertMessage = ids.count == 1 ? TrashAlertCopy.moveFailedOne : TrashAlertCopy.moveFailedMany
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

    /// Lands on the nearest survivor of the last hidden item in the order the user saw
    /// when issuing the command: the next one, or the previous one when the hidden items
    /// ended the list (`BrowserModePolicy.nearestSurvivor`).
    private func navigateAfterHiding(
        _ hidden: Set<MediaAssetID>,
        context: TrashNavigationContext
    ) {
        guard !hidden.isEmpty,
              viewMode == context.mode,
              queryDescriptor == context.descriptor
        else {
            return
        }
        let survivors = state.mediaGrid.orderedAssetIDs.filter { !hidden.contains($0) }
        let successor = context.orderedIDs.last(where: hidden.contains).flatMap { lastHidden in
            BrowserModePolicy.nearestSurvivor(
                of: lastHidden,
                previousOrderedIDs: context.orderedIDs,
                surviving: Set(survivors)
            )
        }
        OtosLog.ui.notice(
            "op=trash.navigate mode=\(context.mode.rawValue, privacy: .public) successor=\(successor?.relativePath.rawValue ?? "none", privacy: .public)"
        )
        switch context.mode {
        case .grid:
            if let successor {
                gridSelection = gridSelection.plainClick(successor)
            } else {
                clearGridSelection(reason: "trashCompleted")
            }
        case .loupe:
            setFocus(successor)
            if let successor {
                gridSelection = gridSelection.plainClick(successor)
            }
            refreshPanePreviews()
        case .compare:
            guard comparePair == context.comparePair, activeComparePane == context.comparePane else {
                return
            }
            let next = ComparePairPolicy.prune(
                pair: context.comparePair,
                previousOrderedIDs: context.orderedIDs,
                survivingOrderedIDs: survivors
            )
            applyComparePair(next, orderedIDs: survivors)
        }
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
    /// The display order when the command was issued: the frame of reference for
    /// where navigation lands once the targets are hidden.
    let orderedIDs: [MediaAssetID]
}
