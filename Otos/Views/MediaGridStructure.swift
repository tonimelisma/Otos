import AppKit
import Synchronization

/// Media grid structure guide
///
/// The one statement of what the collection view shows: the identities in display order,
/// cut into sections, each a contiguous range of that order. Under Date sort a section is
/// one capture day (DES-069, APP-030); under any other sort the whole order is one
/// ungrouped section. `MediaGridViewController` is the collection view's data source and
/// answers every count, item and index-path question from the structure it last handed to
/// AppKit; the day bar, the day headers, the layout, selection, drag, prefetch, zoom and
/// scroll anchoring all read that same value.
///
/// AppKit holds the order as **one section**: an item's index path is
/// `IndexPath(item: position, section: 0)`, and a day header's is
/// `IndexPath(item: headerItem, section: 0)` (`MediaGridStructure.Headers`). The day sections are
/// the layout's (`MediaGridLayout`), not AppKit's: AppKit re-asks every section's count,
/// walks every section's supplementaries and maps every section on each update, which at the
/// owner's 5,000 days made a one-photo batch cost about 93 M instructions on the main thread
/// against about 17 M for one section
/// (`docs/research/2026-11-15-grid-removal-without-a-reload.md`).
///
/// It is Otos's own value rather than `NSDiffableDataSourceSnapshot` because AppKit's
/// snapshot copies its whole item set on every mutating call, so a grid of D days and N
/// items cost D × N to describe: 13–15 seconds for the owner's 158,000 items over about
/// 5,000 days. This is built in one linear pass, off the main actor, inside the mutation
/// gate's exclusive slot (`docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`).
/// A structure following edits of the order on screen (a Move to Trash, a Put Back, a stack
/// expanding or collapsing, a read that moved photos) is built from the old sections and the
/// edit alone (`init(grid:following:)`).
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
    /// Where each day section's header sits in AppKit's index space.
    let headers: Headers

    /// Whether the sections' days run in one order, so no two sections share a key, which
    /// every batch needs: sections pair by key, and a header keeps its index path across a
    /// batch by its day. Always true under Date sort, where sections are days in order.
    var keysAreUnique: Bool {
        headers.areKeyed
    }

    /// Where each section's day header sits in AppKit's one section: the supplementary view
    /// at `IndexPath(item: headerItem, section: 0)`.
    ///
    /// Keyed by its day (`item(of:)`), so a header keeps its index path, and AppKit keeps its
    /// view and moves it, while days before it come and go in a batch: AppKit carries a
    /// supplementary view's index path across a batch by its section alone. Keyed headers run
    /// in the sections' day order — one direction under Date sort, the unknown day anywhere —
    /// so a header's section is found by binary search on its item. Positional — the
    /// section's own index — when the days are not in one order (a day met twice), which no
    /// batch describes: such a structure is only ever reloaded.
    ///
    /// Which of the two, and the direction, are told by one pass over the sections the first
    /// time they are asked — by a batch's derivation off the main actor, or the layout's
    /// first pass — and kept, so a fresh build pays nothing for them.
    struct Headers: Equatable, Sendable {
        fileprivate let sections: [Section]
        private let told: Told

        static let none = Headers(sections: [])

        fileprivate init(sections: [Section]) {
            self.sections = sections
            told = Told()
        }

        /// Whether the headers are keyed by day.
        var areKeyed: Bool {
            told.order(of: sections).isOrdered
        }

        /// The header item of `section`.
        func item(ofSection section: Int) -> Int {
            areKeyed ? Self.item(of: sections[section].key) : section
        }

        /// The section whose header is at `item`, if any.
        func section(ofItem item: Int) -> Int? {
            let order = told.order(of: sections)
            guard order.isOrdered else {
                return item >= 0 && item < sections.count ? item : nil
            }
            if item == 0 {
                return order.unknownSection
            }
            let known = sections.count - (order.unknownSection == nil ? 0 : 1)
            func section(_ index: Int) -> Int {
                guard let unknown = order.unknownSection, index >= unknown else {
                    return index
                }
                return index + 1
            }
            var low = 0
            var high = known
            while low < high {
                let middle = (low + high) / 2
                let found = Self.item(of: sections[section(middle)].key)
                if found == item {
                    return section(middle)
                }
                if (found > item) == order.descending {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return nil
        }

        /// The same sections: told by the arrays' own identity check when they are one.
        static func == (lhs: Headers, rhs: Headers) -> Bool {
            lhs.sections == rhs.sections
        }

        /// A day's header item: stable across structures, so a header keeps its index path
        /// while other days come and go. A day bucket is the start of a day, a whole number of
        /// seconds distinct from every other day's; the unknown day (and the ungrouped
        /// section, which has no header) is 0, every known day positive.
        fileprivate static func item(of key: SectionKey) -> Int {
            guard case let .day(day) = key, let day else {
                return 0
            }
            // Plain comparisons rather than `min`/`max`, which cost more than the rest of
            // this in a Debug build.
            var seconds = day.timeIntervalSinceReferenceDate
            if seconds < -offset + 1 {
                seconds = -offset + 1
            } else if seconds > offset - 2 {
                seconds = offset - 2
            }
            return 1 + Int(offset + seconds)
        }

        /// Seconds a day may lie before the reference date and still have a positive item.
        private static let offset = Double(1 << 52)

        /// How the sections' days run: the known days strictly one way, the unknown day at
        /// most once and anywhere, the ungrouped section only alone.
        fileprivate struct Order: Sendable {
            var isOrdered = true
            var descending = true
            var unknownSection: Int?
        }

        private final class Told: Sendable {
            private let told = Mutex<Order?>(nil)

            func order(of sections: [Section]) -> Order {
                told.withLock { told in
                    let order = told ?? Self.tell(sections)
                    told = order
                    return order
                }
            }

            /// One pass through the sections' buffer, comparing each known day's seconds with
            /// the one before: plain loops and comparisons, because a Debug build's iterators
            /// and generic comparisons cost several thousand instructions a section here.
            private static func tell(_ sections: [Section]) -> Order {
                var isOrdered = true
                var unknownSection = -1
                var direction = 0
                var hasLast = false
                var last = 0.0
                sections.withUnsafeBufferPointer { buffer in
                    var index = 0
                    while index < buffer.count {
                        switch buffer[index].key {
                        case .ungrouped:
                            if index != 0 {
                                isOrdered = false
                            }
                        case .day(nil):
                            if unknownSection >= 0 {
                                isOrdered = false
                            } else {
                                unknownSection = index
                            }
                        case let .day(day?):
                            let seconds = day.timeIntervalSinceReferenceDate
                            if hasLast {
                                let step = seconds < last ? -1 : seconds > last ? 1 : 0
                                if step == 0 || (direction != 0 && step != direction) {
                                    isOrdered = false
                                }
                                direction = step
                            }
                            hasLast = true
                            last = seconds
                        }
                        index += 1
                    }
                }
                return Order(
                    isOrdered: isOrdered,
                    descending: direction <= 0,
                    unknownSection: unknownSection >= 0 ? unknownSection : nil
                )
            }
        }
    }

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
        headers = Headers(sections: sections)
    }

    /// The sections as the layout reads them (`MediaGridLayout`): each one's count and
    /// whether it has a day header, in one value, written in place in one pass, with where
    /// the headers sit. Asking the collection view for every count and the controller for
    /// every flag one at a time cost about 65 M instructions of a reload's main-thread pass
    /// at 5,000 days; this costs about 5 M
    /// (`docs/research/2026-11-15-grid-hide-follows-the-removal.md`).
    var layoutInput: MediaGridLayoutInput {
        MediaGridLayoutInput(sections: layoutSections, headers: headers)
    }

    var layoutSections: [MediaGridLayoutGeometry.Section] {
        sections.withUnsafeBufferPointer { source in
            Array(unsafeUninitializedCapacity: source.count) { buffer, initialized in
                var index = 0
                while index < source.count {
                    let section = source[index]
                    var hasHeader = true
                    if case .ungrouped = section.key {
                        hasHeader = false
                    }
                    (buffer.baseAddress! + index).initialize(
                        to: MediaGridLayoutGeometry.Section(itemCount: section.items.count, hasHeader: hasHeader)
                    )
                    index += 1
                }
                initialized = source.count
            }
        }
    }

    init(grid: CatalogMediaGridState) {
        self.init(content: grid.content)
    }

    /// `grid`'s structure, taken from `previous` when `grid`'s order was made from the one
    /// `previous` shows by an edit (`CatalogGridContent.edit(from:)`): each section loses
    /// the removed positions that fell in it, the inserted items join the day they name,
    /// and the rest shift, so the cost is the sections and the edit, not the items. The
    /// sections are the ones a fresh build of `grid` makes.
    init(grid: CatalogMediaGridState, following previous: MediaGridStructure) {
        guard let edit = grid.content.edit(from: previous.content),
              let sections = Self.sections(of: previous, editedBy: edit, into: grid.content)
        else {
            self.init(content: grid.content)
            return
        }
        self.init(content: grid.content, sections: sections)
    }

    /// `previous`'s sections edited by `edit` into `content`: what `init(content:)` makes
    /// of `content`. A section left empty is dropped, an inserted item joins the run of its
    /// day or starts one, and runs that meet and name the same day become one, as a walk of
    /// the buckets would make them. Nil when `previous` has no days to carry over but
    /// `content` does.
    private static func sections(
        of previous: MediaGridStructure,
        editedBy edit: CatalogGridContent.Edit,
        into content: CatalogGridContent
    ) -> [Section]? {
        let count = content.orderedAssetIDs.count
        guard content.dayBuckets.count == count, count > 0 else {
            return [Section(key: .ungrouped, items: 0 ..< count)]
        }
        guard previous.content.dayBuckets.count == previous.orderedIDs.count else {
            return nil
        }
        let removed = edit.removed
        let inserted = edit.inserted
        let buckets = content.dayBuckets
        var sections: [Section] = []
        sections.reserveCapacity(previous.sections.count + inserted.count)
        var position = 0
        var nextRemoved = 0
        var nextInserted = 0
        func emit(_ key: SectionKey, _ items: Int) {
            guard items > 0 else {
                return
            }
            if let last = sections.last, last.key == key {
                sections[sections.count - 1] = Section(key: key, items: last.items.lowerBound ..< position + items)
            } else {
                sections.append(Section(key: key, items: position ..< position + items))
            }
            position += items
        }
        func emitInsertedHere() {
            while nextInserted < inserted.count, inserted[nextInserted] == position {
                emit(.day(buckets[position]), 1)
                nextInserted += 1
            }
        }
        for section in previous.sections {
            var removedHere = 0
            while nextRemoved < removed.count, removed[nextRemoved] < section.items.upperBound {
                removedHere += 1
                nextRemoved += 1
            }
            var kept = section.items.count - removedHere
            emitInsertedHere()
            while kept > 0 {
                let nextInsertion = nextInserted < inserted.count ? inserted[nextInserted] : Int.max
                let run = min(kept, nextInsertion - position)
                emit(section.key, run)
                kept -= run
                emitInsertedHere()
            }
        }
        emitInsertedHere()
        return sections
    }

    /// The edit that made this structure's order from `previous`'s, if it was made by one.
    func edit(since previous: MediaGridStructure) -> CatalogGridContent.Edit? {
        content.edit(from: previous.content)
    }

    /// The edit that makes `next` from this structure's order, if `next` was made from it by
    /// edits, so the structure that shows it costs the sections and the edit to build, not
    /// the items.
    func edit(into next: CatalogGridContent) -> CatalogGridContent.Edit? {
        next.edit(from: content)
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

    /// The items of every section: AppKit's one section's count.
    var numberOfItems: Int {
        orderedIDs.count
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

    /// The identity at AppKit's `indexPath`: the item at that position of the order.
    func id(at indexPath: IndexPath) -> MediaAssetID? {
        guard indexPath.count == 2, indexPath.section == 0,
              indexPath.item >= 0, indexPath.item < orderedIDs.count
        else {
            return nil
        }
        return orderedIDs[indexPath.item]
    }

    func indexPath(of id: MediaAssetID) -> IndexPath? {
        content.position(of: id).map(Self.indexPath(atPosition:))
    }

    /// AppKit's index path of the item at `position` in `orderedIDs`.
    static func indexPath(atPosition position: Int) -> IndexPath {
        IndexPath(item: position, section: 0)
    }

    /// The section holding the item at `position`, by binary search over the sections'
    /// contiguous ranges; nil past the end.
    func section(containing position: Int) -> Int? {
        guard position >= 0, position < orderedIDs.count, !sections.isEmpty else {
            return nil
        }
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
        return low
    }

    /// AppKit's index path of `section`'s day header; nil for the ungrouped section, which
    /// has none.
    func headerIndexPath(ofSection section: Int) -> IndexPath? {
        guard day(inSection: section) != nil else {
            return nil
        }
        return IndexPath(item: headers.item(ofSection: section), section: 0)
    }

    /// The day section whose header AppKit holds at `indexPath`.
    func section(ofHeaderAt indexPath: IndexPath) -> Int? {
        guard indexPath.count == 2, indexPath.section == 0,
              let section = headers.section(ofItem: indexPath.item),
              day(inSection: section) != nil
        else {
            return nil
        }
        return section
    }
}

/// How one structure turns into the next, found in proportion to what changed: the one
/// identity comparison the apply policy's summary and the batch both read
/// (`MediaGridStructuralApplyPolicy.summarize`, `MediaGridBatchUpdates.between`).
///
/// An order made from the one on screen by edits (`CatalogGridContent.Edit`: a Move to
/// Trash, a Put Back, a stack expanding or collapsing, a read that moved photos, and any of
/// them composed across publications the window skipped) is read from the edit: nothing is
/// compared, and only what it inserted is looked up, to tell an item it moved from one it
/// added. Any other pair of orders (a new query's, published whole) is compared: sections pair by key, a paired
/// section's items are compared from both ends, in order, for the run they share at the
/// front and at the back, and only what lies between those runs, and every item of a
/// section with no pair, is looked up by identity. A day the change did not touch is one
/// shared run, so a few photos moving between days in a grid of 158,000 looks up a few
/// hundred identities instead of every one, and an order the change did not touch looks
/// up none (`docs/research/2026-11-15-grid-reorder-follows-the-change.md`).
///
/// Identities are unique within an order, so an item of a shared run is at the same place
/// in its section on both sides and every item that moved lies in a looked-up stretch.
nonisolated struct MediaGridStructureChange: Sendable {
    /// One new section's pairing with the old structure.
    struct PairedSection: Equatable, Sendable {
        /// The old section with the same key.
        let oldSection: Int
        /// How many items the two share at their front, and then at their back.
        let sharedFront: Int
        let sharedBack: Int
    }

    enum Kind: Sendable {
        /// The new order is the old one edited: survivors keep their relative order.
        /// `moved` is each inserted item the old order held, from its old position to its
        /// new one: an item the edit moved rather than added.
        case edit(CatalogGridContent.Edit, moved: [(from: Int, to: Int)])
        /// The orders were compared. `pairs` is each new section's pairing, `nil` for a
        /// section the old structure has no key for; `newIndexOfOldSection` the new index
        /// of each old section, or -1 when its key is gone. Every pairing is `nil`, and
        /// `newIndexOfOldSection` is `nil`, when a key repeats on either side, which no
        /// batch describes.
        case compared(pairs: [PairedSection?], newIndexOfOldSection: [Int]?)
    }

    let old: MediaGridStructure
    let new: MediaGridStructure
    let kind: Kind
    /// How many of the new structure's items the old one holds.
    let retainedCount: Int
    /// Whether the two orders are the same sequence: every item at the place it had.
    let orderIsUnchanged: Bool
    /// The work the change took, in items: those compared in place across the two orders
    /// (every item of the runs a compared section shares), and those looked up by identity.
    /// An edit compares none and looks up only what it inserted (diagnostics, and what the
    /// tests hold an edit's apply to).
    let comparedCount: Int
    let lookedUpCount: Int

    init(from old: MediaGridStructure, to new: MediaGridStructure) {
        if let edit = new.edit(since: old) {
            self.init(old: old, new: new, edit: edit)
        } else {
            self.init(comparing: old, with: new)
        }
    }

    /// An edit's change: every new item but the inserted ones is an old one, and an inserted
    /// one the old order holds was moved.
    private init(old: MediaGridStructure, new: MediaGridStructure, edit: CatalogGridContent.Edit) {
        self.old = old
        self.new = new
        var moved: [(from: Int, to: Int)] = []
        for position in edit.inserted {
            if let oldPosition = old.position(of: new.orderedIDs[position]) {
                moved.append((oldPosition, position))
            }
        }
        kind = .edit(edit, moved: moved)
        retainedCount = new.orderedIDs.count - edit.inserted.count + moved.count
        orderIsUnchanged = edit.isEmpty
        comparedCount = 0
        lookedUpCount = edit.inserted.count
    }

    /// Each new section's pairing; empty for an edit, which pairs nothing.
    var pairs: [PairedSection?] {
        if case let .compared(pairs, _) = kind {
            return pairs
        }
        return []
    }

    private init(comparing old: MediaGridStructure, with new: MediaGridStructure) {
        self.old = old
        self.new = new
        let oldIndexByKey = Self.sectionIndexByKey(old)
        let newIndexByKey = Self.sectionIndexByKey(new)
        let keysPair = oldIndexByKey != nil && newIndexByKey != nil
        let newIndexOfOldSection = keysPair
            ? old.sections.map { newIndexByKey?[$0.key] ?? -1 }
            : nil
        let oldIDs = old.orderedIDs
        let newIDs = new.orderedIDs
        var pairs: [PairedSection?] = []
        pairs.reserveCapacity(new.sections.count)
        var retained = 0
        var orderIsUnchanged = oldIDs.count == newIDs.count
        var compared = 0
        var lookedUp = 0
        /// The answers are counted, not kept: a change small enough to animate looks its
        /// few stretches up again for the batch, and a scope switch's would be every item.
        func lookUp(_ positions: Range<Int>) {
            // An empty old structure holds none of them, so a first apply looks up nothing;
            // the orders' counts already differ.
            guard !oldIDs.isEmpty else {
                return
            }
            lookedUp += positions.count
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
            compared += front + back
            let frontMoved = front > 0 && oldItems.lowerBound != newItems.lowerBound
            let backMoved = back > 0 && oldItems.upperBound != newItems.upperBound
            orderIsUnchanged = orderIsUnchanged && !frontMoved && !backMoved
            lookUp(newItems.lowerBound + front ..< newItems.upperBound - back)
        }
        kind = .compared(pairs: pairs, newIndexOfOldSection: newIndexOfOldSection)
        retainedCount = retained
        self.orderIsUnchanged = orderIsUnchanged
        comparedCount = compared
        lookedUpCount = lookedUp
    }

    /// The old positions between `pair`'s shared runs: where every item of its old section
    /// that moved within it, or left it, lies.
    func ownStretch(of pair: PairedSection) -> Range<Int> {
        let oldItems = old.sections[pair.oldSection].items
        return oldItems.lowerBound + pair.sharedFront ..< oldItems.upperBound - pair.sharedBack
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
/// `NSCollectionView.performBatchUpdates` takes for the grid's one AppKit section:
/// deletions and move sources at old positions, insertions and move destinations at new
/// ones, and the day headers that go and come at their supplementary index paths.
///
/// An edit (`MediaGridStructureChange.Kind.edit`) is its removed and inserted positions, an
/// item it both removed and inserted being a move, and the headers of the days it emptied or
/// started: no survivor changes its relative order, so nothing else moves. A compared change matches sections by key: a section only in
/// the old structure loses its header, one only in the new gains one. An item that left
/// its section for another is an explicit move, wherever it went. Within a surviving
/// section, the longest run of its own items already in old order stays put and AppKit
/// infers their new places; every other item is an explicit move. That is the fewest moves
/// that describe the change, so a few photos moving between days in a large grid stay a
/// few moves.
///
/// It is read from `MediaGridStructureChange`, so it costs what changed: the runs a
/// section shares at its ends stay put without being looked at again.
nonisolated struct MediaGridBatchUpdates: Equatable, Sendable {
    struct Move: Equatable, Sendable {
        let from: IndexPath
        let to: IndexPath
    }

    var deletedItems = Set<IndexPath>()
    var insertedItems = Set<IndexPath>()
    var movedItems: [Move] = []
    var headers = MediaGridHeaderUpdates()

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
        guard change.old.keysAreUnique, change.new.keysAreUnique else {
            return nil
        }
        switch change.kind {
        case let .edit(edit, moved):
            return edited(edit, moved: moved, change: change)
        case let .compared(pairs, newIndexOfOldSection):
            guard let newIndexOfOldSection,
                  let edits = sectionEdits(change, newIndexOfOldSection: newIndexOfOldSection)
            else {
                return nil
            }
            var updates = edits.updates
            // Old positions some new item was found at: the rest of a looked-up old
            // stretch, and of a section that is gone, left the structure.
            var found = Set<Int>()
            for (newSection, pair) in pairs.enumerated() {
                if let pair {
                    updates.addPairedSection(newSection, pair: pair, change: change, found: &found)
                } else {
                    updates.addInsertedSection(newSection, change: change, found: &found)
                }
            }
            // Only once every new section is walked: an item may have left for a later one.
            updates.addLeavers(change, deletedSections: edits.deletedSections, found: found)
            return updates
        }
    }

    /// An edit's batch: its positions — an item it moved is a move, so AppKit keeps its view —
    /// and the headers of the days it emptied or started, each told by its key in the other
    /// structure.
    private static func edited(
        _ edit: CatalogGridContent.Edit,
        moved: [(from: Int, to: Int)],
        change: MediaGridStructureChange
    ) -> MediaGridBatchUpdates {
        let old = change.old
        let new = change.new
        var updates = MediaGridBatchUpdates()
        updates.deletedItems = Set(edit.removed.map(MediaGridStructure.indexPath(atPosition:)))
        updates.insertedItems = Set(edit.inserted.map(MediaGridStructure.indexPath(atPosition:)))
        for (from, to) in moved {
            let source = MediaGridStructure.indexPath(atPosition: from)
            let target = MediaGridStructure.indexPath(atPosition: to)
            updates.deletedItems.remove(source)
            updates.insertedItems.remove(target)
            updates.movedItems.append(Move(from: source, to: target))
        }
        var lastSection: Int?
        for position in edit.removed {
            guard let section = old.section(containing: position), section != lastSection else {
                continue
            }
            lastSection = section
            if let header = old.headerIndexPath(ofSection: section), new.section(ofHeaderAt: header) == nil {
                updates.headers.deleted.insert(header)
            }
        }
        lastSection = nil
        for position in edit.inserted {
            guard let section = new.section(containing: position), section != lastSection else {
                continue
            }
            lastSection = section
            if let header = new.headerIndexPath(ofSection: section), old.section(ofHeaderAt: header) == nil {
                updates.headers.inserted.insert(header)
            }
        }
        return updates
    }

    /// The headers of the sections deleted and inserted, and the old sections deleted;
    /// `nil` when two surviving sections swapped order.
    private static func sectionEdits(
        _ change: MediaGridStructureChange,
        newIndexOfOldSection: [Int]
    ) -> (updates: MediaGridBatchUpdates, deletedSections: [Int])? {
        var updates = MediaGridBatchUpdates()
        var deletedSections: [Int] = []
        var lastSurvivingNewIndex = -1
        for (index, newIndex) in newIndexOfOldSection.enumerated() {
            guard newIndex >= 0 else {
                deletedSections.append(index)
                if let header = change.old.headerIndexPath(ofSection: index) {
                    updates.headers.deleted.insert(header)
                }
                continue
            }
            guard newIndex > lastSurvivingNewIndex else {
                return nil
            }
            lastSurvivingNewIndex = newIndex
        }
        for (index, pair) in change.pairs.enumerated() where pair == nil {
            if let header = change.new.headerIndexPath(ofSection: index) {
                updates.headers.inserted.insert(header)
            }
        }
        return (updates, deletedSections)
    }

    /// An inserted section's items: each one the old structure holds moves in, the rest
    /// are inserted.
    private mutating func addInsertedSection(
        _ newSection: Int,
        change: MediaGridStructureChange,
        found: inout Set<Int>
    ) {
        let old = change.old
        let new = change.new
        for position in new.sections[newSection].items {
            let to = MediaGridStructure.indexPath(atPosition: position)
            guard let oldPosition = old.position(of: new.orderedIDs[position]) else {
                insertedItems.insert(to)
                continue
            }
            found.insert(oldPosition)
            movedItems.append(Move(from: MediaGridStructure.indexPath(atPosition: oldPosition), to: to))
        }
    }

    /// A surviving section's looked-up stretch: its own items keep their longest in-order
    /// run and the rest move; an item from another section moves in; a new one is
    /// inserted.
    private mutating func addPairedSection(
        _ newSection: Int,
        pair: MediaGridStructureChange.PairedSection,
        change: MediaGridStructureChange,
        found: inout Set<Int>
    ) {
        let old = change.old
        let new = change.new
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
            let to = MediaGridStructure.indexPath(atPosition: item.newPosition)
            guard let oldPosition = item.oldPosition else {
                insertedItems.insert(to)
                continue
            }
            if ownStretch.contains(oldPosition), staying.next() == true {
                continue
            }
            movedItems.append(Move(from: MediaGridStructure.indexPath(atPosition: oldPosition), to: to))
        }
    }

    /// Items no new section holds: in a surviving section's looked-up old stretch, and in
    /// a section that is gone.
    private mutating func addLeavers(
        _ change: MediaGridStructureChange,
        deletedSections: [Int],
        found: Set<Int>
    ) {
        for pair in change.pairs {
            guard let pair else {
                continue
            }
            for position in change.ownStretch(of: pair) where !found.contains(position) {
                deletedItems.insert(MediaGridStructure.indexPath(atPosition: position))
            }
        }
        for oldSection in deletedSections {
            for position in change.old.sections[oldSection].items where !found.contains(position) {
                deletedItems.insert(MediaGridStructure.indexPath(atPosition: position))
            }
        }
    }

    var isEmpty: Bool {
        deletedItems.isEmpty && insertedItems.isEmpty && movedItems.isEmpty
            && headers.deleted.isEmpty && headers.inserted.isEmpty
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
