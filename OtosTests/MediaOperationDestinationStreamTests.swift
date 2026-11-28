import Foundation
@testable import OtosKit
import Testing

/// The remembered destination per source reaches Settings through one ordered stream:
/// it opens with the current map, and each pick the coordinator applies is published in
/// the order it was applied, so a later pick is never followed by an earlier map.
@Suite(.testScope)
struct MediaOperationDestinationStreamTests {
    // Validates: ARC-047
    @Test func destinationPicksArePublishedInTheOrderTheyWereApplied() async throws {
        let temp = try makeTestDirectory()
        let source = LibraryRootPath(rawValue: temp.appending(path: "Card").path(percentEncoded: false))
        let first = LibraryRootPath(rawValue: temp.appending(path: "First").path(percentEncoded: false))
        let second = LibraryRootPath(rawValue: temp.appending(path: "Second").path(percentEncoded: false))
        let coordinator = MediaOperationCoordinator(
            store: makeTestStore(location: .inMemory),
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity
        )

        var maps = await coordinator.destinationsStream().makeAsyncIterator()
        #expect(await maps.next() == [:], "the stream opens with the current map")

        await coordinator.setDestination(first, for: source)
        #expect(await maps.next() == [source: first])
        await coordinator.setDestination(second, for: source)
        #expect(await maps.next() == [source: second])
    }
}
