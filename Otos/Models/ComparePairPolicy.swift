import Foundation

/// Compare pair policy guide
///
/// Pure rules for the symmetric two-pane compare viewer. There are no Select/Candidate
/// roles, labels, or swap/promote chrome — the pair *is* the selection capped at two.
/// Panes are positional slots: a plain strip click replaces the **right** pane; a
/// ⌘-click replaces the **left** pane. Arrow keys slide the window:
/// `(A, B) → (B, next(B))` and `← → (prev(A), A)`.
nonisolated enum PanePosition: Equatable {
    case left
    case right
}

nonisolated struct ComparePair: Equatable {
    var left: MediaAssetID?
    var right: MediaAssetID?

    static let empty = ComparePair(left: nil, right: nil)

    var members: [MediaAssetID] {
        [left, right].compactMap(\.self)
    }

    func remapped(by batch: CatalogIdentityRemapBatch) -> ComparePair {
        guard !batch.remaps.isEmpty else {
            return self
        }
        let map = Dictionary(uniqueKeysWithValues: batch.remaps.map { ($0.oldID, $0.newID) })
        return ComparePair(
            left: left.map { map[$0] ?? $0 },
            right: right.map { map[$0] ?? $0 }
        )
    }
}

nonisolated enum ComparePairPolicy {
    /// Enter compare: first two selected in display order; one selected → it + next
    /// neighbor as right; none selected → first two in scope.
    static func entry(
        selection: GridSelection,
        orderedIDs: [MediaAssetID]
    ) -> ComparePair {
        guard !orderedIDs.isEmpty else {
            return .empty
        }
        let selected = GridSelection.orderedSelection(selection.selection, in: orderedIDs)
        switch selected.count {
        case 0:
            let prefix = Array(orderedIDs.prefix(2))
            return ComparePair(
                left: prefix.first,
                right: prefix.count > 1 ? prefix[1] : nil
            )
        case 1:
            let first = selected[0]
            if let index = orderedIDs.firstIndex(of: first),
               orderedIDs.indices.contains(index + 1) {
                return ComparePair(left: first, right: orderedIDs[index + 1])
            }
            if let index = orderedIDs.firstIndex(of: first), index > 0 {
                return ComparePair(left: orderedIDs[index - 1], right: first)
            }
            return ComparePair(left: first, right: nil)
        default:
            return ComparePair(left: selected[0], right: selected[1])
        }
    }

    /// Filmstrip/grid click: set the named slot to `id`. If `id` already occupies the
    /// other slot, swap instead of duplicating. Modified clicks share this path — the
    /// 2-cap makes range/toggle meaningless; the modifier only chooses the slot.
    static func click(
        _ id: MediaAssetID,
        replacing position: PanePosition,
        pair: ComparePair,
        orderedIDs: [MediaAssetID]
    ) -> ComparePair {
        guard orderedIDs.contains(id) else {
            return pair
        }
        switch position {
        case .left:
            if pair.right == id {
                return ComparePair(left: pair.right, right: pair.left)
            }
            return ComparePair(left: id, right: pair.right)
        case .right:
            if pair.left == id {
                return ComparePair(left: pair.right, right: pair.left)
            }
            return ComparePair(left: pair.left, right: id)
        }
    }

    /// Sliding window. `delta > 0` → `(old right, next(right))`;
    /// `delta < 0` → `(prev(left), old left)`.
    static func slide(
        _ delta: Int,
        pair: ComparePair,
        orderedIDs: [MediaAssetID]
    ) -> ComparePair {
        if delta > 0 {
            guard let right = pair.right,
                  let index = orderedIDs.firstIndex(of: right),
                  orderedIDs.indices.contains(index + 1)
            else {
                return pair
            }
            return ComparePair(left: right, right: orderedIDs[index + 1])
        }
        if delta < 0 {
            guard let left = pair.left,
                  let index = orderedIDs.firstIndex(of: left),
                  index > 0
            else {
                return pair
            }
            return ComparePair(left: orderedIDs[index - 1], right: left)
        }
        return pair
    }

    /// Structural-apply prune: a removed member's own slot is refilled with its nearest
    /// display-order survivor; the other slot is untouched. Both gone → fresh entry.
    static func prune(
        pair: ComparePair,
        previousOrderedIDs: [MediaAssetID],
        survivingOrderedIDs: [MediaAssetID]
    ) -> ComparePair {
        if survivingOrderedIDs.isEmpty {
            return .empty
        }
        let leftSurvives = pair.left.map(survivingOrderedIDs.contains) ?? false
        let rightSurvives = pair.right.map(survivingOrderedIDs.contains) ?? false
        if !leftSurvives, !rightSurvives {
            return entry(selection: .empty, orderedIDs: survivingOrderedIDs)
        }
        var left = pair.left
        var right = pair.right
        if let current = left, !survivingOrderedIDs.contains(current) {
            left = nearestSurvivor(
                to: current,
                previousOrderedIDs: previousOrderedIDs,
                survivingOrderedIDs: survivingOrderedIDs,
                excluding: right
            )
        }
        if let current = right, !survivingOrderedIDs.contains(current) {
            right = nearestSurvivor(
                to: current,
                previousOrderedIDs: previousOrderedIDs,
                survivingOrderedIDs: survivingOrderedIDs,
                excluding: left
            )
        }
        return ComparePair(left: left, right: right)
    }

    private static func nearestSurvivor(
        to id: MediaAssetID,
        previousOrderedIDs: [MediaAssetID],
        survivingOrderedIDs: [MediaAssetID],
        excluding: MediaAssetID?
    ) -> MediaAssetID? {
        let index = previousOrderedIDs.firstIndex(of: id) ?? 0
        for distance in 0 ..< max(previousOrderedIDs.count, 1) {
            let candidates = [index + distance, index - distance]
            for candidateIndex in candidates where previousOrderedIDs.indices.contains(candidateIndex) {
                let candidate = previousOrderedIDs[candidateIndex]
                guard survivingOrderedIDs.contains(candidate),
                      candidate != id,
                      candidate != excluding
                else {
                    continue
                }
                return candidate
            }
        }
        return survivingOrderedIDs.first { $0 != excluding }
    }
}
