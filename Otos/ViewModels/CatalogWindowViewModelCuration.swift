import Foundation
import OSLog

/// Curation intent guide
///
/// The result first (DES-120, APP-086). A Like, Dislike or Not Rated shows in the step that
/// handles it, before the catalog records it: the choice is held in `MediaChoiceOverlay`, the
/// tiles, panes and toolbar control of its targets show it at once (`showChoices`), the
/// selection advances when Advance After Choice is on, Edit ▸ Undo names the act, and
/// Projection takes a target out of a choice filter it no longer matches
/// (`CatalogProjectionIntent.choose`). The write follows on the one media-choice stream, to
/// the one writer (`MediaChoiceWriter`, the Store's one-row-update owner). Grid, loupe,
/// compare, menu, keyboard, accessibility, context menu and inline controls all call
/// `submitMediaChoice(_:target:origin:)`.
///
/// The stream's consumer applies the Store's answer in submission order: a write that landed
/// is reported to the overlay and to Projection, which keep the choice until a read that
/// started after it covers it; a write that found no row, or changed nothing, takes the act's
/// undo entry back off the stack; a write that failed withdraws the choice — the targets show
/// what they showed before, are selected, and the failure alert says so (DES-076's form).
///
/// Undo (APP-039). An act's undo is registered as it is shown, under a record of it
/// (`MediaChoiceUndoRecord`) the consumer fills with the prior choice per asset the Store
/// reports — catalog truth, read where truth lives. Undo and redo enqueue a restore of that
/// record on the same stream, so one pressed before the act's write lands is written after
/// it, from the priors the write reported; what an undo shows at once is those priors when
/// they are known, else what the window showed before the act. Undo and redo never advance
/// the selection and register their opposite entry synchronously at fire time, so the manager
/// files it on the other stack. Move to Trash is not registered here (ADR 0022).
nonisolated enum MediaTarget: Equatable {
    case current
    case item(MediaAssetID)
    case compare(PanePosition)
}

nonisolated enum MediaChoiceOrigin: String, Equatable {
    case menu
    case toolbar
    case keyboard
    case inline
    case accessibility
    case contextMenu
    case undo
    case redo
}

/// The one write of curation: the Store's in production, a held or failing one in tests.
struct MediaChoiceWriter {
    let write: @Sendable ([MediaAssetID: MediaChoice]) async throws -> CatalogStore.MediaChoiceMutationResult

    static func store(_ store: CatalogStore) -> MediaChoiceWriter {
        MediaChoiceWriter { assignments in try await store.setMediaChoices(assignments) }
    }
}

/// One user choice and everything its undo and redo need: what it assigned, what the window
/// showed before it, and — once its write answers — what each asset held in the catalog.
/// Also the act's undo target, so an act whose write changed nothing or failed takes back
/// exactly its own entries. Only the media-choice consumer writes `previous`, in submission
/// order, so a restore always finds what the act's write reported.
@MainActor
final class MediaChoiceUndoRecord {
    let assignments: [MediaAssetID: MediaChoice]
    let shownBefore: [MediaAssetID: MediaChoice]
    let actionName: String
    /// The catalog's choice per asset before the act's write; nil until it answers, and
    /// for good when it failed.
    var previous: [MediaAssetID: MediaChoice]?

    init(assignments: [MediaAssetID: MediaChoice], shownBefore: [MediaAssetID: MediaChoice], actionName: String) {
        self.assignments = assignments
        self.shownBefore = shownBefore
        self.actionName = actionName
    }

    /// What the act changed in the catalog: each asset whose prior differed from its new value.
    var changedPriors: [MediaAssetID: MediaChoice]? {
        previous.map { previous in previous.filter { assignments[$0.key] != $0.value } }
    }

    /// What an undo writes (the priors of what changed) or a redo writes (the act again, for
    /// what changed). Nil before the act's write answered.
    func restore(undoing: Bool) -> [MediaAssetID: MediaChoice]? {
        guard let changed = changedPriors else { return nil }
        return undoing ? changed : assignments.filter { changed[$0.key] != nil }
    }

    /// What an undo or redo shows the moment it is pressed: what it will write when that is
    /// known, else what the window showed before the act, or the act itself.
    func shown(undoing: Bool) -> [MediaAssetID: MediaChoice] {
        restore(undoing: undoing) ?? (undoing ? shownBefore : assignments)
    }
}

