import Foundation
import OSLog

// Duplicates intents (ADR 0042)
//
// Projection publishes the groups on `CatalogWindowState.duplicates` in every scope; this
// file owns what is specific to working through them: the user's Keep marks and open
// summaries (`DuplicatesSession`), and the intents — Keep This Copy, Don't Keep This Copy,
// Keep Only This Copy, Keep All Copies, Review Again, Keep Both Libraries, Keep Only
// <Library>, Move Extra Copies to Trash, and opening a group. Menu items, buttons and
// VoiceOver actions all call these. Moving copies goes through `moveMediaToTrash`, the one
// Move to Trash path, so its undo, its download question and its queue are the ordinary
// ones.

extension CatalogWindowViewModel {
    /// Whether the detail pane is the duplicates list. Read from the published scope
    /// for the reason `showsPlacesMap` gives: the pane shows `state`, not the intent.
    var showsDuplicatesList: Bool {
        state.resolvedSidebarSelection == .duplicates
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
        guard state.isCatalogLoaded else {
            return false
        }
        return state.duplicates?.activeGroups.isEmpty == false || sidebarSelection.sidebarRow == .duplicates
    }

    /// The row's count, photos with duplicates; nil until the groups are first built.
    var duplicatesCount: Int? {
        state.duplicates?.activeGroups.count
    }

    /// What the bar states and the act moves; nil until the groups are first built.
    var duplicatesTally: DuplicatesTally? {
        state.duplicates.map { duplicatesSession.tally(in: $0) }
    }

    /// The group holding a copy, among those on screen or kept.
    func duplicateGroup(containing id: MediaAssetID) -> DuplicateGroup? {
        state.duplicates?.groups.first { group in group.copies.contains { $0.id == id } }
    }

    // MARK: - State

    /// Groups not built yet say nothing about which copies left, so marks stay. The last
    /// act's receipt is the list's: leaving the list ends it.
    func applyDuplicatesState(_ next: CatalogWindowState) {
        if let duplicates = next.duplicates {
            duplicatesSession.forgetMarks(absentFrom: duplicates)
        }
        if next.resolvedSidebarSelection != .duplicates, duplicatesSession.receipt != nil {
            duplicatesSession.receipt = nil
        }
    }

