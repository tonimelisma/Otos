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

        guard case let .apply(started, resetScroll) = gate.receive(first) else {
            Issue.record("The first structural state should start an apply")
            return
        }
        #expect(started == first)
        #expect(resetScroll == false)

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

        guard case let .apply(next, nextResetScroll) = gate.complete(applied: first) else {
            Issue.record("Completing the first apply should start the newest pending state")
            return
        }
        #expect(next == newest)
        #expect(nextResetScroll == false)
    }

    @Test func identicalIDsRefreshDetailsWithoutStructuralApply() throws {
        let gate = MediaAssetCollectionApplyGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        guard case .apply = gate.receive(first) else {
            Issue.record("Expected initial structural apply")
            return
        }
        #expect(isNone(gate.complete(applied: first)))

        var changed = first
        let id = try #require(changed.orderedAssetIDs.first)
        let original = try #require(changed.assetsByID[id])
        changed.assetsByID[id] = MediaAsset(
            libraryRootPath: original.libraryRootPath,
            libraryDisplayName: original.libraryDisplayName,
            relativePath: original.relativePath,
            name: "changed.jpg",
            contentTypeIdentifier: original.contentTypeIdentifier,
            byteSize: 2,
            createdAt: original.createdAt,
            contentModifiedAt: original.contentModifiedAt
        )

        guard case let .refreshVisible(refreshed, resetScroll) = gate.receive(changed) else {
            Issue.record("Unchanged identities should refresh visible item details")
            return
        }
        #expect(refreshed == changed)
        #expect(resetScroll == false)
    }

    @Test func scopeChangeResetsScrollAndSameScopeStructurePreservesIt() {
        let gate = MediaAssetCollectionApplyGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        guard case .apply = gate.receive(allMedia) else {
            Issue.record("Expected initial structural apply")
            return
        }
        _ = gate.complete(applied: allMedia)

        let sameScope = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        guard case let .apply(_, sameScopeReset) = gate.receive(sameScope) else {
            Issue.record("Expected same-scope structural apply")
            return
        }
        #expect(sameScopeReset == false)
        _ = gate.complete(applied: sameScope)

        let libraryPath = LibraryRootPath(rawValue: "/Pictures")
        let differentScope = makeGrid(scope: .library(libraryPath), paths: ["a.jpg"])
        guard case let .apply(_, differentScopeReset) = gate.receive(differentScope) else {
            Issue.record("Expected scope-changing structural apply")
            return
        }
        #expect(differentScopeReset)
    }

    @Test func onlyMovieContentTypesReceiveVideoPresentation() {
        #expect(MediaAssetTilePresentation.isVideo(makeAsset(path: "movie.mp4", type: UTType.mpeg4Movie.identifier)))
        #expect(!MediaAssetTilePresentation.isVideo(makeAsset(path: "image.jpg", type: UTType.jpeg.identifier)))
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
}

@MainActor
private func makeGrid(scope: SidebarSelection, paths: [String]) -> CatalogMediaGridState {
    let assets = paths.map { makeAsset(path: $0, type: UTType.jpeg.identifier) }
    return CatalogMediaGridState(
        scope: scope,
        orderedAssetIDs: assets.map(\.id),
        assetsByID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    )
}

@MainActor
private func makeAsset(path: String, type: String?, name: String? = "asset") -> MediaAsset {
    MediaAsset(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        libraryDisplayName: "Pictures",
        relativePath: MediaRelativePath(rawValue: path),
        name: name,
        contentTypeIdentifier: type,
        byteSize: 1,
        createdAt: nil,
        contentModifiedAt: nil
    )
}

@MainActor
private func isNone(_ action: MediaAssetCollectionApplyGate.Action) -> Bool {
    if case .none = action {
        return true
    }
    return false
}
