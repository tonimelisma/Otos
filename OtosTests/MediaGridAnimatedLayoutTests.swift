import AppKit
@testable import OtosKit
import Testing

/// Tests the pure update-tracking bookkeeping (spec 0047). `NSCollectionViewUpdateItem`
/// has no public initializer, so this exercises `MediaGridAnimatedLayoutPolicy` through
/// the plain `MediaGridUpdateItem` mirror rather than real AppKit update items —
/// `MediaGridAnimatedLayout` itself only ever maps real update items into that mirror.
@MainActor
struct MediaGridAnimatedLayoutTests {
    @Test func insertsAreTrackedByTheirAfterUpdateIndexPath() {
        let items = [
            MediaGridUpdateItem(action: .insert, indexPathBeforeUpdate: nil, indexPathAfterUpdate: path(3)),
            MediaGridUpdateItem(action: .insert, indexPathBeforeUpdate: nil, indexPathAfterUpdate: path(7)),
        ]
        let tracked = MediaGridAnimatedLayoutPolicy.trackedIndexPaths(for: items)
        #expect(tracked.inserted == [path(3), path(7)])
        #expect(tracked.deleted.isEmpty)
    }

    @Test func deletesAreTrackedByTheirBeforeUpdateIndexPath() {
        let items = [
            MediaGridUpdateItem(action: .delete, indexPathBeforeUpdate: path(1), indexPathAfterUpdate: nil),
        ]
        let tracked = MediaGridAnimatedLayoutPolicy.trackedIndexPaths(for: items)
        #expect(tracked.deleted == [path(1)])
        #expect(tracked.inserted.isEmpty)
    }

    @Test func moveAndReloadAndNoneAreNotTrackedAsInsertsOrDeletes() {
        let items = [
            MediaGridUpdateItem(action: .move, indexPathBeforeUpdate: path(0), indexPathAfterUpdate: path(1)),
            MediaGridUpdateItem(action: .reload, indexPathBeforeUpdate: path(2), indexPathAfterUpdate: path(2)),
            MediaGridUpdateItem(action: .none, indexPathBeforeUpdate: path(4), indexPathAfterUpdate: path(4)),
        ]
        let tracked = MediaGridAnimatedLayoutPolicy.trackedIndexPaths(for: items)
        #expect(tracked.inserted.isEmpty)
        #expect(tracked.deleted.isEmpty)
    }

    @Test func emptyUpdateBatchTracksNothing() {
        let tracked = MediaGridAnimatedLayoutPolicy.trackedIndexPaths(for: [])
        #expect(tracked.inserted.isEmpty)
        #expect(tracked.deleted.isEmpty)
    }

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

    @Test func moveOnlyBatchRegistersNoDecoratedIndexPaths() {
        let items = [
            MediaGridUpdateItem(action: .move, indexPathBeforeUpdate: path(0), indexPathAfterUpdate: path(2)),
            MediaGridUpdateItem(action: .move, indexPathBeforeUpdate: path(1), indexPathAfterUpdate: path(0)),
            MediaGridUpdateItem(action: .move, indexPathBeforeUpdate: path(2), indexPathAfterUpdate: path(1)),
        ]
        let tracked = MediaGridAnimatedLayoutPolicy.trackedIndexPaths(for: items)
        #expect(tracked.inserted.isEmpty)
        #expect(tracked.deleted.isEmpty)
    }
}

private func path(_ item: Int) -> IndexPath {
    IndexPath(item: item, section: 0)
}
