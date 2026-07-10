@testable import Otos
import Testing

struct CatalogQueryModelsTests {
    @Test func sortOrdersExposeSixCompleteUserFacingChoices() {
        #expect(MediaSortOrder.allCases.map(\.label) == [
            "Date — Newest First",
            "Date — Oldest First",
            "Filename — A to Z",
            "Filename — Z to A",
            "Size — Largest First",
            "Size — Smallest First",
        ])
        #expect(MediaSortOrder.defaultOrder == .dateNewest)
    }
}
