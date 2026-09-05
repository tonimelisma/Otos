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

    /// A `sectionProvider` closure (not a fixed `section:`) so `.ungrouped` and
    /// `.day` sections — which never coexist in one snapshot, but alternate as
    /// sort changes — can differ in whether they carry a header, without ever
    /// needing to rebuild this layout object on a data change. Compositional
    /// layout re-invokes the closure per section on every layout pass that
    /// follows a diffable-data-source apply, so it always sees the just-applied
    /// snapshot. `dataSource` is read fresh each call (never captured by value)
    /// for the same reason. Column-count changes still replace the whole layout
    /// object via the existing zoom-swap path (`MediaGridZoom.swift`); this
    /// closure only varies per-section header presence within one such object.
    private func makeGridLayout(columnCount: Int) -> MediaGridAnimatedLayout {
        let configuration = NSCollectionViewCompositionalLayoutConfiguration()
        return MediaGridAnimatedLayout(
            sectionProvider: { [weak self] sectionIndex, _ in
                Self.gridLayoutSection(
                    columnCount: columnCount,
                    showsDayHeader: self?.sectionShowsDayHeader(at: sectionIndex) ?? false
                )
            },
            configuration: configuration
        )
    }

    private func sectionShowsDayHeader(at sectionIndex: Int) -> Bool {
        guard let dataSource else {
            return false
        }
        let identifiers = dataSource.snapshot().sectionIdentifiers
        guard sectionIndex < identifiers.count else {
            return false
        }
        if case .day = identifiers[sectionIndex] {
            return true
        }
        return false
    }

    private static func gridLayoutSection(columnCount: Int, showsDayHeader: Bool) -> NSCollectionLayoutSection {
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
        if showsDayHeader {
            // DES-069: pinned header, self-sized to its SwiftUI content.
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(32)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: MediaGridDayHeaderView.elementKind,
                alignment: .top
            )
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]
        }
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
