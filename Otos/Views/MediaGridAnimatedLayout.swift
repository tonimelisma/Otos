import AppKit

/// A lightweight, AppKit-independent mirror of the parts of `NSCollectionViewUpdateItem`
/// this layout needs. `NSCollectionViewUpdateItem` has no public initializer — AppKit
/// only ever hands the layout instances it created itself — so the bookkeeping this file
/// does with the mirror's readable properties is tested directly with plain Swift values
/// instead of exercising real AppKit update items.
nonisolated struct MediaGridUpdateItem: Equatable {
    let action: NSCollectionView.UpdateAction
    let indexPathBeforeUpdate: IndexPath?
    let indexPathAfterUpdate: IndexPath?
}

/// Pure bookkeeping for which index paths a batch of collection-view updates inserts or
/// deletes. Kept separate from `MediaGridAnimatedLayout` so it is unit-testable without a
/// live `NSCollectionView`.
nonisolated enum MediaGridAnimatedLayoutPolicy {
    static func trackedIndexPaths(
        for items: [MediaGridUpdateItem]
    ) -> (inserted: Set<IndexPath>, deleted: Set<IndexPath>) {
        var inserted = Set<IndexPath>()
        var deleted = Set<IndexPath>()
        for item in items {
            switch item.action {
            case .insert:
                if let after = item.indexPathAfterUpdate {
                    inserted.insert(after)
                }
            case .delete:
                if let before = item.indexPathBeforeUpdate {
                    deleted.insert(before)
                }
            default:
                break
            }
        }
        return (inserted, deleted)
    }
}

/// Animated insert/remove choreography guide
///
/// `NSCollectionViewCompositionalLayout` gives every appearing/disappearing item the same
/// transition as the surviving items around it (a plain frame glide) unless a layout
/// overrides the appear/disappear attribute hooks. This subclass fades and shrinks *only*
/// the items a diffable apply actually inserted or deleted in the current batch — every
/// other appearing item (initial layout install, scroll-driven reuse, a future zoom's
/// layout swap) falls through to `super` untouched, so those paths never see a spurious
/// fade. Bookkeeping is populated in `prepare(forCollectionViewUpdates:)` (called once per
/// batch before the appear/disappear hooks) and cleared in `finalizeCollectionViewUpdates()`
/// (called after the batch's animation completes), matching the documented AppKit update
/// lifecycle (`NSCollectionViewLayout.h`). When no update is in flight both tracking sets
/// are empty and this subclass is behaviorally identical to its superclass.
final class MediaGridAnimatedLayout: NSCollectionViewCompositionalLayout {
    private var insertedIndexPaths: Set<IndexPath> = []
    private var deletedIndexPaths: Set<IndexPath> = []

    override func prepare(forCollectionViewUpdates updateItems: [NSCollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        let mirrored = updateItems.map {
            MediaGridUpdateItem(
                action: $0.updateAction,
                indexPathBeforeUpdate: $0.indexPathBeforeUpdate as IndexPath?,
                indexPathAfterUpdate: $0.indexPathAfterUpdate as IndexPath?
            )
        }
        let tracked = MediaGridAnimatedLayoutPolicy.trackedIndexPaths(for: mirrored)
        insertedIndexPaths = tracked.inserted
        deletedIndexPaths = tracked.deleted
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        insertedIndexPaths = []
        deletedIndexPaths = []
    }

    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath) else {
            return nil
        }
        guard insertedIndexPaths.contains(itemIndexPath) else {
            return attributes
        }
        return Self.fadedAndShrunk(attributes)
    }

    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath) else {
            return nil
        }
        guard deletedIndexPaths.contains(itemIndexPath) else {
            return attributes
        }
        return Self.fadedAndShrunk(attributes)
    }

    /// Copies `attributes` before mutating — `super`'s return value may be a cached
    /// instance AppKit reuses across calls, not a fresh value owned by this call.
    private static func fadedAndShrunk(
        _ attributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        guard let copy = attributes.copy() as? NSCollectionViewLayoutAttributes else {
            return attributes
        }
        copy.alpha = 0
        let inset = copy.frame.width * MediaGridAnimation.insertShrinkFraction
        copy.frame = copy.frame.insetBy(dx: inset, dy: inset)
        return copy
    }
}
