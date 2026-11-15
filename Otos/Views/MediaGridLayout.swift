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
/// sections in one value: in the grid, from the structure AppKit took in the same
/// synchronous region (`MediaGridStructure.layoutSections`), whose counts are the ones
/// AppKit holds, which inside a batch update are already the new ones, so a pass asks no
/// per-section question of the collection view or the controller. Scrolling never
/// invalidates it: only a width change does, and a move to a screen
/// of another backing scale (`MediaGridCollectionView`).
///
/// Insert and remove choreography: AppKit's base layout already supplies the attributes
/// a batch animates between — a survivor from its old frame to its new one, an insert
/// fading in at its new frame, a delete fading out at its old one, measured identical to
/// what the compositional layout supplied. This layout additionally shrinks *only* the
/// items the batch explicitly inserted or deleted (`MediaGridAnimation.insertShrinkFraction`).
/// Items of an inserted or deleted section, and every appearing item outside a batch,
/// keep the base attributes. Bookkeeping is filled in `prepare(forCollectionViewUpdates:)`
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
        var top: CGFloat = 0
        for section in sections {
            minY.append(top)
            let rows = (section.itemCount + self.columnCount - 1) / self.columnCount
            top += (section.hasHeader ? headerHeight : 0) + 2 * Self.sectionInset + CGFloat(rows) * cellEdge
        }
        minY.append(top)
        sectionMinY = minY
    }

    var numberOfSections: Int {
        sections.count
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

final class MediaGridLayout: NSCollectionViewLayout {
    let columnCount: Int
    /// The sections `prepare()` lays out, for the collection view it lays out.
    private let sections: (NSCollectionView) -> [MediaGridLayoutGeometry.Section]
    private(set) var geometry: MediaGridLayoutGeometry
    private var insertedIndexPaths: Set<IndexPath> = []
    private var deletedIndexPaths: Set<IndexPath> = []

    /// Lays out the counts the collection view holds, with the header flags
    /// `sectionHasDayHeader` gives: one count and one flag asked per section.
    convenience init(columnCount: Int, sectionHasDayHeader: @escaping (Int) -> Bool) {
        self.init(columnCount: columnCount) { collectionView in
            (0 ..< collectionView.numberOfSections).map { section in
                MediaGridLayoutGeometry.Section(
                    itemCount: collectionView.numberOfItems(inSection: section),
                    hasHeader: sectionHasDayHeader(section)
                )
            }
        }
    }

    /// Lays out the sections `sections` answers in one value: in the grid, the structure's
    /// (`MediaGridStructure.layoutSections`). Asking for every section's count and flag one
    /// at a time was most of a reload's main-thread cost at 5,000 days
    /// (`docs/research/2026-11-15-grid-hide-follows-the-removal.md`).
    init(columnCount: Int, sections: @escaping (NSCollectionView) -> [MediaGridLayoutGeometry.Section]) {
        self.columnCount = columnCount
        self.sections = sections
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
        var sections: [MediaGridLayoutGeometry.Section] = []
        var width: CGFloat = 0
        var scale: CGFloat = 1
        var isRightToLeft = false
        if let collectionView {
            sections = self.sections(collectionView)
            width = collectionView.bounds.width
            scale = collectionView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            isRightToLeft = collectionView.userInterfaceLayoutDirection == .rightToLeft
        }
        geometry = MediaGridLayoutGeometry(
            sections: sections,
            columnCount: columnCount,
            width: width,
            headerHeight: MediaGridDayHeaderView.height,
            scale: scale,
            isRightToLeft: isRightToLeft
        )
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
                Self.headerAttributes(section: section, frame: frame)
            case let .item(indexPath, frame):
                Self.itemAttributes(indexPath: indexPath, frame: frame)
            }
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        geometry.itemFrame(at: indexPath).map { Self.itemAttributes(indexPath: indexPath, frame: $0) }
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == MediaGridDayHeaderView.elementKind, indexPath.count == 2 else {
            return nil
        }
        return geometry.headerFrame(inSection: indexPath.section).map {
            Self.headerAttributes(section: indexPath.section, frame: $0)
        }
    }

    private static func itemAttributes(indexPath: IndexPath, frame: CGRect) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame
        return attributes
    }

    /// Above the tiles, as the compositional layout placed boundary supplementaries.
    private static func headerAttributes(section: Int, frame: CGRect) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: MediaGridDayHeaderView.elementKind,
            with: IndexPath(item: 0, section: section)
        )
        attributes.frame = frame
        attributes.zIndex = 1
        return attributes
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
