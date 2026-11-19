import AVFoundation
import Foundation
@testable import OtosKit
import Synchronization
import Testing

@MainActor
struct VideoPreviewLoaderTests {
    private func id(_ name: String) -> MediaAssetID {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
            relativePath: MediaRelativePath(rawValue: name)
        )
    }

    private func detail(kind: MediaKind) -> MediaTileDetail {
        MediaTileDetail(
            libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
            relativePath: MediaRelativePath(rawValue: "v.mp4"),
            byteSize: 1024,
            thumbnailPath: nil,
            bestKind: kind,
            durationSeconds: 12
        )
    }

    @Test func playGatesOnVideoKind() async {
        let loader = VideoPreviewLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in .cancelled }
        )
        let imageDetail = detail(kind: .image)
        let result = await loader.preparePlayer(id: id("v.mp4"), detail: imageDetail)
        #expect(result == .notVideo)
    }

    @Test func playMaterializesWhenDataless() async throws {
        final class CheckSeq: Sendable {
            private let storage = Mutex(0)
            func next() -> FileMaterializationStatus {
                let count = storage.withLock { $0 += 1
                    return $0
                }
                return count == 1 ? .dataless : .materialized
            }
        }
        let seq = CheckSeq()
        let counter = TestCounter()
        let requester = ClosureMaterializationRequester(status: { _ in seq.next() }) { _ in
            counter.increment()
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 10)
        }
        let loader = VideoPreviewLoader(
            status: { _ in seq.next() },
            materializationRequester: requester
        )
        let videoDetail = detail(kind: .video)
        let state = try #require(await loader.preparePlayer(id: id("b.mp4"), detail: videoDetail).readyState)
        expectFreshPlayer(state, for: id("b.mp4"))
        #expect(counter.value == 1)
    }

    @Test func providerUnavailableAnswersWhyThereIsNoPlayer() async {
        let requester = ClosureMaterializationRequester(status: { _ in .dataless }) { _ in
            MaterializationResult(outcome: .providerUnavailable, rerequestCount: 2, elapsedMs: 2000)
        }
        let loader = VideoPreviewLoader(
            status: { _ in .dataless },
            materializationRequester: requester
        )
        let videoDetail = detail(kind: .video)
        let result = await loader.preparePlayer(id: id("c.mp4"), detail: videoDetail)
        #expect(result == .unavailable(.downloadFailed))
    }

    /// Each answer the request for the original's bytes can give names its own reason, so
    /// the pane says what is wrong rather than only that something is.
    @Test(arguments: [
        (MaterializationOutcome.serverUnreachable, LoupeVideoUnavailable.serverUnreachable),
        (.deviceUnavailable, .deviceUnavailable),
        (.insufficientLocalSpace, .insufficientSpace),
        (.refusedReadOnly, .downloadsOff),
        (.timedOut, .downloadFailed),
    ])
    func unavailableNamesTheSourcesState(outcome: MaterializationOutcome, reason: LoupeVideoUnavailable) async {
        let requester = ClosureMaterializationRequester(status: { _ in .dataless }) { _ in
            MaterializationResult(outcome: outcome, rerequestCount: 0, elapsedMs: 0)
        }
        let loader = VideoPreviewLoader(status: { _ in .dataless }, materializationRequester: requester)
        let result = await loader.preparePlayer(id: id("d.mp4"), detail: detail(kind: .video))
        #expect(result == .unavailable(reason))
    }

    @Test func loupeVideoStateCleanupReplacesPlayer() async throws {
        let loader = VideoPreviewLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in .cancelled }
        )
        let videoDetail = detail(kind: .video)
        let first = try #require(await loader.preparePlayer(id: id("a.mp4"), detail: videoDetail).readyState)
        loader.cleanup(first)
        #expect(first.player.currentItem == nil)
        #expect(first.player.rate == 0)
        // A play after cleanup gets its own player for the new asset.
        let second = try #require(await loader.preparePlayer(id: id("b.mp4"), detail: videoDetail).readyState)
        expectFreshPlayer(second, for: id("b.mp4"))
        #expect(second.player !== first.player)
    }

    /// A newly prepared player: paused, for exactly this asset's file. The fixture paths
    /// name no real file, so no video track is readable and the display size is unknown.
    private func expectFreshPlayer(_ state: LoupeVideoState, for id: MediaAssetID) {
        #expect(state.id == id)
        #expect(!state.isPlaying)
        #expect(state.displaySize == nil)
        #expect((state.player.currentItem?.asset as? AVURLAsset)?.url == id.fileURL)
    }
}

extension LoupeVideoPreparation {
    /// The player, when preparation made one.
    var readyState: LoupeVideoState? {
        if case let .ready(state) = self {
            state
        } else {
            nil
        }
    }
}
