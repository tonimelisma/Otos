import AVFoundation
import Foundation
@testable import OtosKit
import Testing

/// ADR 0036 video trim: a trim is a recipe the player plays and the trim UI reads back, and
/// saving one renders nothing.
@Suite(.testScope)
@MainActor
struct VideoTrimTests {
    private var fixture: URL {
        SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov")
    }

    @Test func thePlayerPlaysTheTrimAndReportsItBack() {
        let player = AVPlayer(playerItem: AVPlayerItem(url: fixture))
        var state = LoupeVideoState(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/x"), relativePath: MediaRelativePath(rawValue: "a.mov")
            ),
            player: player,
            isPlaying: false
        )

        state.applyTrim(EditRecipe(trimStart: 0.5, trimEnd: 1.25))
        #expect(state.currentTrim.start == 0.5)
        #expect(state.currentTrim.end == 1.25)

        state.applyTrim(.neutral)
        #expect(state.currentTrim.start == nil)
        #expect(state.currentTrim.end == nil)
    }

    /// A video's thumbnail does not carry its trim, so saving a trim marks its products
    /// current: no render, and no download at the next launch.
    @Test func savingAVideosTrimMarksItsProductsCurrent() async throws {
        let root = try makeTestDirectory().appending(path: "Clips", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root.appending(path: "clip.mov"))
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(5))
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try MediaAssetID(
            libraryRootPath: CatalogPath.normalizedExistingDirectoryPath(for: root),
            relativePath: MediaRelativePath(rawValue: "clip.mov")
        )

        let result = try await store.setEditRecipe(EditRecipe(trimStart: 0.5), for: id)

        #expect(result.isVideo)
        let detail = try await store.mediaTileDetails(for: [id])[id]
        #expect(detail?.renderedRevision == result.saved?.revision)
        await store.shutdown()
    }
}
