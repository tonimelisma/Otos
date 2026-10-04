import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Content inserted above the viewport must not displace what the user is reading, and a
/// filter or sort change must not lose the user's place (APP-033, APP-042).
///
/// `NSScrollView` holds the scroll offset fixed, so items inserted above slide the content
/// down under a stationary window. During an import that happens on every apply: the order
/// is newest-first and a card copies oldest-first, so each published asset lands at index 0.
/// Measured on a 999-item card: 273 applies inserting 2–10 items each, one about every
/// 1.1 s for five minutes.
@MainActor
struct MediaGridScrollAnchorTests {
    /// The defect, stated as the invariant it broke: the item under the viewport's top edge
    /// stays under the viewport's top edge across an apply that inserts above it.
    @Test func insertingAboveTheViewportDoesNotMoveWhatTheUserIsLooking() throws {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 600)

        let before = try #require(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []))

        controller.applyIDs(prepending: 12, to: controller.currentIDs)
        controller.restoreScrollAnchor(before)

        let after = try #require(
            controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []),
            "the restore left the grid at the top, so the anchor was lost entirely"
        )
        #expect(after.id == before.id, "the viewport's top item changed — the user was displaced")
        #expect(
            abs(after.offsetFromViewportLeadingEdge - before.offsetFromViewportLeadingEdge) < 1,
            "the anchored item moved on screen"
        )
    }

    /// Without the restore the same apply displaces the user, so the test above is proving
    /// the anchor and not merely a grid that happens to hold still.
    @Test func withoutTheRestoreTheSameInsertDoesDisplaceTheUser() {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 600)
        let before = controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: [])?.id

        controller.applyIDs(prepending: 12, to: controller.currentIDs)

        let after = controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: [])?.id
        #expect(before != after, "negative control: an unanchored insert above must displace")
    }

    /// The exception that makes the rule feel right. At the top, arrivals pushing the grid
    /// down is the signal that something is happening, and nothing the user was reading is
    /// displaced — so anchoring is deliberately withheld there.
    @Test func atTheTopOfTheGridArrivalsAreAllowedToPushDown() {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 0)

        #expect(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []) == nil)
    }

    /// A new scope starts at the top, and the anchor must not fight that.
    @Test func aNewScopeIsNotAnchored() {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 600)

        #expect(controller.captureScrollAnchor(change: .scope, nextOrderedIDs: []) == nil)
    }

    /// An anchor whose item this apply removed leaves the scroll alone rather than guessing
    /// at a replacement — a guess would be a jump to an unrelated place in the library.
    @Test func aVanishedAnchorLeavesTheScrollAlone() {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 600)
        let stale = MediaGridViewController.ScrollAnchor(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "never-existed.jpg")
            ),
            offsetFromViewportLeadingEdge: 0,
            source: .leading
        )
        let before = controller.scrollView.contentView.bounds.origin.y

        controller.restoreScrollAnchor(stale)

        #expect(controller.scrollView.contentView.bounds.origin.y == before)
    }

    /// The filmstrip under the loupe scrolls horizontally, and the same import order puts
    /// every arrival to the left of the viewport. The tile under the viewport's left edge
    /// stays there, at the same offset.
    @Test func insertingLeftOfTheStripViewportDoesNotMoveTheStrip() throws {
        let controller = makeAnchorController(itemCount: 200, presentation: .strip(tileEdge: 72))
        controller.scrollTo(offset: 900)

        let before = try #require(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []))

        controller.applyIDs(prepending: 12, to: controller.currentIDs)
        controller.restoreScrollAnchor(before)

        let after = try #require(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []))
        #expect(after.id == before.id, "the strip's leading tile changed — the strip drifted")
        #expect(
            abs(after.offsetFromViewportLeadingEdge - before.offsetFromViewportLeadingEdge) < 1,
            "the anchored tile moved on screen"
        )
    }

    /// Negative control for the strip: unanchored, the same insert does displace it.
    @Test func withoutTheRestoreTheSameInsertDoesDisplaceTheStrip() {
        let controller = makeAnchorController(itemCount: 200, presentation: .strip(tileEdge: 72))
        controller.scrollTo(offset: 900)
        let before = controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: [])?.id

        controller.applyIDs(prepending: 12, to: controller.currentIDs)

        let after = controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: [])?.id
        #expect(before != after, "negative control: an unanchored insert to the left must displace")
    }

    /// The grid's top-edge exception does not carry over: the strip's viewport holds the
    /// tile the loupe is showing, so arrivals at its leading edge would push that tile away.
    /// Asserted on the anchored tile's on-screen position rather than on which tile is
    /// leftmost: at the leading edge the section inset is visible, and after the restore
    /// the tail of the newest arrival legitimately fills it.
    @Test func theStripIsAnchoredEvenAtItsLeadingEdge() throws {
        let controller = makeAnchorController(itemCount: 200, presentation: .strip(tileEdge: 72))
        controller.scrollTo(offset: 0)

        let before = try #require(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []))
        let screenXBefore = try #require(controller.viewportX(of: before.id))

        controller.applyIDs(prepending: 12, to: controller.currentIDs)
        controller.restoreScrollAnchor(before)

        let screenXAfter = try #require(controller.viewportX(of: before.id))
        #expect(abs(screenXAfter - screenXBefore) < 1, "arrivals pushed the leading tile")
    }

    // MARK: - Filter and sort keep the user's place (APP-042)

    /// A filter that keeps the item under the viewport's top edge leaves that item exactly
    /// where it was on screen — the user's place survives narrowing the collection. The
    /// assertion is on the item's on-screen offset, not on which item is now leftmost in
    /// the top row: the filter reflows the rows, so the anchored item can sit mid-row.
    @Test func aFilterKeepsTheTopItemWhereItWas() throws {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 600)
        let before = try #require(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []))
        let ids = controller.currentIDs
        let kept = ids.enumerated()
            .filter { $0.offset.isMultiple(of: 3) || $0.element == before.id }
            .map(\.element)

        controller.perform(controller.mutationGate.receive(filtered(kept)))

        let after = try #require(
            controller.onScreenOffset(of: before.id),
            "the filter moved the item the user was on off screen"
        )
        #expect(abs(after - before.offsetFromViewportLeadingEdge) < 1)
    }

    /// A filter that removes the top item puts its nearest survivor *in the order the user
    /// was looking at* in its place — the next later survivor, not whatever now sits at the
    /// same index of the shorter list. Scrolled deep into a large library so the survivor
    /// is far enough down the filtered grid to be positioned without clamping to the top.
    @Test func aFilterThatRemovesTheTopItemLandsOnItsNearestSurvivor() throws {
        let controller = makeAnchorController(itemCount: 600)
        controller.scrollTo(offset: 3000)
        let before = try #require(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []))
        let ids = controller.currentIDs
        let topIndex = try #require(ids.firstIndex(of: before.id))
        // Keep every fifth item, but none of the five starting at the top item: the next
        // later survivor is then the first multiple of five past that run.
        let kept = ids.indices
            .filter { $0.isMultiple(of: 5) && !(topIndex ..< topIndex + 5).contains($0) }
            .map { ids[$0] }
        let expected = try #require(ids[(topIndex + 1)...].first(where: Set(kept).contains))

        controller.perform(controller.mutationGate.receive(filtered(kept)))

        let after = try #require(
            controller.onScreenOffset(of: expected),
            "the nearest survivor is not on screen"
        )
        #expect(abs(after - before.offsetFromViewportLeadingEdge) < 1)
    }

    /// Negative control for the two tests above: the same filtered snapshot without the
    /// anchor does not leave the user's item where it was.
    @Test func withoutTheAnchorAFilterDisplacesTheUser() throws {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 600)
        let before = try #require(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []))
        let ids = controller.currentIDs
        let kept = ids.enumerated()
            .filter { $0.offset.isMultiple(of: 3) || $0.element == before.id }
            .map(\.element)

        controller.applyIDs(prepending: 0, to: kept)

        let after = controller.onScreenOffset(of: before.id)
        #expect(after.map { abs($0 - before.offsetFromViewportLeadingEdge) >= 1 } ?? true)
    }

    /// A visible selected tile is what the user was working on, so a sort that would carry
    /// it to the other end of the grid keeps it on screen at the same position instead.
    @Test func aSortKeepsAVisibleSelectedTileWhereItWas() throws {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 600)
        let top = try #require(controller.captureScrollAnchor(change: .unchanged, nextOrderedIDs: []))
        let ids = controller.currentIDs
        let selected = try ids[#require(ids.firstIndex(of: top.id)) + 7]
        controller.selectionHandlers = MediaGridSelectionHandlers(
            currentSelection: { GridSelection.empty.plainClick(selected) }
        )
        let offsetBefore = try #require(controller.onScreenOffset(of: selected))

        controller.perform(controller.mutationGate.receive(sorted(Array(ids.reversed()))))

        let offsetAfter = try #require(
            controller.onScreenOffset(of: selected),
            "the selected tile left the viewport"
        )
        #expect(abs(offsetAfter - offsetBefore) < 1)
    }

    /// At the top of the grid a filter with nothing selected stays at the top — there is no
    /// place to keep other than "the beginning".
    @Test func aFilterAtTheTopStaysAtTheTop() {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 0)
        let kept = controller.currentIDs.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)

        #expect(controller.captureScrollAnchor(change: .filterOrSort, nextOrderedIDs: kept) == nil)
        controller.perform(controller.mutationGate.receive(filtered(kept)))

        #expect(controller.scrollView.contentView.bounds.origin.y == 0)
    }
}

