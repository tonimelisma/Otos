@testable import OtosKit

extension PeopleAssignment {
    /// Runs passes as the loop would, until one writes nothing, and returns the state it
    /// publishes. Assignment run on its own output changes nothing, so this is two passes.
    static func settle(store: CatalogStore, libraries: [CatalogLibraryState]) async throws -> CatalogPeopleState {
        while true {
            if case let .publish(state, _, _) = try await run(store: store, libraries: libraries) {
                return state
            }
        }
    }
}
