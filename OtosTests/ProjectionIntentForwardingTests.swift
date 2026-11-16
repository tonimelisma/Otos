import Dispatch
import Foundation
@testable import OtosKit
import Testing

/// The window's Projection intents reach Projection off the main actor (DES-119): a Move to
/// Trash's hide is applied while the main thread is still busy, not after its next turn. A
/// consumer bound to the main actor resumed only between main-thread turns, so on the owner's
/// Mac a hide queued one turn (about 70 ms in a Debug build) behind every intent before it.
@Suite(.testScope)
struct ProjectionIntentForwardingTests {
    @MainActor
    @Test func aHideReachesProjectionWhileTheMainThreadIsBusy() async throws {
        try await withCatalogedLibrary(fileCount: 3, fileNamePrefix: "forward") { fixture in
            let projection = CatalogProjection(cadence: .milliseconds(10))
            let recorder = AsyncValueRecorder<CatalogWindowState>()
            let stream = await projection.states(
                store: fixture.store,
                initialDescriptor: CatalogQueryDescriptor(scope: .library(fixture.rootPath))
            )
            // Off the main actor, so the main thread held below cannot hold the recording.
            let recording = Task.detached {
                for await state in stream {
                    await recorder.append(state)
                }
            }
            defer { recording.cancel() }
            let shown = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == 3 }
            let order = try #require(shown.last).mediaGrid.orderedAssetIDs
            try await waitForProjectionQuiescence(projection)

            let (intents, continuation) = AsyncStream<CatalogProjectionIntent>.makeStream(bufferingPolicy: .unbounded)
            let forwarding = Task {
                await CatalogWindowViewModel.forwardProjectionIntents(intents, to: projection, searchIndex: nil)
            }
            defer {
                continuation.finish()
                forwarding.cancel()
            }
            let hidden = [order[1], order[2]]
            // One hide and its withdrawal through the forwarder first, waited on without
            // holding anything: the forwarder is then running and parked on the stream, as the
            // window's is after launch.
            let first = MediaTrashBatchID(unixMilliseconds: 1)
            continuation.yield(.hide([order[0]], batch: first))
            _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == hidden }
            continuation.yield(.hideWithdrawn(first, storeChanged: false))
            _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == order }

            let applied = DispatchSemaphore(value: 0)
            let watcher = Task.detached {
                _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == hidden }
                applied.signal()
            }
            defer { watcher.cancel() }

            // The hide is yielded and the main thread is then held, in one main-actor step,
            // until Projection has published the window without the item. A consumer on the
            // main actor could not run meanwhile, and this wait would never end.
            continuation.yield(.hide([order[0]], batch: MediaTrashBatchID(unixMilliseconds: 2)))
            holdTheMainThread(until: applied)
            #expect(await recorder.snapshot().last?.mediaGrid.orderedAssetIDs == hidden)
        }
    }
}

/// Blocks the calling thread until `signal` is signalled: a synchronous wait, so the main
/// thread stays held for its whole length.
private func holdTheMainThread(until signal: DispatchSemaphore) {
    signal.wait()
}
