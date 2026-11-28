import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0027: the free space a multi-write owner checks the floor against is the lesser of
/// the volume's figure now and the first figure less every byte committed since.
struct FreeSpaceLedgerTests {
    private let floor = FreeSpaceFloor.bytes

    // Validates: APP-029
    /// `copyfile` reserves a file's size when it starts, so a fresh figure already shows a
    /// started write. It is not charged a second time.
    @Test func aFreshFigureIsNotChargedTwiceForAStartedWrite() {
        var ledger = FreeSpaceLedger()
        let admitted1 = ledger.admit(1000, reported: floor + 2500)
        #expect(admitted1)
        let admitted2 = ledger.admit(1000, reported: floor + 1500)
        #expect(admitted2, "the first write is in the figure, not counted again")
        let admitted3 = ledger.admit(1000, reported: floor + 500)
        #expect(!admitted3)
    }

    // Validates: APP-029
    /// A figure that lags or never moves leaves the projection in charge.
    @Test func aFigureThatNeverMovesStillCountsEveryCommittedWrite() {
        var ledger = FreeSpaceLedger()
        let admitted4 = ledger.admit(1000, reported: floor + 2500)
        #expect(admitted4)
        let admitted5 = ledger.admit(1000, reported: floor + 2500)
        #expect(admitted5)
        let admitted6 = ledger.admit(1000, reported: floor + 2500)
        #expect(!admitted6)
        #expect(ledger.inFlightBytes == 2000)
    }

    // Validates: APP-029
    /// A landed write stays counted: its bytes are on the disk. A write that left nothing
    /// behind gives its bytes back.
    @Test func aWriteThatLandedNothingGivesItsBytesBackAndALandedOneDoesNot() {
        var ledger = FreeSpaceLedger()
        let admitted7 = ledger.admit(1000, reported: floor + 2000)
        #expect(admitted7)
        let admitted8 = ledger.admit(1000, reported: floor + 2000)
        #expect(admitted8)
        let admitted9 = ledger.admit(1000, reported: floor + 2000)
        #expect(!admitted9)
        ledger.settle(committed: 1000, landed: 0)
        let admitted10 = ledger.admit(1000, reported: floor + 2000)
        #expect(admitted10)
        #expect(ledger.inFlightBytes == 2000)
        ledger.settle(committed: 1000, landed: 1000)
        let admitted11 = ledger.admit(1000, reported: floor + 2000)
        #expect(!admitted11, "the landed write is still on the disk the figure has not caught up with")
        #expect(ledger.inFlightBytes == 1000)
    }

    /// A download that found its file already local wrote nothing: its outcome lands no
    /// bytes, so its commitment is given back in full (ADR 0027).
    @Test func aFileAlreadyLocalLandsNothing() {
        #expect(MaterializationOutcome.alreadyMaterialized.landedBytes(of: 1000) == 0)
        #expect(MaterializationOutcome.materialized.landedBytes(of: 1000) == 1000)
        #expect(MaterializationOutcome.timedOut.landedBytes(of: 1000) == 0)
        var ledger = FreeSpaceLedger()
        let admitted = ledger.admit(1000, reported: floor + 1500)
        #expect(admitted)
        ledger.settle(committed: 1000, landed: MaterializationOutcome.alreadyMaterialized.landedBytes(of: 1000))
        let next = ledger.admit(1000, reported: floor + 1500)
        #expect(next, "nothing was written, so the room is still there")
    }

    // Validates: ENR-008
    /// Space freed while writes are in flight: a figure that rises above the last one is
    /// live, and the projection is re-based on it less what is still in flight.
    @Test func freedSpaceIsAdmittedBeforeTheStretchEnds() {
        var ledger = FreeSpaceLedger()
        let first = ledger.admit(1000, reported: floor + 1500)
        #expect(first)
        let held = ledger.admit(1000, reported: floor + 500)
        #expect(!held)
        // The user empties the Trash: the figure rises 10 000 with the first write in flight.
        let freed = ledger.admit(1000, reported: floor + 10500)
        #expect(freed)
        #expect(ledger.available(reported: floor + 10500) == floor + 10500 - 2000)
    }

    // Validates: ENR-008
    /// A figure that holds still is not live, however many writes land: no re-base.
    @Test func aFigureThatHoldsStillNeverRebases() {
        var ledger = FreeSpaceLedger()
        let first = ledger.admit(1000, reported: floor + 1500)
        #expect(first)
        ledger.settle(committed: 1000, landed: 1000)
        let second = ledger.admit(1000, reported: floor + 1500)
        #expect(!second)
    }

