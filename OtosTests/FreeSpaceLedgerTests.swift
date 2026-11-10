@testable import OtosKit
import Testing

/// ADR 0027: the free space a multi-write owner checks the floor against is the lesser of
/// the volume's figure now and the first figure less every byte committed since.
struct FreeSpaceLedgerTests {
    private let floor = FreeSpaceFloor.bytes

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

    /// A figure that lags or never moves leaves the projection in charge.
    @Test func aFigureThatNeverMovesStillCountsEveryCommittedWrite() {
        var ledger = FreeSpaceLedger()
        let admitted4 = ledger.admit(1000, reported: floor + 2500)
        #expect(admitted4)
        let admitted5 = ledger.admit(1000, reported: floor + 2500)
        #expect(admitted5)
        let admitted6 = ledger.admit(1000, reported: floor + 2500)
        #expect(!admitted6)
        #expect(ledger.committedBytes == 2000)
    }

    /// A landed write stays committed: its bytes are on the disk. A write that left
    /// nothing behind returns its bytes.
    @Test func aReleasedWriteReturnsItsBytesAndALandedOneDoesNot() {
        var ledger = FreeSpaceLedger()
        let admitted7 = ledger.admit(1000, reported: floor + 2000)
        #expect(admitted7)
        let admitted8 = ledger.admit(1000, reported: floor + 2000)
        #expect(admitted8)
        let admitted9 = ledger.admit(1000, reported: floor + 2000)
        #expect(!admitted9)
        ledger.release(1000)
        let admitted10 = ledger.admit(1000, reported: floor + 2000)
        #expect(admitted10)
        #expect(ledger.committedBytes == 2000)
    }

    /// Someone else's write lowers the figure below the projection: the figure is believed.
    @Test func aFigureLowerThanTheProjectionIsBelieved() {
        var ledger = FreeSpaceLedger()
        let admitted11 = ledger.admit(1000, reported: floor + 5000)
        #expect(admitted11)
        let admitted12 = ledger.admit(1000, reported: floor + 500)
        #expect(!admitted12)
        #expect(ledger.available(reported: floor + 500) == floor + 500)
    }

    /// A write committed without the check (the photo on screen) before the ledger's
    /// first reading is assumed not to be in that reading yet.
    @Test func bytesCommittedBeforeTheFirstReadingAreAssumedUnseen() {
        var ledger = FreeSpaceLedger()
        ledger.commit(1000)
        let admitted13 = ledger.admit(1000, reported: floor + 1500)
        #expect(!admitted13)
        #expect(ledger.available(reported: floor + 1500) == floor + 500)
    }

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
