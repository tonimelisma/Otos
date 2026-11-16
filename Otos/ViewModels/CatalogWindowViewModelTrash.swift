import AppKit
import Foundation
import OSLog

/// Recoverable deletion intent guide
///
/// The ViewModel resolves the same current target model as curation and shows the result
/// first (DES-119, APP-085): in the step that applies the intent, the targets leave the
/// window (`CatalogProjectionIntent.hide`, which Projection publishes from the order it
/// holds, with no catalog read), the selection or focus moves to the nearest survivor, and
/// `Undo Move to Trash` is registered. The Store's mark follows on the trash intent stream;
/// the durable queue in `MediaTrashCoordinator` owns every filesystem move from there.
///
/// Every surface — Photo menu, ⌘⌫, context menu, toolbar Action menu — calls
/// `moveTargetedMediaToTrash()`, which acts at once: the act is undoable, so it asks
/// nothing first (HIG: no alerts for common, undoable actions; Plan 0104 D1). The one
/// question, the large download (APP-045), is asked before anything is hidden. Its answer
/// is read when the targets change, not when the command arrives: the targets' question
/// lane (ADR 0032: a revision pair, one doorbell loop) sizes the command the current targets
/// would make off the main actor (`MediaTrashCoordinator.downloadBytes`), so a command whose
/// targets were read asks or hides in the step that applies it. Only a command that arrives
/// before its targets' reading has finished waits, for a read of its own.
///
/// Undo (APP-039). Undo and redo register their opposite entry synchronously at fire time,
/// as curation's do, then hand the work to the queue on the same stream as the mark, so an
/// undo pressed before the mark lands is applied after it: the stream's one consumer knows
/// what each command's mark hid (`hiddenByBatch`) and undoes exactly that. Undo asks
/// `MediaTrashCoordinator.undo` to withdraw what is still pending and put back what is in
/// the Trash; redo hides the items again at once and marks what the undone command hid
/// under a new command identity. A mark that fails or hides nothing takes its undo entry
/// back off the stack (`TrashUndoTarget`); a failed one puts its items back and says so.
///
/// The queue reports back through one event stream consumed here: its state feeds the
/// bottom status bar, its decisions queue as prompts (D3/D4 of Plan 0104), and a move
/// that failed after download re-shows the failure alert.
/// A Move to Trash and every user act aimed at the trash queue after it. They share one
/// lossless stream so the queue sees them in the order the user acted.
nonisolated enum TrashIntent: Sendable {
    /// Hide `items` behind the pending command `batch` in the Store. `receiptSizes` are the
    /// sizes the duplicates list showed for them, for its receipt.
    case mark(batch: MediaTrashBatchID, items: TrashMarkItems, carries: [DuplicateCarry], receiptSizes: DuplicateSizes?)
    case undo(batch: MediaTrashBatchID)
    case deleteImmediately([MediaAssetID])
    case restore([MediaAssetID])
    case keepWaitingForSpace([MediaAssetID])
    /// The trash bar's Cancel: every item still waiting to move stays where it is.
    case cancelPending
}

/// What a mark hides: the items a Move to Trash targeted, or — for its redo — exactly the
/// items an earlier command's mark hid, which only the stream's consumer knows.
nonisolated enum TrashMarkItems: Sendable {
    case targets([MediaAssetID])
    case hiddenBy(MediaTrashBatchID)
}

/// One Move to Trash command's undo target. `UndoManager` removes a target's entries by
/// identity, so a command whose mark failed or hid nothing takes back exactly its own.
final class TrashUndoTarget {
    let batch: MediaTrashBatchID

    init(batch: MediaTrashBatchID) {
        self.batch = batch
    }
}

