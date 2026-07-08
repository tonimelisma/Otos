import Foundation
@testable import Otos
import Testing

struct RemovableEjectOutcomeTests {
    @Test func busyErrorMapsFromLocalizedDescription() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "The disk couldn't be ejected because it is in use."]
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .busy(displayName: "CARD"))
    }

    @Test func failedErrorMapsGenericDescription() {
        let error = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unmount failed for an unknown reason."]
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .failed(description: "Unmount failed for an unknown reason."))
    }
}
