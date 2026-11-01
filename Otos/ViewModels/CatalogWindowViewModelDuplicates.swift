import Foundation
import OSLog

// Duplicates intents (ADR 0042)
//
// Projection publishes the groups on `CatalogWindowState.duplicates` in every scope; this
// file owns what is specific to working through them: the user's Keep marks and open
// summaries (`DuplicatesSession`), and the intents — Keep This Copy, Move This Copy to
// Trash, Keep All Copies, Keep Both Libraries, Move Marked Items to Trash, and opening a
// group. Menu items, buttons and VoiceOver actions all call these. Moving copies goes
// through `moveMediaToTrash`, the one Move to Trash path, so its undo, its download question
// and its queue are the ordinary ones.

extension CatalogWindowViewModel {
    /// Whether the detail pane is the duplicates list.
    var showsDuplicatesList: Bool {
        sidebarSelection == .duplicates
    }

    /// Whether Back to Duplicates applies: the browser shows one group under Duplicates.
    var showsDuplicateGroupLeaf: Bool {
        if case .duplicateGroup = sidebarSelection {
            return true
        }
        return false
    }

    /// The sidebar row exists, once the catalog has loaded (APP-044), while any group is
    /// active and while it is selected.
    var showsDuplicatesRow: Bool {
        state.isCatalogLoaded
            && (!state.duplicates.activeGroups.isEmpty || sidebarSelection.sidebarRow == .duplicates)
    }

    /// The row's count: photos with duplicates.
    var duplicatesCount: Int {
        state.duplicates.activeGroups.count
    }

    var duplicatesTally: DuplicatesTally {
        duplicatesSession.tally(in: state.duplicates)
    }

    /// The group holding a copy, among those on screen or kept.
    func duplicateGroup(containing id: MediaAssetID) -> DuplicateGroup? {
        state.duplicates.groups.first { group in group.copies.contains { $0.id == id } }
    }

    // MARK: - State

    func applyDuplicatesState(_ next: CatalogWindowState) {
        duplicatesSession.forgetMarks(absentFrom: next.duplicates)
    }

    // MARK: - Intents

    /// The list's row selection, which is the ordinary media selection: Photo commands,
    /// ⌘⌫ and Undo's reveal all read it.
    func setDuplicatesSelection(_ ids: Set<MediaAssetID>) {
        let ordered = state.mediaGrid.orderedAssetIDs.filter(ids.contains)
        gridSelection = GridSelection(selection: ids, anchor: ordered.first, base: ids)
        setFocus(ordered.first)
    }

    /// The intents the passive list calls.
    var duplicatesActions: DuplicatesActions {
        DuplicatesActions(
            keep: { [weak self] id in self?.setDuplicateKeep(true, for: [id]) },
            moveToTrash: { [weak self] id in self?.setDuplicateKeep(false, for: [id]) },
            keepAll: { [weak self] group in self?.keepAllDuplicateCopies([group]) },
            keepBothLibraries: { [weak self] pair in self?.keepBothLibraries(pair) },
            togglePair: { [weak self] pair in self?.toggleDuplicateLibraryPair(pair) },
            toggleKept: { [weak self] in self?.duplicatesSession.showsKept.toggle() },
            openGroup: { [weak self] in self?.openSelectedDuplicateGroup() },
            moveMarked: { [weak self] in self?.moveMarkedDuplicatesToTrash() },
            revealNeedingChoice: { [weak self] in self?.revealDuplicateGroupNeedingChoice() }
        )
    }

    /// Photo ▸ Keep This Copy: the selected copies are kept.
    func keepSelectedDuplicateCopies() {
        setDuplicateKeep(true, for: orderedSelectedAssetIDs)
    }

    /// Photo ▸ Move This Copy to Trash: the selected copies are marked to move. A group
    /// always keeps one copy, so the last kept copy of a group is never marked.
    func markSelectedDuplicateCopiesForTrash() {
        setDuplicateKeep(false, for: orderedSelectedAssetIDs)
    }

