import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The Activity board (ADR 0058): what it publishes as watched owners begin, end and wait, read
/// from its snapshot stream, each published value awaited as the event it is.
struct ActivityBoardTests {
    /// An owner whose requests, passes and hold the test sets, settling as a real owner does.
    private actor ScriptedOwner: QuiescentOwner {
        let activity: OwnerActivity

        init(_ name: String) {
            activity = OwnerActivity(owner: name)
        }

        @discardableResult
        func begin() -> UInt64 {
            let request = activity.request()
            activity.beginPass()
            return request
        }

        func end(covering request: UInt64) {
            activity.endPass(covering: request)
            settleQuiescence()
        }

        func hold(_ hold: BackgroundHold?) {
            activity.heldBy = hold
        }

        func holdNow(_ read: @escaping @Sendable () -> BackgroundHold?) {
            activity.heldNow = read
        }

        func ringIdle() {}

        /// Rows held for a fact outside it, which only an owner at rest is asked for.
        private var held: [OwnerHeldRows] = []

        func holdRows(_ rows: [OwnerHeldRows]) {
            held = rows
        }

        func heldRows() async -> [OwnerHeldRows] {
            held
        }

        func backOff(_ wake: OwnerWake?) {
            activity.wake = wake
        }
    }

    /// The board's clock, which the test moves.
    private final class TestClock: Sendable {
        private let moment = Mutex(Date(timeIntervalSince1970: 1_000_000))

        var now: Date {
            moment.withLock { $0 }
        }

        func advance(_ seconds: TimeInterval) {
            moment.withLock { $0 = $0.addingTimeInterval(seconds) }
        }
    }

    /// Every snapshot the board publishes, recorded as it arrives.
    private final class Published: Sendable {
        let recorder = AsyncValueRecorder<ActivitySnapshot>()
        private let task: Task<Void, Never>

        init(_ board: ActivityBoard) {
            task = Task { [recorder] in
                for await snapshot in board.snapshots {
                    await recorder.append(snapshot)
                }
            }
        }

        /// Returns the newest snapshot once it satisfies `matches`.
        func newest(where matches: @escaping @Sendable (ActivitySnapshot) -> Bool) async -> ActivitySnapshot {
            await recorder.waitForValues { $0.last.map(matches) ?? false }.last!
        }

        deinit {
            task.cancel()
        }
    }

