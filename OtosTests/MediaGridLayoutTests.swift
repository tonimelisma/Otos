import AppKit
@testable import OtosKit
import Testing

/// The grid's geometry against the compositional layout it replaced.
///
/// Every expected number below was read from `NSCollectionViewCompositionalLayout`
/// configured as the grid's was until 2026-11-15 (12-pt section insets, 4-pt tile insets,
/// fractional columns, a full-width boundary header of 28 pt) in an on-screen window at a
/// backing scale of 2, before that layout was deleted. The same comparison across 420
/// structure × width × column × direction cases matched every frame, content size and rect
/// query (`docs/research/2026-11-15-grid-layout-without-compositional-solve.md`). They are
/// the oracle now: a change to the grid's pixel geometry fails here.
struct MediaGridLayoutTests {
    /// The compositional layout's frames for one structure, factored the way they came out:
    /// every tile has one edge, a column one x in every row, a row one y across its columns.
    /// The test rebuilds each tile's frame from its column and row and compares it whole.
    private struct Oracle {
        let sections: [MediaGridLayoutGeometry.Section]
        let width: CGFloat
        let columnCount: Int
        var isRightToLeft = false
        let contentHeight: CGFloat
        /// Each section's header y (`nil`: no header); every header is the full width, 28 pt.
        let headerY: [CGFloat?]
        let tileEdge: CGFloat
        /// Each column's tile x, leading column first.
        let columnX: [CGFloat]
        /// Each section's row ys, top row first.
        let rowY: [[CGFloat]]
        var rects: [(CGRect, [MediaGridLayoutTests.Hit])] = []

        var geometry: MediaGridLayoutGeometry {
            MediaGridLayoutGeometry(
                sections: sections,
                columnCount: columnCount,
                width: width,
                headerHeight: 28,
                scale: 2,
                isRightToLeft: isRightToLeft
            )
        }

        func tileFrame(section: Int, item: Int) -> CGRect {
            CGRect(
                x: columnX[item % columnCount],
                y: rowY[section][item / columnCount],
                width: tileEdge,
                height: tileEdge
            )
        }
    }

    enum Hit: Hashable {
        case header(Int)
        case item(Int, Int)
    }

    private static func daySections(_ counts: [Int]) -> [MediaGridLayoutGeometry.Section] {
        counts.map { MediaGridLayoutGeometry.Section(itemCount: $0, hasHeader: true) }
    }

    /// Seven columns of 1,001 pt: every cell edge is fractional, so this is the rounding.
    private static let days = Oracle(
        sections: daySections([1, 7, 6, 13, 2]),
        width: 1001,
        columnCount: 7,
        contentHeight: 1097.5,
        headerY: [0, 191.5, 383, 574.5, 906],
        tileEdge: 131.5,
        columnX: [16, 155.5, 295, 434.5, 574.5, 714, 853.5],
        rowY: [[44], [235.5], [427], [618.5, 758.5], [950]],
        rects: [
            (
                CGRect(x: 0, y: 100, width: 1001, height: 200),
                [.header(1), .item(0, 0)] + (0 ..< 7).map { .item(1, $0) }
            ),
            // The row below starts at 618.71 exactly, 618.5 rounded: a rect ending at 618.5
            // meets the rounded frame's edge but not the exact one, so it holds the header only.
            (CGRect(x: 0, y: 574.5, width: 1001, height: 44), [.header(3)]),
        ]
    )

    /// Four columns of 1,001 pt put origins and sizes on quarter points: exact ties, which
    /// round half away from zero.
    private static let daysOnQuarterPoints = Oracle(
        sections: daySections([1, 7, 6, 13, 2]),
        width: 1001,
        columnCount: 4,
        contentHeight: 2702.5,
        headerY: [0, 296.5, 837, 1377.5, 2406.5],
        tileEdge: 236.5,
        columnX: [16, 260.5, 504.5, 749],
        rowY: [[44], [340.5, 584.5], [881, 1125], [1421.5, 1665.5, 1910, 2154], [2450.5]],
        rects: [(CGRect(x: 0, y: 836.75, width: 1001, height: 0.5), [.header(2)])]
    )

    private static let daysRightToLeft = Oracle(
        sections: daySections([1, 7, 6, 13, 2]),
        width: 1001,
        columnCount: 7,
        isRightToLeft: true,
        contentHeight: 1097.5,
        headerY: [0, 191.5, 383, 574.5, 906],
        tileEdge: 131.5,
        columnX: [853.5, 714, 574.5, 434.5, 295, 155.5, 16],
        rowY: [[44], [235.5], [427], [618.5, 758.5], [950]]
    )

    /// Any sort but Date: one section, no header.
    private static let ungrouped = Oracle(
        sections: [MediaGridLayoutGeometry.Section(itemCount: 20, hasHeader: false)],
        width: 333,
        columnCount: 4,
        contentHeight: 410.5,
        headerY: [nil],
        tileEdge: 69.5,
        columnX: [16, 93.5, 170.5, 248],
        rowY: [[16, 93.5, 170.5, 248, 325]],
        rects: [
            // The fourth row starts at 247.75, 248 rounded: a rect ending at 248 holds it.
            (CGRect(x: 0, y: 37, width: 333, height: 211), (0 ..< 16).map { .item(0, $0) }),
        ]
    )

