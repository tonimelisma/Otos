import CoreGraphics
@testable import Otos
import Testing
import UniformTypeIdentifiers

@MainActor
struct MediaAssetCollectionTests {
    @Test func applyGateKeepsOnlyNewestPendingGrid() {
        let gate = MediaAssetCollectionApplyGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        let intermediate = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        let newest = makeGrid(scope: .allMedia, paths: ["c.jpg"])

        guard case let .apply(started, resetScroll, resetSelection) = gate.receive(first) else {
            Issue.record("The first structural state should start an apply")
            return
        }
        #expect(started == first)
        #expect(resetScroll == false)
        #expect(resetSelection == false)

        guard case let .pending(replacedFirstPending) = gate.receive(intermediate) else {
            Issue.record("An update during an apply should become pending")
            return
        }
        #expect(replacedFirstPending == false)

        guard case let .pending(replacedExisting) = gate.receive(newest) else {
            Issue.record("A newer update should replace the pending state")
            return
        }
        #expect(replacedExisting)

        guard case let .apply(next, nextResetScroll, nextResetSelection) = gate.complete(applied: first) else {
            Issue.record("Completing the first apply should start the newest pending state")
            return
        }
        #expect(next == newest)
        #expect(nextResetScroll == false)
        #expect(nextResetSelection == false)
    }

    @Test func identicalIDsRefreshVisibleWithoutStructuralApply() {
        let gate = MediaAssetCollectionApplyGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        guard case .apply = gate.receive(first) else {
            Issue.record("Expected initial structural apply")
            return
        }
        #expect(isNone(gate.complete(applied: first)))

        guard case let .refreshVisible(refreshed, resetScroll, resetSelection) = gate.receive(first) else {
            Issue.record("Unchanged identities should refresh visible item details")
            return
        }
        #expect(refreshed == first)
        #expect(resetScroll == false)
        #expect(resetSelection == false)
    }

    @Test func descriptorChangeResetsScrollAndSelectionAndSameDescriptorStructurePreservesThem() {
        let gate = MediaAssetCollectionApplyGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        guard case .apply = gate.receive(allMedia) else {
            Issue.record("Expected initial structural apply")
            return
        }
        _ = gate.complete(applied: allMedia)

        let sameDescriptor = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        let sameDescriptorAction = gate.receive(sameDescriptor)
        guard case let .apply(_, sameResetScroll, sameResetSelection) = sameDescriptorAction else {
            Issue.record("Expected same-descriptor structural apply")
            return
        }
        #expect(sameResetScroll == false)
        #expect(sameResetSelection == false)
        _ = gate.complete(applied: sameDescriptor)

        let libraryPath = LibraryRootPath(rawValue: "/Pictures")
        let differentScope = makeGrid(scope: .library(libraryPath), paths: ["a.jpg"])
        let differentScopeAction = gate.receive(differentScope)
        guard case let .apply(_, scopeResetScroll, scopeResetSelection) = differentScopeAction else {
            Issue.record("Expected scope-changing structural apply")
            return
        }
        #expect(scopeResetScroll)
        #expect(scopeResetSelection)
    }

    @Test func descriptorChangeWithSameIDsRefreshClearsSelection() {
        let gate = MediaAssetCollectionApplyGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        guard case .apply = gate.receive(allMedia) else {
            Issue.record("Expected initial structural apply")
            return
        }
        _ = gate.complete(applied: allMedia)

        let sameIDsInLibraryScope = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            paths: ["a.jpg"]
        )
        let scopeRefreshAction = gate.receive(sameIDsInLibraryScope)
        guard case let .refreshVisible(refreshed, resetScroll, resetSelection) = scopeRefreshAction else {
            Issue.record("Expected descriptor-changing refresh when IDs are unchanged")
            return
        }
        #expect(refreshed == sameIDsInLibraryScope)
        #expect(resetScroll)
        #expect(resetSelection)
    }

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

        // Falls back to the filesystem date when no metadata date exists.
        let filesystemOnly = makeDatedAsset(bestCaptureDate: created, createdAt: created)
        #expect(MediaAssetTilePresentation.captureDateText(filesystemOnly, now: now, calendar: calendar)
            == "Yesterday")

        // Empty, never fabricated, when nothing is known.
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

    @Test func imageContentKeyDistinguishesThumbnailPathStampAndSize() {
        let base = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 10
        )
        let sameAgain = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 10
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                == MediaAssetTilePresentation.imageContentKey(sameAgain)
        )

        let newThumbnail = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "u.jpg",
            enrichedMTime: 10
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newThumbnail)
        )

        // A re-thumbnailed file keeps the same name but a newer stamp; the key must change.
        let newStamp = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 11
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newStamp)
        )

        // Bytes can change while mtime seconds stay equal; the size must be in the key.
        let newSize = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 10,
            enrichedSize: 999
        )
        #expect(
            MediaAssetTilePresentation.imageContentKey(base)
                != MediaAssetTilePresentation.imageContentKey(newSize)
        )
    }

    @Test func imageContentKeyIgnoresDateAndDurationOverlayChanges() {
        let base = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 10
        )
        let newDate = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 2000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 10
        )
        #expect(MediaAssetTilePresentation.imageContentKey(base) == MediaAssetTilePresentation.imageContentKey(newDate))

        let newDuration = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 10,
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
    enrichedMTime: Int? = nil,
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
private func makeGrid(scope: SidebarSelection, paths: [String]) -> CatalogMediaGridState {
    let assets = paths.map { makeAsset(path: $0, type: UTType.jpeg.identifier) }
    return CatalogMediaGridState(
        scope: scope,
        orderedAssetIDs: assets.map(\.id)
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

@MainActor
private func isNone(_ action: MediaAssetCollectionApplyGate.Action) -> Bool {
    if case .none = action {
        return true
    }
    return false
}
