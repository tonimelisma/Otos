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

    // MARK: - Thumbnail-only hit area (spec 0049)

    @Test func thumbnailFaceRectMatchesContentRect() {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        #expect(MediaAssetTilePresentation.thumbnailFaceRect(
            imagePixelSize: CGSize(width: 400, height: 200),
            bounds: bounds
        ) == CGRect(x: 0, y: 30, width: 120, height: 60))
    }

    @Test func thumbnailFaceRectIsFullBoundsForPlaceholder() {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        #expect(MediaAssetTilePresentation.thumbnailFaceRect(imagePixelSize: nil, bounds: bounds) == bounds)
    }

    @Test func landscapeThumbnailLetterboxIsMissAndFaceIsHit() {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        let face = MediaAssetTilePresentation.thumbnailFaceRect(
            imagePixelSize: CGSize(width: 400, height: 200),
            bounds: bounds
        )
        #expect(!face.contains(CGPoint(x: 60, y: 10)))
        #expect(!face.contains(CGPoint(x: 60, y: 110)))
        #expect(face.contains(CGPoint(x: 60, y: 60)))
    }

    @Test func portraitThumbnailLetterboxIsMissAndFaceIsHit() {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        let face = MediaAssetTilePresentation.thumbnailFaceRect(
            imagePixelSize: CGSize(width: 200, height: 400),
            bounds: bounds
        )
        #expect(!face.contains(CGPoint(x: 10, y: 60)))
        #expect(!face.contains(CGPoint(x: 110, y: 60)))
        #expect(face.contains(CGPoint(x: 60, y: 60)))
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

    // MARK: - Placeholder icon (spec 0047)

    @Test func placeholderIconIsFilmForVideoAndPhotoOtherwise() {
        #expect(MediaAssetTilePresentation.placeholderIconSystemName(for: .video) == "film")
        #expect(MediaAssetTilePresentation.placeholderIconSystemName(for: .image) == "photo")
        #expect(MediaAssetTilePresentation.placeholderIconSystemName(for: nil) == "photo")
    }

    @Test func placeholderIconCacheReturnsSameInstanceForSameKind() throws {
        let photoA = try #require(MediaAssetTilePresentation.placeholderIcon(for: .image))
        let photoB = try #require(MediaAssetTilePresentation.placeholderIcon(for: nil))
        let filmA = try #require(MediaAssetTilePresentation.placeholderIcon(for: .video))
        let filmB = try #require(MediaAssetTilePresentation.placeholderIcon(for: .video))

        #expect(photoA === photoB)
        #expect(filmA === filmB)
        #expect(photoA !== filmA)
    }

    @Test func placeholderIconSideIsAQuarterOfTheShorterContentDimension() {
        #expect(MediaAssetTileLayout.placeholderIconSide(
            contentBounds: CGRect(x: 0, y: 0, width: 120, height: 120)
        ) == 30)
        // Wider-than-tall content uses the shorter (height) dimension.
        #expect(MediaAssetTileLayout.placeholderIconSide(
            contentBounds: CGRect(x: 0, y: 0, width: 400, height: 100)
        ) == 25)
    }

    @Test func placeholderIconSideIsClampedToALegibleRange() {
        #expect(MediaAssetTileLayout.placeholderIconSide(
            contentBounds: CGRect(x: 0, y: 0, width: 40, height: 40)
        ) == 16) // 40/4 = 10, clamped up to the 16 pt minimum
        #expect(MediaAssetTileLayout.placeholderIconSide(
            contentBounds: CGRect(x: 0, y: 0, width: 400, height: 400)
        ) == 40) // 400/4 = 100, clamped down to the 40 pt maximum
    }

    @Test func placeholderIconFrameIsCenteredInContentBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        let frame = MediaAssetTileLayout.placeholderIconFrame(contentBounds: bounds)
        #expect(frame == CGRect(x: 45, y: 45, width: 30, height: 30))
        #expect(frame.midX == bounds.midX)
        #expect(frame.midY == bounds.midY)
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