struct MediaChoiceCommand {
    enum Write {
        case assign([MediaAssetID: MediaChoice])
        /// Undo (`undoing`) or redo of `record`, resolved when the consumer reaches it.
        case restore(MediaChoiceUndoRecord, undoing: Bool)
    }

    let write: Write
    /// The overlay command holding what this write shows, and the items it holds them for.
    let held: UInt64
    let heldIDs: [MediaAssetID]
    /// The act's record, for a user choice; its undo and redo carry it in `write`.
    let record: MediaChoiceUndoRecord?
    let origin: MediaChoiceOrigin

    /// What the write assigns, read when the consumer reaches it: a restore's priors are
    /// known only once the act's own write, ahead of it on the stream, has answered.
    var assignments: [MediaAssetID: MediaChoice]? {
        switch write {
        case let .assign(assignments): assignments
        case let .restore(record, undoing): record.restore(undoing: undoing)
        }
    }
}

/// What a write of choices came to, applied on the main actor after its await.
enum MediaChoiceOutcome {
    case written(CatalogStore.MediaChoiceMutationResult)
    /// A restore whose act's write failed, or changed nothing: nothing to write.
    case nothingToWrite
    case failed(any Error)
}

/// The failure alert for a choice the catalog could not record (DES-076's form).
nonisolated struct MediaChoiceFailure: Equatable {
    let count: Int

    var title: String {
        count == 1 ? "This Choice Couldn't Be Saved" : "These Choices Couldn't Be Saved"
    }

    static let message = "The affected items are back as they were and selected."
}

/// What the tiles on screen must show again, after a choice changed what some of them hold:
/// the grid reconfigures the visible ones among `ids` in place, never applying its structure.
nonisolated struct TileChoiceChange: Equatable {
    var revision: UInt64 = 0
    var ids: Set<MediaAssetID> = []
}

/// What Edit ▸ Undo / Redo render. Published by the ViewModel after every registration,
/// undo and redo, because `UndoManager` itself is not observable.
nonisolated struct UndoMenuState: Equatable, Sendable {
    var canUndo = false
    var canRedo = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"
}

extension CatalogWindowViewModel {
    /// Above this many targets the toolbar control shows no state rather than read a
    /// detail row per selected asset on every selection change.
    static let currentTargetChoiceLimit = 64

    var hasMediaChoiceTarget: Bool {
        !targetIDs(.current).isEmpty
    }

    /// Reads the current targets' choices once per target change and publishes the one value
    /// they share, or nil. The read answers through the overlay, so a choice held for them is
    /// what it reports.
    ///
    /// A failed read publishes no choice: the value on display belongs to the previous
    /// targets, so it is retracted to nil (unknown) and the next target change reads again.
    func refreshCurrentTargetChoice() {
        currentTargetChoiceTask?.cancel()
        let ids = targetIDs(.current)
        guard !ids.isEmpty, ids.count <= Self.currentTargetChoiceLimit else {
            if currentTargetChoice != nil {
                currentTargetChoice = nil
            }
            currentTargetChoiceTask = nil
            return
        }
        let reader = tileDetailReader
        currentTargetChoiceTask = Task { [weak self] in
            let shared: MediaChoice?
            do {
                let details = try await reader.details(for: ids)
                let choices = Set(ids.compactMap { details[$0]?.mediaChoice })
                shared = choices.count == 1 && details.count == ids.count ? choices.first : nil
            } catch {
                shared = nil
            }
            guard !Task.isCancelled, let self, targetIDs(.current) == ids else { return }
            if currentTargetChoice != shared {
                currentTargetChoice = shared
            }
            currentTargetChoiceTask = nil
        }
    }

    func setAdvanceAfterMediaChoice(_ enabled: Bool) {
        guard advanceAfterMediaChoice != enabled else {
            return
        }
        advanceAfterMediaChoice = enabled
        preferences.set(enabled, forKey: Self.advanceAfterMediaChoiceDefaultsKey)
    }

