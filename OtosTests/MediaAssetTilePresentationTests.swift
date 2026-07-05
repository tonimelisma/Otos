import CoreGraphics
@testable import Otos
import Testing
import UniformTypeIdentifiers

@MainActor
struct MediaAssetTilePresentationTests {
    @Test func onlyMovieContentTypesReceiveVideoPresentation() {
        #expect(MediaAssetTilePresentation.isVideo(makeAsset(
            path: "movie.mp4",
            type: UTType.mpeg4Movie.identifier,
            kind: .video
        )))
        #expect(!MediaAssetTilePresentation.isVideo(makeAsset(
            path: "image.jpg",
            type: UTType.jpeg.identifier,
            kind: .image
        )))
        #expect(!MediaAssetTilePresentation.isVideo(makeAsset(path: "audio.mp3", type: UTType.mp3.identifier)))
        #expect(!MediaAssetTilePresentation.isVideo(makeAsset(path: "unknown.bin", type: nil)))
        #expect(!MediaAssetTilePresentation.isVideo(makeAsset(
            path: "document.docx",
            type: "org.openxmlformats.wordprocessingml.document"
        )))
        #expect(!MediaAssetTilePresentation.isVideo(makeAsset(path: "source.swift", type: "public.swift-source")))
    }

    @Test func tileTitleFallsBackToRelativePathFilename() {
        let asset = makeAsset(path: "Nested/fallback.jpg", type: UTType.jpeg.identifier, name: nil)
        #expect(MediaAssetTilePresentation.title(asset) == "fallback.jpg")
    }

    @Test func captureDateTextUsesBestDateAndIsEmptyWhenUnknown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 10,
            hour: 12
        )))
        let captured = Date(timeIntervalSince1970: 1000)
        let created = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 9,
            hour: 12
        )))

        let enriched = makeDatedAsset(bestCaptureDate: captured, createdAt: created)
        #expect(MediaAssetTilePresentation.captureDateText(enriched, now: now, calendar: calendar)
            == "January 1, 1970")

        let filesystemOnly = makeDatedAsset(bestCaptureDate: created, createdAt: created)
        #expect(MediaAssetTilePresentation.captureDateText(filesystemOnly, now: now, calendar: calendar)
            == "Yesterday")

        let undated = makeDatedAsset(bestCaptureDate: nil, createdAt: nil)
        #expect(MediaAssetTilePresentation.captureDateText(undated, now: now, calendar: calendar).isEmpty)
    }

    @Test func videoBadgeTextOnlyAppearsForVideosWithDuration() {
        #expect(MediaAssetTilePresentation.videoBadgeText(makeAsset(
            path: "image.jpg",
            type: UTType.jpeg.identifier,
            kind: .image,
            durationSeconds: 42
        )) == nil)
        #expect(MediaAssetTilePresentation.videoBadgeText(makeAsset(
            path: "movie.mp4",
            type: UTType.mpeg4Movie.identifier,
            kind: .video,
            durationSeconds: nil
        )) == nil)
        #expect(MediaAssetTilePresentation.videoBadgeText(makeAsset(
            path: "short.mp4",
            type: UTType.mpeg4Movie.identifier,
            kind: .video,
            durationSeconds: 0.5
        )) == "0:00")
        #expect(MediaAssetTilePresentation.videoBadgeText(makeAsset(
            path: "clip.mp4",
            type: UTType.mpeg4Movie.identifier,
            kind: .video,
            durationSeconds: 42
        )) == "0:42")
        #expect(MediaAssetTilePresentation.videoBadgeText(makeAsset(
            path: "scene.mp4",
            type: UTType.mpeg4Movie.identifier,
            kind: .video,
            durationSeconds: 187
        )) == "3:07")
        #expect(MediaAssetTilePresentation.videoBadgeText(makeAsset(
            path: "long.mp4",
            type: UTType.mpeg4Movie.identifier,
            kind: .video,
            durationSeconds: 3753
        )) == "1:02:33")
    }

    @Test func videoBadgeVisibilityIsVideosOnly() {
        #expect(MediaAssetTilePresentation.showsVideoBadge(makeAsset(
            path: "movie.mp4",
            type: UTType.mpeg4Movie.identifier,
            kind: .video
        )))
        #expect(!MediaAssetTilePresentation.showsVideoBadge(makeAsset(
            path: "image.jpg",
            type: UTType.jpeg.identifier,
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

    @Test func overlayVisibilityHidesBadgeBeforeDateOnShortRects() {
        #expect(MediaAssetTilePresentation.overlayVisibility(
            contentRect: CGRect(x: 0, y: 0, width: 80, height: 80)
        ) == MediaAssetTileOverlayVisibility(showsDate: true, showsVideoBadge: true))
        #expect(MediaAssetTilePresentation.overlayVisibility(
            contentRect: CGRect(x: 0, y: 0, width: 80, height: 50)
        ) == MediaAssetTileOverlayVisibility(showsDate: true, showsVideoBadge: false))
        #expect(MediaAssetTilePresentation.overlayVisibility(
            contentRect: CGRect(x: 0, y: 0, width: 80, height: 25)
        ) == MediaAssetTileOverlayVisibility(showsDate: false, showsVideoBadge: false))
        #expect(MediaAssetTilePresentation.overlayVisibility(
            contentRect: CGRect(x: 0, y: 0, width: 40, height: 80)
        ) == MediaAssetTileOverlayVisibility(showsDate: false, showsVideoBadge: false))
    }

    @Test func textScrimIsTextSizedAndCornerAnchored() throws {
        let frames = try #require(MediaAssetTileLayout.textScrimFrames(
            contentBounds: CGRect(x: 0, y: 0, width: 120, height: 80),
            titleTextWidth: 40,
            dateTextWidth: 72,
            showsDate: true
        ))

        #expect(frames.scrim == CGRect(x: 0, y: 0, width: 77, height: 31))
        #expect(frames.title == CGRect(x: 0, y: 0, width: 72, height: 14))
        #expect(frames.date == CGRect(x: 0, y: 15, width: 72, height: 12))

        let capped = try #require(MediaAssetTileLayout.textScrimFrames(
            contentBounds: CGRect(x: 0, y: 0, width: 80, height: 80),
            titleTextWidth: 200,
            dateTextWidth: 0,
            showsDate: false
        ))
        #expect(capped.scrim == CGRect(x: 0, y: 0, width: 80, height: 18))
        #expect(capped.title == CGRect(x: 0, y: 0, width: 75, height: 14))
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

    @Test func tilePaintDecisionUsesCachedImageSynchronously() {
        let asset = makeAsset(path: "a.jpg", type: UTType.jpeg.identifier)
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "thumb.jpg#100#1",
            incomingThumbnailPath: "thumb.jpg",
            currentKey: nil,
            currentAssetID: nil,
            incomingAssetID: asset.id,
            cacheHasImage: true,
            hasPaintedImage: false
        )) == .paintCached)
    }

    @Test func tilePaintDecisionKeepsCurrentForSameIdentityDetailDowngrade() {
        let asset = makeAsset(path: "a.jpg", type: UTType.jpeg.identifier)
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "#-1#-1",
            incomingThumbnailPath: nil,
            currentKey: "thumb.jpg#100#1",
            currentAssetID: asset.id,
            incomingAssetID: asset.id,
            cacheHasImage: false,
            hasPaintedImage: true
        )) == .keepCurrent)
    }

    @Test func tilePaintDecisionPlaceholdersOnlyBeforeAnyPaintedImage() {
        let asset = makeAsset(path: "a.jpg", type: UTType.jpeg.identifier)
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "#-1#-1",
            incomingThumbnailPath: nil,
            currentKey: nil,
            currentAssetID: nil,
            incomingAssetID: asset.id,
            cacheHasImage: false,
            hasPaintedImage: false
        )) == .placeholder)
    }

    @Test func tilePaintDecisionRetainsCurrentImageForSameAssetCacheMiss() {
        let asset = makeAsset(path: "a.jpg", type: UTType.jpeg.identifier)
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "new-thumb.jpg#100#2",
            incomingThumbnailPath: "new-thumb.jpg",
            currentKey: "old-thumb.jpg#100#1",
            currentAssetID: asset.id,
            incomingAssetID: asset.id,
            cacheHasImage: false,
            hasPaintedImage: true
        )) == .loadAsync(retainsCurrentImage: true))
    }

    @Test func tilePaintDecisionClearsDifferentAssetBeforeAsyncLoad() {
        let oldAsset = makeAsset(path: "a.jpg", type: UTType.jpeg.identifier)
        let newAsset = makeAsset(path: "b.jpg", type: UTType.jpeg.identifier)
        #expect(MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: "b-thumb.jpg#100#1",
            incomingThumbnailPath: "b-thumb.jpg",
            currentKey: "a-thumb.jpg#100#1",
            currentAssetID: oldAsset.id,
            incomingAssetID: newAsset.id,
            cacheHasImage: false,
            hasPaintedImage: true
        )) == .loadAsync(retainsCurrentImage: false))
    }

    @Test func imageContentKeyDistinguishesThumbnailPathStampAndSize() {
        let base = makeDatedAsset(bestCaptureDate: Date(timeIntervalSince1970: 1000), thumbnailPath: "t.jpg")
        let sameAgain = makeDatedAsset(bestCaptureDate: Date(timeIntervalSince1970: 1000), thumbnailPath: "t.jpg")
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                == MediaAssetTilePresentation.imageContentKey(sameAgain)
        )

        let newThumbnail = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "u.jpg"
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newThumbnail)
        )

        let newStamp = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 11
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newStamp)
        )

        let newSize = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedSize: 999
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newSize)
        )
    }

    @Test func imageContentKeyIgnoresDateAndDurationOverlayChanges() {
        let base = makeDatedAsset(bestCaptureDate: Date(timeIntervalSince1970: 1000), thumbnailPath: "t.jpg")
        let newDate = makeDatedAsset(bestCaptureDate: Date(timeIntervalSince1970: 2000), thumbnailPath: "t.jpg")
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                == MediaAssetTilePresentation.imageContentKey(newDate)
        )

        let newDuration = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            durationSeconds: 42
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                == MediaAssetTilePresentation.imageContentKey(newDuration)
        )
    }
}

@MainActor
private func makeDatedAsset(
    bestCaptureDate: Date?,
    createdAt: Date? = nil,
    thumbnailPath: String? = nil,
    enrichedMTime: Int? = 10,
    enrichedSize: Int64 = 1,
    durationSeconds: Double? = nil
) -> MediaAsset {
    MediaAsset(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: "a.jpg"),
        name: "a.jpg",
        contentTypeIdentifier: UTType.jpeg.identifier,
        byteSize: 1,
        createdAt: createdAt,
        contentModifiedAt: nil,
        thumbnailPath: thumbnailPath,
        bestCaptureDate: bestCaptureDate,
        durationSeconds: durationSeconds,
        enrichedSourceSize: enrichedSize,
        enrichedSourceMTimeSeconds: enrichedMTime
    )
}

@MainActor
private func makeAsset(
    path: String,
    type: String?,
    name: String? = "asset",
    kind: MediaKind? = nil,
    durationSeconds: Double? = nil
) -> MediaAsset {
    MediaAsset(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path),
        name: name,
        contentTypeIdentifier: type,
        byteSize: 1,
        createdAt: nil,
        contentModifiedAt: nil,
        bestKind: kind,
        durationSeconds: durationSeconds
    )
}
