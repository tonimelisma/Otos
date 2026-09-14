import Foundation
import OSLog

/// Curation intent guide
///
/// A curation command is captured on the MainActor, then delivered losslessly to the
/// Store's one-row-update owner. The command carries the display/query facts needed to
/// reject stale post-await navigation; it never carries a catalog row or a filesystem
/// fact. Grid, loupe, compare, menu, keyboard, accessibility, context menu and inline
/// controls all call `submitMediaChoice(_:target:origin:)`.
///
/// Undo (APP-039). A user command's inverse is registered on `curationUndoManager`
/// when the Store confirms the write and reports the prior choice per asset — the
/// prior is catalog truth, so it is read where truth lives, never guessed from a tile
/// cache. Undo and redo enqueue the same command type through the same serial stream
/// (so they order after any user choice still in flight), carry per-asset assignments
/// because a batch may have held mixed priors, never advance the selection, and
/// register their own inverse synchronously at fire time so the manager files it on
/// the opposite stack. Move to Trash is not registered here: Finder's Put Back is its
/// undo (ADR 0022).
nonisolated enum MediaChoiceTarget: Equatable {
    case current
    case item(MediaAssetID)
    case compare(PanePosition)
}

nonisolated enum MediaChoiceOrigin: String, Equatable {
    case menu
    case keyboard
    case inline
    case accessibility
    case contextMenu
    case undo
    case redo

    /// Undo and redo restore recorded values; only a user's own choice registers an
    /// inverse at completion or advances the selection.
    var isUserChoice: Bool {
        switch self {
        case .undo, .redo: false
        default: true
        }
    }
}

struct MediaChoiceCommand: Equatable {
    /// The choice per asset. A user choice assigns one value to every target; an undo
    /// or redo restores whatever each asset held.
    let assignments: [MediaAssetID: MediaChoice]
    /// Targets in display order — the order the batch was resolved in.
    let ids: [MediaAssetID]
    /// Menu title for the undo entry: `Like`, `Dislike`, `Mark as Not Rated`.
    let actionName: String
    let target: MediaChoiceTarget
    let mode: BrowserViewMode
    let descriptor: CatalogQueryDescriptor
    let queryGeneration: UInt64
    let orderedIDs: [MediaAssetID]
    let selection: GridSelection
    let comparePair: ComparePair
    let comparePane: PanePosition
    let advanceFrom: MediaAssetID?
    let advanceTo: MediaAssetID?
    let origin: MediaChoiceOrigin
}

/// What Edit ▸ Undo / Redo render. Published by the ViewModel after every registration,
/// undo and redo, because `UndoManager` itself is not observable.
nonisolated struct CurationUndoState: Equatable, Sendable {
    var canUndo = false
    var canRedo = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"
}

extension CatalogWindowViewModel {
    var hasMediaChoiceTarget: Bool {
        !mediaChoiceTargetIDs(.current).isEmpty
    }

    func setAdvanceAfterMediaChoice(_ enabled: Bool) {
        guard advanceAfterMediaChoice != enabled else {
            return
        }
        advanceAfterMediaChoice = enabled
        preferences.set(enabled, forKey: Self.advanceAfterMediaChoiceDefaultsKey)
    }

    func submitMediaChoice(
        _ choice: MediaChoice,
        target: MediaChoiceTarget = .current,
        origin: MediaChoiceOrigin = .menu
    ) {
        if case let .compare(position) = target {
            activeComparePane = position
        }
        let ids = mediaChoiceTargetIDs(target)
        guard !ids.isEmpty else {
            return
        }
        let orderedIDs = state.mediaGrid.orderedAssetIDs
        let advanceFrom = ids.last
        let advanceTo: MediaAssetID? = advanceFrom.flatMap { id in
            guard let index = orderedIDs.firstIndex(of: id) else {
                return nil
            }
            return orderedIDs.dropFirst(index + 1).first
        }
        enqueueMediaChoice(
            assignments: Dictionary(uniqueKeysWithValues: ids.map { ($0, choice) }),
            ids: ids,
            actionName: choice.actionLabel,
            target: target,
            advanceFrom: advanceFrom,
            advanceTo: advanceTo,
            origin: origin
        )
        OtosLog.ui.notice(
            "op=mediaChoice.submit choice=\(choice.rawValue, privacy: .public) count=\(ids.count, privacy: .public) origin=\(origin.rawValue, privacy: .public)"
        )
    }

    private func enqueueMediaChoice(
        assignments: [MediaAssetID: MediaChoice],
        ids: [MediaAssetID],
        actionName: String,
        target: MediaChoiceTarget,
        advanceFrom: MediaAssetID?,
        advanceTo: MediaAssetID?,
        origin: MediaChoiceOrigin
    ) {
        let command = MediaChoiceCommand(
            assignments: assignments,
            ids: ids,
            actionName: actionName,
            target: target,
            mode: viewMode,
            descriptor: queryDescriptor,
            queryGeneration: queryGeneration,
            orderedIDs: state.mediaGrid.orderedAssetIDs,
            selection: gridSelection,
            comparePair: comparePair,
            comparePane: activeComparePane,
            advanceFrom: advanceFrom,
            advanceTo: advanceTo,
            origin: origin
        )
        mediaChoiceContinuation.yield(command)
    }