extension CatalogWindowViewModel {
    var canMoveTargetedMediaToTrash: Bool {
        guard trashSizingTask == nil, showsSelectedScope else {
            return false
        }
        // On the duplicates list the targets are the selected groups' extra copies, never
        // a kept one (ADR 0042).
        let ids = showsDuplicatesList ? selectedDuplicatesToMove().ids : targetIDs(.current)
        guard !ids.isEmpty else {
            return false
        }
        let roots = Dictionary(
            uniqueKeysWithValues: (state.libraries + state.removableSources).map { ($0.path, $0.root) }
        )
        return ids.allSatisfy { roots[$0.libraryRootPath]?.kind.supportsMoveToTrash != false }
    }

    /// Hides the targets behind one pending Move to Trash and hands them to the queue.
    func moveTargetedMediaToTrash() {
        guard canMoveTargetedMediaToTrash else {
            return
        }
        let command = trashCommand()
        moveMediaToTrash(command.ids, carrying: command.carries)
    }

    /// What a Move to Trash of the current targets moves, by file, with the work a duplicates
    /// move carries onto kept copies: the one resolution the command and its question's
    /// reading share. On the duplicates list, the selected groups' extra copies, never a kept
    /// one (ADR 0042); elsewhere a collapsed stack is one photo of several files, and Move to
    /// Trash moves them all, while a member of an expanded stack is a photo of its own (ADR 0052).
    func trashCommand() -> (ids: [MediaAssetID], carries: [DuplicateCarry]) {
        if showsDuplicatesList {
            return selectedDuplicatesToMove()
        }
        let stacks = state.mediaGrid.stacks
        var seen = Set<MediaAssetID>()
        return (targetIDs(.current).flatMap(stacks.files(reachedThrough:)).filter { seen.insert($0).inserted }, [])
    }

    /// The one Move to Trash path for a known set of items: the current targets, or the
    /// copies Duplicates marked (ADR 0042). Asks the large-download question when it
    /// applies (APP-045), then hides the items behind one undoable command.
    func moveMediaToTrash(_ ids: [MediaAssetID], carrying carries: [DuplicateCarry] = []) {
        guard trashSizingTask == nil, !ids.isEmpty else {
            return
        }
        guard asksBeforeLargeTrashDownload else {
            performMoveToTrash(ids, carrying: carries)
            return
        }
        // Read when the targets last changed (`trashQuestionReading`): the command asks or
        // hides in this step. The reading is of exactly these files or it is not this
        // command's.
        if let reading = trashQuestionReading, reading.files == ids {
            answerTrashQuestion(ids, carrying: carries, bytes: reading.bytes, readAt: "targetsChanged")
            return
        }
        // Not read yet — the command came before its targets' reading finished, or it is not
        // the current targets' (Duplicates' Move All) — so it waits for a read of its own
        // before anything is hidden. The window holds no locality fact of its own: whether a
        // file is cloud-only is a point-in-time filesystem fact Otos never stores (ADR 0008).
        // `trashSizingTask` keeps a second command from starting until this one has either
        // asked or moved.
        let coordinator = mediaTrashCoordinator
        // Single in flight by construction (`trashSizingTask` gates every start), so there is
        // nothing to order: a read-only sizing question, answered once.
        trashSizingTask = Task { [weak self, coordinator] in
            let bytes = await coordinator.downloadBytes(for: ids)
            guard let self else { return }
            trashSizingTask = nil
            answerTrashQuestion(ids, carrying: carries, bytes: bytes, readAt: "command")
        }
    }

    /// The question's answer for a command, from its download as read (`readAt`): asked when
    /// it applies, else the items are hidden now.
    private func answerTrashQuestion(
        _ ids: [MediaAssetID],
        carrying carries: [DuplicateCarry],
        bytes: PartialByteCount?,
        readAt: String
    ) {
        guard let bytes else {
            // The catalog could not size the download, so there is no number to put in a
            // prompt. The move goes ahead on its own safeguards: the free-space floor and a
            // failed download both stop and ask the user.
            OtosLog.ui.notice("op=mediaTrash.prompt phase=sizeUnknown count=\(ids.count, privacy: .public)")
            performMoveToTrash(ids, carrying: carries)
            return
        }
        if LargeTrashDownloadPrompt.asks(bytes: bytes, preference: asksBeforeLargeTrashDownload) {
            largeTrashDownloadPrompt = LargeTrashDownloadPrompt(ids: ids, bytes: bytes, carries: carries)
            OtosLog.ui.noticeOperation("mediaTrash.prompt", phase: "shown", fields: [
                "count": "\(ids.count)",
                "knownBytes": "\(bytes.knownBytes)",
                "unknownSizeCount": "\(bytes.unknownCount)",
                "readAt": readAt,
            ])
        } else {
            OtosLog.ui.noticeOperation("mediaTrash.prompt", phase: "notAsked", fields: [
                "count": "\(ids.count)",
                "readAt": readAt,
            ])
            performMoveToTrash(ids, carrying: carries)
        }
    }

