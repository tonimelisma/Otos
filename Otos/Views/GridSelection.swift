import Foundation

/// Grid selection model guide
///
/// The single source of truth for the media grid's mouse selection. This is a pure,
/// `nonisolated` value type: it owns the selected set, the range anchor, and the base
/// "islands" a ⇧-range unions with. It has no AppKit dependency and no I/O, so every
/// selection rule is unit-testable without a collection view.
///
/// Why a model owns selection (spec 0046): the prior design read
/// `NSCollectionView.selectionIndexPaths` as an *input* to its selection computation and
/// then corrected AppKit's result. That coupled the computation to AppKit's
/// mouseDown/mouseUp commit timing — undocumented and unstable — so the correction raced
/// AppKit's own commit and produced the "contracting range drops the clicked tile" and
/// "selection remembers the old set" bugs. `GridSelection` inverts the relationship: the
/// model is the truth, and `selectionIndexPaths` is an *output* the controller writes
/// from `gridSelection.selection`. The controller never reads AppKit's selection to
/// *decide* a gesture; it reads it only to compute the minimal write delta and to
/// reconcile after native keyboard selection (⌘A, ⇧-arrows). Because
/// `MediaGridCollectionView.mouseDown` does not call `super.mouseDown`, AppKit's native
/// mouse-selection tracking loop never runs, so there is no competing commit to race.
///
/// The anchor/base rules follow the Finder/Photos idiom: a plain or ⌘-click moves the
/// anchor and snapshots the base; a ⇧-click ranges from the anchor without moving it, so
/// a chain of ⇧-clicks from the same anchor grows and shrinks the range instead of
/// accumulating intermediate clicks; ⌘⇧ extends the range while keeping existing
/// islands.
nonisolated struct GridSelection: Equatable {
    private(set) var selection: Set<MediaAssetID>
    private(set) var anchor: MediaAssetID?
    /// The "islands" a ⇧-range unions with — snapshotted at the last plain/⌘-click, so a
    /// chain of ⇧-clicks from the same anchor recomputes against the same origin.
    private(set) var base: Set<MediaAssetID>

    static let empty = GridSelection(selection: [], anchor: nil, base: [])

    /// Plain click: select only `id`; it becomes the anchor and the base.
    func plainClick(_ id: MediaAssetID) -> GridSelection {
        GridSelection(selection: [id], anchor: id, base: [id])
    }

    /// ⌘-click: toggle `id`. The clicked item becomes the pivot (anchor) even when it was
    /// deselected — matching Finder — and the result becomes the new base.
    func commandClick(_ id: MediaAssetID) -> GridSelection {
        let toggled = selection.symmetricDifference([id])
        return GridSelection(selection: toggled, anchor: id, base: toggled)
    }

    /// ⇧-click: select the contiguous display-order range from the anchor to `id`, unioned
    /// with the base. The anchor and base are unchanged so a chain of ⇧-clicks from the
    /// same anchor grows and shrinks instead of accumulating. Falls back to a plain click
    /// when there is no anchor or when the anchor/`id` is not in the current display order
    /// — a removed anchor must never resurrect a stale range.
    func shiftClick(_ id: MediaAssetID, orderedIDs: [MediaAssetID]) -> GridSelection {
        guard let anchor,
              let anchorIndex = orderedIDs.firstIndex(of: anchor),
              let clickedIndex = orderedIDs.firstIndex(of: id)
        else {
            return plainClick(id)
        }
        let range = Set(orderedIDs[min(anchorIndex, clickedIndex) ... max(anchorIndex, clickedIndex)])
        return GridSelection(selection: base.union(range), anchor: anchor, base: base)
    }

    /// ⌘⇧-click **(eng default)**: extend the range from the anchor to `id` while
    /// *keeping* existing selected islands (`selection ∪ range`), rather than collapsing
    /// to `base ∪ range` (which a plain ⇧-click does). Anchor and base unchanged. Falls
    /// back to a plain click with no anchor or a missing endpoint.
    func commandShiftClick(_ id: MediaAssetID, orderedIDs: [MediaAssetID]) -> GridSelection {
        guard let anchor,
              let anchorIndex = orderedIDs.firstIndex(of: anchor),
              let clickedIndex = orderedIDs.firstIndex(of: id)
        else {
            return plainClick(id)
        }
        let range = Set(orderedIDs[min(anchorIndex, clickedIndex) ... max(anchorIndex, clickedIndex)])
        return GridSelection(selection: selection.union(range), anchor: anchor, base: base)
    }

    /// Empty-space plain click: clear selection, anchor, and base.
    func clearedBySpace() -> GridSelection {
        .empty
    }

    /// Reconcile the selection field with an external truth (the live AppKit selection)
    /// after native *keyboard* selection (⌘A, ⇧-arrows), which writes
    /// `selectionIndexPaths` directly and bypasses the model. When the live selection
    /// differs from the model's, `base` becomes the live set so a later ⇧-click unions
    /// against the keyboard result (⌘A + ⇧-click keeps everything) instead of a stale
    /// pre-keyboard base. Anchor is unchanged. This is the only place the model adopts a
    /// value read from `selectionIndexPaths` — and it is a one-way adoption into the
    /// `selection`/`base` fields, never an input to a gesture computation.
    func reconcilingSelection(_ liveSelection: Set<MediaAssetID>) -> GridSelection {
        if liveSelection == selection {
            return self
        }
        return GridSelection(selection: liveSelection, anchor: anchor, base: liveSelection)
    }

    /// Structural-apply survivor prune (same descriptor): drop identities that left the
    /// display order from both `selection` and `base`; if the anchor itself left, clear
    /// anchor and base so a later ⇧-click falls back to a plain click instead of ranging
    /// from a stale anchor. A *descriptor* change resets to `.empty` (handled by the
    /// caller, not here).
    func pruned(to orderedIDs: [MediaAssetID]) -> GridSelection {
        let orderSet = Set(orderedIDs)
        let prunedSelection = selection.intersection(orderSet)
        guard let anchor, orderSet.contains(anchor) else {
            return GridSelection(selection: prunedSelection, anchor: nil, base: [])
        }
        return GridSelection(selection: prunedSelection, anchor: anchor, base: base.intersection(orderSet))
    }
}
