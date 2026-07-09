import AppKit

extension MediaGridViewController {
    /// The column count is user-adjustable (3–9, default `GridColumnCount.defaultValue`;
    /// spec 0048) and owned by `MediaGridMutationGate`, not a static constant. Every zoom
    /// surface routes through the gate, which emits a `.zoomSwap` action that
    /// `performZoomSwap(to:)` realizes by rebuilding this layout for the new count.
    static func makeLayout(columnCount: Int) -> MediaGridAnimatedLayout {
        // A counted fractional group expresses the column count once; AppKit
        // recomputes the square item size as the viewport width or column count changes.
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
}
