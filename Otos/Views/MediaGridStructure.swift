import AppKit

/// Media grid structure guide
///
/// The one statement of what the collection view shows: the identities in display order,
/// cut into sections, each a contiguous range of that order. Under Date sort a section is
/// one capture day (DES-069, APP-030); under any other sort the whole order is one
/// ungrouped section. `MediaGridViewController` is the collection view's data source and
/// answers every count, item and index-path question from the structure it last handed to
/// AppKit; the day bar, the day headers, the layout's section provider, selection, drag,
/// prefetch, zoom and scroll anchoring all read that same value.
///
/// It is Otos's own value rather than `NSDiffableDataSourceSnapshot` because AppKit's
/// snapshot copies its whole item set on every mutating call and has no call that appends
/// to more than one section, so a grid of D days and N items cost D × N to describe: 13–15
/// seconds for the owner's 158,000 items over about 5,000 days. This is built in one linear
/// pass, off the main actor, inside the mutation gate's exclusive slot
/// (`docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`).
///
/// `positions` is the inverse of `orderedIDs`, built in the same pass: index-path lookup
/// by identity (selection, focus, anchoring, drag) and the membership test the apply
/// policy needs both read it. It is part of the value, not a cache: it is never updated
/// apart from the order it inverts.
nonisolated struct MediaGridStructure: Sendable {
    /// What a section is. `.day(nil)` is the "no known capture date" bucket, still a day
    /// section with its own header rather than folded into `.ungrouped`. A section's
    /// identity across two structures is its key, which is what the batch-update derivation
    /// matches sections by.
    enum SectionKey: Hashable, Sendable {
        case ungrouped
        case day(Date?)
    }

    struct Section: Equatable, Sendable {
        let key: SectionKey
        /// The section's items, as positions in `orderedIDs`.
        let items: Range<Int>

        /// The section's user-facing day facts; `nil` for the ungrouped section, which
        /// names no day.
        var day: MediaGridDayBarPolicy.Day? {
            guard case let .day(date) = key else {
                return nil
            }
            return MediaGridDayBarPolicy.Day(date: date, itemCount: items.count)
        }
    }

    let orderedIDs: [MediaAssetID]
    let sections: [Section]
    private let positions: [MediaAssetID: Int]

    /// No sections at all: what the collection view shows before its first apply.
    static let empty = MediaGridStructure(orderedIDs: [], sections: [], positions: [:])

    private init(orderedIDs: [MediaAssetID], sections: [Section], positions: [MediaAssetID: Int]) {
        self.orderedIDs = orderedIDs
        self.sections = sections
        self.positions = positions
    }

    init(grid: CatalogMediaGridState) {
        self.init(orderedIDs: grid.orderedAssetIDs, dayBuckets: grid.dayBuckets)
    }

    /// One ungrouped section when `dayBuckets` does not pair 1:1 with `orderedIDs` (any
    /// sort but Date, or before capture dates are known), and for an empty order. Otherwise
    /// a new day section each time the bucket changes while walking the already date-sorted
    /// order, so section order is the order days are first met, wherever the query placed
    /// the unknown-date run.
    init(orderedIDs: [MediaAssetID], dayBuckets: [Date?] = []) {
        var positions: [MediaAssetID: Int] = [:]
        positions.reserveCapacity(orderedIDs.count)
        for (position, id) in orderedIDs.enumerated() {
            positions[id] = position
        }
        guard dayBuckets.count == orderedIDs.count, !orderedIDs.isEmpty else {
            self.init(
                orderedIDs: orderedIDs,
                sections: [Section(key: .ungrouped, items: 0 ..< orderedIDs.count)],
                positions: positions
            )
            return
        }
        var sections: [Section] = []
        var runStart = 0
        for position in 1 ... dayBuckets.count {
            if position == dayBuckets.count || dayBuckets[position] != dayBuckets[runStart] {
                sections.append(Section(key: .day(dayBuckets[runStart]), items: runStart ..< position))
                runStart = position
            }
        }
        self.init(orderedIDs: orderedIDs, sections: sections, positions: positions)
    }

    var numberOfSections: Int {
        sections.count
    }

    func numberOfItems(inSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].items.count : 0
    }

    /// The day `section` names; `nil` for an ungrouped section or one that does not exist.
    func day(inSection section: Int) -> MediaGridDayBarPolicy.Day? {
        sections.indices.contains(section) ? sections[section].day : nil
    }

    func contains(_ id: MediaAssetID) -> Bool {
        positions[id] != nil
    }

    func id(at indexPath: IndexPath) -> MediaAssetID? {
        guard indexPath.count == 2, sections.indices.contains(indexPath.section) else {
            return nil
        }
        let items = sections[indexPath.section].items
        let position = items.lowerBound + indexPath.item
        guard indexPath.item >= 0, items.contains(position) else {
            return nil
        }
        return orderedIDs[position]
    }

    func indexPath(of id: MediaAssetID) -> IndexPath? {
        positions[id].map(indexPath(atPosition:))
    }

    /// The index path of the item at `position` in `orderedIDs`: the section holding it, by
    /// binary search over the sections' contiguous ranges.
    func indexPath(atPosition position: Int) -> IndexPath {
        var low = 0
        var high = sections.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if sections[middle].items.lowerBound <= position {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return IndexPath(item: position - sections[low].items.lowerBound, section: low)
    }
}

