import Foundation
@testable import OtosKit
import Testing

/// The search index's start (ADR 0032 rule 1): its state is set in the synchronous step after
/// its awaits, so a start that arrives while another is between them starts nothing twice.
@Suite(.testScope)
struct PhotoSearchIndexStartTests {
    /// A second `start()` that arrives while the first is parked between its awaits starts
    /// nothing of its own (ADR 0032 rule 1): the index keeps one subscription and one loop, so
    /// each Store change reaches it once, and its shutdown ends everything it started.
    @Test func aSecondStartWhileTheFirstAwaitsStartsNothing() async throws {
        let store = makeTestStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        let gate = ArrivalGate()
        let index = try PhotoSearchIndex(
            store: store, thumbnailDirectory: nil, vectorDirectory: makeTestDirectory().appending(path: "SearchIndex"),
            bundle: Bundle(for: CatalogWindowViewModel.self), textReader: .readingNoText(),
            startDidSubscribe: { await gate.arrive() }
        )
        let first = Task { await index.start() }
        await gate.waitForArrivals(1)
        // The first start is parked at its subscription; the second enters now.
        let second = Task { await index.start() }
        await gate.waitForArrivals(2)
        await gate.open()
        await first.value
        await second.value
        _ = try await index.untilQuiescent()

        let counted = CatalogStore.DeliveryCount()
        let probe = await store.changeNotifications(deliveries: counted)
        let before = await index.deliveredChanges
        await store.setDuplicatesReach(.acrossLibraries)
        _ = try await index.untilQuiescent()
        let reached = await index.deliveredChanges - before
        #expect(counted.delivered >= 1)
        #expect(reached == counted.delivered, "each Store change reaches the index once")
        _ = probe
        await index.shutdown()
        await store.shutdown()
    }
}
