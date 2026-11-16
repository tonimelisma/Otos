@testable import OtosKit
import Testing

/// A store released without `shutdown()` leaves nothing waiting on it (`CatalogStore.deinit`).
@Suite(.testScope)
struct CatalogStoreReleaseTests {
    /// A subscriber to a store that is released, never shut down, sees its stream end rather
    /// than waiting forever for a change no one will send. Proven by the stream's end, which
    /// only the store's release can bring: the test holds no other reference to the store.
    @Test func releasingAStoreEndsItsSubscribersStreams() async {
        let changes: AsyncStream<CatalogStoreChange>
        let planning: AsyncStream<RootPlanningChange>
        do {
            let store = makeTestStore(location: .inMemory)
            changes = await store.changeNotifications()
            planning = await store.planningChangeNotifications()
        }
        for await _ in changes {}
        for await _ in planning {}
    }
}
