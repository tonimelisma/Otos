import AppKit
@testable import OtosKit
import Testing

/// Tests the pure update-tracking bookkeeping. `NSCollectionViewUpdateItem`
/// has no public initializer, so this exercises `MediaGridAnimatedLayoutPolicy` through
/// the plain `MediaGridUpdateItem` mirror rather than real AppKit update items —
/// `MediaGridAnimatedLayout` itself only ever maps real update items into that mirror.
@MainActor
struct MediaGridAnimatedLayoutTests {
    @Test func mixedBatchTracksOnlyInsertsAndDeletes() {
        let items = [
            MediaGridUpdateItem(action: .insert, indexPathBeforeUpdate: nil, indexPathAfterUpdate: path(5)),
            MediaGridUpdateItem(action: .delete, indexPathBeforeUpdate: path(2), indexPathAfterUpdate: nil),
            MediaGridUpdateItem(action: .move, indexPathBeforeUpdate: path(0), indexPathAfterUpdate: path(1)),
        ]
        let tracked = MediaGridAnimatedLayoutPolicy.trackedIndexPaths(for: items)
        #expect(tracked.inserted == [path(5)])
        #expect(tracked.deleted == [path(2)])
    }
}

private func path(_ item: Int) -> IndexPath {
    IndexPath(item: item, section: 0)
}