    var canKeepSelectedDuplicateCopies: Bool {
        showsDuplicatesList && orderedSelectedAssetIDs.contains { id in
            duplicateGroup(containing: id).map { !duplicatesSession.keeps(id, in: $0) } ?? false
        }
    }

    var canMarkSelectedDuplicateCopiesForTrash: Bool {
        showsDuplicatesList && orderedSelectedAssetIDs.contains { id in
            duplicateGroup(containing: id).map { duplicatesSession.canMoveToTrash(id, in: $0) } ?? false
        }
    }

    func setDuplicateKeep(_ keep: Bool, for ids: [MediaAssetID]) {
        var changed = 0
        for id in ids {
            guard let group = duplicateGroup(containing: id) else {
                continue
            }
            if keep {
                guard !duplicatesSession.keeps(id, in: group) else { continue }
            } else {
                guard duplicatesSession.canMoveToTrash(id, in: group) else { continue }
            }
            duplicatesSession.keepOverrides[id] = keep
            changed += 1
        }
        OtosLog.ui.noticeOperation("duplicates.mark", phase: keep ? "keep" : "move", fields: [
            "requested": "\(ids.count)", "changed": "\(changed)",
        ])
    }

    /// The groups the selection touches, or the one given.
    private func selectedDuplicateGroups() -> [DuplicateGroup] {
        var seen: Set<DuplicateGroupID> = []
        return orderedSelectedAssetIDs.compactMap { id in
            guard let group = duplicateGroup(containing: id), seen.insert(group.id).inserted else {
                return nil
            }
            return group
        }
    }

    var canKeepAllSelectedDuplicateCopies: Bool {
        showsDuplicatesList && selectedDuplicateGroups().contains { !$0.isKept }
    }

    /// Photo ▸ Keep All Copies, and a group's Keep All button: the groups are set aside,
    /// remembered per pair of copies, and listed under Kept. Undoable.
    func keepAllDuplicateCopies(_ groups: [DuplicateGroup]? = nil) {
        let targets = (groups ?? selectedDuplicateGroups()).filter { !$0.isKept }
        guard !targets.isEmpty else {
            return
        }
        submitDuplicatesKeepAll(targets.map { $0.copies.map(\.id) }, actionName: "Keep All Copies")
    }

    /// A library pair's Keep Both Libraries: every group the two libraries share is kept.
    func keepBothLibraries(_ pair: DuplicateLibraryPair) {
        let targets = state.duplicates.activeGroups.filter { $0.libraryPair == pair }
        guard !targets.isEmpty else {
            return
        }
        submitDuplicatesKeepAll(targets.map { $0.copies.map(\.id) }, actionName: "Keep Both Libraries")
    }

    /// The bar's act: every marked copy moves to the Trash, through the one Move to Trash
    /// path.
    func moveMarkedDuplicatesToTrash() {
        let ids = duplicatesTally.itemsToMove
        guard !ids.isEmpty, mediaTrashTask == nil else {
            return
        }
        OtosLog.ui.noticeOperation("duplicates.move", phase: "start", fields: ["count": "\(ids.count)"])
        moveMediaToTrash(ids)
    }

    var canMoveMarkedDuplicatesToTrash: Bool {
        showsDuplicatesList && mediaTrashTask == nil && !duplicatesTally.itemsToMove.isEmpty
    }

    func toggleDuplicateLibraryPair(_ pair: DuplicateLibraryPair) {
        if duplicatesSession.expandedPairs.contains(pair) {
            duplicatesSession.expandedPairs.remove(pair)
        } else {
            duplicatesSession.expandedPairs.insert(pair)
        }
    }

    /// `6 need your choice · Show`: selects the first group that waits.
    func revealDuplicateGroupNeedingChoice() {
        guard let group = state.duplicates.activeGroups.first(where: duplicatesSession.needsChoice)
        else {
            return
        }
        if let pair = group.libraryPair {
            duplicatesSession.expandedPairs.insert(pair)
        }
        selectAssets(group.copies.map(\.id))
    }