    private static let trailingDay = Oracle(
        sections: daySections([5, 1]),
        width: 637,
        columnCount: 5,
        contentHeight: 349,
        headerY: [0, 174.5],
        tileEdge: 114.5,
        columnX: [16, 138.5, 261, 384, 506.5],
        rowY: [[44], [218.5]],
        // The last tile ends at 333.2 exactly, 333 rounded.
        rects: [(CGRect(x: 0, y: 333, width: 637, height: 211), [.item(1, 0)])]
    )

    /// An empty order is one empty ungrouped section, which still holds its insets.
    private static let emptyUngrouped = Oracle(
        sections: [MediaGridLayoutGeometry.Section(itemCount: 0, hasHeader: false)],
        width: 900,
        columnCount: 6,
        contentHeight: 24,
        headerY: [nil],
        tileEdge: 0,
        columnX: [],
        rowY: [[]],
        rects: [(CGRect(x: 0, y: 0, width: 900, height: 700), [])]
    )

    private static let noSections = Oracle(
        sections: [],
        width: 900,
        columnCount: 6,
        contentHeight: 0,
        headerY: [],
        tileEdge: 0,
        columnX: [],
        rowY: [],
        rects: [(CGRect(x: 0, y: 0, width: 900, height: 700), [])]
    )

    private static let oracles = [
        days, daysOnQuarterPoints, daysRightToLeft, ungrouped, trailingDay, emptyUngrouped, noSections,
    ]

    @Test(arguments: oracles.indices)
    func geometryIsTheCompositionalLayouts(index: Int) {
        let oracle = Self.oracles[index]
        let geometry = oracle.geometry
        #expect(geometry.contentSize == CGSize(width: oracle.width, height: oracle.contentHeight))
        #expect(geometry.numberOfSections == oracle.sections.count)
        for (section, headerY) in oracle.headerY.enumerated() {
            let expected = headerY.map { CGRect(x: 0, y: $0, width: oracle.width, height: 28) }
            #expect(geometry.headerFrame(inSection: section) == expected)
        }
        for (section, contents) in oracle.sections.enumerated() {
            for item in 0 ..< contents.itemCount {
                let frame = geometry.itemFrame(at: IndexPath(item: item, section: section))
                #expect(frame == oracle.tileFrame(section: section, item: item))
            }
            #expect(geometry.itemFrame(at: IndexPath(item: contents.itemCount, section: section)) == nil)
        }
        for (rect, expected) in oracle.rects {
            let hits = geometry.elements(in: rect).map { element -> Hit in
                switch element {
                case let .header(section, _):
                    .header(section)
                case let .item(indexPath, _):
                    .item(indexPath.section, indexPath.item)
                }
            }
            #expect(Set(hits) == Set(expected))
            #expect(hits.count == expected.count)
        }
    }

    /// A rect query returns each element at the same frame a single-element query does,
    /// and every element the full content rect holds.
    @Test(arguments: oracles.indices)
    func aRectQueryAgreesWithSingleElementQueries(index: Int) {
        let geometry = Self.oracles[index].geometry
        let all = geometry.elements(in: CGRect(origin: .zero, size: geometry.contentSize))
        var items = 0
        for element in all {
            switch element {
            case let .header(section, frame):
                #expect(geometry.headerFrame(inSection: section) == frame)
            case let .item(indexPath, frame):
                items += 1
                #expect(geometry.itemFrame(at: indexPath) == frame)
            }
        }
        #expect(items == Self.oracles[index].sections.map(\.itemCount).reduce(0, +))
    }

    /// The owner's scale: a rect deep in the grid holds exactly the rows it crosses, found
    /// without visiting the sections before it.
    @Test func aRectDeepInALargeGridHoldsOnlyItsRows() {
        let sections = (0 ..< 5000).map { MediaGridLayoutGeometry.Section(itemCount: 31 + $0 % 3, hasHeader: true) }
        let geometry = MediaGridLayoutGeometry(
            sections: sections, columnCount: 6, width: 1200, headerHeight: 28, scale: 2, isRightToLeft: false
        )
        let viewport = CGRect(x: 0, y: geometry.contentSize.height / 2, width: 1200, height: 800)
        let elements = geometry.elements(in: viewport)
        #expect(!elements.isEmpty)
        #expect(elements.count < 100)
        for element in elements {
            switch element {
            case let .header(_, frame), let .item(_, frame):
                #expect(frame.maxY >= viewport.minY - 0.5)
                #expect(frame.minY <= viewport.maxY + 0.5)
            }
        }
    }