    @Test func aKindWorksFromItsFirstRequestAndIsUpToDateWhenItsOwnerSettles() async {
        let clock = TestClock()
        let board = ActivityBoard(now: { clock.now })
        let faces = ScriptedOwner("previewFaces")
        let places = ScriptedOwner("placeNames")
        let published = Published(board)
        await board.watch([.init(kind: .findingFaces, owner: faces), .init(kind: .namingPlaces, owner: places)], room: nil)

        let idle = await published.newest { $0.watching }
        #expect(idle.entries == [
            ActivityEntry(kind: .findingFaces, state: .upToDate), ActivityEntry(kind: .namingPlaces, state: .upToDate),
        ], "every watched kind is listed, with its status")

        let started = clock.now
        let request = await faces.begin()
        let working = await published.newest { $0.isWorking(.findingFaces) }
        #expect(working.entries == [
            ActivityEntry(kind: .findingFaces, state: .working(since: started)), ActivityEntry(kind: .namingPlaces, state: .upToDate),
        ])

        clock.advance(90)
        await faces.end(covering: request)
        let settled = await published.newest { !$0.isWorking(.findingFaces) }
        #expect(settled.entries.first == ActivityEntry(kind: .findingFaces, state: .upToDate))
        await board.shutdown()
    }

    @Test func aKindServedByTwoOwnersWorksWhileEitherDoesAndIsPausedOnlyWhenBothAre() async {
        let clock = TestClock()
        let board = ActivityBoard(now: { clock.now })
        let groups = ScriptedOwner("duplicates")
        let signatures = ScriptedOwner("renderSignatures")
        let published = Published(board)
        await board.watch(
            [.init(kind: .findingDuplicates, owner: groups), .init(kind: .findingDuplicates, owner: signatures)],
            room: nil
        )
        _ = await published.newest { $0.watching }

        let started = clock.now
        let groupsRequest = await groups.begin()
        let signaturesRequest = await signatures.begin()
        await groups.hold(.thermal)
        // One of two held: the kind still works.
        let oneHeld = await published.newest { $0.isWorking(.findingDuplicates) }
        #expect(oneHeld.entries.first?.state == .working(since: started))

        await signatures.hold(.thermal)
        let bothHeld = await published.newest { $0.entries.first?.state == .waiting(.paused(.thermal)) }
        #expect(!bothHeld.isWorking(.findingDuplicates))

        clock.advance(5)
        await signatures.hold(nil)
        await groups.hold(nil)
        await groups.end(covering: groupsRequest)
        // The other still works: the stretch keeps its start through the pause.
        let stillWorking = await published.newest { $0.entries.first?.state == .working(since: started) }
        #expect(stillWorking.isWorking(.findingDuplicates))

        await signatures.end(covering: signaturesRequest)
        let settled = await published.newest { !$0.isWorking(.findingDuplicates) }
        #expect(settled.entries == [ActivityEntry(kind: .findingDuplicates, state: .upToDate)])
        await board.shutdown()
    }

    @Test func theRoomChangingRingsTheBoardForAHoldReadAsOfTheRound() async {
        let board = ActivityBoard()
        let room = BackgroundRoom(conditions: MachineConditions(memory: .normal, thermal: .nominal, lowPower: false))
        let descriptions = ScriptedOwner("descriptions")
        let published = Published(board)
        await board.watch([.init(kind: .describingPhotos, owner: descriptions)], room: room)
        _ = await published.newest { $0.watching }
        await descriptions.begin()
        await descriptions.holdNow { room.hold(for: .description) }
        _ = await published.newest { $0.isWorking(.describingPhotos) }

        room.deliver(MachineConditions(memory: .normal, thermal: .nominal, lowPower: true))
        let held = await published.newest { $0.entries.first?.state == .waiting(.paused(.lowPower)) }
        #expect(!held.isWorking(.describingPhotos))
        await board.shutdown()
    }

    /// An owner at rest that holds rows for their originals, or waits to try again, waits;
    /// once it holds none and no wake is armed, it is up to date.
    @Test func anOwnerAtRestWaitsOnWhatItHoldsAndIsUpToDateWithoutIt() async {
        let board = ActivityBoard()
        let enrichment = ScriptedOwner("enrichment")
        let places = ScriptedOwner("placeNames")
        let published = Published(board)
        await board.watch(
            [.init(kind: .readingPhotos, owner: enrichment), .init(kind: .namingPlaces, owner: places)], room: nil
        )
        _ = await published.newest { $0.watching }

        await enrichment.holdRows([
            OwnerHeldRows(waitingFor: .digestAwaitsLocalBytes, count: 2999),
            OwnerHeldRows(waitingFor: .pacing, count: 0),
        ])
        await places.backOff(OwnerWake(kind: .backoff, at: ContinuousClock.now.advanced(by: .seconds(60))))
        board.ring()
        let waiting = await published.newest { $0.entries.last?.state == .waiting(.retrying) }
        #expect(waiting.entries == [
            ActivityEntry(kind: .readingPhotos, state: .waiting(.originals(count: 2999))),
            ActivityEntry(kind: .namingPlaces, state: .waiting(.retrying)),
        ])

        await enrichment.holdRows([OwnerHeldRows(waitingFor: .digestAwaitsLocalBytes, count: 0)])
        await places.backOff(nil)
        board.ring()
        let upToDate = await published.newest { $0.entries.allSatisfy { $0.state == .upToDate } }
        #expect(upToDate.entries.count == 2)
        await board.shutdown()
    }
}

