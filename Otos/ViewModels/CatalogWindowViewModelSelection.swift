import AppKit
import Foundation
import OSLog

/// Catalog window selection ownership guide
///
/// `CatalogWindowViewModel` owns the pure `GridSelection` value (selection, ⇧-range
/// anchor, base islands) that is the single source of mouse-selection truth. The AppKit
/// grid and filmstrip are renderers of that value: they swallow `mouseDown`, forward
/// `(hit, modifiers)` synchronously into these intents, receive the updated model as the
/// return value, and write `selectionIndexPaths` from it as the last operation of the
/// gesture — same thread, same ordering, no SwiftUI round-trip on the write path.
///
/// Why the ViewModel owns selection rather than the collection-view controller: loupe and
/// compare both need the selection + anchor, and the AppKit controller deallocates when
/// SwiftUI swaps the detail surface. Two renderers of one selection truth means the truth
/// must live above both.
///
/// Selection writers are exactly four classes: (1) mouse-gesture intents, (2) view-mode
/// intents, (3) gated native-keyboard reconcile, (4) state-driven prune/clear in
/// `applyState`. AppKit's `selectionIndexPaths` is render output only — no structural-apply
/// or programmatic-delta path may compute a model write from `selectedIdentities()` except
/// the gated native-keyboard reconcile.
///
/// Native keyboard selection (⌘A, ⇧-arrows) still writes `selectionIndexPaths` directly;
/// the controller reconciles upward through `reconcileNativeSelection` only when it is
/// not mid-programmatic delta write.
extension CatalogWindowViewModel {
    /// The ⇧-range / "active photo" anchor, if any.
    var selectionAnchor: MediaAssetID? {
        gridSelection.anchor
    }

    /// Selected identities in current display order.
    var orderedSelectedAssetIDs: [MediaAssetID] {
        GridSelection.orderedSelection(
            gridSelection.selection,
            in: state.mediaGrid.orderedAssetIDs
        )
    }

    /// Synchronous mouse-gesture intent. Applies the gesture against the model alone
    /// and returns the updated value so the controller can write `selectionIndexPaths`
    /// as the gesture's last operation. Does not read AppKit live selection.
    @discardableResult
    func applyGridClick(
        hit: MediaAssetID?,
        modifiers: NSEvent.ModifierFlags,
        orderedIDs: [MediaAssetID]
    ) -> GridSelection {
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)

        // Loupe/compare: empty-space clicks are no-ops — selection must keep
        // mirroring focus (loupe) / the pair (compare).
        if viewMode != .grid, hit == nil {
            return gridSelection
        }

        if viewMode == .compare {
            guard let hit else {
                return gridSelection
            }
            // Plain / ⇧ → replace right; ⌘ / ⌘⇧ → replace left.
            let position: PanePosition = command ? .left : .right
            applyCompareClick(hit, replacing: position, orderedIDs: orderedIDs)
            return gridSelection
        }

        if viewMode == .loupe, let hit, !shift, !command {
            setFocus(hit)
            gridSelection = gridSelection.plainClick(hit)
            return gridSelection
        }
        // loupe + modified click falls through: selection semantics apply, focus unchanged

        guard let hit else {
            if !shift, !command {
                gridSelection = gridSelection.clearedBySpace()
            }
            return gridSelection
        }

