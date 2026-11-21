import AppKit

/// Media grid layout guide
///
/// The grid is square tiles in equal columns, cut into sections (one per capture day under
/// Date sort, DES-069), each optionally headed by a day header of one fixed height
/// (`MediaGridDayHeaderView.height`). Every frame is therefore arithmetic over the
/// sections' item counts, and `MediaGridLayoutGeometry` is that arithmetic as a value:
/// built in one pass over the section counts, it answers any item's or header's frame and
/// which elements a rect holds by binary search, without visiting other sections. A rect
/// query decides membership on exact frames and returns rounded ones, as the compositional
/// layout did. Arrow-key navigation stays AppKit's own, answered from rect queries.
///
/// It replaces `NSCollectionViewCompositionalLayout` for the grid, which solved every
/// section on each invalidation — about 0.5 M instructions per section, so about 300 ms of
/// main thread for each structural apply at the owner's 4,800 days
/// (`docs/research/2026-11-15-grid-layout-without-compositional-solve.md`). The pixel
/// geometry is the compositional layout's, measured and kept as the oracle in
/// `MediaGridLayoutTests`: a section inset of 12 pt on every side, each tile inset 4 pt
/// inside its cell of `(width − 24) / columns`, the header spanning the full width at the
/// section's top with the section's top inset below it, every origin and size rounded to
/// the nearest backing pixel (half away from zero), columns mirrored right to left.
///
/// The header spans the full width rather than the inset content width because the day
/// bar, which carries the same label, spans the viewport (DES-069): following the insets
/// put the label 12 pt to the side of the bar's at every handoff. It is in flow at the
/// label's one height, blank or not, so the first row sits below the bar, and it is never
/// pinned — `MediaGridDayLabel.swift` records why the bar holds the current day instead.
///
/// `MediaGridLayout` is the `NSCollectionViewLayout` over that value. `prepare()` takes the
/// sections and their header keys in one value: in the grid, from the structure AppKit
/// took in the same synchronous region (`MediaGridStructure.layoutInput`), whose item count
/// is the one AppKit holds, which inside a batch update is already the new one, so a pass
/// asks no per-section question of the collection view or the controller. AppKit holds the
/// order as one section; this layout maps its index paths to days and back. Scrolling never
/// invalidates it: only a width change does, and a move to a screen
/// of another backing scale (`MediaGridCollectionView`).
///
/// Insert and remove choreography: AppKit's base layout already supplies the attributes
/// a batch animates between — a survivor from its old frame to its new one, an insert
/// fading in at its new frame, a delete fading out at its old one, measured identical to
/// what the compositional layout supplied. This layout additionally shrinks *only* the
/// items the batch explicitly inserted or deleted (`MediaGridAnimation.insertShrinkFraction`).
/// Every appearing item outside a batch keeps the base attributes, and a day header the
/// batch removes or adds (`receiveHeaderUpdates`) fades as the base layout fades it; a
/// header whose day survives keeps its view and moves. Bookkeeping is filled in `prepare(forCollectionViewUpdates:)`
/// (once per batch, before the appear and disappear hooks) and cleared in
/// `finalizeCollectionViewUpdates()`, AppKit's documented update lifecycle.
///
/// Grid only. The filmstrip is one section, which the compositional layout solves once,
/// so it keeps its plain horizontal compositional layout (`MediaGridPresentation.swift`).
nonisolated struct MediaGridLayoutGeometry: Equatable, Sendable {
    /// One section as the layout sees it.
    struct Section: Equatable, Sendable {
        let itemCount: Int
        let hasHeader: Bool
    }

    /// Between the grid's edge and its cells, on every side of every section.
    static let sectionInset: CGFloat = 12
    /// Between a cell's edge and the tile drawn in it, on every side.
    static let tileInset: CGFloat = 4

    let columnCount: Int
    let width: CGFloat
    let headerHeight: CGFloat
    /// Backing pixels per point; frames are rounded to whole pixels at this scale.
    let scale: CGFloat
    let isRightToLeft: Bool
    private let sections: [Section]
    /// Where each section starts, unrounded, plus one entry past the last: the unrounded
    /// content height. Rounding happens per frame, so no error accumulates down the grid.
    private let sectionMinY: [CGFloat]
    /// Each section's first item as a position in the whole order, plus one entry past the
    /// last: the item count. AppKit holds the order as one section (`MediaGridLayout`).
    private let sectionFirstItem: [Int]

    init(
        sections: [Section],
        columnCount: Int,
        width: CGFloat,
        headerHeight: CGFloat,
        scale: CGFloat,
        isRightToLeft: Bool
    ) {
        self.sections = sections
        self.columnCount = max(1, columnCount)
        self.width = width
        self.headerHeight = headerHeight
        self.scale = scale > 0 ? scale : 1
        self.isRightToLeft = isRightToLeft
        let cellEdge = max(0, width - 2 * Self.sectionInset) / CGFloat(self.columnCount)
        var minY: [CGFloat] = []
        minY.reserveCapacity(sections.count + 1)
        var firstItem: [Int] = []
        firstItem.reserveCapacity(sections.count + 1)
        var top: CGFloat = 0
        var items = 0
        for section in sections {
            minY.append(top)
            firstItem.append(items)
            let rows = (section.itemCount + self.columnCount - 1) / self.columnCount
            top += (section.hasHeader ? headerHeight : 0) + 2 * Self.sectionInset + CGFloat(rows) * cellEdge
            items += section.itemCount
        }
        minY.append(top)
        firstItem.append(items)
        sectionMinY = minY
        sectionFirstItem = firstItem
    }

    var numberOfSections: Int {
        sections.count
    }

    /// Every section's items together: the length of the order.
    var itemCount: Int {
        sectionFirstItem[sections.count]
    }

    /// The position in the whole order of `indexPath`'s item (a section and an item in it).
    func position(of indexPath: IndexPath) -> Int {
        sectionFirstItem[indexPath.section] + indexPath.item
    }

    /// The section and item at `position` in the whole order, by binary search over the
    /// sections' first items; nil past the end. An empty section holds no position.
    func indexPath(atPosition position: Int) -> IndexPath? {
        guard position >= 0, position < itemCount else {
            return nil
        }
        var low = 0
        var high = sections.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if sectionFirstItem[middle] <= position {
                low = middle
            } else {
                high = middle - 1
            }
        }
        // The last section starting at or before `position`: an empty section shares its
        // first item with the one after it, so it is never the last.
        return IndexPath(item: position - sectionFirstItem[low], section: low)
    }

    /// One cell's edge: the content width shared equally by the columns.
    var cellEdge: CGFloat {
        max(0, width - 2 * Self.sectionInset) / CGFloat(columnCount)
    }

    var contentSize: CGSize {
        CGSize(width: width, height: aligned(sectionMinY[sections.count]))
    }

    func itemFrame(at indexPath: IndexPath) -> CGRect? {
        guard indexPath.count == 2, sections.indices.contains(indexPath.section),
              indexPath.item >= 0, indexPath.item < sections[indexPath.section].itemCount
        else {
            return nil
        }
        return aligned(exactItemFrame(section: indexPath.section, item: indexPath.item))
    }

    /// The header of `section`, spanning the full width at the section's top; `nil` for a
    /// section without one.
    func headerFrame(inSection section: Int) -> CGRect? {
        guard sections.indices.contains(section), sections[section].hasHeader else {
            return nil
        }
        return aligned(exactHeaderFrame(inSection: section))
    }

    enum Element: Equatable {
        case header(section: Int, frame: CGRect)
        case item(IndexPath, frame: CGRect)
    }

    /// Every header and item that meets `rect`, section by section, each section's header
    /// before its items. Whether an element meets the rect is decided on its exact frame,
    /// before pixel rounding, as the compositional layout decided it: a tile whose rounded
    /// frame stops at the rect's edge is still returned while its exact frame reaches
    /// inside. Finds the first section by binary search and the rows inside each section
    /// by arithmetic, so the cost is the elements returned, not the grid's size.
    func elements(in rect: CGRect) -> [Element] {
        guard !sections.isEmpty, rect.height > 0, rect.width > 0 else {
            return []
        }
        var elements: [Element] = []
        var section = firstSection(endingAfter: rect.minY)
        while section < sections.count, sectionMinY[section] < rect.maxY {
            if sections[section].hasHeader {
                let header = exactHeaderFrame(inSection: section)
                if header.intersects(rect) {
                    elements.append(.header(section: section, frame: aligned(header)))
                }
            }
            appendItems(inSection: section, meeting: rect, to: &elements)
            section += 1
        }
        return elements
    }

    private func appendItems(inSection section: Int, meeting rect: CGRect, to elements: inout [Element]) {
        let itemCount = sections[section].itemCount
        let cellEdge = cellEdge
        guard itemCount > 0, cellEdge > 0 else {
            return
        }
        let rows = (itemCount + columnCount - 1) / columnCount
        let rowsMinY = firstRowMinY(inSection: section)
        // The rows whose cells meet the rect; each tile lies inside its cell, so this is a
        // superset, narrowed by the tile's own frame below.
        let firstRow = max(0, Int(((rect.minY - rowsMinY) / cellEdge).rounded(.down)))
        let lastRow = min(rows - 1, Int(((rect.maxY - rowsMinY) / cellEdge).rounded(.down)))
        guard firstRow <= lastRow else {
            return
        }
        for row in firstRow ... lastRow {
            for column in 0 ..< columnCount {
                let item = row * columnCount + column
                guard item < itemCount else {
                    break
                }
                let frame = exactItemFrame(section: section, item: item)
                if frame.intersects(rect) {
                    elements.append(.item(IndexPath(item: item, section: section), frame: aligned(frame)))
                }
            }
        }
    }

    /// The first section whose bottom edge lies below `edge`.
    private func firstSection(endingAfter edge: CGFloat) -> Int {
        var low = 0
        var high = sections.count
        while low < high {
            let middle = (low + high) / 2
            if sectionMinY[middle + 1] <= edge {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func firstRowMinY(inSection section: Int) -> CGFloat {
        sectionMinY[section] + (sections[section].hasHeader ? headerHeight : 0) + Self.sectionInset
    }

    private func exactHeaderFrame(inSection section: Int) -> CGRect {
        CGRect(x: 0, y: sectionMinY[section], width: width, height: headerHeight)
    }

    private func exactItemFrame(section: Int, item: Int) -> CGRect {
        let row = item / columnCount
        let column = item % columnCount
        let cellEdge = cellEdge
        let cellMinX = isRightToLeft
            ? width - Self.sectionInset - CGFloat(column + 1) * cellEdge
            : Self.sectionInset + CGFloat(column) * cellEdge
        let edge = max(0, cellEdge - 2 * Self.tileInset)
        return CGRect(
            x: cellMinX + Self.tileInset,
            y: firstRowMinY(inSection: section) + CGFloat(row) * cellEdge + Self.tileInset,
            width: edge,
            height: edge
        )
    }

    private func aligned(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Origin and size each rounded to the nearest pixel, independently, as the
    /// compositional layout rounds them.
    private func aligned(_ rect: CGRect) -> CGRect {
        CGRect(x: aligned(rect.minX), y: aligned(rect.minY), width: aligned(rect.width), height: aligned(rect.height))
    }
}

/// A lightweight, AppKit-independent mirror of the parts of `NSCollectionViewUpdateItem`
/// this layout needs. `NSCollectionViewUpdateItem` has no public initializer — AppKit
/// only ever hands the layout instances it created itself — so the bookkeeping is tested
/// directly with plain Swift values instead of exercising real AppKit update items.
nonisolated struct MediaGridUpdateItem: Equatable {
    let action: NSCollectionView.UpdateAction
    let indexPathBeforeUpdate: IndexPath?
    let indexPathAfterUpdate: IndexPath?
}

/// Pure bookkeeping for which index paths a batch of collection-view updates inserts or
/// deletes. Kept apart from `MediaGridLayout` so it is unit-testable without a live
/// `NSCollectionView`. A section insert or delete arrives as an update item whose item
/// index is `NSNotFound`; it is tracked like any other path and so never matches an item,
/// which leaves that section's items on the base fade.
nonisolated enum MediaGridLayoutUpdatePolicy {
    static func trackedIndexPaths(
        for items: [MediaGridUpdateItem]
    ) -> (inserted: Set<IndexPath>, deleted: Set<IndexPath>) {
        var inserted = Set<IndexPath>()
        var deleted = Set<IndexPath>()
        for item in items {
            switch item.action {
            case .insert:
                if let after = item.indexPathAfterUpdate {
                    inserted.insert(after)
                }
            case .delete:
                if let before = item.indexPathBeforeUpdate {
                    deleted.insert(before)
                }
            default:
                break
            }
        }
        return (inserted, deleted)
    }
}

/// What the grid's layout lays out, in one value: each section's count and whether it has
/// a day header, and where the headers sit in AppKit's index space
/// (`MediaGridStructure.layoutInput`, `MediaGridStructure.Headers`).
nonisolated struct MediaGridLayoutInput: Equatable, Sendable {
    let sections: [MediaGridLayoutGeometry.Section]
    let headers: MediaGridStructure.Headers

    static let empty = MediaGridLayoutInput(sections: [], headers: .none)
}

/// The day headers a batch removes and adds, at their supplementary index paths: AppKit
/// fades a header out or in only when the layout names it
/// (`indexPathsToDeleteForSupplementaryView(ofKind:)`).
nonisolated struct MediaGridHeaderUpdates: Equatable, Sendable {
    var deleted = Set<IndexPath>()
    var inserted = Set<IndexPath>()
}

/// The grid's `NSCollectionViewLayout`. AppKit holds the whole order as **one section**:
/// an item's index path is `IndexPath(item: position, section: 0)`, and the day sections
/// are this layout's alone, mapped to and from positions by `MediaGridLayoutGeometry`.
/// AppKit does work for every section it holds on each update — it re-asks every count,
/// walks every section's supplementaries and maps every section — which made a batch at
/// the owner's 5,000 days cost about 93 M instructions for one removed photo, where one
/// section costs about 17 M (`docs/research/2026-11-15-grid-removal-without-a-reload.md`).
final class MediaGridLayout: NSCollectionViewLayout {
    let columnCount: Int
    /// What `prepare()` lays out, for the collection view it lays out.
    private let input: (NSCollectionView) -> MediaGridLayoutInput
    private(set) var geometry: MediaGridLayoutGeometry
    private var headers = MediaGridStructure.Headers.none
    private var insertedIndexPaths: Set<IndexPath> = []
    private var deletedIndexPaths: Set<IndexPath> = []
    /// The headers the batch in progress removes and adds, handed over by the controller in
    /// the same synchronous region as `performBatchUpdates` (`receiveHeaderUpdates`), read
    /// while AppKit prepares the batch, cleared when it finalizes it.
    private var headerUpdates = MediaGridHeaderUpdates()

    /// Lays out what `input` answers in one value: in the grid, the structure's
    /// (`MediaGridStructure.layoutInput`). Asking for every section's count and flag one
    /// at a time was most of a reload's main-thread cost at 5,000 days
    /// (`docs/research/2026-11-15-grid-hide-follows-the-removal.md`).
    init(columnCount: Int, input: @escaping (NSCollectionView) -> MediaGridLayoutInput) {
        self.columnCount = columnCount
        self.input = input
        geometry = MediaGridLayoutGeometry(
            sections: [],
            columnCount: columnCount,
            width: 0,
            headerHeight: MediaGridDayHeaderView.height,
            scale: 1,
            isRightToLeft: false
        )
        super.init()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// One pass over the section counts; nothing per item.
    override func prepare() {
        super.prepare()
        var input = MediaGridLayoutInput.empty
        var width: CGFloat = 0
        var scale: CGFloat = 1
        var isRightToLeft = false
        if let collectionView {
            input = self.input(collectionView)
            width = collectionView.bounds.width
            scale = collectionView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            isRightToLeft = collectionView.userInterfaceLayoutDirection == .rightToLeft
        }
        geometry = MediaGridLayoutGeometry(
            sections: input.sections,
            columnCount: columnCount,
            width: width,
            headerHeight: MediaGridDayHeaderView.height,
            scale: scale,
            isRightToLeft: isRightToLeft
        )
        headers = input.headers
    }

    override var collectionViewContentSize: NSSize {
        geometry.contentSize
    }

    /// Only a width change moves any frame; a scroll moves none.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != geometry.width
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        geometry.elements(in: rect).map { element in
            switch element {
            case let .header(section, frame):
                Self.headerAttributes(at: headerIndexPath(ofSection: section), frame: frame)
            case let .item(indexPath, frame):
                Self.itemAttributes(
                    indexPath: IndexPath(item: geometry.position(of: indexPath), section: 0),
                    frame: frame
                )
            }
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.count == 2, indexPath.section == 0,
              let local = geometry.indexPath(atPosition: indexPath.item)
        else {
            return nil
        }
        return geometry.itemFrame(at: local).map { Self.itemAttributes(indexPath: indexPath, frame: $0) }
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == MediaGridDayHeaderView.elementKind, indexPath.count == 2, indexPath.section == 0,
              let section = headers.section(ofItem: indexPath.item)
        else {
            return nil
        }
        return geometry.headerFrame(inSection: section).map { Self.headerAttributes(at: indexPath, frame: $0) }
    }

    /// Where `section`'s header sits in AppKit's index space.
    func headerIndexPath(ofSection section: Int) -> IndexPath {
        IndexPath(item: headers.item(ofSection: section), section: 0)
    }

    private static func itemAttributes(indexPath: IndexPath, frame: CGRect) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame
        return attributes
    }

    /// Above the tiles, as the compositional layout placed boundary supplementaries.
    private static func headerAttributes(at indexPath: IndexPath, frame: CGRect) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: MediaGridDayHeaderView.elementKind,
            with: indexPath
        )
        attributes.frame = frame
        attributes.zIndex = 1
        return attributes
    }

    /// The headers the next batch removes and adds. Called right before
    /// `performBatchUpdates`, in the same synchronous region.
    func receiveHeaderUpdates(_ updates: MediaGridHeaderUpdates) {
        headerUpdates = updates
    }

    override func indexPathsToDeleteForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind
    ) -> Set<IndexPath> {
        let base = super.indexPathsToDeleteForSupplementaryView(ofKind: elementKind)
        return elementKind == MediaGridDayHeaderView.elementKind ? base.union(headerUpdates.deleted) : base
    }

    override func indexPathsToInsertForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind
    ) -> Set<IndexPath> {
        let base = super.indexPathsToInsertForSupplementaryView(ofKind: elementKind)
        return elementKind == MediaGridDayHeaderView.elementKind ? base.union(headerUpdates.inserted) : base
    }

    override func prepare(forCollectionViewUpdates updateItems: [NSCollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        let mirrored = updateItems.map {
            MediaGridUpdateItem(
                action: $0.updateAction,
                indexPathBeforeUpdate: $0.indexPathBeforeUpdate as IndexPath?,
                indexPathAfterUpdate: $0.indexPathAfterUpdate as IndexPath?
            )
        }
        let tracked = MediaGridLayoutUpdatePolicy.trackedIndexPaths(for: mirrored)
        insertedIndexPaths = tracked.inserted
        deletedIndexPaths = tracked.deleted
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        insertedIndexPaths = []
        deletedIndexPaths = []
        headerUpdates = MediaGridHeaderUpdates()
    }

    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath) else {
            return nil
        }
        guard insertedIndexPaths.contains(itemIndexPath) else {
            return attributes
        }
        return Self.fadedAndShrunk(attributes)
    }

    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath) else {
            return nil
        }
        guard deletedIndexPaths.contains(itemIndexPath) else {
            return attributes
        }
        return Self.fadedAndShrunk(attributes)
    }

    /// Copies `attributes` before mutating — `super`'s return value may be a cached
    /// instance AppKit reuses across calls, not a fresh value owned by this call.
    private static func fadedAndShrunk(
        _ attributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        guard let copy = attributes.copy() as? NSCollectionViewLayoutAttributes else {
            return attributes
        }
        copy.alpha = 0
        let inset = copy.frame.width * MediaGridAnimation.insertShrinkFraction
        copy.frame = copy.frame.insetBy(dx: inset, dy: inset)
        return copy
    }
}