    func mediaChoiceTargetIDs(_ target: MediaChoiceTarget) -> [MediaAssetID] {
        let ordered = state.mediaGrid.orderedAssetIDs
        switch target {
        case .current:
            switch viewMode {
            case .grid:
                return orderedSelectedAssetIDs
            case .loupe:
                return focusedAssetID.map { [$0] } ?? []
            case .compare:
                return compareID(for: activeComparePane).map { [$0] } ?? []
            }
        case let .item(id):
            return ordered.contains(id) ? [id] : []
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

    func startMediaChoiceForwarding(store: CatalogStore) {
        mediaChoiceForwardingTask = Task { [weak self, mediaChoiceStream, store] in
            for await command in mediaChoiceStream {
                guard !Task.isCancelled else {
                    break
                }
                do {
                    let result = try await store.setMediaChoices(command.assignments)
                    guard result.accepted else {
                        OtosLog.ui.notice(
                            "op=mediaChoice.persist outcome=noRows origin=\(command.origin.rawValue, privacy: .public)"
                        )
                        continue
                    }
                    guard let self else {
                        break
                    }
                    updatePaneMediaChoices(command.assignments)
                    completeMediaChoice(command)
                    if command.origin.isUserChoice {
                        registerUndo(inverseOf: command, previous: result.previous)
                    }
                } catch {
                    OtosLog.persistence.error(
                        "op=mediaChoice.persist failed=\(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    // MARK: - Undo

    /// Edit ▸ Undo (⌘Z).
    func undoCuration() {
        guard curationUndoManager.canUndo else { return }
        curationUndoManager.undo()
        publishUndoState()
        OtosLog.ui.notice("op=mediaChoice.undo")
    }

    /// Edit ▸ Redo (⇧⌘Z).
    func redoCuration() {
        guard curationUndoManager.canRedo else { return }
        curationUndoManager.redo()
        publishUndoState()
        OtosLog.ui.notice("op=mediaChoice.redo")
    }

    /// Registers the inverse of a confirmed user choice: restore each asset the write
    /// actually changed to the value the Store reported it held.
    private func registerUndo(inverseOf command: MediaChoiceCommand, previous: [MediaAssetID: MediaChoice]) {
        let restored = previous.filter { command.assignments[$0.key] != $0.value }
        guard !restored.isEmpty else { return }
        let inverse = command.assignments.filter { restored[$0.key] != nil }
        let name = command.actionName
        // Explicit groups: registration happens on a store completion, not inside an
        // AppKit event, so the manager's per-event grouping has nothing to close.
        curationUndoManager.beginUndoGrouping()
        curationUndoManager.registerUndo(withTarget: self) { model in
            model.restoreMediaChoices(restored, inverse: inverse, actionName: name)
        }
        curationUndoManager.setActionName(name)
        curationUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()` / `redo()`: files the opposite entry
    /// synchronously — the manager is undoing or redoing right now, so the entry
    /// lands on the other stack — then enqueues the restore through the serial lane.
    private func restoreMediaChoices(
        _ assignments: [MediaAssetID: MediaChoice],
        inverse: [MediaAssetID: MediaChoice],
        actionName: String
    ) {
        let origin: MediaChoiceOrigin = curationUndoManager.isUndoing ? .undo : .redo
        curationUndoManager.registerUndo(withTarget: self) { model in
            model.restoreMediaChoices(inverse, inverse: assignments, actionName: actionName)
        }
        curationUndoManager.setActionName(actionName)
        let ids = state.mediaGrid.orderedAssetIDs.filter { assignments[$0] != nil }
        enqueueMediaChoice(
            assignments: assignments,
            ids: ids,
            actionName: actionName,
            target: .current,
            advanceFrom: nil,
            advanceTo: nil,
            origin: origin
        )
        OtosLog.ui.notice(
            "op=mediaChoice.restore count=\(assignments.count, privacy: .public) origin=\(origin.rawValue, privacy: .public)"
        )
    }

    func publishUndoState() {
        let next = CurationUndoState(
            canUndo: curationUndoManager.canUndo,
            canRedo: curationUndoManager.canRedo,
            undoTitle: curationUndoManager.undoMenuItemTitle,
            redoTitle: curationUndoManager.redoMenuItemTitle
        )
        if curationUndoState != next {
            curationUndoState = next
        }
    }

    private func completeMediaChoice(_ command: MediaChoiceCommand) {
        guard command.origin.isUserChoice,
              advanceAfterMediaChoice,
              let advanceTo = command.advanceTo,
              viewMode == command.mode,
              queryDescriptor == command.descriptor,
              queryGeneration == command.queryGeneration,
              state.mediaGrid.orderedAssetIDs.contains(advanceTo)
        else {
            return
        }

        switch command.mode {
        case .grid:
            guard gridSelection == command.selection else { return }
            gridSelection = gridSelection.plainClick(advanceTo)
        case .loupe:
            guard focusedAssetID == command.ids.first else { return }
            gridSelection = gridSelection.plainClick(advanceTo)
            setFocus(advanceTo)
            refreshPanePreviews()
        case .compare:
            guard comparePair == command.comparePair,
                  activeComparePane == command.comparePane
            else { return }
            let next = ComparePairPolicy.click(
                advanceTo,
                replacing: command.comparePane,
                pair: comparePair,
                orderedIDs: state.mediaGrid.orderedAssetIDs
            )
            applyComparePair(next, orderedIDs: state.mediaGrid.orderedAssetIDs)
        }
        OtosLog.ui.notice(
            "op=mediaChoice.advance phase=completed moved=1"
        )
    }

    private func updatePaneMediaChoices(_ assignments: [MediaAssetID: MediaChoice]) {
        for slot in PaneSlot.allCases {
            guard let preview = panePreviews[slot], let choice = assignments[preview.id] else {
                continue
            }
            panePreviews[slot] = PanePreview(
                id: preview.id,
                image: preview.image,
                mediaChoice: choice
            )
        }
    }
}
