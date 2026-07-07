import AppKit

extension MediaAssetCollectionViewController {
    /// Fixed for now; increment 3 (grid zoom) replaces this constant with a published,
    /// user-adjustable column count.
    static let columnCount = 6

    static func makeLayout() -> MediaGridAnimatedLayout {
        // A counted fractional group expresses the invariant six columns once;
        // AppKit recomputes the square item size as the viewport width changes.
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
