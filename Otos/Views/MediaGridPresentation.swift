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

    /// A `sectionProvider` closure (not a fixed `section:`) so `.day` and
    /// `.ungrouped` sections — which never coexist in one snapshot, but alternate as
    /// the sort changes — can differ in whether they carry a day header, without
    /// rebuilding this layout object on a data change.
    ///
    /// Which sections carry one is answered from `structure`, which AppKit took in the
    /// same synchronous region that invalidated this layout.
    ///
    /// Column-count changes still replace the whole layout object via the zoom-swap
    /// path (`MediaGridZoom.swift`); this closure only varies per-section header
    /// presence within one such object.
    private func makeGridLayout(columnCount: Int) -> MediaGridAnimatedLayout {
        MediaGridAnimatedLayout(
            sectionProvider: { [weak self] sectionIndex, _ in
                Self.gridLayoutSection(
                    columnCount: columnCount,
                    showsDayHeader: self?.sectionShowsDayHeader(at: sectionIndex) ?? false
                )
            },
            configuration: NSCollectionViewCompositionalLayoutConfiguration()
        )
    }

    private func sectionShowsDayHeader(at sectionIndex: Int) -> Bool {
        structure.day(inSection: sectionIndex) != nil
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
            // The header spans the section's full width rather than its inset content
            // width, because the bar that carries the same label spans the viewport.
            // Measured: following the insets puts the header at x=12 w=876 against the
            // bar's x=0 w=900, so the label jumped 12 pt sideways at every handoff.
            // Vertical already agrees — the section's top inset lands below the
            // header, between it and the tiles.
            section.supplementariesFollowContentInsets = false
            // DES-069: an in-flow header at the label's one height (blank or not, so
            // the first row sits below the bar), scrolling with its own run.
            // Deliberately **not** `pinToVisibleBounds` — `MediaGridDayLabel.swift`
            // records what pinning actually does and why `MediaGridDayBarView` holds the
            // current day instead.
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(MediaGridDayHeaderView.height)
                ),
                elementKind: MediaGridDayHeaderView.elementKind,
                alignment: .top
            )
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
