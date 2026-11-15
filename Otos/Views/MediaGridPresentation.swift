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
            makeLayout(columnCount: columnCount)
        case let .strip(tileEdge):
            Self.makeStripLayout(tileEdge: tileEdge)
        }
    }

    /// The grid layout for `columnCount` columns; a zoom swap installs a new one
    /// (`MediaGridZoom.swift`), since the column count is the one geometry input a data
    /// change never moves.
    ///
    /// Which sections carry a day header is answered from `structure`, which AppKit took
    /// in the same synchronous region that invalidated this layout: `.day` and
    /// `.ungrouped` sections never coexist in one structure, but alternate as the sort
    /// changes, without rebuilding the layout object.
    func makeLayout(columnCount: Int) -> MediaGridLayout {
        MediaGridLayout(columnCount: columnCount) { [weak self] section in
            self?.structure.day(inSection: section) != nil
        }
    }

    /// Horizontal filmstrip: a plain compositional layout. The strip is one section, which
    /// the compositional layout solves once, so it has none of the per-section cost that
    /// moved the grid onto `MediaGridLayout`; it needs no insert/remove choreography.
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