        switch (shift, command) {
        case (false, false):
            gridSelection = gridSelection.plainClick(hit)
        case (false, true):
            gridSelection = gridSelection.commandClick(hit)
        case (true, false):
            gridSelection = gridSelection.shiftClick(hit, orderedIDs: orderedIDs)
        case (true, true):
            gridSelection = gridSelection.commandShiftClick(hit, orderedIDs: orderedIDs)
        }
        return gridSelection
    }

    /// Adopts a live AppKit selection written by native keyboard handling (⌘A,
    /// ⇧-arrows). Idempotent when `live` already equals `gridSelection.selection`.
    /// Compare ignores native multi-selection writes — the pair is model-owned and
    /// strip multi-select is disabled (APP-021).
    @discardableResult
    func reconcileNativeSelection(_ live: Set<MediaAssetID>) -> GridSelection {
        if viewMode == .compare {
            return gridSelection
        }
        gridSelection = gridSelection.reconcilingSelection(live)
        return gridSelection
    }

    /// Scope-change clear. Resets selection, anchor, and base unconditionally.
    func clearGridSelection(reason: String) {
        guard gridSelection != .empty else {
            return
        }
        gridSelection = .empty
        OtosLog.ui.debug(
            "Catalog selection cleared reason=\(reason, privacy: .public)"
        )
    }

    /// A scope change: a different collection, so the old selection means nothing there —
    /// unless the intent that opened this scope chose a selection for it
    /// (`scopeEntrySelection`), whose survivors in the new order become the selection.
    /// Whether `next`, a state of the query an intent chose a selection for, now holds one
    /// of its items: in the scope already shown, the chosen items may arrive after it opened.
    func holdsScopeEntrySelection(_ next: CatalogWindowState) -> Bool {
        guard let entry = scopeEntrySelection, entry.generation == next.queryGeneration else { return false }
        let present = Set(next.mediaGrid.orderedAssetIDs)
        return entry.ids.contains(where: present.contains)
    }

    func applyScopeEntrySelection(_ next: CatalogWindowState) {
        guard let entry = scopeEntrySelection, entry.generation == next.queryGeneration else {
            clearGridSelection(reason: "scopeChange")
            return
        }
        scopeEntrySelection = nil
        let present = Set(next.mediaGrid.orderedAssetIDs)
        let kept = entry.ids.filter(present.contains)
        guard let first = kept.first else {
            clearGridSelection(reason: "scopeEntryGone")
            return
        }
        gridSelection = GridSelection(selection: Set(kept), anchor: first, base: Set(kept))
        OtosLog.ui.debug(
            "Catalog selection entered reason=scopeEntry kept=\(kept.count, privacy: .public)/\(entry.ids.count, privacy: .public)"
        )
    }

    /// Selects all visible assets. Used by Edit → Select All (\u2318A).
    func selectAll() {
        let ordered = state.mediaGrid.orderedAssetIDs
        guard !ordered.isEmpty else { return }
        gridSelection = GridSelection(
            selection: Set(ordered),
            anchor: ordered.first,
            base: Set(ordered)
        )
    }

    /// Clears selection. Used by Edit → Deselect All (\u21E7\u2318A).
    func deselectAll() {
        guard !gridSelection.selection.isEmpty else { return }
        gridSelection = .empty
    }

    /// Selects and scrolls to a specific set of assets. Used by the import bar's
    /// `Show them` (state D, `import-bar.md`): the grid is the plan view, so
    /// revealing attention items is a selection, not a modal list.
    func selectAssets(_ ids: [MediaAssetID]) {
        guard !ids.isEmpty else { return }
        gridSelection = GridSelection(
            selection: Set(ids),
            anchor: ids.first,
            base: Set(ids)
        )
        setFocus(ids.first)
    }

    /// Reveals the current targets' originals in Finder — the Grid selection, the Loupe
    /// focus, or the active Compare pane, the same targets Open, Share and Copy act on. A
    /// hand-off to Finder, so it travels the hand-off lane: an original a source stages and
    /// has not copied yet is fetched first, and a source that cannot send one fails the
    /// reveal with the alert that names it. A cloud placeholder is revealed as it is, so a
    /// folder's dataless original is never materialized.
    func revealCurrentTargetsInFinder() {
        handOff(.revealInFinder)
    }
}

/// Closure bundle the AppKit bridge injects so the controller never owns selection
/// truth. Every call is synchronous on the MainActor; the controller writes AppKit
/// selection from the returned model as the gesture's last operation.
struct MediaGridSelectionHandlers {
    var currentSelection: () -> GridSelection = { .empty }
    var applyClick: (
        _ hit: MediaAssetID?,
        _ modifiers: NSEvent.ModifierFlags,
        _ orderedIDs: [MediaAssetID]
    ) -> GridSelection = { _, _, _ in .empty }
    var reconcileNative: (Set<MediaAssetID>) -> GridSelection = { _ in .empty }
    /// The drag pasteboard writer for a dragged item: what the selection hands to another
    /// app (the hand-off's choice, `CatalogWindowViewModel.dragWriter(for:)`).
    var dragWriter: (MediaAssetID) -> NSPasteboardWriting = { $0.fileURL as NSURL }

    /// Wires the ViewModel's selection intents into the bridge.
    @MainActor
    static func from(_ viewModel: CatalogWindowViewModel) -> MediaGridSelectionHandlers {
        MediaGridSelectionHandlers(
            currentSelection: { viewModel.gridSelection },
            applyClick: { hit, modifiers, orderedIDs in
                viewModel.applyGridClick(
                    hit: hit,
                    modifiers: modifiers,
                    orderedIDs: orderedIDs
                )
            },
            reconcileNative: { live in
                viewModel.reconcileNativeSelection(live)
            },
            dragWriter: { id in
                viewModel.dragWriter(for: id)
            }
        )
    }
}