    /// Return on a row: the group in Compare (two copies) or Loupe, the group as the
    /// filmstrip. The sidebar keeps Duplicates highlighted (`SidebarSelection.sidebarRow`).
    func openSelectedDuplicateGroup() {
        guard let group = selectedDuplicateGroups().first else {
            return
        }
        let ids = group.copies.map(\.id)
        OtosLog.ui.noticeOperation("duplicates.group", phase: "open", fields: [
            "copies": "\(ids.count)", "kind": group.id.kindName,
        ])
        userHasChosenSource = true
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .duplicateGroup(group.id),
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
        selectAssets(Array(ids.prefix(2)))
        setViewMode(ids.count == 2 ? .compare : .loupe)
    }

    /// Back to Duplicates from a group.
    func returnToDuplicates() {
        guard showsDuplicateGroupLeaf else {
            return
        }
        OtosLog.ui.noticeOperation("duplicates.group", phase: "return")
        setViewMode(.grid)
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .duplicates,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
    }

    // MARK: - Keep All

    private func submitDuplicatesKeepAll(_ groups: [[MediaAssetID]], actionName: String) {
        submitDuplicatesIntent(.keepAll(groups: groups, actionName: actionName))
    }

    private func submitDuplicatesIntent(_ intent: DuplicatesIntent) {
        switch duplicatesIntentContinuation.yield(intent) {
        case .enqueued:
            return
        case .dropped, .terminated:
            OtosLog.ui.error("op=duplicates.intent phase=dropped")
        @unknown default:
            OtosLog.ui.error("op=duplicates.intent phase=unknownYield")
        }
    }

    /// The one consumer of Keep All and its undo, in submission order. Holds the view model
    /// weakly across each wait and ends with the stream.
    func startDuplicatesIntentConsumer() {
        guard duplicatesIntentTask == nil else { return }
        let intents = duplicatesIntentStream
        let store = catalogStore
        duplicatesIntentTask = Task { [weak self, store] in
            for await intent in intents {
                switch intent {
                case let .keepAll(groups, actionName):
                    do {
                        let added = try await store.keepCopiesTogether(groups)
                        if !added.isEmpty {
                            self?.registerKeepAllUndo(added, groups: groups, actionName: actionName)
                        }
                    } catch {
                        OtosLog.ui.errorOperation("duplicates.keepAll", phase: "failed", fields: [
                            "groups": "\(groups.count)", "error": String(describing: error),
                        ])
                    }
                case let .forget(pairs):
                    do {
                        try await store.forgetKeptPairs(pairs)
                    } catch {
                        OtosLog.ui.errorOperation("duplicates.keepAll", phase: "undoFailed", fields: [
                            "pairs": "\(pairs.count)", "error": String(describing: error),
                        ])
                    }
                }
                if self == nil {
                    return
                }
            }
        }
    }

    private func registerKeepAllUndo(_ pairs: Set<DuplicateKeptPair>, groups: [[MediaAssetID]], actionName: String) {
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.undoKeepAll(pairs, groups: groups, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()`: files redo synchronously, then forgets the pairs.
    private func undoKeepAll(_ pairs: Set<DuplicateKeptPair>, groups: [[MediaAssetID]], actionName: String) {
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.submitDuplicatesKeepAll(groups, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        submitDuplicatesIntent(.forget(pairs))
        // The groups come back among those on screen; reveal them (HIG Undo).
        if showsDuplicatesList, let first = groups.first {
            selectAssets(first)
        }
    }
}

/// A Duplicates act that writes the catalog, delivered in the order the user acted.
nonisolated enum DuplicatesIntent: Sendable {
    case keepAll(groups: [[MediaAssetID]], actionName: String)
    case forget(Set<DuplicateKeptPair>)
}
