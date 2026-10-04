@testable import OtosKit
import Testing

struct MediaGridAnimationTests {
    @Test func suppressesApplyAnimationWhileScrollTickIsRecent() {
        #expect(MediaGridAnimation.suppressesApplyAnimation(lastScrollTickAge: 0))
        #expect(MediaGridAnimation.suppressesApplyAnimation(lastScrollTickAge: 0.16))
        #expect(
            MediaGridAnimation.suppressesApplyAnimation(
                lastScrollTickAge: MediaGridAnimation.applyAnimationScrollQuietThreshold - 0.001
            )
        )
    }

    @Test func allowsApplyAnimationAfterScrollQuietThreshold() {
        #expect(
            !MediaGridAnimation.suppressesApplyAnimation(
                lastScrollTickAge: MediaGridAnimation.applyAnimationScrollQuietThreshold
            )
        )
        #expect(MediaGridAnimation.suppressesApplyAnimation(lastScrollTickAge: 1) == false)
        #expect(MediaGridAnimation.suppressesApplyAnimation(lastScrollTickAge: .infinity) == false)
    }

    /// Import arrivals land left of the strip's anchored tile. The restore scrolls the strip
    /// by their width, so animating the survivors would draw a lurch the restore already
    /// cancelled — every visible tile ends where it started (APP-033).
    @Test func suppressesStripAnimationWhenArrivalsShiftTheAnchoredTile() {
        let ids = assetIDs(10)
        #expect(
            MediaGridAnimation.suppressesAnchoredStripAnimation(
                anchorID: ids[4],
                previousOrderedIDs: ids,
                nextOrderedIDs: assetIDs(3, prefix: "fresh") + ids
            )
        )
    }

    /// Changes that leave the anchored tile at its index scroll nothing, so the motion the
    /// animation draws (a neighbor closing a gap to the right) is real.
    @Test func keepsStripAnimationWhenTheAnchoredTileKeepsItsIndex() {
        let ids = assetIDs(10)
        #expect(
            !MediaGridAnimation.suppressesAnchoredStripAnimation(
                anchorID: ids[4],
                previousOrderedIDs: ids,
                nextOrderedIDs: ids.filter { $0 != ids[7] }
            )
        )
    }

    /// A removed anchor leaves the scroll untouched, so nothing is cancelled.
    @Test func keepsStripAnimationWhenTheAnchoredTileIsRemoved() {
        let ids = assetIDs(10)
        #expect(
            !MediaGridAnimation.suppressesAnchoredStripAnimation(
                anchorID: ids[4],
                previousOrderedIDs: ids,
                nextOrderedIDs: ids.filter { $0 != ids[4] }
            )
        )
    }
}

private func assetIDs(_ count: Int, prefix: String = "asset") -> [MediaAssetID] {
    (0 ..< count).map {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "\(prefix)-\($0).jpg")
        )
    }
}
