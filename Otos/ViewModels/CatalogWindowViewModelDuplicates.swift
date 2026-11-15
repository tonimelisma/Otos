import AppKit
import Foundation
import OSLog

// Duplicates intents (ADR 0042)
//
// Projection publishes the groups on `CatalogWindowState.duplicates` in every scope; this
// file owns what is specific to working through them: the copy the user clicked in each
// group and the rule set for each folder (`DuplicatesSession`), and the intents — Keep
// This Copy, a folder rule, Keep All Copies, Review Again, Move Copies to Trash, and opening
// a group. Moving copies goes through `moveMediaToTrash`, the one Move to Trash path, so
// its undo, its download question and its queue are the ordinary ones.

extension CatalogWindowViewModel {
    /// Whether the detail pane is the duplicates list. Read from the published scope
    /// for the reason `showsPlacesMap` gives: the pane shows `state`, not the intent.
    var showsDuplicatesList: Bool {
        state.resolvedSidebarSelection == .duplicates
    }

    /// Whether the list's acts apply: the pane shows the list and the list is the scope
    /// the user selected. Between a click on another row and its publication the list stays
    /// on screen, but it is no longer the user's scope, so nothing on it acts.
    var actsOnDuplicatesList: Bool {
        showsDuplicatesList && showsSelectedScope
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

    /// Picks whose copy left are forgotten, when the groups changed; the last move's receipt
    /// is the list's, so leaving the list ends it. Unchanged groups are the last
    /// publication's own (`CatalogWindowState.sharingUnchanged`), so telling them unchanged costs nothing.
    func applyDuplicatesState(previous: CatalogWindowState, next: CatalogWindowState) {
        if let duplicates = next.duplicates, duplicates != previous.duplicates {
            duplicatesSession.forgetPicks(absentFrom: duplicates)
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

    /// An arrow key on a photo, through the grid's click intent: the list's selection is
    /// the ordinary media selection, which Photo commands, ⌘⌫ and Undo's reveal all read.
    func selectDuplicateCopy(_ hit: MediaAssetID?, modifiers: NSEvent.ModifierFlags, orderedIDs: [MediaAssetID]) {
        applyGridClick(hit: hit, modifiers: modifiers, orderedIDs: orderedIDs)
        setFocus(hit)
    }

    /// The intents the passive list calls.
    var duplicatesActions: DuplicatesActions {
        // Each act checks, when it is called, that the list is still the user's scope.
        DuplicatesActions(
            select: { [weak self] hit, modifiers, order in
                guard let self, actsOnDuplicatesList else { return }
                selectDuplicateCopy(hit, modifiers: modifiers, orderedIDs: order)
            },
            keep: { [weak self] id in
                guard let self, actsOnDuplicatesList else { return }
                keepDuplicateCopy(id)
            },
            setRule: { [weak self] rule, set in
                guard let self, actsOnDuplicatesList else { return }
                setDuplicateFolderRule(rule, for: set)
            },
            keepAll: { [weak self] group in
                guard let self, actsOnDuplicatesList else { return }
                keepAllDuplicateCopies([group])
            },
            reviewAgain: { [weak self] groups in
                guard let self, actsOnDuplicatesList else { return }
                reviewKeptDuplicateGroups(groups)
            },
            openGroup: { [weak self] in
                guard let self, actsOnDuplicatesList else { return }
                openSelectedDuplicateGroup()
            },
            openGroupContaining: { [weak self] id in
                guard let self, actsOnDuplicatesList else { return }
                openDuplicateGroup(containing: id)
            },
            moveToTrashNow: { [weak self] id in
                guard let self, actsOnDuplicatesList else { return }
                moveMediaToTrash([id])
            },
            moveAll: { [weak self] in
                guard let self, actsOnDuplicatesList else { return }
                moveDuplicatesToTrash()
            },
            undoMove: { [weak self] in
                guard let self, actsOnDuplicatesList else { return }
                undoLastChange()
            },
            revealNeedingChoice: { [weak self] in
                guard let self, actsOnDuplicatesList else { return }
                revealDuplicateGroupNeedingChoice()
            }
        )
    }

    /// A click on a photo, Space, and Photo ▸ Keep This Copy: this copy stays and the rest
    /// of its group goes, whatever its folder's rule says.
    func keepDuplicateCopy(_ id: MediaAssetID) {
        guard let group = duplicateGroup(containing: id), !group.isKept else {
            return
        }
        duplicatesSession.picks[group.id] = id
        duplicatesSession.receipt = nil
        OtosLog.ui.noticeOperation("duplicates.keep", phase: "pick", fields: [
            "copies": "\(group.copies.count)", "kind": group.id.kindName,
        ])
    }

    func keepSelectedDuplicateCopy() {
        guard let id = orderedSelectedAssetIDs.first else {
            return
        }
        keepDuplicateCopy(id)
    }

    var canKeepSelectedDuplicateCopy: Bool {
        actsOnDuplicatesList && orderedSelectedAssetIDs.count == 1
            && orderedSelectedAssetIDs.first.flatMap(duplicateGroup(containing:)).map { !$0.isKept } == true
    }

    /// A folder's rule: every group in that folder set keeps what the rule says, except
    /// the groups whose photo the user clicked. Choosing a rule clears none of those picks.
    func setDuplicateFolderRule(_ rule: DuplicateFolderRule, for set: DuplicateFolderSet) {
        duplicatesSession.rules[set] = rule == .automatic ? nil : rule
        duplicatesSession.receipt = nil
        OtosLog.ui.noticeOperation("duplicates.keep", phase: "rule", fields: [
            "folders": "\(set.folders.count)", "rule": "\(rule)",
        ])
    }

    /// The bar's act: every group's extra copies move to the Trash through the one Move to
    /// Trash path, carrying their likes and edits onto the kept copy that lacks them.
    func moveDuplicatesToTrash() {
        guard canMoveDuplicatesToTrash, let tally = duplicatesTally else {
            return
        }
        OtosLog.ui.noticeOperation("duplicates.move", phase: "start", fields: [
            "count": "\(tally.itemsToMove.count)", "carries": "\(tally.carries.count)",
        ])
        // The receipt is written once the Store has hidden the copies (`performMoveToTrash`).
        moveMediaToTrash(tally.itemsToMove, carrying: tally.carries)
    }

    var canMoveDuplicatesToTrash: Bool {
        actsOnDuplicatesList && mediaTrashTask == nil && duplicatesTally?.itemsToMove.isEmpty == false
    }

    /// What ⌘⌫ moves on this list: the extra copies of the groups the selection touches,
    /// never a kept copy, so Select All then ⌘⌫ is the bar's act and not the loss of every
    /// copy.
    func selectedDuplicatesToMove() -> (ids: [MediaAssetID], carries: [DuplicateCarry]) {
        let resolutions = selectedDuplicateGroups().compactMap(duplicatesSession.resolution(of:))
        return (resolutions.flatMap(\.moving), resolutions.flatMap(\.carries))
    }

    /// The groups the selection touches, in list order.
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
        actsOnDuplicatesList && selectedDuplicateGroups().contains { !$0.isKept }
    }

    /// Photo ▸ Keep All Copies and a photo's context menu: the groups are set aside,
    /// remembered per pair of copies, and listed under Kept. Undoable.
    func keepAllDuplicateCopies(_ groups: [DuplicateGroup]? = nil) {
        let targets = (groups ?? selectedDuplicateGroups()).filter { !$0.isKept }
        guard !targets.isEmpty else {
            return
        }
        submitDuplicatesKeepAll(targets.map { $0.copies.map(\.id) }, actionName: "Keep All Copies")
    }

    /// `6 photos need your choice · Show`: selects the first group whose copies hold work
    /// that cannot be combined and that the user has not decided.
    func revealDuplicateGroupNeedingChoice() {
        guard let group = state.duplicates?.activeGroups.first(where: { $0.defaultKeep == nil && duplicatesSession.picks[$0.id] == nil })
        else {
            return
        }
        selectAssets(group.copies.map(\.id))
    }

    /// Return on a photo: the group in Compare (two copies) or Loupe, the group as the
    /// filmstrip. The sidebar keeps Duplicates highlighted (`SidebarSelection.sidebarRow`).
    func openSelectedDuplicateGroup() {
        guard let group = selectedDuplicateGroups().first else {
            return
        }
        openDuplicateGroup(group, mode: group.copies.count == 2 ? .compare : .loupe)
    }

    /// Double-click on a photo: that photo's group, whatever the selection holds at that
    /// instant.
    func openDuplicateGroup(containing id: MediaAssetID) {
        guard let group = duplicateGroup(containing: id) else {
            return
        }
        openDuplicateGroup(group, mode: group.copies.count == 2 ? .compare : .loupe)
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
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
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
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
        ))
    }

    // MARK: - Keep All

    private func submitDuplicatesKeepAll(_ groups: [[MediaAssetID]], actionName: String) {
        submitDuplicatesIntent(.keepAll(groups: groups, actionName: actionName))
    }

    var canReviewSelectedDuplicateGroups: Bool {
        actsOnDuplicatesList && selectedDuplicateGroups().contains(where: \.isKept)
    }

    /// Review Again, on a kept group's header or Photo ▸ Review Again on the selected kept
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
