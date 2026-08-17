@testable import OtosKit
import Testing

struct GridColumnCountTests {
    // MARK: - clamped

    @Test func clampedKeepsInRangeValuesUnchanged() {
        #expect(GridColumnCount.clamped(3) == 3)
        #expect(GridColumnCount.clamped(6) == 6)
        #expect(GridColumnCount.clamped(9) == 9)
    }

    @Test func clampedPullsBelowMinimumUpToMinimum() {
        #expect(GridColumnCount.clamped(2) == 3)
        #expect(GridColumnCount.clamped(-5) == 3)
    }

    @Test func clampedPullsAboveMaximumDownToMaximum() {
        #expect(GridColumnCount.clamped(10) == 9)
        #expect(GridColumnCount.clamped(1000) == 9)
    }

    // MARK: - validated

    @Test func validatedKeepsInRangeStoredValues() {
        #expect(GridColumnCount.validated(3) == 3)
        #expect(GridColumnCount.validated(9) == 9)
        #expect(GridColumnCount.validated(4) == 4)
    }

    @Test func validatedFallsBackToDefaultForUnsetOrGarbageValues() {
        #expect(GridColumnCount.validated(0) == 6) // UserDefaults.integer default for an unset key
        #expect(GridColumnCount.validated(2) == 6)
        #expect(GridColumnCount.validated(10) == 6)
        #expect(GridColumnCount.validated(-1) == 6)
    }
}
