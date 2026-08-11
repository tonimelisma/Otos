import AppKit

/// Grid vs filmstrip presentation for the shared AppKit collection bridge.
///
/// One paint/selection/mutation owner (`MediaGridViewController`); only layout,
/// scroller axis, and zoom plumbing differ. Grid and strip are never on screen at
/// the same time — each mode hosts one representable instance.
enum MediaGridPresentation: Equatable {
    /// Multi-column vertical grid. `columnCount` is ViewModel-owned (3–9).
    case grid(columnCount: Int)
    /// Single-row horizontal filmstrip. `tileEdge` is the square tile size in points.
    case strip(tileEdge: CGFloat)

    static let defaultStripTileEdge: CGFloat = 72
    static let minStripTileEdge: CGFloat = 48
    static let maxStripTileEdge: CGFloat = 192

    var isStrip: Bool {
        if case .strip = self {
            return true
        }
        return false
    }
}

extension MediaGridViewController {
    static func makeLayout(presentation: MediaGridPresentation) -> NSCollectionViewLayout {
        switch presentation {
        case let .grid(columnCount):
            makeGridLayout(columnCount: columnCount)
        case let .strip(tileEdge):
            makeStripLayout(tileEdge: tileEdge)
        }
    }

    /// Backward-compatible entry used by zoom swaps (grid only).
    static func makeLayout(columnCount: Int) -> MediaGridAnimatedLayout {
        makeGridLayout(columnCount: columnCount)
    }

    private static func makeGridLayout(columnCount: Int) -> MediaGridAnimatedLayout {
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
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        return MediaGridAnimatedLayout(section: section)
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
