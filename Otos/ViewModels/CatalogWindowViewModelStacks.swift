import Foundation
import OSLog

/// Stack intents (ADR 0052): expanding and collapsing a stack, Make Key Photo, and the
/// `JPG`/`RAW` switch. Every surface — Photo menu, S and ⇧S, the tile badge, the loupe
/// capsule and the edit panel's switch — calls one of these. Expansion is window state
/// sent to the projection with the query request; the key choice is the one stack fact the
/// user authors, written through its own serial lane (`stackKeyStream`) and undoable.
struct StackKeyCommand {
    /// Each member's new stamp: now for the chosen member, nil for the others.
    let stamps: [MediaAssetID: Int64?]
    let actionName: String
    /// False for undo and redo, which file their own opposite entry.
    let registersUndo: Bool
}

extension CatalogWindowViewModel {
    /// The stacks the current targets show, collapsed and expanded.
    private var targetStacks: (collapsed: [PhotoStack], expanded: [PhotoStack]) {
        let stacks = state.mediaGrid.stacks
        var seen = Set<PhotoStackID>()
        var collapsed: [PhotoStack] = []
        var expanded: [PhotoStack] = []
        for id in targetIDs(.current) {
            if let stack = stacks.collapsed[id], seen.insert(stack.id).inserted {
                collapsed.append(stack)
            } else if let stack = stacks.expanded[id], seen.insert(stack.id).inserted {
                expanded.append(stack)
            }
        }
        return (collapsed, expanded)
    }

    /// Photo ▸ Expand Stack / Collapse Stack: enabled while a target shows a stack.
    var canToggleStackExpansion: Bool {
        let stacks = targetStacks
        return !stacks.collapsed.isEmpty || !stacks.expanded.isEmpty
    }

    /// `Collapse Stack` when every targeted stack is expanded, else `Expand Stack`.
    var stackExpansionTitle: String {
        let stacks = targetStacks
        return stacks.collapsed.isEmpty && !stacks.expanded.isEmpty ? "Collapse Stack" : "Expand Stack"
    }

    /// S and the menu item: expands every targeted collapsed stack, or, when none is
    /// collapsed, collapses every targeted expanded one.
    func toggleStackExpansion() {
        let stacks = targetStacks
        if !stacks.collapsed.isEmpty {
            setExpandedStacks(expandedStacks.union(stacks.collapsed.map(\.id)))
        } else if !stacks.expanded.isEmpty {
            setExpandedStacks(expandedStacks.subtracting(stacks.expanded.map(\.id)))
        }
    }

    /// A click on a tile's stack badge: expands or collapses that tile's stack alone.
    func toggleStack(shownBy id: MediaAssetID) {
        guard let stack = state.mediaGrid.stacks.stack(shownBy: id) else { return }
        if expandedStacks.contains(stack.id) {
            setExpandedStacks(expandedStacks.subtracting([stack.id]))
        } else {
            setExpandedStacks(expandedStacks.union([stack.id]))
        }
    }

    /// The one photo Make Key Photo and the `JPG`/`RAW` switch act on, and its stack.
    private var keyTarget: (id: MediaAssetID, stack: PhotoStack)? {
        let ids = targetIDs(.current)
        guard ids.count == 1, let id = ids.first, let stack = state.mediaGrid.stacks.stack(shownBy: id) else {
            return nil
        }
        return (id, stack)
    }

    /// Photo ▸ Make Key Photo (⇧S): enabled on one member of an expanded stack that is not
    /// its key already.
    var canMakeKeyPhoto: Bool {
        guard let target = keyTarget else { return false }
        return state.mediaGrid.stacks.expanded[target.id] != nil && target.stack.key != target.id
    }

    func makeKeyPhoto() {
        guard canMakeKeyPhoto, let target = keyTarget else { return }
        submitStackKey(target.id, in: target.stack)
    }

    /// The pair the loupe or the edit panel shows, for its `JPG`/`RAW` switch: the one
    /// target's stack when it is a pair, else nil and the switch is absent.
    var shownPair: PhotoStack? {
        guard let target = keyTarget, target.stack.id.kind == .pair else { return nil }
        return target.stack
    }

    /// The `JPG`/`RAW` switch: shows `member` in its pair's place. The focus and the
    /// selection follow it when the new state arrives (`carrySelectionIntoStacks`).
    func showPairMember(_ member: MediaAssetID) {
        guard let target = keyTarget, target.stack.members.contains(member), member != target.id else { return }
        if state.mediaGrid.stacks.expanded[target.id] != nil {
            // An expanded pair shows both files; the switch moves to the other one.
            if viewMode == .loupe {
                setFocus(member)
            } else {
                gridSelection = GridSelection.empty.plainClick(member)
            }
            return
        }
        submitStackKey(member, in: target.stack)
    }

    private func submitStackKey(_ member: MediaAssetID, in stack: PhotoStack) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var stamps: [MediaAssetID: Int64?] = [:]
        for candidate in stack.members {
            stamps[candidate] = candidate == member ? now : nil
        }
        OtosLog.ui.noticeOperation("stack.key", phase: "submitted", fields: [
            "kind": stack.id.kind.rawValue, "members": "\(stack.members.count)",
        ])
        stackKeyContinuation.yield(StackKeyCommand(stamps: stamps, actionName: "Make Key Photo", registersUndo: true))
    }

    func startStackKeyForwarding(store: CatalogStore) {
        stackKeyForwardingTask = Task { [weak self, stackKeyStream, store] in
            for await command in stackKeyStream {
                guard !Task.isCancelled else { break }
                do {
                    let previous = try await store.setStackKeyChoices(command.stamps)
                    guard let self else { break }
                    if command.registersUndo, !previous.isEmpty {
                        registerStackKeyUndo(restoring: previous, redo: command.stamps, actionName: command.actionName)
                    }
                } catch {
                    OtosLog.persistence.errorOperation("stack.key", phase: "failed", fields: [
                        "error": String(describing: error),
                    ])
                }
            }
        }
    }

    private func registerStackKeyUndo(
        restoring previous: [MediaAssetID: Int64?],
        redo: [MediaAssetID: Int64?],
        actionName: String
    ) {
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.restoreStackKeys(previous, inverse: redo, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()` / `redo()`: files the opposite entry synchronously,
    /// then writes the restore through the serial lane.
    private func restoreStackKeys(
        _ stamps: [MediaAssetID: Int64?],
        inverse: [MediaAssetID: Int64?],
        actionName: String
    ) {
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.restoreStackKeys(inverse, inverse: stamps, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        stackKeyContinuation.yield(StackKeyCommand(stamps: stamps, actionName: actionName, registersUndo: false))
        publishUndoState()
    }

    /// A selection or focus on a member its stack now hides — the stack collapsed, or its
    /// key changed — moves to the member shown in its place, so neither is dropped.
    func carrySelectionIntoStacks(_ stacks: CatalogGridStacks) {
        let map = stacks.shownForHiddenMember
        guard !map.isEmpty else { return }
        gridSelection = gridSelection.remapped(by: map)
        if let focus = focusedAssetID, let shown = map[focus] {
            setFocus(shown)
        }
    }
}