    // Validates: APP-029
    /// Someone else's write lowers the figure below the projection: the figure is believed.
    @Test func aFigureLowerThanTheProjectionIsBelieved() {
        var ledger = FreeSpaceLedger()
        let admitted11 = ledger.admit(1000, reported: floor + 5000)
        #expect(admitted11)
        let admitted12 = ledger.admit(1000, reported: floor + 500)
        #expect(!admitted12)
        #expect(ledger.available(reported: floor + 500) == floor + 500)
    }

    // Validates: APP-029
    /// A write committed without the check (the photo on screen) before the ledger's
    /// first reading is assumed not to be in that reading yet.
    @Test func bytesCommittedBeforeTheFirstReadingAreAssumedUnseen() {
        var ledger = FreeSpaceLedger()
        ledger.commit(1000)
        let admitted13 = ledger.admit(1000, reported: floor + 1500)
        #expect(!admitted13)
        #expect(ledger.available(reported: floor + 1500) == floor + 500)
    }

    // Validates: APP-029
    /// No figure is not evidence of no room: the ledger admits, then holds to what it has
    /// projected from the last figure it did read.
    @Test func anUnknownFigureAdmitsUntilAProjectionExists() {
        var ledger = FreeSpaceLedger()
        let admitted14 = ledger.admit(100, reported: nil)
        #expect(admitted14)
        let admitted15 = ledger.admit(1000, reported: floor + 1500)
        #expect(admitted15, "projected from floor + 1500 less the 100 already committed")
        let admitted16 = ledger.admit(1000, reported: nil)
        #expect(!admitted16, "the projection, floor + 400, is still known")
    }
}

/// The volume figure the floor reads (`VolumeCapacityHold`): one CacheDelete calculation per
/// volume per refresh, lowered at once by every byte the volume's own free count loses, and
/// never raised before the next calculation.
struct VolumeCapacityHoldTests {
    private final class Volume: Sendable {
        private let state = Mutex((important: Int64(100_000), free: Int64(60000), calculations: 0, now: ContinuousClock.now))

        var calculations: Int {
            state.withLock { $0.calculations }
        }

        func set(important: Int64? = nil, free: Int64? = nil, advancedBy: Duration = .zero) {
            state.withLock { state in
                state.important = important ?? state.important
                state.free = free ?? state.free
                state.now = state.now.advanced(by: advancedBy)
            }
        }

        func hold() -> VolumeCapacityHold {
            VolumeCapacityHold(
                readImportant: { _ in self.state.withLock { $0.calculations += 1
                    return $0.important
                } },
                readFree: { _ in VolumeCapacityHold.Free(volume: [1, 2], bytes: self.state.withLock(\.free)) },
                now: { self.state.withLock(\.now) },
                refresh: .seconds(60)
            )
        }
    }

    // Validates: ENR-008
    @Test func aWriteShowsAtOnceAndFreedSpaceAtTheNextCalculation() {
        let volume = Volume()
        let hold = volume.hold()
        let url = URL(fileURLWithPath: "/volume/file")
        #expect(hold.available(onVolumeOf: url) == 100_000)
        // A write lands: the free count drops, and the figure with it, with no calculation.
        volume.set(free: 55000, advancedBy: .seconds(10))
        #expect(hold.available(onVolumeOf: url) == 95000)
        // Space is freed: the held figure does not rise before the next calculation.
        volume.set(important: 120_000, free: 75000, advancedBy: .seconds(10))
        #expect(hold.available(onVolumeOf: url) == 100_000)
        #expect(volume.calculations == 1)
        volume.set(advancedBy: .seconds(41))
        #expect(hold.available(onVolumeOf: url) == 120_000)
        #expect(volume.calculations == 2)
    }

    /// A volume `statfs` cannot read is calculated every time, as before.
    @Test func aVolumeWithoutAFreeCountIsCalculatedEachTime() {
        let calculations = Mutex(0)
        let hold = VolumeCapacityHold(
            readImportant: { _ in calculations.withLock { $0 += 1
                return 7
            } }, readFree: { _ in nil }
        )
        let url = URL(fileURLWithPath: "/volume/file")
        #expect(hold.available(onVolumeOf: url) == 7)
        #expect(hold.available(onVolumeOf: url) == 7)
        #expect(calculations.withLock { $0 } == 2)
    }
}
