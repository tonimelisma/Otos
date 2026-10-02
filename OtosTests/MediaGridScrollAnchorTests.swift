import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Content inserted above the viewport must not displace what the user is reading.
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

        let before = try #require(controller.captureScrollAnchor(resetScroll: false))

        controller.applyIDs(prepending: 12, to: controller.currentIDs)
        controller.restoreScrollAnchor(before)

        let after = try #require(
            controller.captureScrollAnchor(resetScroll: false),
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
        let before = controller.captureScrollAnchor(resetScroll: false)?.id

        controller.applyIDs(prepending: 12, to: controller.currentIDs)

        let after = controller.captureScrollAnchor(resetScroll: false)?.id
        #expect(before != after, "negative control: an unanchored insert above must displace")
    }

    /// The exception that makes the rule feel right. At the top, arrivals pushing the grid
    /// down is the signal that something is happening, and nothing the user was reading is
    /// displaced — so anchoring is deliberately withheld there.
    @Test func atTheTopOfTheGridArrivalsAreAllowedToPushDown() {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 0)

        #expect(controller.captureScrollAnchor(resetScroll: false) == nil)
    }

    /// A deliberate scroll-to-top must not be fought by the anchor.
    @Test func aDeliberateScrollResetIsNotAnchored() {
        let controller = makeAnchorController(itemCount: 200)
        controller.scrollTo(offset: 600)

        #expect(controller.captureScrollAnchor(resetScroll: true) == nil)
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
            offsetFromViewportLeadingEdge: 0
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

        let before = try #require(controller.captureScrollAnchor(resetScroll: false))

        controller.applyIDs(prepending: 12, to: controller.currentIDs)
        controller.restoreScrollAnchor(before)

        let after = try #require(controller.captureScrollAnchor(resetScroll: false))
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
        let before = controller.captureScrollAnchor(resetScroll: false)?.id

        controller.applyIDs(prepending: 12, to: controller.currentIDs)

        let after = controller.captureScrollAnchor(resetScroll: false)?.id
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

        let before = try #require(controller.captureScrollAnchor(resetScroll: false))
        let screenXBefore = try #require(controller.viewportX(of: before.id))

        controller.applyIDs(prepending: 12, to: controller.currentIDs)
        controller.restoreScrollAnchor(before)

        let screenXAfter = try #require(controller.viewportX(of: before.id))
        #expect(abs(screenXAfter - screenXBefore) < 1, "arrivals pushed the leading tile")
    }
}

@MainActor
private extension MediaGridViewController {
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
    return controller
}
