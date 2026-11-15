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
/// Index-path lookup by identity (selection, focus, anchoring, drag) and the identities
/// `MediaGridStructureChange` looks up both read the position index of the `CatalogGridContent` the order
/// came in: one shared, immutable value per publication, whose index Projection builds off
/// the main actor at publication, so a structure never builds a second one.
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

    let sections: [Section]
    /// The order and its position index.
    private let content: CatalogGridContent

    var orderedIDs: [MediaAssetID] {
        content.orderedAssetIDs
    }

    /// No sections at all: what the collection view shows before its first apply.
    static let empty = MediaGridStructure(
        content: CatalogGridContent(orderedAssetIDs: [], dayBuckets: [], stacks: .empty),
        sections: []
    )

    private init(content: CatalogGridContent, sections: [Section]) {
        self.content = content
        self.sections = sections
    }

    init(grid: CatalogMediaGridState) {
        self.init(content: grid.content)
    }

    /// An order and its day buckets outside a publication, as a test or a fixture holds them.
    init(orderedIDs: [MediaAssetID], dayBuckets: [Date?] = []) {
        self.init(content: CatalogGridContent(orderedAssetIDs: orderedIDs, dayBuckets: dayBuckets, stacks: .empty))
    }

    /// One ungrouped section when `dayBuckets` does not pair 1:1 with `orderedIDs` (any
    /// sort but Date, or before capture dates are known), and for an empty order. Otherwise
    /// a new day section each time the bucket changes while walking the already date-sorted
    /// order, so section order is the order days are first met, wherever the query placed
    /// the unknown-date run.
    private init(content: CatalogGridContent) {
        let orderedIDs = content.orderedAssetIDs
        let dayBuckets = content.dayBuckets
        guard dayBuckets.count == orderedIDs.count, !orderedIDs.isEmpty else {
            self.init(content: content, sections: [Section(key: .ungrouped, items: 0 ..< orderedIDs.count)])
            return
        }
        // Every bucket is read once, through the buffer: this walk is the one part of a
        // reorder's build that reads every item, so its per-item cost is what it costs.
        var sections: [Section] = []
        dayBuckets.withUnsafeBufferPointer { buckets in
            var runStart = 0
            var runDay = buckets[0]
            var position = 1
            while position < buckets.count {
                let day = buckets[position]
                if day != runDay {
                    sections.append(Section(key: .day(runDay), items: runStart ..< position))
                    runStart = position
                    runDay = day
                }
                position += 1
            }
            sections.append(Section(key: .day(runDay), items: runStart ..< buckets.count))
        }
        self.init(content: content, sections: sections)
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
        content.contains(id)
    }

    /// Where `id` sits in `orderedIDs`; `nil` when it is not in the structure.
    func position(of id: MediaAssetID) -> Int? {
        content.position(of: id)
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
        content.position(of: id).map(indexPath(atPosition:))
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

/// How one structure turns into the next, found in proportion to what changed: the one
/// identity comparison the apply policy's summary and the batch both read
/// (`MediaGridStructuralApplyPolicy.summarize`, `MediaGridBatchUpdates.between`).
///
/// Sections pair by key. A paired section's items are compared from both ends, in order,
/// for the run they share at the front and at the back; only what lies between those runs,
/// and every item of a section with no pair, is looked up by identity. A day the change did
/// not touch is one shared run, so a few photos moving between days in a grid of 158,000
/// looks up a few hundred identities instead of every one, and an order the change did not
/// touch looks up none (`docs/research/2026-11-15-grid-reorder-follows-the-change.md`).
///
/// Identities are unique within an order, so an item of a shared run is at the same place
/// in its section on both sides and every item that moved lies in a looked-up stretch.
nonisolated struct MediaGridStructureChange: Sendable {
    /// One new section's pairing with the old structure.
    struct PairedSection: Sendable {
        /// The old section with the same key.
        let oldSection: Int
        /// How many items the two share at their front, and then at their back.
        let sharedFront: Int
        let sharedBack: Int
    }

    let old: MediaGridStructure
    let new: MediaGridStructure
    /// Each new section's pairing, `nil` for a section the old structure has no key for.
    /// Every entry is `nil` when a key repeats on either side, which no batch describes.
    let pairs: [PairedSection?]
    /// The new index of each old section, or -1 when its key is gone; `nil` when a key
    /// repeats on either side.
    let newIndexOfOldSection: [Int]?
    /// How many of the new structure's items the old one holds.
    let retainedCount: Int
    /// Whether the two orders are the same sequence: every item at the place it had.
    let orderIsUnchanged: Bool

    init(from old: MediaGridStructure, to new: MediaGridStructure) {
        self.old = old
        self.new = new
        let oldIndexByKey = Self.sectionIndexByKey(old)
        let newIndexByKey = Self.sectionIndexByKey(new)
        let keysPair = oldIndexByKey != nil && newIndexByKey != nil
        newIndexOfOldSection = keysPair
            ? old.sections.map { newIndexByKey?[$0.key] ?? -1 }
            : nil
        let oldIDs = old.orderedIDs
        let newIDs = new.orderedIDs
        var pairs: [PairedSection?] = []
        pairs.reserveCapacity(new.sections.count)
        var retained = 0
        var orderIsUnchanged = oldIDs.count == newIDs.count
        /// The answers are counted, not kept: a change small enough to animate looks its
        /// few stretches up again for the batch, and a scope switch's would be every item.
        func lookUp(_ positions: Range<Int>) {
            // An empty old structure holds none of them, so a first apply looks up nothing;
            // the orders' counts already differ.
            guard !oldIDs.isEmpty else {
                return
            }
            for position in positions {
                let oldPosition = old.position(of: newIDs[position])
                retained += oldPosition == nil ? 0 : 1
                orderIsUnchanged = orderIsUnchanged && oldPosition == position
            }
        }
        for section in new.sections {
            guard keysPair, let oldSection = oldIndexByKey?[section.key] else {
                pairs.append(nil)
                lookUp(section.items)
                continue
            }
            let oldItems = old.sections[oldSection].items
            let newItems = section.items
            let (front, back) = Self.sharedRuns(oldIDs, oldItems, newIDs, newItems)
            pairs.append(PairedSection(oldSection: oldSection, sharedFront: front, sharedBack: back))
            retained += front + back
            let frontMoved = front > 0 && oldItems.lowerBound != newItems.lowerBound
            let backMoved = back > 0 && oldItems.upperBound != newItems.upperBound
            orderIsUnchanged = orderIsUnchanged && !frontMoved && !backMoved
            lookUp(newItems.lowerBound + front ..< newItems.upperBound - back)
        }
        self.pairs = pairs
        retainedCount = retained
        self.orderIsUnchanged = orderIsUnchanged
    }

    /// The old positions between `pair`'s shared runs: where every item of its old section
    /// that moved within it, or left it, lies.
    func ownStretch(of pair: PairedSection) -> Range<Int> {
        let oldItems = old.sections[pair.oldSection].items
        return oldItems.lowerBound + pair.sharedFront ..< oldItems.upperBound - pair.sharedBack
    }

    /// Whether old section `section` has a key the new structure keeps.
    func survives(oldSection section: Int) -> Bool {
        (newIndexOfOldSection?[section] ?? -1) >= 0
    }

    /// The new positions of new section `section` that lie outside the runs it shares
    /// with its old section: every item of it for an unpaired section. Only these are
    /// looked up by identity.
    func stretch(ofNewSection section: Int) -> Range<Int> {
        let newItems = new.sections[section].items
        guard let pair = pairs[section] else {
            return newItems
        }
        return newItems.lowerBound + pair.sharedFront ..< newItems.upperBound - pair.sharedBack
    }

    /// How many items two sections share at their front, and then at their back, compared
    /// in place through the orders' buffers: every item of a day the change did not touch
    /// is compared here, so its per-item cost is what such a day costs.
    private static func sharedRuns(
        _ oldIDs: [MediaAssetID],
        _ oldItems: Range<Int>,
        _ newIDs: [MediaAssetID],
        _ newItems: Range<Int>
    ) -> (front: Int, back: Int) {
        oldIDs.withUnsafeBufferPointer { old in
            newIDs.withUnsafeBufferPointer { new in
                let shorter = min(oldItems.count, newItems.count)
                var front = 0
                while front < shorter, old[oldItems.lowerBound + front] == new[newItems.lowerBound + front] {
                    front += 1
                }
                let oldLast = oldItems.upperBound - 1
                let newLast = newItems.upperBound - 1
                var back = 0
                while back < shorter - front, old[oldLast - back] == new[newLast - back] {
                    back += 1
                }
                return (front, back)
            }
        }
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
}

/// The collection-view batch that turns one structure into the next, in the terms
/// `NSCollectionView.performBatchUpdates` takes: deletions and move sources at the old
/// index paths, insertions and move destinations at the new ones.
///
/// Sections match by key. A section only in the old structure is deleted, which takes its
/// items with it; one only in the new is inserted, with its items. AppKit cannot move an
/// item out of a deleted section or into an inserted one, so an asset crossing either edge
/// is a delete at its old place (when that section survives) and an insert at its new one
/// (when that section survives). An item that changed between surviving sections is an
/// explicit move. Within a surviving section, the longest run of its own items already in
/// old order stays put and AppKit infers their new places; every other item is an explicit
/// move. That is the fewest moves that describe the change, so a few photos moving between
/// days in a large grid stay a few moves.
///
/// It is read from `MediaGridStructureChange`, so it costs what changed: the runs a
/// section shares at its ends stay put without being looked at again.
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
        between(MediaGridStructureChange(from: old, to: new))
    }

    static func between(_ change: MediaGridStructureChange) -> MediaGridBatchUpdates? {
        guard let newIndexOfOldSection = change.newIndexOfOldSection,
              var updates = sectionEdits(change, newIndexOfOldSection: newIndexOfOldSection)
        else {
            return nil
        }
        // Old positions some new item was found at: the rest of a looked-up old stretch
        // left the structure.
        var found = Set<Int>()
        for (newSection, pair) in change.pairs.enumerated() {
            if let pair {
                updates.addPairedSection(newSection, pair: pair, change: change, found: &found)
            } else {
                updates.addInsertedSection(newSection, change: change, found: &found)
            }
        }
        // Only once every new section is walked: an item may have left for a later one.
        updates.addLeavers(change, found: found)
        return updates
    }

    /// The sections deleted and inserted; `nil` when two surviving sections swapped order.
    private static func sectionEdits(
        _ change: MediaGridStructureChange,
        newIndexOfOldSection: [Int]
    ) -> MediaGridBatchUpdates? {
        var updates = MediaGridBatchUpdates()
        var lastSurvivingNewIndex = -1
        for (index, newIndex) in newIndexOfOldSection.enumerated() {
            guard newIndex >= 0 else {
                updates.deletedSections.insert(index)
                continue
            }
            guard newIndex > lastSurvivingNewIndex else {
                return nil
            }
            lastSurvivingNewIndex = newIndex
        }
        for (index, pair) in change.pairs.enumerated() where pair == nil {
            updates.insertedSections.insert(index)
        }
        return updates
    }

    /// An inserted section brings its items: one that left a surviving section is a delete
    /// there.
    private mutating func addInsertedSection(
        _ newSection: Int,
        change: MediaGridStructureChange,
        found: inout Set<Int>
    ) {
        let old = change.old
        let new = change.new
        for position in new.sections[newSection].items {
            guard let oldPosition = old.position(of: new.orderedIDs[position]) else {
                continue
            }
            found.insert(oldPosition)
            let from = old.indexPath(atPosition: oldPosition)
            if change.survives(oldSection: from.section) {
                deletedItems.insert(from)
            }
        }
    }

    /// A surviving section's looked-up stretch: its own items keep their longest in-order
    /// run and the rest move; an item from another surviving section moves in; one from a
    /// deleted section, or a new one, is inserted.
    private mutating func addPairedSection(
        _ newSection: Int,
        pair: MediaGridStructureChange.PairedSection,
        change: MediaGridStructureChange,
        found: inout Set<Int>
    ) {
        let old = change.old
        let new = change.new
        let newItems = new.sections[newSection].items
        let items = change.stretch(ofNewSection: newSection).map { position in
            (newPosition: position, oldPosition: old.position(of: new.orderedIDs[position]))
        }
        let ownStretch = change.ownStretch(of: pair)
        // This section's own items, in new order with their old positions: the candidates
        // for staying put.
        var ownOldPositions: [Int] = []
        for item in items {
            guard let oldPosition = item.oldPosition else {
                continue
            }
            found.insert(oldPosition)
            if ownStretch.contains(oldPosition) {
                ownOldPositions.append(oldPosition)
            }
        }
        var staying = Self.longestIncreasingRun(ownOldPositions).makeIterator()
        for item in items {
            let to = IndexPath(item: item.newPosition - newItems.lowerBound, section: newSection)
            guard let oldPosition = item.oldPosition else {
                insertedItems.insert(to)
                continue
            }
            if ownStretch.contains(oldPosition) {
                if staying.next() == false {
                    movedItems.append(Move(from: old.indexPath(atPosition: oldPosition), to: to))
                }
                continue
            }
            let from = old.indexPath(atPosition: oldPosition)
            if change.survives(oldSection: from.section) {
                movedItems.append(Move(from: from, to: to))
            } else {
                insertedItems.insert(to)
            }
        }
    }

    /// Items of a surviving section's looked-up old stretch that no new section holds.
    private mutating func addLeavers(_ change: MediaGridStructureChange, found: Set<Int>) {
        for pair in change.pairs {
            guard let pair else {
                continue
            }
            let oldItems = change.old.sections[pair.oldSection].items
            for position in change.ownStretch(of: pair) where !found.contains(position) {
                deletedItems.insert(IndexPath(item: position - oldItems.lowerBound, section: pair.oldSection))
            }
        }
    }

    var isEmpty: Bool {
        deletedSections.isEmpty && insertedSections.isEmpty && deletedItems.isEmpty
            && insertedItems.isEmpty && movedItems.isEmpty
    }

    /// Which indices into `values` belong to one longest strictly increasing subsequence
    /// (patience sorting, O(n log n)).
    private static func longestIncreasingRun(_ values: [Int]) -> [Bool] {
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
        var run = [Bool](repeating: false, count: values.count)
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run[cursor] = true
            cursor = predecessor[cursor]
        }
        return run
    }
}