struct ActivityPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_795_262_400)

    @Test func beforeTheOwnersAreWatchedNothingIsClaimed() {
        let presentation = ActivityPresentation.map(ActivitySnapshot())
        #expect(presentation.line == nil)
        #expect(presentation.lineDetail == nil)
        #expect(presentation.lineStatus == nil)
        #expect(presentation.rows.isEmpty)
    }

    @Test func nothingWorkingOrWaitingReadsUpToDateOnEveryRow() {
        let presentation = ActivityPresentation.map(ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .readingPhotos, state: .upToDate), ActivityEntry(kind: .namingPlaces, state: .upToDate),
        ]))
        #expect(presentation.line == "Up to date")
        #expect(presentation.lineDetail == nil)
        #expect(presentation.lineStatus == .upToDate)
        #expect(presentation.header == "Up to date")
        #expect(presentation.rows.map(\.title) == ["Photos", "Places"])
        #expect(presentation.rows.map(\.detail) == ["Up to date", "Up to date"])
    }

    /// Every row says its status, never a time: the line names the work that has run longest
    /// and counts the rest.
    @Test func eachRowSaysWhetherItWorksWaitsOrIsUpToDate() {
        let snapshot = ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .readingPhotos, state: .waiting(.originals(count: 2999))),
            ActivityEntry(kind: .findingFaces, state: .working(since: now.addingTimeInterval(-600))),
            ActivityEntry(kind: .namingPlaces, state: .upToDate),
            ActivityEntry(kind: .preparingSearch, state: .working(since: now.addingTimeInterval(-3600))),
            ActivityEntry(kind: .describingPhotos, state: .waiting(.paused(.lowPower))),
        ])
        let presentation = ActivityPresentation.map(snapshot, uncheckedFaces: MediaCount(photos: 8412))
        #expect(presentation.line == "Preparing search")
        #expect(presentation.lineDetail == "and 1 more")
        #expect(presentation.lineStatus == .working)
        #expect(presentation.header == "Working on 2 things")
        #expect(presentation.rows.map(\.title) == ["Photos", "Faces", "Places", "Search", "Descriptions"])
        #expect(presentation.rows.map(\.detail) == [
            "Waiting for 2,999 originals", "Working, 8,412 photos to check", "Up to date", "Working",
            "Paused in Low Power Mode",
        ])
        #expect(presentation.rows.map(\.status) == [.waiting, .working, .upToDate, .working, .waiting])
        #expect(presentation.accessibilityLabel == "Activity, Preparing search, and 1 more")
    }

    @Test func withNothingWorkingTheLineSaysWhatWaits() {
        let snapshot = ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .readingPhotos, state: .waiting(.originals(count: 1))),
            ActivityEntry(kind: .namingPlaces, state: .waiting(.retrying)),
        ])
        let presentation = ActivityPresentation.map(snapshot)
        #expect(presentation.line == "Photos: waiting for 1 original")
        #expect(presentation.lineDetail == "and 1 more")
        #expect(presentation.lineStatus == .waiting)
        #expect(presentation.header == "Waiting on 2 things")
        #expect(presentation.rows.last?.detail == "Waiting to try again")
    }

    @Test func accountsSayWhetherTheySyncWaitOrAreUpToDate() {
        let accounts = [
            ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .online, isSyncing: true)),
            ActivityAccount(name: "Cabin", status: ImmichAccountStatus(reach: .offline)),
            ActivityAccount(name: "Old", status: ImmichAccountStatus(reach: .signedOut)),
            ActivityAccount(name: "Work", status: ImmichAccountStatus(reach: .online)),
        ]
        let presentation = ActivityPresentation.map(ActivitySnapshot(watching: true), accounts: accounts)
        #expect(presentation.rows.map(\.detail) == [
            "Syncing", "Waiting for the server", "Waiting for you to sign in", "Up to date",
        ])
        #expect(presentation.line == "Syncing Home")
    }

    @Test func theDuplicatesBarSaysItIsStillLookingOnlyWhileNothingWouldMove() {
        let tally = DuplicatesTally(itemsWithDuplicates: 3, noun: .photos, itemsToMove: [], bytesToMove: 0, needingChoice: 0)
        #expect(DuplicatesBarPresentation.map(tally, stillLooking: true).secondaryLine == "Still looking for duplicates")
        #expect(DuplicatesBarPresentation.map(tally, stillLooking: false).secondaryLine == nil)
    }
}