    /// Like, Dislike and Mark as Not Rated, from every surface: shown now, written after.
    func submitMediaChoice(
        _ choice: MediaChoice,
        target: MediaTarget = .current,
        origin: MediaChoiceOrigin = .menu
    ) {
        if case let .compare(position) = target {
            activeComparePane = position
        }
        let ids = targetIDs(target)
        guard !ids.isEmpty else {
            return
        }
        let assignments = Dictionary(uniqueKeysWithValues: ids.map { ($0, choice) })
        let record = MediaChoiceUndoRecord(
            assignments: assignments,
            shownBefore: Dictionary(uniqueKeysWithValues: ids.map { ($0, shownChoice(for: $0)) }),
            actionName: choice.actionLabel
        )
        let held = holdChoices(assignments)
        registerMediaChoiceUndo(record)
        advanceAfterChoice(from: ids.last)
        enqueueMediaChoice(MediaChoiceCommand(
            write: .assign(assignments), held: held, heldIDs: ids, record: record, origin: origin
        ))
        OtosLog.ui.notice(
            "op=mediaChoice.submit choice=\(choice.rawValue, privacy: .public) count=\(ids.count, privacy: .public) origin=\(origin.rawValue, privacy: .public)"
        )
    }

    /// The choice the window shows for `id` now: one held, else what its tile last read.
    private func shownChoice(for id: MediaAssetID) -> MediaChoice {
        mediaChoiceOverlay.choice(for: id) ?? tileContentStore.content(for: id)?.detail.mediaChoice ?? .default
    }

    /// Holds `assignments` until the catalog's word on them is read, and shows them now.
    private func holdChoices(_ assignments: [MediaAssetID: MediaChoice]) -> UInt64 {
        let held = mediaChoiceOverlay.submit(assignments, shown: shownChoice(for:))
        showChoices(assignments)
        // Command: Projection takes a target out of a choice filter before it hears the
        // write landed.
        projectionIntentContinuation.yield(.choose(assignments, request: held))
        return held
    }

    /// Shows `choices` on every surface that draws them, in this step: the tiles in the tile
    /// store (the grid reconfigures the visible ones among them), the loupe and compare panes,
    /// and the toolbar control when they decide the targets' shared value.
    private func showChoices(_ choices: [MediaAssetID: MediaChoice]) {
        var changed = Set<MediaAssetID>()
        for (id, choice) in choices where tileContentStore.setMediaChoice(choice, for: id) {
            changed.insert(id)
        }
        if !changed.isEmpty {
            tileChoiceChange = TileChoiceChange(revision: tileChoiceChange.revision &+ 1, ids: changed)
        }
        updatePaneMediaChoices(choices)
        let targets = targetIDs(.current)
        let shared = Set(targets.compactMap { choices[$0] })
        if !targets.isEmpty, targets.count <= Self.currentTargetChoiceLimit, targets.allSatisfy({ choices[$0] != nil }),
           shared.count == 1
        {
            currentTargetChoiceTask?.cancel()
            currentTargetChoiceTask = nil
            if currentTargetChoice != shared.first {
                currentTargetChoice = shared.first
            }
        } else if targets.contains(where: { choices[$0] != nil }) {
            refreshCurrentTargetChoice()
        }
    }

    private func enqueueMediaChoice(_ command: MediaChoiceCommand) {
        submittedMediaChoiceCount += 1
        mediaChoiceContinuation.yield(command)
    }

    /// True once every submitted choice has been persisted or refused and its outcome
    /// applied, so a caller can assert what a choice did — including that it changed
    /// nothing — without guessing how long persistence takes.
    var hasSettledMediaChoices: Bool {
        handledMediaChoiceCount == submittedMediaChoiceCount
    }

    /// What an act on `target` acts on. Nothing while the pane still shows a scope the user
    /// has left: its items are not in the scope the sidebar has selected.
    func targetIDs(_ target: MediaTarget) -> [MediaAssetID] {
        guard showsSelectedScope else {
            return []
        }
        switch target {
        case .current:
            // The duplicates list has one presentation: its rows are the selection.
            if showsDuplicatesList {
                return orderedSelectedAssetIDs
            }
            switch viewMode {
            case .grid:
                return orderedSelectedAssetIDs
            case .loupe:
                return focusedAssetID.map { [$0] } ?? []
            case .compare:
                return compareID(for: activeComparePane).map { [$0] } ?? []
            }
        case let .item(id):
            return state.mediaGrid.content.contains(id) ? [id] : []
        case let .compare(position):
            return compareID(for: position).map { [$0] } ?? []
        }
    }

    private func compareID(for position: PanePosition) -> MediaAssetID? {
        switch position {
        case .left:
            comparePair.left
        case .right:
            comparePair.right
        }
    }