/// The collection-view batch that turns one structure into the next, in the terms
/// `NSCollectionView.performBatchUpdates` takes: deletions and move sources at the old
/// index paths, insertions and move destinations at the new ones.
///
/// Sections match by key. A section only in the old structure is deleted, which takes its
/// items with it; one only in the new is inserted, with its items. AppKit cannot move an
/// item out of a deleted section or into an inserted one, so an asset crossing either edge
/// is a delete at its old place (when that section survives) and an insert at its new one
/// (when that section survives). Among items whose sections both survive, the longest run
/// already in old order stays put and AppKit infers its new places; every other item is an
/// explicit move. That is the fewest moves that describe the change, so a few photos moving
/// between days in a large grid stay a few moves.
nonisolated struct MediaGridBatchUpdates: Equatable, Sendable {
    struct Move: Equatable, Sendable {
        let from: IndexPath
        let to: IndexPath
    }

    var deletedSections = IndexSet()
    var insertedSections = IndexSet()
    var deletedItems = Set<IndexPath>()
    var insertedItems = Set<IndexPath>()
    var movedItems: [Move] = []

    /// `nil` when no batch can describe the change: a section key repeats within one
    /// structure, or two surviving sections changed their relative order. Neither happens
    /// under a date sort, where sections are days in order; the caller reloads instead.
    static func between(
        _ old: MediaGridStructure,
        _ new: MediaGridStructure
    ) -> MediaGridBatchUpdates? {
        guard let oldSectionIndex = sectionIndexByKey(old),
              let newSectionIndex = sectionIndexByKey(new)
        else {
            return nil
        }
        var updates = MediaGridBatchUpdates()
        var lastSurvivingNewIndex = -1
        for (index, section) in old.sections.enumerated() {
            guard let newIndex = newSectionIndex[section.key] else {
                updates.deletedSections.insert(index)
                continue
            }
            guard newIndex > lastSurvivingNewIndex else {
                return nil
            }
            lastSurvivingNewIndex = newIndex
        }
        for (index, section) in new.sections.enumerated() where oldSectionIndex[section.key] == nil {
            updates.insertedSections.insert(index)
        }

        // Survivors whose old and new sections both survive, in new order, with their old
        // position: the candidates for staying put.
        var survivors: [(newPath: IndexPath, oldPath: IndexPath, oldPosition: Int)] = []
        for (newSection, section) in new.sections.enumerated() {
            let newSectionSurvives = !updates.insertedSections.contains(newSection)
            for position in section.items {
                let newPath = IndexPath(item: position - section.items.lowerBound, section: newSection)
                let id = new.orderedIDs[position]
                guard let oldPath = old.indexPath(of: id) else {
                    if newSectionSurvives {
                        updates.insertedItems.insert(newPath)
                    }
                    continue
                }
                let oldSectionSurvives = !updates.deletedSections.contains(oldPath.section)
                switch (oldSectionSurvives, newSectionSurvives) {
                case (true, true):
                    let oldPosition = old.sections[oldPath.section].items.lowerBound + oldPath.item
                    survivors.append((newPath, oldPath, oldPosition))
                case (true, false):
                    updates.deletedItems.insert(oldPath)
                case (false, true):
                    updates.insertedItems.insert(newPath)
                case (false, false):
                    break
                }
            }
        }
        for (oldSection, section) in old.sections.enumerated() where !updates.deletedSections.contains(oldSection) {
            for position in section.items where !new.contains(old.orderedIDs[position]) {
                updates.deletedItems.insert(IndexPath(item: position - section.items.lowerBound, section: oldSection))
            }
        }

        let staying = longestIncreasingRun(survivors.map(\.oldPosition))
        for (index, survivor) in survivors.enumerated() {
            let sameSection = old.sections[survivor.oldPath.section].key == new.sections[survivor.newPath.section].key
            if !staying.contains(index) || !sameSection {
                updates.movedItems.append(Move(from: survivor.oldPath, to: survivor.newPath))
            }
        }
        return updates
    }

    var isEmpty: Bool {
        deletedSections.isEmpty && insertedSections.isEmpty && deletedItems.isEmpty
            && insertedItems.isEmpty && movedItems.isEmpty
    }

    private static func sectionIndexByKey(
        _ structure: MediaGridStructure
    ) -> [MediaGridStructure.SectionKey: Int]? {
        var indexByKey: [MediaGridStructure.SectionKey: Int] = [:]
        for (index, section) in structure.sections.enumerated() {
            guard indexByKey.updateValue(index, forKey: section.key) == nil else {
                return nil
            }
        }
        return indexByKey
    }

    /// The indices into `values` of one longest strictly increasing subsequence
    /// (patience sorting, O(n log n)).
    private static func longestIncreasingRun(_ values: [Int]) -> Set<Int> {
        var tails: [Int] = []
        var predecessor = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < value {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 {
                predecessor[index] = tails[low - 1]
            }
            if low == tails.count {
                tails.append(index)
            } else {
                tails[low] = index
            }
        }
        var run = Set<Int>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.insert(cursor)
            cursor = predecessor[cursor]
        }
        return run
    }
}
