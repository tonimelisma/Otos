import CoreGraphics
@testable import Otos
import Testing

@MainActor
struct MediaAssetTilePresentationTests {
    @Test func onlyVideoDetailsReceiveVideoPresentation() {
        #expect(MediaAssetTilePresentation.isVideo(makeDetail(path: "movie.mp4", kind: .video)))
        #expect(!MediaAssetTilePresentation.isVideo(makeDetail(path: "image.jpg", kind: .image)))
        #expect(!MediaAssetTilePresentation.isVideo(makeDetail(path: "unknown.bin", kind: nil)))
    }

    @Test func videoBadgeTextOnlyAppearsForVideosWithDuration() {
        #expect(MediaAssetTilePresentation.videoBadgeText(makeDetail(
            path: "image.jpg",
            kind: .image,
            durationSeconds: 42
        )) == nil)
        #expect(MediaAssetTilePresentation.videoBadgeText(makeDetail(
            path: "movie.mp4",
            kind: .video,
            durationSeconds: nil
        )) == nil)
        #expect(MediaAssetTilePresentation.videoBadgeText(makeDetail(
            path: "short.mp4",
            kind: .video,
            durationSeconds: 0.5
        )) == "0:00")
        #expect(MediaAssetTilePresentation.videoBadgeText(makeDetail(
            path: "clip.mp4",
            kind: .video,
            durationSeconds: 42
        )) == "0:42")
        #expect(MediaAssetTilePresentation.videoBadgeText(makeDetail(
            path: "scene.mp4",
            kind: .video,
            durationSeconds: 187
        )) == "3:07")
        #expect(MediaAssetTilePresentation.videoBadgeText(makeDetail(
            path: "long.mp4",
            kind: .video,
            durationSeconds: 3753
        )) == "1:02:33")
    }

    @Test func videoBadgeVisibilityIsVideosOnly() {
        #expect(MediaAssetTilePresentation.showsVideoBadge(makeDetail(
            path: "movie.mp4",
            kind: .video
        )))
        #expect(!MediaAssetTilePresentation.showsVideoBadge(makeDetail(
            path: "image.jpg",
            kind: .image,
            durationSeconds: 42
        )))
    }

    @Test func contentRectAspectFitsImageInsideSquareCell() {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        #expect(MediaAssetTilePresentation.contentRect(
            imagePixelSize: CGSize(width: 400, height: 200),
            bounds: bounds
        ) == CGRect(x: 0, y: 30, width: 120, height: 60))
        #expect(MediaAssetTilePresentation.contentRect(
            imagePixelSize: CGSize(width: 200, height: 400),
            bounds: bounds
        ) == CGRect(x: 30, y: 0, width: 60, height: 120))
        #expect(MediaAssetTilePresentation.contentRect(
            imagePixelSize: CGSize(width: 300, height: 300),
            bounds: bounds
        ) == bounds)
        #expect(MediaAssetTilePresentation.contentRect(imagePixelSize: nil, bounds: bounds) == bounds)
    }

    @Test func badgeVisibilityHidesOnSmallRects() {
        #expect(MediaAssetTilePresentation.showsVideoBadge(
            contentRect: CGRect(x: 0, y: 0, width: 80, height: 80)
        ))
        #expect(!MediaAssetTilePresentation.showsVideoBadge(
            contentRect: CGRect(x: 0, y: 0, width: 80, height: 50)
        ))
        #expect(!MediaAssetTilePresentation.showsVideoBadge(
            contentRect: CGRect(x: 0, y: 0, width: 40, height: 80)
        ))
    }

    @Test func videoBadgeIsCornerAnchored() throws {
        let frame = try #require(MediaAssetTileLayout.videoBadgeFrame(
            contentBounds: CGRect(x: 0, y: 0, width: 120, height: 80),
            badgeWidth: 31
        ))
        #expect(frame == CGRect(x: 89, y: 60, width: 31, height: 20))
        #expect(MediaAssetTileLayout.videoBadgeFrame(
            contentBounds: CGRect(x: 0, y: 0, width: 30, height: 80),
            badgeWidth: 31
        ) == nil)
    }

    @Test func durationTextIsCenteredInsideRightAnchoredBadge() throws {
        let badgeWidth = MediaAssetTileLayout.videoBadgeWidth(durationTextWidth: 23.5)
        #expect(badgeWidth == 34)

        let badgeFrame = try #require(MediaAssetTileLayout.videoBadgeFrame(
            contentBounds: CGRect(x: 0, y: 0, width: 120, height: 80),
            badgeWidth: badgeWidth
        ))
        #expect(badgeFrame == CGRect(x: 86, y: 60, width: 34, height: 20))

        let textFrame = MediaAssetTileLayout.videoBadgeDurationFrame(badgeWidth: badgeWidth)
        #expect(textFrame == CGRect(x: 5, y: 3, width: 24, height: 14))
        #expect(textFrame.midX == badgeWidth / 2)
    }

    @Test func tilePaintDecisionUsesCachedImageSynchronously() {
        let detail = makeDetail(path: "a.jpg")
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "thumb.jpg#100#1",
            incomingThumbnailPath: "thumb.jpg",
            currentKey: nil,
            currentAssetID: nil,
            incomingAssetID: detail.id,
            cacheHasImage: true,
            hasPaintedImage: false
        )) == .paintCached)
    }

    @Test func tilePaintDecisionKeepsCurrentForSameIdentityDetailDowngrade() {
        let detail = makeDetail(path: "a.jpg")
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "#-1#-1",
            incomingThumbnailPath: nil,
            currentKey: "thumb.jpg#100#1",
            currentAssetID: detail.id,
            incomingAssetID: detail.id,
            cacheHasImage: false,
            hasPaintedImage: true
        )) == .keepCurrent)
    }

    @Test func tilePaintDecisionPlaceholdersOnlyBeforeAnyPaintedImage() {
        let detail = makeDetail(path: "a.jpg")
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "#-1#-1",
            incomingThumbnailPath: nil,
            currentKey: nil,
            currentAssetID: nil,
            incomingAssetID: detail.id,
            cacheHasImage: false,
            hasPaintedImage: false
        )) == .placeholder)
    }

    @Test func tilePaintDecisionRetainsCurrentImageForSameAssetCacheMiss() {
        let detail = makeDetail(path: "a.jpg")
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "new-thumb.jpg#100#2",
            incomingThumbnailPath: "new-thumb.jpg",
            currentKey: "old-thumb.jpg#100#1",
            currentAssetID: detail.id,
            incomingAssetID: detail.id,
            cacheHasImage: false,
            hasPaintedImage: true
        )) == .loadAsync(retainsCurrentImage: true))
    }

    @Test func tilePaintDecisionClearsDifferentAssetBeforeAsyncLoad() {
        let oldDetail = makeDetail(path: "a.jpg")
        let newDetail = makeDetail(path: "b.jpg")
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "b-thumb.jpg#100#1",
            incomingThumbnailPath: "b-thumb.jpg",
            currentKey: "a-thumb.jpg#100#1",
            currentAssetID: oldDetail.id,
            incomingAssetID: newDetail.id,
            cacheHasImage: false,
            hasPaintedImage: true
        )) == .loadAsync(retainsCurrentImage: false))
    }

    @Test func imageContentKeyDistinguishesThumbnailPathStampAndSize() {
        let base = makeDetail(thumbnailPath: "t.jpg")
        let sameAgain = makeDetail(thumbnailPath: "t.jpg")
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                == MediaAssetTilePresentation.imageContentKey(sameAgain)
        )

        let newThumbnail = makeDetail(thumbnailPath: "u.jpg")
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newThumbnail)
        )

        let newStamp = makeDetail(thumbnailPath: "t.jpg", enrichedMTime: 11)
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newStamp)
        )

        let newSize = makeDetail(thumbnailPath: "t.jpg", enrichedSize: 999)
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newSize)
        )
    }

    @Test func imageContentKeyIgnoresDurationBadgeChanges() {
        let base = makeDetail(thumbnailPath: "t.jpg")
        let newDuration = makeDetail(thumbnailPath: "t.jpg", durationSeconds: 42)
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                == MediaAssetTilePresentation.imageContentKey(newDuration)
        )
    }
}

@MainActor
private func makeDetail(
    path: String = "a.jpg",
    thumbnailPath: String? = nil,
    enrichedMTime: Int? = 10,
    enrichedSize: Int64 = 1,
    kind: MediaKind? = nil,
    durationSeconds: Double? = nil
) -> MediaTileDetail {
    MediaTileDetail(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path),
        thumbnailPath: thumbnailPath,
        bestKind: kind,
        durationSeconds: durationSeconds,
        enrichedSourceSize: enrichedSize,
        enrichedSourceMTimeSeconds: enrichedMTime
    )
}