    /// Whether the bar's receipt may offer Undo: the window's last change is a Move to
    /// Trash — read from the published undo state, the one owner of that fact — and any
    /// later move from the list has replaced the receipt, so Undo takes back the act the
    /// receipt reports and nothing else.
    var canUndoDuplicatesMove: Bool {
        undoMenuState.canUndo && undoMenuState.undoTitle == "Undo \(Self.moveToTrashActionName)"
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
            unkeep: { [weak self] id in self?.setDuplicateKeep(false, for: [id]) },
            keepAll: { [weak self] group in self?.keepAllDuplicateCopies([group]) },
            keepOnly: { [weak self] id in self?.keepOnlyDuplicateCopy(id) },
            reviewAgain: { [weak self] groups in self?.reviewKeptDuplicateGroups(groups) },
            keepBothLibraries: { [weak self] pair in self?.keepBothLibraries(pair) },
            keepOnlyLibrary: { [weak self] library, pair in self?.keepOnlyLibrary(library, of: pair) },
            keepEachLibrary: { [weak self] pair in self?.keepEachLibrary(of: pair) },
            togglePair: { [weak self] pair in self?.toggleDuplicateLibraryPair(pair) },
            openGroup: { [weak self] in self?.openSelectedDuplicateGroup() },
            openGroupContaining: { [weak self] id in self?.openDuplicateGroup(containing: id) },
            compareGroup: { [weak self] group in self?.compareDuplicateGroup(group) },
            moveToTrashNow: { [weak self] id in self?.moveMediaToTrash([id]) },
            moveMarked: { [weak self] in self?.moveMarkedDuplicatesToTrash() },
            undoMove: { [weak self] in self?.undoLastChange() },
            revealNeedingChoice: { [weak self] in self?.revealDuplicateGroupNeedingChoice() }
        )
    }

    /// Photo ▸ Keep This Copy: the selected copies are kept.
    func keepSelectedDuplicateCopies() {
        setDuplicateKeep(true, for: orderedSelectedAssetIDs)
    }

    /// Photo ▸ Keep Only This Copy: the selected copy is kept and every other copy of its
    /// group marked to move.
    func keepOnlySelectedDuplicateCopy() {
        guard let id = orderedSelectedAssetIDs.first else {
            return
        }
        keepOnlyDuplicateCopy(id)
    }

    var canKeepOnlySelectedDuplicateCopy: Bool {
        showsDuplicatesList && orderedSelectedAssetIDs.count == 1
            && orderedSelectedAssetIDs.first.flatMap(duplicateGroup(containing:)).map { !$0.isKept } == true
    }

    func keepOnlyDuplicateCopy(_ id: MediaAssetID) {
        guard let group = duplicateGroup(containing: id), !group.isKept else {
            return
        }
        duplicatesSession.keepOnly(id, in: group)
        duplicatesSession.receipt = nil
        OtosLog.ui.noticeOperation("duplicates.mark", phase: "keepOnly", fields: [
            "copies": "\(group.copies.count)", "kind": group.id.kindName,
        ])
    }

    /// A library pair's Keep Only <Library>: every copy the pair's groups hold in the other
    /// library is marked to move; the act moves them, under its ordinary count.
    func keepOnlyLibrary(_ library: LibraryRootPath, of pair: DuplicateLibraryPair) {
        let groups = state.duplicates?.activeGroups.filter { $0.libraryPair == pair } ?? []
        guard !groups.isEmpty else {
            return
        }
        duplicatesSession.keepOnly(library, in: groups)
        OtosLog.ui.noticeOperation("duplicates.mark", phase: "keepOnlyLibrary", fields: [
            "groups": "\(groups.count)",
        ])
    }

    /// A library pair's Keep One Copy in Each Library: the pair's marks return to the
    /// default, so a Keep Only pick is taken back without the act.
    func keepEachLibrary(of pair: DuplicateLibraryPair) {
        let groups = state.duplicates?.activeGroups.filter { $0.libraryPair == pair } ?? []
        guard !groups.isEmpty else {
            return
        }
        duplicatesSession.forgetMarks(in: groups)
        OtosLog.ui.noticeOperation("duplicates.mark", phase: "keepEachLibrary", fields: [
            "groups": "\(groups.count)",
        ])
    }

    /// Photo ▸ Don't Keep This Copy: the selected copies are marked to move. A group
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
            duplicateGroup(containing: id).map { !$0.isKept && duplicatesSession.canUnkeep(id, in: $0) } ?? false
        }
    }

    /// What ⌘⌫ and Photo ▸ Move to Trash move on this list: the selected rows that are
    /// extra copies — never a kept one, and never a row that was not selected — so Select
    /// All then ⌘⌫ clears the extras and nothing else. A copy is moved now, kept or not,
    /// only by its row's Move to Trash Now.
    func selectedDuplicatesToMove() -> (ids: [MediaAssetID], carries: [DuplicateCarry]) {
        var ids: [MediaAssetID] = []
        var carries: [DuplicateCarry] = []
        for group in selectedDuplicateGroups() where !group.isKept {
            let moving = duplicatesSession.copiesToMove(in: group)
            let selected = Set(orderedSelectedAssetIDs)
            let chosen = moving.filter(selected.contains)
            guard !chosen.isEmpty else { continue }
            ids += chosen
            carries += duplicatesSession.carries(in: group).filter { chosen.contains($0.from) }
        }
        return (ids, carries)
    }

    func setDuplicateKeep(_ keep: Bool, for ids: [MediaAssetID]) {
        var changed = 0
        for id in ids {
            guard let group = duplicateGroup(containing: id), !group.isKept else {
                continue
            }
            if keep {
                guard !duplicatesSession.keeps(id, in: group) else { continue }
                duplicatesSession.keepOverrides[id] = true
                changed += 1
            } else if duplicatesSession.unkeep(id, in: group) {
                changed += 1
            }
        }
        if changed > 0 {
            duplicatesSession.receipt = nil
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
        let targets = state.duplicates?.activeGroups.filter { $0.libraryPair == pair } ?? []
        guard !targets.isEmpty else {
            return
        }
        submitDuplicatesKeepAll(targets.map { $0.copies.map(\.id) }, actionName: "Keep Both Libraries")
    }

    /// The bar's act: every marked copy moves to the Trash, through the one Move to Trash
    /// path, carrying its curation and edit onto the kept copy that lacks them.
    func moveMarkedDuplicatesToTrash() {
        guard let tally = duplicatesTally, !tally.itemsToMove.isEmpty, mediaTrashTask == nil else {
            return
        }
        OtosLog.ui.noticeOperation("duplicates.move", phase: "start", fields: [
            "count": "\(tally.itemsToMove.count)", "carries": "\(tally.carries.count)",
        ])
        // The receipt is written once the Store has hidden the copies (`performMoveToTrash`).
        moveMediaToTrash(tally.itemsToMove, carrying: tally.carries)
    }

    var canMoveMarkedDuplicatesToTrash: Bool {
        showsDuplicatesList && mediaTrashTask == nil && duplicatesTally?.itemsToMove.isEmpty == false
    }

    func toggleDuplicateLibraryPair(_ pair: DuplicateLibraryPair) {
        if duplicatesSession.expandedPairs.contains(pair) {
            duplicatesSession.expandedPairs.remove(pair)
        } else {
            duplicatesSession.expandedPairs.insert(pair)
        }
    }

    /// `6 photos need your choice · Show`: selects the first group that waits.
    func revealDuplicateGroupNeedingChoice() {
        guard let group = state.duplicates?.activeGroups.first(where: duplicatesSession.needsChoice)
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
        openDuplicateGroup(group, mode: group.copies.count == 2 ? .compare : .loupe)
    }

    /// Double-click on a row: that row's group, whatever the selection holds at that
    /// instant.
    func openDuplicateGroup(containing id: MediaAssetID) {
        guard let group = duplicateGroup(containing: id) else {
            return
        }
        openDuplicateGroup(group, mode: group.copies.count == 2 ? .compare : .loupe)
    }

    /// A same-photo group's Compare: versions are told apart by their pixels, so its first
    /// two — the kept version and the next — side by side, the group as the filmstrip.
    func compareDuplicateGroup(_ group: DuplicateGroup) {
        openDuplicateGroup(group, mode: .compare)
    }

    private func openDuplicateGroup(_ group: DuplicateGroup, mode: BrowserViewMode) {
        let ids = group.copies.map(\.id)
        OtosLog.ui.noticeOperation("duplicates.group", phase: "open", fields: [
            "copies": "\(ids.count)", "kind": group.id.kindName, "mode": mode.rawValue,
        ])
        userHasChosenSource = true
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .duplicateGroup(group.id),
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
        selectAssets(Array(ids.prefix(2)))
        setViewMode(mode)
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

    var canReviewSelectedDuplicateGroups: Bool {
        showsDuplicatesList && selectedDuplicateGroups().contains(where: \.isKept)
    }

    /// Review Again, on a kept group's card or Photo ▸ Review Again on the selected kept
    /// groups: forgets the pairs that keep them aside, so they return to the list with their
    /// default. Undoable by its own name: undo keeps them again.
    func reviewKeptDuplicateGroups(_ groups: [DuplicateGroup]? = nil) {
        let targets = (groups ?? selectedDuplicateGroups()).filter(\.isKept)
        guard !targets.isEmpty else {
            return
        }
        let members = targets.map { $0.copies.map(\.id) }
        OtosLog.ui.noticeOperation("duplicates.keepAll", phase: "reviewAgain", fields: [
            "groups": "\(targets.count)",
        ])
        forgetKeptGroups(members, actionName: "Review Again")
    }

    /// Forgets every pair among each group's copies, registering the keep-again as its undo.
    private func forgetKeptGroups(_ groups: [[MediaAssetID]], actionName: String) {
        var pairs: Set<DuplicateKeptPair> = []
        for members in groups {
            for (index, left) in members.enumerated() {
                for right in members[(index + 1)...] {
                    pairs.insert(DuplicateKeptPair(left, right))
                }
            }
        }
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.submitDuplicatesKeepAll(groups, actionName: actionName)
        }
        windowUndoManager.setActionName(actionName)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
        submitDuplicatesIntent(.forget(pairs))
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