    /// The one consumer of choice writes, in submission order: each write goes to `writer`
    /// and its answer is applied when the await returns (`applyMediaChoiceOutcome`). A
    /// restore's assignments are read as the consumer reaches it, before the await. Holds the
    /// view model weakly across each wait and ends with the stream.
    func startMediaChoiceForwarding(writer: MediaChoiceWriter) {
        mediaChoiceForwardingTask = Task { [weak self, mediaChoiceStream, writer] in
            for await command in mediaChoiceStream {
                defer { self?.handledMediaChoiceCount += 1 }
                guard !Task.isCancelled else {
                    break
                }
                let outcome: MediaChoiceOutcome
                if let assignments = command.assignments, !assignments.isEmpty {
                    do {
                        outcome = try await .written(writer.write(assignments))
                    } catch {
                        outcome = .failed(error)
                    }
                } else {
                    outcome = .nothingToWrite
                }
                guard let self else {
                    break
                }
                applyMediaChoiceOutcome(outcome, of: command)
            }
        }
    }

    /// The Store's answer to one write, in submission order.
    func applyMediaChoiceOutcome(_ outcome: MediaChoiceOutcome, of command: MediaChoiceCommand) {
        switch outcome {
        case let .written(result) where result.accepted:
            command.record?.previous = result.previous
            if let record = command.record, record.changedPriors?.isEmpty != false {
                // The act changed nothing: there is nothing to undo.
                removeMediaChoiceUndo(record)
            }
            mediaChoiceOverlay.landed(command.held, ids: command.heldIDs)
            projectionIntentContinuation.yield(.choicesLanded(request: command.held))
            OtosLog.ui.noticeOperation("mediaChoice.persist", phase: "landed", fields: [
                "origin": command.origin.rawValue,
                "changed": "\(result.changedCount)",
            ])
        case .written:
            // No row exists for any target: they left the catalog, and their reads show it.
            withdrawChoices(command)
            command.record.map(removeMediaChoiceUndo)
            OtosLog.ui.noticeOperation("mediaChoice.persist", phase: "noRows", fields: ["origin": command.origin.rawValue])
        case .nothingToWrite:
            withdrawChoices(command)
            OtosLog.ui.noticeOperation("mediaChoice.persist", phase: "nothingToWrite", fields: ["origin": command.origin.rawValue])
        case let .failed(error):
            withdrawChoices(command)
            let record: MediaChoiceUndoRecord? = switch command.write {
            case .assign: command.record
            case let .restore(record, _): record
            }
            record.map(removeMediaChoiceUndo)
            let shown = state.mediaGrid.orderedAssetIDs.filter(Set(command.heldIDs).contains)
            selectAssets(shown)
            mediaChoiceFailure = MediaChoiceFailure(count: command.heldIDs.count)
            OtosLog.persistence.errorOperation("mediaChoice.persist", phase: "failed", fields: [
                "origin": command.origin.rawValue,
                "count": "\(command.heldIDs.count)",
                "error": String(describing: error),
            ])
        }
    }

    /// The write did not land: its choices come off every surface, which show what they
    /// showed before, and Projection puts back what it took out of a choice filter.
    private func withdrawChoices(_ command: MediaChoiceCommand) {
        let shown = mediaChoiceOverlay.withdraw(command.held, ids: command.heldIDs)
        showChoices(shown)
        projectionIntentContinuation.yield(.choicesWithdrawn(request: command.held))
    }

    func dismissMediaChoiceFailure() {
        mediaChoiceFailure = nil
    }

    // MARK: - Undo

    /// Edit ▸ Undo (⌘Z): the window's last change, whichever kind — a like, a Move to
    /// Trash, an edit.
    func undoLastChange() {
        guard windowUndoManager.canUndo else { return }
        let name = windowUndoManager.undoActionName
        windowUndoManager.undo()
        publishUndoState()
        OtosLog.ui.noticeOperation("undo", phase: "applied", fields: ["action": name])
    }

    /// Edit ▸ Redo (⇧⌘Z).
    func redoLastChange() {
        guard windowUndoManager.canRedo else { return }
        let name = windowUndoManager.redoActionName
        windowUndoManager.redo()
        publishUndoState()
        OtosLog.ui.noticeOperation("redo", phase: "applied", fields: ["action": name])
    }

