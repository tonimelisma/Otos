import Foundation
@testable import OtosKit
import Testing

/// The window applies the newest publication there is when its consumer runs (ADR 0032,
/// rule 5). A publication a newer one replaced while the main actor was busy is never
/// applied: on the owner's Mac each such apply was one more main-thread turn, about 60 ms,
/// before an act's own state reached the grid
/// (`docs/research/2026-11-16-grid-applies-during-motion.md`).
@Suite(.testScope)
@MainActor
struct WindowStateDeliveryTests {
    /// Background republishes and an act's publication all arrive while the consumer is
    /// parked on its doorbell and before the main actor runs it: one apply runs, it applies
    /// the act's state, and what the window shows besides the hidden tile is what it showed.
    /// Applying every publication in order would be one main-thread update each, ahead of
    /// the act's own.
    @Test func publicationsReplacedBeforeTheWindowRunsAreNeverApplied() async throws {
        let model = makeViewModel()
        let mailbox = NewestValueMailbox<CatalogWindowState>()
        model.startApplyingStates(from: mailbox)
        let ids = makeIDs(4)
        let shown = windowState(ids: ids).sharingUnchanged(with: nil)
        mailbox.put(shown)
        try await waitUntil { model.state.mediaGrid.orderedAssetIDs == ids }
        model.selectAssets([ids[2]])
        let appliedBefore = model.appliedStateCount

        // The consumer applied `shown` and parked on the doorbell in that same main-actor
        // job. Every publication lands in this one job, so the main actor runs the consumer
        // only after the last: each earlier one is what an `AsyncStream` would have handed it.
        var published = shown
        for refresh in UInt64(2) ... 5 {
            published = windowState(ids: ids, detailRefresh: refresh).sharingUnchanged(with: published)
            mailbox.put(published)
        }
        let hidden = [ids[0], ids[2], ids[3]]
        mailbox.put(windowState(ids: hidden, detailRefresh: 5).sharingUnchanged(with: published))

        try await waitUntil { model.appliedStateCount > appliedBefore }
        #expect(model.appliedStateCount == appliedBefore + 1)
        #expect(model.state.mediaGrid.orderedAssetIDs == hidden)
        #expect(model.state.mediaGrid.detailRefreshGeneration == 5)
        // The selection and the focus on a tile the act left in place stay where they were.
        #expect(model.gridSelection.selection == [ids[2]])
        #expect(model.focusedAssetID == ids[2])
    }

    /// The relay puts each publication in the mailbox as it arrives, off the main actor: with
    /// the main thread held, a consumer off the main actor still takes the act's state. A
    /// relay bound to the main actor could not run meanwhile, and this test would never end.
    @Test func theRelayFillsTheMailboxWhileTheMainThreadIsHeld() async {
        let mailbox = NewestValueMailbox<CatalogWindowState>()
        let (states, continuation) = AsyncStream<CatalogWindowState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let relay = Task {
            await CatalogWindowViewModel.relayStates(states, into: mailbox)
        }
        defer {
            continuation.finish()
            relay.cancel()
        }
        let ids = makeIDs(3)
        let shown = windowState(ids: ids).sharingUnchanged(with: nil)
        let act = windowState(ids: [ids[1], ids[2]]).sharingUnchanged(with: shown)
        let (taken, takenContinuation) = AsyncStream<[MediaAssetID]>.makeStream(bufferingPolicy: .unbounded)
        let received = DispatchSemaphore(value: 0)
        let taker = Task.detached {
            for await delivery in mailbox {
                takenContinuation.yield(delivery.value.mediaGrid.orderedAssetIDs)
                if delivery.value.mediaGrid.orderedAssetIDs == act.mediaGrid.orderedAssetIDs {
                    received.signal()
                }
            }
        }
        defer { taker.cancel() }
        // The relay is running and parked on the stream, as the window's is after launch.
        continuation.yield(shown)
        var takenIterator = taken.makeAsyncIterator()
        #expect(await takenIterator.next() == ids)

        continuation.yield(act)
        holdTheMainThread(until: received)
        #expect(await takenIterator.next() == act.mediaGrid.orderedAssetIDs)
    }

    /// The mailbox hands one consumer the newest value and how many it replaced; a ring
    /// whose value was already taken waits again, and a finished mailbox delivers what it
    /// still holds, then ends.
    @Test func theMailboxDeliversTheNewestValueThenEnds() async {
        let mailbox = NewestValueMailbox<Int>()
        var iterator = mailbox.makeAsyncIterator()
        mailbox.put(1)
        mailbox.put(2)
        mailbox.put(3)
        let first = await iterator.next()
        #expect(first?.value == 3)
        #expect(first?.superseded == 2)
        mailbox.put(4)
        mailbox.finish()
        let second = await iterator.next()
        #expect(second?.value == 4)
        #expect(second?.superseded == 0)
        #expect(await iterator.next()?.value == nil)
    }
}

/// Blocks the calling thread until `signal` is signalled: a synchronous wait, so the main
/// thread stays held for its whole length.
private func holdTheMainThread(until signal: DispatchSemaphore) {
    signal.wait()
}

private let pictures = LibraryRootPath(rawValue: "/Users/example/Pictures")

private func makeIDs(_ count: Int) -> [MediaAssetID] {
    (0 ..< count).map { MediaAssetID(libraryRootPath: pictures, relativePath: MediaRelativePath(rawValue: "asset-\($0).jpg")) }
}

@MainActor
private func makeViewModel() -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: makeTestStore(location: .inMemory),
        enrichmentCoordinator: nil,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
}

private func windowState(ids: [MediaAssetID], detailRefresh: UInt64 = 1) -> CatalogWindowState {
    CatalogWindowState(
        title: "Test",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(
            descriptor: CatalogQueryDescriptor(scope: .allMedia),
            orderedAssetIDs: ids,
            detailRefreshGeneration: detailRefresh
        ),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: ids.isEmpty ? .noMedia : nil,
        deviceConnectionBanner: nil,
        queryGeneration: 0
    )
}
