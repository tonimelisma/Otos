import Darwin
import Foundation
@testable import Otos
import Testing

struct RemovableEjectOutcomeTests {
    @Test func busyErrorMapsFromPOSIXUnderlyingEBUSY() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY), userInfo: nil)
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .busy(displayName: "CARD"))
    }

    @Test func busyErrorMapsFromDiskArbitrationDissenter() {
        let error = NSError(
            domain: "com.apple.DiskArbitration.DADissenterError",
            code: 1,
            userInfo: nil
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .busy(displayName: "CARD"))
    }

    @Test func busyErrorMapsFromLocalizedDescriptionFallback() {
        let error = NSError(
            domain: "Test",
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "The disk couldn't be ejected because it is in use."]
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .busy(displayName: "CARD"))
    }

    @Test func userCancelledMapsToCancelledNotBusy() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: nil
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .cancelled)
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