    // MARK: - The targets' question lane

    /// The current targets may have changed: their command is read again. Called from every
    /// target writer (`refreshOpenWithMenu`) and when the preference turns on. A count and a
    /// doorbell; the lane starts on its first request.
    func requestTrashQuestionReading() {
        trashQuestionRequested &+= 1
        if trashQuestionTask == nil {
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            trashQuestionContinuation = continuation
            trashQuestionTask = Task { [weak self] in
                for await _ in stream {
                    guard let self else {
                        return
                    }
                    await runTrashQuestionReadings()
                }
            }
        }
        trashQuestionContinuation?.yield()
    }

    /// Runs readings until the newest request is covered. Each pass resolves the command on
    /// the main actor, leaves it for the read, and keeps the result as the reading of exactly
    /// the files it read; a command compares its own files with them, so a reading the
    /// targets have since moved past is never used. A failed read keeps nothing and leaves
    /// the request outstanding for the next change, and a command then reads for itself.
    private func runTrashQuestionReadings() async {
        while trashQuestionRequested != trashQuestionCovered {
            let startedFrom = trashQuestionRequested
            let files = asksBeforeLargeTrashDownload ? trashCommand().ids : []
            guard !files.isEmpty else {
                trashQuestionCovered = startedFrom
                trashQuestionReading = nil
                continue
            }
            if trashQuestionReading?.files == files {
                trashQuestionCovered = startedFrom
                continue
            }
            let started = ContinuousClock.now
            let bytes = await mediaTrashCoordinator.downloadBytes(for: files)
            guard !Task.isCancelled else {
                return
            }
            guard let bytes else {
                OtosLog.ui.noticeOperation("mediaTrash.question", phase: "readFailed", fields: [
                    "count": "\(files.count)",
                ])
                return
            }
            trashQuestionCovered = startedFrom
            trashQuestionReading = TrashQuestionReading(files: files, bytes: bytes)
            OtosLog.ui.noticeOperation("mediaTrash.question", phase: "read", fields: [
                "count": "\(files.count)",
                "knownBytes": "\(bytes.knownBytes)",
                "unknownSizeCount": "\(bytes.unknownCount)",
                "ms": "\(DiagnosticsTiming.milliseconds(since: started))",
            ])
        }
    }

    /// `Download and Move to Trash`: the items the user was asked about are moved.
    func confirmLargeTrashDownload() {
        guard let prompt = largeTrashDownloadPrompt else { return }
        largeTrashDownloadPrompt = nil
        OtosLog.ui.notice("op=mediaTrash.prompt phase=confirmed count=\(prompt.ids.count, privacy: .public)")
        performMoveToTrash(prompt.ids, carrying: prompt.carries)
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
        requestTrashQuestionReading()
        OtosLog.ui.notice("op=mediaTrash.prompt phase=\(asks ? "enabled" : "suppressed", privacy: .public)")
    }

