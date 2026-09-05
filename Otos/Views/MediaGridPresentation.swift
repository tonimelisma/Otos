import AppKit

/// Grid vs filmstrip presentation for the shared AppKit collection bridge.
///
/// One paint/selection/mutation owner (`MediaGridViewController`); only layout,
/// scroller axis, and zoom plumbing differ. Grid and strip are never on screen at
/// the same time — each mode hosts one representable instance.
nonisolated enum MediaGridPresentation: Equatable {
    /// Multi-column vertical grid. `columnCount` is ViewModel-owned (3–9).
    case grid(columnCount: Int)
    /// Single-row horizontal filmstrip. `tileEdge` is the square tile size in points.
    case strip(tileEdge: CGFloat)

    static let defaultStripTileEdge: CGFloat = 72
    /// The smallest filmstrip tile, set by what the hover curation group needs
    /// rather than by how small a thumbnail can usefully be drawn. Two 28pt acts
    /// (DES-067's hit-region floor) plus spacing and the corner margin need 61pt,
    /// so a 48pt tile could not show them without either shrinking the targets —
    /// exactly where they are hardest to hit — or overflowing onto the next tile.
    static let minStripTileEdge: CGFloat = 64
    static let maxStripTileEdge: CGFloat = 192

    var isStrip: Bool {
        if case .strip = self {
            return true
        }
        return false
    }
}

extension MediaGridViewController {
    func makeLayout(presentation: MediaGridPresentation) -> NSCollectionViewLayout {
        switch presentation {
        case let .grid(columnCount):
            makeGridLayout(columnCount: columnCount)
        case let .strip(tileEdge):
            Self.makeStripLayout(tileEdge: tileEdge)
        }
    }

    /// Backward-compatible entry used by zoom swaps (grid only).
    func makeLayout(columnCount: Int) -> MediaGridAnimatedLayout {
        makeGridLayout(columnCount: columnCount)
    }

    /// One fixed `section:` rather than a `sectionProvider` closure. Every grid
    /// section is laid out identically — day grouping changes which items sit in
    /// which section, never how a section is built — so there is nothing for a
    /// per-section closure to vary.
    ///
    /// It used to vary one thing: whether a section carried a day header. Answering
    /// that meant reading the diffable data source's section identifiers, and the
    /// only way AppKit offers to read them is `dataSource.snapshot()`, which copies
    /// the applied snapshot — once per section, on every layout pass following an
    /// apply. With a day section per day and enrichment applying about once a
    /// second, that was the most expensive remaining reader of a structure the
    /// controller already knows (`appliedDaySections`). Removing the header removed
    /// the question.
    ///
    /// Column-count changes still replace the whole layout object via the zoom-swap
    /// path (`MediaGridZoom.swift`).
    private func makeGridLayout(columnCount: Int) -> MediaGridAnimatedLayout {
        MediaGridAnimatedLayout(
            section: Self.gridLayoutSection(columnCount: columnCount),
            configuration: NSCollectionViewCompositionalLayoutConfiguration()
        )
    }

    private static func gridLayoutSection(columnCount: Int) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalWidth(1.0 / CGFloat(columnCount))
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            subitem: item,
            count: columnCount
        )
        let section = NSCollectionLayoutSection(group: group)
        // DES-060. Under Date sort each day is its own section, so this inset is also
        // what marks a day break in the grid: 24 pt between runs against 8 pt gutters
        // within one. There is no in-flow header to mark it — `MediaGridDayBarView` is
        // the single rendering of the day (DES-069).
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        return section
    }

    /// Horizontal filmstrip: plain compositional layout (no animated subclass). The strip
    /// needs no insert/remove choreography, and horizontal `scrollDirection` on the
    /// animated subclass was rejected after SIGSEGV during test teardown.
    private static func makeStripLayout(tileEdge: CGFloat) -> NSCollectionViewCompositionalLayout {
        let edge = max(MediaGridPresentation.minStripTileEdge, tileEdge)
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(edge),
            heightDimension: .absolute(edge)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute(edge),
            heightDimension: .absolute(edge)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        // Horizontal collection-view scrolling (not an orthogonal embedded scroller)
        // so the controller's clip-view bounds observer drives detail queries / preheat.
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        section.interGroupSpacing = 0
        let configuration = NSCollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        return NSCollectionViewCompositionalLayout(section: section, configuration: configuration)
    }
}