@MainActor
private extension MediaGridViewController {
    /// The item's top edge relative to the viewport's top edge, or nil when off screen.
    func onScreenOffset(of id: MediaAssetID) -> CGFloat? {
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame
        else {
            return nil
        }
        let viewport = scrollView.documentVisibleRect
        guard frame.intersects(viewport) else {
            return nil
        }
        return frame.minY - viewport.minY
    }

    var currentIDs: [MediaAssetID] {
        (0 ..< collectionView.numberOfItems(inSection: 0))
            .compactMap { dataSource.itemIdentifier(for: IndexPath(item: $0, section: 0)) }
    }

    /// The item's left edge relative to the viewport's left edge.
    func viewportX(of id: MediaAssetID) -> CGFloat? {
        guard let path = dataSource.indexPath(for: id),
              let frame = collectionView.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame
        else {
            return nil
        }
        return frame.minX - scrollView.documentVisibleRect.minX
    }

    func scrollTo(offset: CGFloat) {
        collectionView.layoutSubtreeIfNeeded()
        let point = presentation.isStrip ? NSPoint(x: offset, y: 0) : NSPoint(x: 0, y: offset)
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        collectionView.layoutSubtreeIfNeeded()
    }

    func applyIDs(prepending count: Int, to existing: [MediaAssetID]) {
        let fresh = (0 ..< count).map {
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "fresh-\($0).jpg")
            )
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, MediaAssetID>()
        snapshot.appendSections([.ungrouped])
        snapshot.appendItems(fresh + existing, toSection: .ungrouped)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutSubtreeIfNeeded()
    }
}

