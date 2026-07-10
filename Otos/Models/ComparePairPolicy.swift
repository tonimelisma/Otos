import Foundation

/// Compare pair policy guide
///
/// Pure rules for the symmetric two-pane compare viewer (plan 0052 §1.3). There are no
/// Select/Candidate roles, labels, or swap/promote chrome — the pair *is* the selection
/// capped at two, left/right follow display order, and a filmstrip click replaces the
/// pane that has been on screen longer (FIFO). Arrow keys slide the window:
/// `(A, B) → (B, next(B))` and `← → (prev(A), A)`.
nonisolated struct ComparePair: Equatable {
    /// The two compared identities (0…2). Display order for panes is derived, not stored.
    var members: [MediaAssetID]
    /// The member that has been on screen longer; the next click replaces it.
    var older: MediaAssetID?

    static let empty = ComparePair(members: [], older: nil)

    /// Left/right pane identities in display order. `right` is nil when only one member.
    func panes(in orderedIDs: [MediaAssetID]) -> (left: MediaAssetID?, right: MediaAssetID?) {
        let ordered = GridSelection.orderedSelection(Set(members), in: orderedIDs)
        switch ordered.count {
        case 0:
            return (nil, nil)
        case 1:
            return (ordered[0], nil)
        default:
            return (ordered[0], ordered[1])
        }
    }
}

nonisolated enum ComparePairPolicy {
    /// Enter compare: first two selected in display order; one selected → it + next
    /// neighbor; none selected → first two in scope. Older = left so → slides cleanly.
    static func entry(
        selection: GridSelection,
        orderedIDs: [MediaAssetID]
    ) -> ComparePair {
        guard !orderedIDs.isEmpty else {
            return .empty
        }
        let selected = GridSelection.orderedSelection(selection.selection, in: orderedIDs)
        let members: [MediaAssetID]
        switch selected.count {
        case 0:
            members = Array(orderedIDs.prefix(2))
        case 1:
            let first = selected[0]
            if let index = orderedIDs.firstIndex(of: first),
               orderedIDs.indices.contains(index + 1)
            {
                members = [first, orderedIDs[index + 1]]
            } else if let index = orderedIDs.firstIndex(of: first),
                      index > 0
            {
                members = [orderedIDs[index - 1], first]
            } else {
                members = [first]
            }
        default:
            members = Array(selected.prefix(2))
        }
        let panes = GridSelection.orderedSelection(Set(members), in: orderedIDs)
        return ComparePair(members: panes, older: panes.first)
    }

    /// Filmstrip/grid click: replace the older member with `id` (no-op if already in pair).
    /// Modified clicks share this path — the 2-cap makes range/toggle meaningless.
    static func click(
        _ id: MediaAssetID,
        pair: ComparePair,
        orderedIDs: [MediaAssetID]
    ) -> ComparePair {
        guard orderedIDs.contains(id) else {
            return pair
        }
        if pair.members.contains(id) {
            // Re-touch: becomes the newer member; the other becomes older.
            let other = pair.members.first { $0 != id }
            let members = GridSelection.orderedSelection(Set([id] + (other.map { [$0] } ?? [])), in: orderedIDs)
            return ComparePair(members: members, older: other)
        }
        switch pair.members.count {
        case 0:
            return ComparePair(members: [id], older: id)
        case 1:
            let members = GridSelection.orderedSelection(Set(pair.members + [id]), in: orderedIDs)
            return ComparePair(members: members, older: pair.members[0])
        default:
            let survivor = pair.members.first { $0 != pair.older } ?? pair.members[1]
            let members = GridSelection.orderedSelection(Set([survivor, id]), in: orderedIDs)
            return ComparePair(members: members, older: survivor)
        }
    }

    /// Sliding window. `delta > 0` → `(right, next(right))`; `delta < 0` → `(prev(left), left)`.
    static func slide(
        _ delta: Int,
        pair: ComparePair,
        orderedIDs: [MediaAssetID]
    ) -> ComparePair {
        let panes = pair.panes(in: orderedIDs)
        guard let left = panes.left else {
            return pair
        }
        if delta > 0 {
            guard let right = panes.right,
                  let index = orderedIDs.firstIndex(of: right),
                  orderedIDs.indices.contains(index + 1)
            else {
                return pair
            }
            let next = orderedIDs[index + 1]
            let members = [right, next]
            return ComparePair(members: members, older: right)
        }
        if delta < 0 {
            guard let index = orderedIDs.firstIndex(of: left),
                  index > 0
            else {
                return pair
            }
            let prev = orderedIDs[index - 1]
            let members = [prev, left]
            return ComparePair(members: members, older: left)
        }
        return pair
    }

    /// Structural-apply prune: drop missing members; fill a hole with the nearest
    /// display-order survivor when possible so compare stays two-up.
    static func prune(
        pair: ComparePair,
        survivingOrderedIDs: [MediaAssetID]
    ) -> ComparePair {
        let survivors = pair.members.filter(survivingOrderedIDs.contains)
        switch survivors.count {
        case 0:
            return entry(selection: .empty, orderedIDs: survivingOrderedIDs)
        case 1:
            let only = survivors[0]
            if let index = survivingOrderedIDs.firstIndex(of: only),
               survivingOrderedIDs.indices.contains(index + 1)
            {
                let members = [only, survivingOrderedIDs[index + 1]]
                return ComparePair(members: members, older: only)
            }
            if let index = survivingOrderedIDs.firstIndex(of: only), index > 0 {
                let members = [survivingOrderedIDs[index - 1], only]
                return ComparePair(members: members, older: members[0])
            }
            return ComparePair(members: [only], older: only)
        default:
            let members = GridSelection.orderedSelection(Set(survivors.prefix(2)), in: survivingOrderedIDs)
            let older = members.contains(where: { $0 == pair.older }) ? pair.older : members.first
            return ComparePair(members: members, older: older)
        }
    }
}