    /// The result first, in this step: the items leave the window, the selection moves on,
    /// the undo entry and the duplicates receipt are there; the Store's mark follows on the
    /// trash intent stream (`finishTrashMark`).
    private func performMoveToTrash(_ ids: [MediaAssetID], carrying carries: [DuplicateCarry]) {
        guard trashSizingTask == nil, !ids.isEmpty else {
            return
        }
        startMediaTrash()
        let batch = MediaTrashBatchID()
        OtosLog.ui.noticeOperation("trash.move", phase: "start", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "count": "\(ids.count)",
        ])
        // The duplicates bar's receipt reports what this command hid, with the sizes the
        // list showed: read before the hide, since the groups leave the window with their
        // copies (ADR 0042).
        let receiptSizes = showsDuplicatesList ? duplicateSizes(for: ids) : nil
        uiStallMonitor.beginActToResult(.moveToTrash, ids: ids)
        // Command: Projection takes the items off before it hears the mark landed.
        projectionIntentContinuation.yield(.hide(ids, batch: batch))
        navigateAfterHiding(Set(ids))
        registerTrashUndo(batch: batch, ids: ids, carries: carries)
        if let receiptSizes {
            duplicatesSession.receipt = DuplicatesReceipt(
                batch: batch,
                movedCount: ids.count,
                bytes: receiptSizes.total(for: ids)
            )
        }
        // Command: ordered before any undo of it, which the consumer applies after the mark.
        submitTrashIntent(.mark(batch: batch, items: .targets(ids), carries: carries, receiptSizes: receiptSizes))
    }

    /// The Store's answer to a mark, applied in the consumer's order. What it hid is what an
    /// undo puts back; a mark that hid nothing has nothing to undo, and one that failed
    /// brings its items back and says so (DES-076).
    private func finishTrashMark(
        batch: MediaTrashBatchID,
        requested: [MediaAssetID],
        outcome: Result<[MediaAssetID], any Error>,
        receiptSizes: DuplicateSizes?
    ) {
        switch outcome {
        case let .success(hidden):
            OtosLog.ui.noticeOperation("trash.queue", phase: "hidden", fields: [
                "batch": "\(batch.unixMilliseconds)",
                "requested": "\(requested.count)",
                "hidden": "\(hidden.count)",
            ])
            if hidden.isEmpty {
                removeTrashUndo(batch: batch)
            }
            if let receipt = duplicatesSession.receipt, receipt.batch == batch, hidden.count != receipt.movedCount {
                duplicatesSession.receipt = hidden.isEmpty ? nil : DuplicatesReceipt(
                    batch: batch,
                    movedCount: hidden.count,
                    bytes: (receiptSizes ?? DuplicateSizes(sizes: [:])).total(for: hidden)
                )
            }
        case let .failure(error):
            // Nothing was hidden or queued: the items are back where they were, selected, with
            // no undo for a move that did not happen.
            OtosLog.ui.errorOperation("trash.queue", phase: "failed", fields: [
                "batch": "\(batch.unixMilliseconds)",
                "requested": "\(requested.count)",
                "error": String(describing: error),
            ])
            removeTrashUndo(batch: batch)
            if duplicatesSession.receipt?.batch == batch {
                duplicatesSession.receipt = nil
            }
            trashFailedIDs = requested
            trashAlertDetail = TrashAlertCopy.moveDetail
            trashAlertMessage = requested.count == 1 ? TrashAlertCopy.moveFailedOne : TrashAlertCopy.moveFailedMany
            selectAssets(requested)
        }
    }

    /// The sizes the duplicates list showed for these copies, for the receipt.
    private func duplicateSizes(for ids: [MediaAssetID]) -> DuplicateSizes {
        var sizes: [MediaAssetID: Int64?] = [:]
        let wanted = Set(ids)
        for group in state.duplicates?.groups ?? [] {
            for copy in group.copies where wanted.contains(copy.id) {
                sizes[copy.id] = copy.byteSize
            }
        }
        return DuplicateSizes(sizes: sizes)
    }

    // MARK: - Undo

    static let moveToTrashActionName = "Move to Trash"

    /// The command's undo target, made once per command and kept (`trashUndoTargets`).
    private func trashUndoTarget(_ batch: MediaTrashBatchID) -> TrashUndoTarget {
        if let target = trashUndoTargets[batch] {
            return target
        }
        let target = TrashUndoTarget(batch: batch)
        trashUndoTargets[batch] = target
        return target
    }

    /// `ids` are the items the command took off the window: what redo hides again at once.
    /// The Store work of undo and redo uses what the mark hid, which the consumer holds.
    private func registerTrashUndo(batch: MediaTrashBatchID, ids: [MediaAssetID], carries: [DuplicateCarry]) {
        // Explicit group: the manager does not group by event (curation registers on Store
        // completions); this registration happens inside the user's event.
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: trashUndoTarget(batch)) { [weak self] target in
            self?.undoMoveToTrash(batch: target.batch, ids: ids, carries: carries)
        }
        windowUndoManager.setActionName(Self.moveToTrashActionName)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Takes the command's entries, undo or redo, back off the stack: its mark failed or hid
    /// nothing, so there is nothing to undo.
    private func removeTrashUndo(batch: MediaTrashBatchID) {
        guard let target = trashUndoTargets[batch] else { return }
        windowUndoManager.removeAllActions(withTarget: target)
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()`: files redo synchronously, then asks the queue
    /// to withdraw or put back the command's items, and the Store to take back what the
    /// command carried onto kept copies.
    private func undoMoveToTrash(batch: MediaTrashBatchID, ids: [MediaAssetID], carries: [DuplicateCarry]) {
        windowUndoManager.registerUndo(withTarget: trashUndoTarget(batch)) { [weak self] target in
            self?.redoMoveToTrash(undone: target.batch, ids: ids, carries: carries)
        }
        windowUndoManager.setActionName(Self.moveToTrashActionName)
        // The receipt reported this batch; undone, there is nothing to report.
        if duplicatesSession.receipt?.batch == batch {
            duplicatesSession.receipt = nil
        }
        OtosLog.ui.notice(
            "op=trash.undo phase=start count=\(ids.count, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public)"
        )
        uiStallMonitor.beginActToResult(.putBack, ids: ids)
        // Command: ordered after the mark it undoes and before a following redo.
        submitTrashIntent(.undo(batch: batch))
    }

    private func finishTrashUndo(_ outcome: MediaTrashCoordinator.UndoResult) {
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
        // Undo shows its result (HIG): on the duplicates list the restored copies' groups
        // rejoin at their dates, so they are selected to be found.
        if showsDuplicatesList, !outcome.restored.isEmpty {
            selectAssets(outcome.restored)
        }
    }

    /// Runs inside `UndoManager.redo()`: files undo synchronously under a new command
    /// identity, takes the items off the window again at once, then marks what the undone
    /// command hid.
    private func redoMoveToTrash(undone: MediaTrashBatchID, ids: [MediaAssetID], carries: [DuplicateCarry]) {
        let batch = MediaTrashBatchID()
        windowUndoManager.registerUndo(withTarget: trashUndoTarget(batch)) { [weak self] target in
            self?.undoMoveToTrash(batch: target.batch, ids: ids, carries: carries)
        }
        windowUndoManager.setActionName(Self.moveToTrashActionName)
        OtosLog.ui.notice(
            "op=trash.redo phase=start count=\(ids.count, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public)"
        )
        uiStallMonitor.beginActToResult(.moveToTrash, ids: ids)
        // Command: Projection takes the items off before it hears the mark landed.
        projectionIntentContinuation.yield(.hide(ids, batch: batch))
        // Command: ordered after the undo it follows.
        submitTrashIntent(.mark(batch: batch, items: .hiddenBy(undone), carries: carries, receiptSizes: nil))
    }

    private func submitTrashIntent(_ intent: TrashIntent) {
        switch mediaTrashIntentContinuation.yield(intent) {
        case .enqueued:
            return
        case .dropped:
            assertionFailure("Unbounded trash intent stream dropped an intent")
            OtosLog.ui.error("Trash intent was unexpectedly dropped")
        case .terminated:
            assertionFailure("Trash intent submitted after stream termination")
            OtosLog.ui.error("Trash intent submitted after termination")
        @unknown default:
            assertionFailure("Unknown trash intent stream yield result")
            OtosLog.ui.error("Trash intent returned an unknown yield result")
        }
    }

    /// The one consumer of trash intents, in submission order. Holds the view model weakly
    /// across each wait and ends with the stream.
    private func startTrashIntentConsumer() {
        guard mediaTrashIntentTask == nil else { return }
        let intents = mediaTrashIntentStream
        let coordinator = mediaTrashCoordinator
        let store = catalogStore
        let projection = projectionIntentContinuation
        let markHook = trashMarkHook
        mediaTrashIntentTask = Task { [weak self, coordinator, store, projection, markHook] in
            // The queue starts before the first intent reaches it, in the same task.
            await coordinator.start()
            // What each command's mark hid: what its undo puts back and its redo marks again.
            // Only this consumer writes or reads it, in intent order.
            var hiddenByBatch: [MediaTrashBatchID: [MediaAssetID]] = [:]
            for await intent in intents {
                switch intent {
                case let .mark(batch, items, carries, receiptSizes):
                    let ids = switch items {
                    case let .targets(ids): ids
                    case let .hiddenBy(undone): hiddenByBatch[undone] ?? []
                    }
                    let outcome: Result<[MediaAssetID], any Error>
                    do {
                        try await markHook?()
                        outcome = try await .success(store.markPendingTrash(ids, batch: batch, carrying: carries))
                    } catch {
                        outcome = .failure(error)
                    }
                    switch outcome {
                    case let .success(hidden):
                        hiddenByBatch[batch] = hidden
                        projection.yield(.hideLanded(batch))
                        coordinator.kick()
                    case .failure:
                        projection.yield(.hideWithdrawn(batch, storeChanged: false))
                    }
                    self?.finishTrashMark(batch: batch, requested: ids, outcome: outcome, receiptSizes: receiptSizes)
                case let .undo(batch):
                    // Kept: a redo marks again what this command hid.
                    let ids = hiddenByBatch[batch] ?? []
                    let outcome = ids.isEmpty
                        ? MediaTrashCoordinator.UndoResult()
                        : await coordinator.undo(batch: batch, ids: ids)
                    do {
                        try await store.revertCarriedWork(batch: batch, restored: Set(outcome.restored))
                    } catch {
                        // The kept copies keep what was carried; the moved copies, back,
                        // hold their own work as well, so nothing is lost.
                        OtosLog.ui.errorOperation("trash.undo", phase: "carryRevertFailed", fields: [
                            "batch": "\(batch.unixMilliseconds)",
                            "error": String(describing: error),
                        ])
                    }
                    // Undone, the command's batch takes nothing off the window: what came
                    // back is read now rather than on the cadence.
                    projection.yield(.hideWithdrawn(batch, storeChanged: !outcome.restored.isEmpty))
                    self?.finishTrashUndo(outcome)
                case let .deleteImmediately(ids):
                    await coordinator.deleteImmediately(ids)
                case let .restore(ids):
                    await coordinator.restore(ids)
                case let .keepWaitingForSpace(ids):
                    await coordinator.keepWaitingForSpace(ids)
                case .cancelPending:
                    let withdrawn = await coordinator.withdrawAllPending()
                    self?.selectAssets(withdrawn)
                }
                if self == nil {
                    return
                }
            }
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
        startTrashIntentConsumer()
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

    /// The trash bar's Cancel (DES-089): every item still waiting to move to the Trash
    /// reappears where it was. Items already in the Trash stay there — ⌘Z or Finder's Put
    /// Back returns them. Reads the queue's own pending rows, so it works the same after a
    /// relaunch, when no undo entry remains.
    func cancelPendingTrash() {
        OtosLog.ui.notice("op=trash.cancel phase=start")
        // Command: ordered with undo, redo and prompt answers on the one intent stream.
        submitTrashIntent(.cancelPending)
    }

    /// The user chose Delete in a decision prompt: the items are deleted immediately.
    func answerTrashDecisionDelete() {
        guard let decision = trashDecisions.first else { return }
        trashDecisions.removeFirst()
        OtosLog.ui.notice(
            "op=trash.decision phase=delete kind=\(decision.kindName, privacy: .public) count=\(decision.ids.count, privacy: .public)"
        )
        // Command: ordered with the other prompt answers and with undo/redo.
        submitTrashIntent(.deleteImmediately(decision.ids))
    }

    /// The user chose Cancel: a failed download's items reappear; items blocked by the
    /// free-space floor keep waiting for room.
    func answerTrashDecisionCancel() {
        guard let decision = trashDecisions.first else { return }
        trashDecisions.removeFirst()
        OtosLog.ui.notice(
            "op=trash.decision phase=cancel kind=\(decision.kindName, privacy: .public) count=\(decision.ids.count, privacy: .public)"
        )
        // Command: ordered with the other prompt answers and with undo/redo.
        switch decision {
        case let .downloadFailed(ids):
            submitTrashIntent(.restore(ids))
        case let .diskFloor(ids):
            submitTrashIntent(.keepWaitingForSpace(ids))
        }
    }

    /// Lands on the nearest survivor of the last hidden item in the order on screen: the next
    /// one, or the previous one when the hidden items ended the list
    /// (`BrowserModePolicy.nearestSurvivor`). Runs as the items are hidden, so the order is
    /// the one the user acted in; it asks the order's index about the hidden items and walks
    /// only to the survivor, never the whole order.
    private func navigateAfterHiding(_ hidden: Set<MediaAssetID>) {
        // Only where the hidden items are on screen: a scope changed while the download
        // question was sized holds none of them, and its selection is the user's own.
        let order = state.mediaGrid.content
        guard showsSelectedScope, let lastHidden = order.inDisplayOrder(hidden).last else {
            return
        }
        let survivors = HidingOrder(order: order, hidden: hidden)
        let successor = BrowserModePolicy.nearestSurvivor(of: lastHidden, previousOrderedIDs: order, surviving: survivors)
        let mode = viewMode
        OtosLog.ui.notice(
            "op=trash.navigate mode=\(mode.rawValue, privacy: .public) successor=\(successor?.relativePath.rawValue ?? "none", privacy: .public)"
        )
        switch mode {
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
        case .compare:
            let next = ComparePairPolicy.prune(pair: comparePair, previousOrderedIDs: order, survivingOrderedIDs: survivors)
            applyComparePair(next, orderedIDs: [])
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

/// A display order without the items a Move to Trash is hiding, answered from the order's
/// own index, so the survivor policies ask about the items they look at, never the whole
/// order. Only `orderedIDs` walks it, for a policy that needs every survivor.
struct HidingOrder: MediaDisplayOrder {
    let order: CatalogGridContent
    let hidden: Set<MediaAssetID>

    var orderedIDs: [MediaAssetID] {
        order.orderedAssetIDs.filter { !hidden.contains($0) }
    }

    func position(of id: MediaAssetID) -> Int? {
        hidden.contains(id) ? nil : order.position(of: id)
    }

    func contains(_ id: MediaAssetID) -> Bool {
        !hidden.contains(id) && order.contains(id)
    }

    func inDisplayOrder(_ ids: Set<MediaAssetID>) -> [MediaAssetID] {
        order.inDisplayOrder(ids.subtracting(hidden))
    }
}

/// The sizes the duplicates list showed for the copies a command set out to hide, read
/// before the Store hid them.
nonisolated struct DuplicateSizes: Sendable {
    let sizes: [MediaAssetID: Int64?]

    func total(for ids: [MediaAssetID]) -> PartialByteCount {
        var known: Int64 = 0
        var unknown = 0
        for id in ids {
            if let size = sizes[id], let size {
                known += size
            } else {
                unknown += 1
            }
        }
        return PartialByteCount(knownBytes: known, unknownCount: unknown)
    }
}
