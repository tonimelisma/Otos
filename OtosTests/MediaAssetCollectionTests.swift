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

    @Test func captureDateTextUsesBestDateAndIsEmptyWhenUnknown() {
        let captured = Date(timeIntervalSince1970: 1000)
        let created = Date(timeIntervalSince1970: 2000)

        let enriched = makeDatedAsset(bestCaptureDate: captured, createdAt: created)
        #expect(MediaAssetTilePresentation.captureDateText(enriched)
            == captured.formatted(date: .abbreviated, time: .omitted))

        // Falls back to the filesystem date when no metadata date exists.
        let filesystemOnly = makeDatedAsset(bestCaptureDate: created, createdAt: created)
        #expect(MediaAssetTilePresentation.captureDateText(filesystemOnly)
            == created.formatted(date: .abbreviated, time: .omitted))

        // Empty, never fabricated, when nothing is known.
        let undated = makeDatedAsset(bestCaptureDate: nil, createdAt: nil)
        #expect(MediaAssetTilePresentation.captureDateText(undated).isEmpty)
    }

    @Test func contentKeyDistinguishesThumbnailStampAndDate() {
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
        #expect(MediaAssetTilePresentation.contentKey(base) == MediaAssetTilePresentation.contentKey(sameAgain))

        let newThumbnail = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "u.jpg",
            enrichedMTime: 10
        )
        #expect(MediaAssetTilePresentation.contentKey(base) != MediaAssetTilePresentation.contentKey(newThumbnail))

        // A re-thumbnailed file keeps the same name but a newer stamp; the key must change.
        let newStamp = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 11
        )
        #expect(MediaAssetTilePresentation.contentKey(base) != MediaAssetTilePresentation.contentKey(newStamp))

        // Bytes can change while mtime seconds stay equal; the size must be in the key.
        let newSize = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 1000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 10,
            enrichedSize: 999
        )
        #expect(MediaAssetTilePresentation.contentKey(base) != MediaAssetTilePresentation.contentKey(newSize))

        let newDate = makeDatedAsset(
            bestCaptureDate: Date(timeIntervalSince1970: 2000),
            thumbnailPath: "t.jpg",
            enrichedMTime: 10
        )
        #expect(MediaAssetTilePresentation.contentKey(base) != MediaAssetTilePresentation.contentKey(newDate))
    }
}

@MainActor
private func makeDatedAsset(
    bestCaptureDate: Date?,
    createdAt: Date? = nil,
    thumbnailPath: String? = nil,
    enrichedMTime: Int? = nil,
    enrichedSize: Int64 = 1
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
private func makeAsset(path: String, type: String?, name: String? = "asset", kind: MediaKind? = nil) -> MediaAsset {
    MediaAsset(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path),
        name: name,
        contentTypeIdentifier: type,
        byteSize: 1,
        createdAt: nil,
        contentModifiedAt: nil,
        bestKind: kind
    )
}

@MainActor
private func isNone(_ action: MediaAssetCollectionApplyGate.Action) -> Bool {
    if case .none = action {
        return true
    }
    return false
}
