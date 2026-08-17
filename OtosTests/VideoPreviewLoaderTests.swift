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
            thumbnailPath: nil,
            bestKind: kind,
            durationSeconds: 12,
            enrichedSourceSize: 1024,
            enrichedSourceMTimeSeconds: nil
        )
    }

    @Test func playGatesOnVideoKind() async {
        let loader = VideoPreviewLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester { _ in .cancelled }
        )
        let imageDetail = detail(kind: .image)
        let result = await loader.play(id: id("v.mp4"), detail: imageDetail)
        #expect(result == nil)
    }

    @Test func playCreatesPlayerWhenMaterialized() async {
        let loader = VideoPreviewLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester { _ in .cancelled }
        )
        let videoDetail = detail(kind: .video)
        let state = await loader.play(id: id("a.mp4"), detail: videoDetail)
        #expect(state != nil)
        #expect(state?.id.relativePath.rawValue == "a.mp4")
    }

    @Test func playMaterializesWhenDataless() async {
        let counter = TestCounter()
        let requester = ClosureMaterializationRequester { _ in
            counter.increment()
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 10)
        }
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
        let loader = VideoPreviewLoader(
            status: { _ in seq.next() },
            materializationRequester: requester
        )
        let videoDetail = detail(kind: .video)
        let state = await loader.play(id: id("b.mp4"), detail: videoDetail)
        #expect(state != nil)
        #expect(counter.value == 1)
    }

    @Test func playReturnsNilOnProviderUnavailable() async {
        let requester = ClosureMaterializationRequester { _ in
            MaterializationResult(outcome: .providerUnavailable, rerequestCount: 2, elapsedMs: 2000)
        }
        let loader = VideoPreviewLoader(
            status: { _ in .dataless },
            materializationRequester: requester
        )
        let videoDetail = detail(kind: .video)
        let state = await loader.play(id: id("c.mp4"), detail: videoDetail)
        #expect(state == nil)
    }

    @Test func loupeVideoStateCleanupReplacesPlayer() async {
        let loader = VideoPreviewLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester { _ in .cancelled }
        )
        let videoDetail = detail(kind: .video)
        let first = await loader.play(id: id("a.mp4"), detail: videoDetail)
        #expect(first != nil)
        if let first {
            loader.cleanup(first)
        }
        // Second play after cleanup should succeed with new id
        let second = await loader.play(id: id("b.mp4"), detail: videoDetail)
        #expect(second?.id.relativePath.rawValue == "b.mp4")
    }
}