    /// Registers the act's undo as it is shown. The handler holds the record; the manager
    /// holds its target unretained.
    private func registerMediaChoiceUndo(_ record: MediaChoiceUndoRecord) {
        // Explicit group: a choice from a menu or the keyboard is inside the user's event, a
        // VoiceOver action or a test is not, and the entry must be one group either way.
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: record) { [weak self, record] _ in
            self?.flipMediaChoices(record)
        }
        windowUndoManager.setActionName(record.actionName)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Takes the act's entries, undo or redo, back off the stack.
    private func removeMediaChoiceUndo(_ record: MediaChoiceUndoRecord) {
        windowUndoManager.removeAllActions(withTarget: record)
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()` / `redo()`: files the opposite entry synchronously —
    /// the manager is undoing or redoing right now, so the entry lands on the other stack —
    /// shows the restore at once, and enqueues it through the serial lane.
    private func flipMediaChoices(_ record: MediaChoiceUndoRecord) {
        let undoing = windowUndoManager.isUndoing
        windowUndoManager.registerUndo(withTarget: record) { [weak self, record] _ in
            self?.flipMediaChoices(record)
        }
        windowUndoManager.setActionName(record.actionName)
        let shown = record.shown(undoing: undoing)
        let ids = state.mediaGrid.orderedAssetIDs.filter { shown[$0] != nil }
        revealUndoneChange(ids)
        let held = holdChoices(shown)
        enqueueMediaChoice(MediaChoiceCommand(
            write: .restore(record, undoing: undoing),
            held: held,
            heldIDs: Array(shown.keys),
            record: nil,
            origin: undoing ? .undo : .redo
        ))
        OtosLog.ui.notice(
            "op=mediaChoice.restore count=\(shown.count, privacy: .public) origin=\(undoing ? "undo" : "redo", privacy: .public)"
        )
    }

    /// Undo and redo show what they change (Undo and redo, HIG; `hig-validation.md` F-18):
    /// when the items a restore touches are not the current targets, they become the
    /// selection — the loupe moves to the first, the grid scrolls to it — so a change to a
    /// photo out of view is never made unseen. Items outside the shown scope stay unrevealed.
    func revealUndoneChange(_ ids: [MediaAssetID]) {
        let changed = Set(ids)
        let shown = state.mediaGrid.orderedAssetIDs.filter(changed.contains)
        guard !shown.isEmpty, Set(targetIDs(.current)) != Set(shown) else { return }
        selectAssets(shown)
        OtosLog.ui.noticeOperation("undo.reveal", phase: "selected", fields: ["count": "\(shown.count)"])
    }

    func publishUndoState() {
        let next = UndoMenuState(
            canUndo: windowUndoManager.canUndo,
            canRedo: windowUndoManager.canRedo,
            undoTitle: windowUndoManager.undoMenuItemTitle,
            redoTitle: windowUndoManager.redoMenuItemTitle
        )
        if undoMenuState != next {
            undoMenuState = next
        }
    }

    /// Advance After Choice: the item after the last target becomes the target, in the step
    /// the choice is shown in. A story moves itself; a choice made while it plays leaves its
    /// position alone.
    private func advanceAfterChoice(from last: MediaAssetID?) {
        let orderedIDs = state.mediaGrid.orderedAssetIDs
        guard advanceAfterMediaChoice, story == nil, let last,
              let index = orderedIDs.firstIndex(of: last), index + 1 < orderedIDs.count
        else {
            return
        }
        let next = orderedIDs[index + 1]
        switch viewMode {
        case .grid:
            gridSelection = gridSelection.plainClick(next)
        case .loupe:
            gridSelection = gridSelection.plainClick(next)
            setFocus(next)
        case .compare:
            let pair = ComparePairPolicy.click(next, replacing: activeComparePane, pair: comparePair, orderedIDs: orderedIDs)
            applyComparePair(pair, orderedIDs: orderedIDs)
        }
        OtosLog.ui.notice("op=mediaChoice.advance phase=completed moved=1")
    }

    private func updatePaneMediaChoices(_ assignments: [MediaAssetID: MediaChoice]) {
        for slot in PaneSlot.allCases {
            guard let preview = panePreviews[slot], let choice = assignments[preview.id], preview.mediaChoice != choice else {
                continue
            }
            panePreviews[slot] = PanePreview(
                id: preview.id,
                image: preview.image,
                mediaChoice: choice,
                uprightPixelSize: preview.uprightPixelSize,
                editRecipe: preview.editRecipe,
                renderedRevision: preview.renderedRevision
            )
        }
    }
}
