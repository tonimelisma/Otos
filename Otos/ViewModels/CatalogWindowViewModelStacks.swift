import Foundation
import OSLog

/// Stack intents (ADR 0052): expanding and collapsing a stack, Make Key Photo, and the
/// `JPG`/`RAW` switch. Every surface — Photo menu, S and ⇧S, the tile badge, the loupe
/// capsule and the edit panel's switch — calls one of these. Expansion is window state
/// sent to the projection with the query request; the key choice is the one stack fact the
/// user authors, written through its own serial lane (`stackKeyStream`) and undoable.
struct StackKeyCommand {
    /// Whose key the stamps choose: a pair's file or a burst's frame, each its own column.
    let kind: PhotoStackKind
    /// Each member's new stamp: now for the chosen member, nil for the others.
    let stamps: [MediaAssetID: Int64?]
    let actionName: String
    /// False for undo and redo, which file their own opposite entry.
    let registersUndo: Bool
}

extension CatalogWindowViewModel {
    /// The stacks the current targets show, collapsed and expanded.
    private var targetStacks: (collapsed: [PhotoStack], expanded: [PhotoStack]) {
        let stacks = parts.gridStacks
        var seen = Set<PhotoStackID>()
        var collapsed: [PhotoStack] = []
        var expanded: [PhotoStack] = []
        for id in targetIDs(.current) {
            if let stack = stacks.collapsed(shownBy: id) {
                if seen.insert(stack.id).inserted {
                    collapsed.append(stack)
                }
            } else if let stack = stacks.expanded(shownBy: id), seen.insert(stack.id).inserted {
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

    /// A click on a tile's stack badge: expands the stack the tile stands for, or collapses
    /// the expanded stack it is in. Nothing until the selected scope's state is applied
    /// (APP-080).
    func toggleStack(shownBy id: MediaAssetID) {
        guard showsSelectedScope else { return }
        let stacks = parts.gridStacks
        if let stack = stacks.collapsed(shownBy: id) {
            setExpandedStacks(expandedStacks.union([stack.id]))
        } else if let stack = stacks.expanded(shownBy: id) {
            setExpandedStacks(expandedStacks.subtracting([stack.id]))
        }
    }

    /// The one photo Make Key Photo and the `JPG`/`RAW` switch act on.
    private var singleTarget: MediaAssetID? {
        let ids = targetIDs(.current)
        return ids.count == 1 ? ids.first : nil
    }

    /// Photo ▸ Make Key Photo (⇧S): enabled on one member of an expanded stack that is not
    /// its key already.
    var canMakeKeyPhoto: Bool {
        guard let id = singleTarget, let stack = parts.gridStacks.expanded(shownBy: id) else { return false }
        return stack.key != id
    }

    func makeKeyPhoto() {
        guard canMakeKeyPhoto, let id = singleTarget, let stack = parts.gridStacks.expanded(shownBy: id) else {
            return
        }
        submitStackKey(id, in: stack)
    }

    /// The pair the loupe or the edit panel shows, for its `JPG`/`RAW` switch: the pair the
    /// one target is a file of, else nil and the switch is absent.
    var shownPair: PhotoStack? {
        singleTarget.flatMap(parts.gridStacks.pair(shownBy:))
    }

    /// The pair the loupe offers its own `JPG`/`RAW` switch for: none while the edit panel
    /// shows, whose header holds the one switch then (DES-117).
    var loupePair: PhotoStack? {
        isEditPanelPresented ? nil : shownPair
    }

    /// The `JPG`/`RAW` switch: shows `member` in its pair's place. The focus and the
    /// selection follow it when the new state arrives (`carrySelectionIntoStacks`).
    func showPairMember(_ member: MediaAssetID) {
        guard let id = singleTarget, let pair = parts.gridStacks.pair(shownBy: id),
              pair.members.contains(member), member != id
        else {
            return
        }
        if parts.gridStacks.tiles[id]?.pairExpanded == true {
            // An expanded pair shows both files; the switch moves to the other one.
            if viewMode == .loupe {
                setFocus(member)
            } else {
                gridSelection = GridSelection.empty.plainClick(member)
            }
            return
        }
        submitStackKey(member, in: pair)
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
        stackKeyContinuation.yield(StackKeyCommand(
            kind: stack.id.kind, stamps: stamps, actionName: "Make Key Photo", registersUndo: true
        ))
    }

    func startStackKeyForwarding(store: CatalogStore) {
        stackKeyForwardingTask = Task { [weak self, stackKeyStream, store] in
            for await command in stackKeyStream {
                guard !Task.isCancelled else { break }
                do {
                    let previous = try await store.setStackKeyChoices(command.stamps, kind: command.kind)
                    guard let self else { break }
                    if command.registersUndo, !previous.isEmpty {
                        registerStackKeyUndo(
                            kind: command.kind, restoring: previous, redo: command.stamps, actionName: command.actionName
                        )
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
        kind: PhotoStackKind,
        restoring previous: [MediaAssetID: Int64?],
        redo: [MediaAssetID: Int64?],
        actionName: String
    ) {
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.restoreStackKeys(kind: kind, previous, inverse: redo, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()` / `redo()`: files the opposite entry synchronously,
    /// then writes the restore through the serial lane.
    private func restoreStackKeys(
        kind: PhotoStackKind,
        _ stamps: [MediaAssetID: Int64?],
        inverse: [MediaAssetID: Int64?],
        actionName: String
    ) {
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.restoreStackKeys(kind: kind, inverse, inverse: stamps, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        stackKeyContinuation.yield(StackKeyCommand(
            kind: kind, stamps: stamps, actionName: actionName, registersUndo: false
        ))
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
