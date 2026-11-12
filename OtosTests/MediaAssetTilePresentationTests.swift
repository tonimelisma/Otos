import CoreGraphics
@testable import OtosKit
import Testing

struct MediaAssetTilePresentationTests {
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

    // MARK: - Kind badge content table (APP-009)

    @Test func placeholderTilesNeverShowLowerRightBadge() {
        #expect(MediaAssetTilePresentation.badgeContent(
            detail: makeDetail(path: "movie.mp4", kind: .video, durationSeconds: 42),
            thumbnailPainted: false
        ) == .none)
        #expect(MediaAssetTilePresentation.badgeContent(
            detail: makeDetail(path: "shot.CR3", kind: .raw),
            thumbnailPainted: false
        ) == .none)
        #expect(MediaAssetTilePresentation.badgeContent(
            detail: makeDetail(path: "image.jpg", kind: .image),
            thumbnailPainted: false
        ) == .none)
    }

    @Test func brokenTilesSuppressBadgeEvenIfPaintedFlagWereTrue() {
        let brokenVideo = makeDetail(
            path: "broken.avi",
            kind: .video,
            enrichedMTime: 1000,
            durationSeconds: 12
        )
        #expect(brokenVideo.thumbnailUnavailable)
        #expect(MediaAssetTilePresentation.badgeContent(
            detail: brokenVideo,
            thumbnailPainted: true
        ) == .none)

        let brokenRaw = makeDetail(path: "broken.CR3", kind: .raw, enrichedMTime: 1000)
        #expect(brokenRaw.thumbnailUnavailable)
        #expect(MediaAssetTilePresentation.badgeContent(
            detail: brokenRaw,
            thumbnailPainted: true
        ) == .none)
    }

    @Test func paintedVideoWithoutDurationShowsFilmIcon() {
        #expect(MediaAssetTilePresentation.badgeContent(
            detail: makeDetail(path: "movie.mp4", kind: .video, thumbnailPath: "t.jpg", durationSeconds: nil),
            thumbnailPainted: true
        ) == .filmIcon)
    }

    @Test func paintedRawShowsRawLabel() {
        #expect(MediaAssetTilePresentation.badgeContent(
            detail: makeDetail(path: "shot.CR3", kind: .raw, thumbnailPath: "t.jpg"),
            thumbnailPainted: true
        ) == .rawLabel)
        #expect(MediaAssetTilePresentation.badgeContent(
            detail: makeDetail(path: "shot.NEF", kind: .raw, thumbnailPath: "t.jpg", durationSeconds: 42),
            thumbnailPainted: true
        ) == .rawLabel)
    }

    @Test func accessibilityLabelCoversBrokenLoadingAndPaintedStates() {
        let brokenImage = makeDetail(path: "x.jpg", kind: .image, enrichedMTime: 1)
        #expect(MediaAssetTilePresentation.accessibilityLabel(
            detail: brokenImage,
            badgeContent: .none
        ) == "x.jpg, image, preview unavailable, not rated")
        let brokenVideo = makeDetail(path: "x.mp4", kind: .video, enrichedMTime: 1)
        #expect(MediaAssetTilePresentation.accessibilityLabel(
            detail: brokenVideo,
            badgeContent: .none
        ) == "x.mp4, video, preview unavailable, not rated")
        let brokenRaw = makeDetail(path: "x.CR3", kind: .raw, enrichedMTime: 1)
        #expect(MediaAssetTilePresentation.accessibilityLabel(
            detail: brokenRaw,
            badgeContent: .none
        ) == "x.CR3, image, preview unavailable, not rated")

        let loadingVideo = makeDetail(path: "v.mp4", kind: .video)
        #expect(MediaAssetTilePresentation.accessibilityLabel(
            detail: loadingVideo,
            badgeContent: .none
        ) == "v.mp4, video, not rated")
        let loadingRaw = makeDetail(path: "r.CR3", kind: .raw)
        #expect(MediaAssetTilePresentation.accessibilityLabel(
            detail: loadingRaw,
            badgeContent: .none
        ) == "r.CR3, RAW image, not rated")

        let painted = makeDetail(path: "v.mp4", kind: .video, thumbnailPath: "t.jpg", durationSeconds: 42)
        #expect(MediaAssetTilePresentation.accessibilityLabel(
            detail: painted,
            badgeContent: .durationText("0:42")
        ) == "v.mp4, video, 0:42, not rated")
        let liked = makeDetail(path: "liked.jpg", kind: .image, mediaChoice: .liked)
        #expect(MediaAssetTilePresentation.accessibilityLabel(
            detail: liked,
            badgeContent: .none
        ) == "liked.jpg, image, liked")
        let edited = makeDetail(path: "e.jpg", kind: .image, thumbnailPath: "t.jpg", editRecipe: EditRecipe(exposure: 1))
        #expect(MediaAssetTilePresentation.isEdited(edited))
        #expect(MediaAssetTilePresentation.accessibilityLabel(
            detail: edited,
            badgeContent: .none
        ) == "e.jpg, image, edited, not rated")
        #expect(!MediaAssetTilePresentation.isEdited(makeDetail(path: "n.jpg", kind: .image, editRecipe: .neutral)))
    }

    @Test func thumbnailUnavailableIsDerivedFromStampWithoutPath() {
        #expect(!makeDetail(path: "a.jpg").thumbnailUnavailable)
        #expect(!makeDetail(path: "a.jpg", thumbnailPath: "t.jpg", enrichedMTime: 1).thumbnailUnavailable)
        #expect(makeDetail(path: "a.jpg", enrichedMTime: 1).thumbnailUnavailable)
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

    // MARK: - Thumbnail-only hit area

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

    @Test func imageContentKeyDistinguishesThumbnailPathStampAndSize() {
        let base = makeDetail(thumbnailPath: "t.jpg", enrichedMTime: 10, enrichedSize: 1)
        let sameAgain = makeDetail(thumbnailPath: "t.jpg", enrichedMTime: 10, enrichedSize: 1)
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                == MediaAssetTilePresentation.imageContentKey(sameAgain)
        )

        let newThumbnail = makeDetail(thumbnailPath: "u.jpg", enrichedMTime: 10, enrichedSize: 1)
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newThumbnail)
        )

        let newStamp = makeDetail(thumbnailPath: "t.jpg", enrichedMTime: 11, enrichedSize: 1)
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newStamp)
        )

        let newSize = makeDetail(thumbnailPath: "t.jpg", enrichedMTime: 10, enrichedSize: 999)
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newSize)
        )
    }

    /// ADR 0036: a saved edit's render keeps the thumbnail's file name, so the key carries
    /// the rendered revision and a tile repaints with the edit.
    @Test func imageContentKeyDistinguishesTheRenderedEdit() {
        let unedited = makeDetail(thumbnailPath: "t.jpg", enrichedMTime: 10, enrichedSize: 1)
        let edited = makeDetail(thumbnailPath: "t.jpg", enrichedMTime: 10, enrichedSize: 1, renderedRevision: 1)
        #expect(
            MediaAssetTilePresentation.imageContentKey(unedited)
                != MediaAssetTilePresentation.imageContentKey(edited)
        )
    }

    @Test func imageContentKeyIgnoresDurationBadgeChanges() {
        let base = makeDetail(thumbnailPath: "t.jpg", enrichedMTime: 10, enrichedSize: 1)
        let newDuration = makeDetail(
            thumbnailPath: "t.jpg",
            enrichedMTime: 10,
            enrichedSize: 1,
            durationSeconds: 42
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                == MediaAssetTilePresentation.imageContentKey(newDuration)
        )
    }

    /// DES-066: the group rides the *thumbnail face* — the aspect-fit image the
    /// user sees — at its corner plus one margin, so it sits on the photo rather
    /// than out in the cell's letterbox, and it moves with the face instead of
    /// staying pinned to a cell corner the image does not reach.
    @Test func theChoiceGroupSitsInTheThumbnailsUpperLeftCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let portrait = CGSize(width: 400, height: 1200)
        let face = MediaAssetTilePresentation.contentRect(imagePixelSize: portrait, bounds: bounds)
        // Precondition: this cell really does letterbox, so face and cell differ.
        #expect(face.minX > bounds.minX)

        let inset = MediaAssetTileLayout.choiceGroupInset
        let group = MediaAssetTilePresentation.choiceGroupRect(buttonCount: 2, contentRect: face)
        #expect(group.minX == face.minX + inset)
        #expect(group.minY == face.minY + inset)
        // It tracks the thumbnail, not the cell.
        #expect(group.minX > bounds.minX + inset)
        // A margin, not a flush corner — and the group stays inside the face.
        #expect(inset > 0)
        #expect(face.contains(group))

        // Two targets at the DES-067 floor, sized from the constants themselves so
        // the assertion keeps meaning if the floor ever moves.
        let expectedWidth = MediaAssetTileLayout.choiceButtonSize * 2
            + MediaAssetTileLayout.choiceButtonSpacing
        #expect(group.width == expectedWidth)
        #expect(group.height == MediaAssetTileLayout.choiceButtonSize)
        #expect(MediaAssetTileLayout.choiceButtonSize >= 28)

        // A landscape image in the same cell letterboxes vertically instead, and
        // the group follows the face down rather than staying at the cell's top.
        let landscape = MediaAssetTilePresentation.contentRect(
            imagePixelSize: CGSize(width: 1200, height: 400),
            bounds: bounds
        )
        let onLandscape = MediaAssetTilePresentation.choiceGroupRect(buttonCount: 2, contentRect: landscape)
        #expect(onLandscape.minY == landscape.minY + inset)
        #expect(onLandscape.minY > bounds.minY + inset)
    }
}

private func makeDetail(
    path: String = "a.jpg",
    kind: MediaKind? = nil,
    thumbnailPath: String? = nil,
    enrichedMTime: Int? = nil,
    enrichedSize: Int64? = nil,
    durationSeconds: Double? = nil,
    mediaChoice: MediaChoice = .default,
    renderedRevision: Int64 = 0,
    editRecipe: EditRecipe? = nil
) -> MediaTileDetail {
    MediaTileDetail(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path),
        thumbnailPath: thumbnailPath,
        editRecipe: editRecipe,
        renderedRevision: renderedRevision,
        bestKind: kind,
        durationSeconds: durationSeconds,
        renderedSourceSize: enrichedSize,
        renderedSourceMTimeSeconds: enrichedMTime,
        mediaChoice: mediaChoice
    )
}