    @Test func mixedBatchTracksOnlyInsertsAndDeletes() {
        let items = [
            MediaGridUpdateItem(action: .insert, indexPathBeforeUpdate: nil, indexPathAfterUpdate: path(5)),
            MediaGridUpdateItem(action: .delete, indexPathBeforeUpdate: path(2), indexPathAfterUpdate: nil),
            MediaGridUpdateItem(action: .move, indexPathBeforeUpdate: path(0), indexPathAfterUpdate: path(1)),
        ]
        let tracked = MediaGridLayoutUpdatePolicy.trackedIndexPaths(for: items)
        #expect(tracked.inserted == [path(5)])
        #expect(tracked.deleted == [path(2)])
    }
}

extension AppKitWindowTests {
    /// `MediaGridLayout` in a real collection view: it reads the counts AppKit holds, the
    /// header flags it is given, the view's width and the window's backing scale, and
    /// answers every query from the geometry those make.
    @MainActor
    struct MediaGridLayoutWindowTests {
        @Test func theLayoutAnswersFromTheCollectionViewsCountsWidthAndScale() {
            let counts = [3, 14, 1, 40, 7]
            let source = LayoutTestSource(counts: counts)
            let collectionView = NSCollectionView()
            let layout = MediaGridLayout(columnCount: 5) { $0 != 2 }
            collectionView.collectionViewLayout = layout
            collectionView.register(LayoutTestTile.self, forItemWithIdentifier: LayoutTestSource.item)
            collectionView.register(
                LayoutTestHeader.self,
                forSupplementaryViewOfKind: MediaGridDayHeaderView.elementKind,
                withIdentifier: LayoutTestSource.header
            )
            collectionView.dataSource = source
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 777, height: 500))
            scrollView.scrollerStyle = .overlay
            scrollView.hasVerticalScroller = true
            scrollView.documentView = collectionView
            let window = orderedInTestWindow(width: 777, height: 500, contentView: scrollView)
            defer { window.close() }
            collectionView.layoutSubtreeIfNeeded()

            let expected = MediaGridLayoutGeometry(
                sections: counts.enumerated().map { .init(itemCount: $1, hasHeader: $0 != 2) },
                columnCount: 5,
                width: collectionView.bounds.width,
                headerHeight: MediaGridDayHeaderView.height,
                scale: window.backingScaleFactor,
                isRightToLeft: false
            )
            #expect(collectionView.bounds.width > 0)
            #expect(layout.collectionViewContentSize == expected.contentSize)
            for (section, count) in counts.enumerated() {
                let header = layout.layoutAttributesForSupplementaryView(
                    ofKind: MediaGridDayHeaderView.elementKind,
                    at: IndexPath(item: 0, section: section)
                )
                #expect(header?.frame == expected.headerFrame(inSection: section))
                for item in 0 ..< count {
                    let indexPath = IndexPath(item: item, section: section)
                    #expect(layout.layoutAttributesForItem(at: indexPath)?.frame == expected.itemFrame(at: indexPath))
                }
            }
            // The collection view realizes exactly the items the viewport holds.
            let viewport = scrollView.documentVisibleRect
            let inViewport = Set(expected.elements(in: viewport).compactMap { element -> IndexPath? in
                if case let .item(indexPath, _) = element {
                    return indexPath
                }
                return nil
            })
            #expect(!inViewport.isEmpty)
            #expect(Set(collectionView.indexPathsForVisibleItems()) == inViewport)

            // Only a width change invalidates.
            var scrolled = collectionView.bounds
            scrolled.origin.y += 300
            #expect(!layout.shouldInvalidateLayout(forBoundsChange: scrolled))
            var taller = collectionView.bounds
            taller.size.height += 200
            #expect(!layout.shouldInvalidateLayout(forBoundsChange: taller))
            var narrower = collectionView.bounds
            narrower.size.width -= 40
            #expect(layout.shouldInvalidateLayout(forBoundsChange: narrower))

            // A data change is read at the next prepare.
            source.counts = [2]
            collectionView.reloadData()
            collectionView.layoutSubtreeIfNeeded()
            #expect(layout.geometry.numberOfSections == 1)
            #expect(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)) == nil)
        }
    }
}

private func path(_ item: Int) -> IndexPath {
    IndexPath(item: item, section: 0)
}

private final class LayoutTestSource: NSObject, NSCollectionViewDataSource {
    var counts: [Int]

    init(counts: [Int]) {
        self.counts = counts
    }

    func numberOfSections(in _: NSCollectionView) -> Int {
        counts.count
    }

    func collectionView(_: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        counts[section]
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        collectionView.makeItem(withIdentifier: Self.item, for: indexPath)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.header, for: indexPath)
    }

    static let item = NSUserInterfaceItemIdentifier("MediaGridLayoutTests.item")
    static let header = NSUserInterfaceItemIdentifier("MediaGridLayoutTests.header")
}

private final class LayoutTestTile: NSCollectionViewItem {
    override func loadView() {
        view = NSView()
    }
}

private final class LayoutTestHeader: NSView, NSCollectionViewElement {}