@MainActor
private func makeAnchorController(
    itemCount: Int,
    presentation: MediaGridPresentation = .grid(columnCount: GridColumnCount.defaultValue)
) -> MediaGridViewController {
    let controller = MediaGridViewController(presentation: presentation)
    // A real frame: the anchor is defined by where an item sits relative to the viewport,
    // so a zero-sized scroll view would make every offset trivially equal. Sized on the
    // controller's root — the grid's root is a container holding the scroll view and the
    // day bar, and the scroll view takes its size from that container's constraints.
    let height: CGFloat = presentation.isStrip ? 100 : 600
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: height)
    controller.view.layoutSubtreeIfNeeded()

    let ids = (0 ..< itemCount).map {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "asset-\($0).jpg")
        )
    }
    var snapshot = NSDiffableDataSourceSnapshot<MediaGridViewController.Section, MediaAssetID>()
    snapshot.appendSections([.ungrouped])
    snapshot.appendItems(ids, toSection: .ungrouped)
    controller.dataSource.apply(snapshot, animatingDifferences: false)
    controller.collectionView.layoutSubtreeIfNeeded()
    // The gate must know what is on screen: a filter's nearest survivor is found in the
    // order the user was looking at, which is the gate's displayed order.
    let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids)
    _ = controller.mutationGate.receive(grid)
    _ = controller.mutationGate.completeStructuralApply(applied: grid)
    return controller
}

/// The same scope under an active filter: a `.filterOrSort` change from the default query.
private func filtered(_ ids: [MediaAssetID]) -> CatalogMediaGridState {
    CatalogMediaGridState(
        descriptor: CatalogQueryDescriptor(scope: .allMedia, filter: MediaFilter(kinds: [.image])),
        orderedAssetIDs: ids
    )
}

/// The same scope under a different sort: a `.filterOrSort` change from the default query.
private func sorted(_ ids: [MediaAssetID]) -> CatalogMediaGridState {
    CatalogMediaGridState(
        descriptor: CatalogQueryDescriptor(
            scope: .allMedia,
            sort: MediaSortOrder(field: .bestDate, direction: .ascending)
        ),
        orderedAssetIDs: ids
    )
}
