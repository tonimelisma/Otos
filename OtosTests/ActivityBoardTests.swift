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

        /// What stops its work, which the board reads every round.
        private var stopped: [OwnerTrouble] = []

        func stop(_ troubles: [OwnerTrouble]) {
            stopped = troubles
        }

        func troubles() async -> [OwnerTrouble] {
            stopped
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
        await board.watch([.init(kind: .findingPeople, owner: faces), .init(kind: .namingPlaces, owner: places)], room: nil)

        let idle = await published.newest { $0.watching }
        #expect(idle.entries == [
            ActivityEntry(kind: .findingPeople, state: .upToDate), ActivityEntry(kind: .namingPlaces, state: .upToDate),
        ], "every watched kind is listed, with its status")

        let started = clock.now
        let request = await faces.begin()
        let working = await published.newest { $0.isWorking(.findingPeople) }
        #expect(working.entries == [
            ActivityEntry(kind: .findingPeople, state: .working(since: started)), ActivityEntry(kind: .namingPlaces, state: .upToDate),
        ])

        clock.advance(90)
        await faces.end(covering: request)
        let settled = await published.newest { !$0.isWorking(.findingPeople) }
        #expect(settled.entries.first == ActivityEntry(kind: .findingPeople, state: .upToDate))
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
        let bothHeld = await published.newest { $0.entries.first?.state == .paused(.thermal) }
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
        let held = await published.newest { $0.entries.first?.state == .paused(.lowPower) }
        #expect(!held.isWorking(.describingPhotos))
        await board.shutdown()
    }

    /// An owner at rest that says what stops its work is stuck on it; a backoff wake alone is
    /// no trouble; once nothing stops it, it is up to date. A working owner's troubles ride
    /// along with its work.
    @Test func anOwnerIsStuckOnWhatItSaysStopsItAndUpToDateWithoutIt() async {
        let clock = TestClock()
        let board = ActivityBoard(now: { clock.now })
        let enrichment = ScriptedOwner("enrichment")
        let places = ScriptedOwner("placeNames")
        let published = Published(board)
        await board.watch(
            [.init(kind: .readingPhotos, owner: enrichment), .init(kind: .namingPlaces, owner: places)], room: nil
        )
        _ = await published.newest { $0.watching }

        let downloads = OwnerTrouble(.downloadsFailed, count: 3)
        await enrichment.stop([downloads, OwnerTrouble(.diskFull, count: 0)])
        await places.backOff(OwnerWake(kind: .backoff, at: ContinuousClock.now.advanced(by: .seconds(60))))
        board.ring()
        let stuck = await published.newest { $0.entries.first?.state == .stuck }
        #expect(stuck.entries == [
            ActivityEntry(kind: .readingPhotos, state: .stuck, troubles: [downloads]),
            ActivityEntry(kind: .namingPlaces, state: .upToDate),
        ], "a counted trouble that stops nothing is none, and a wake alone is no trouble")

        let started = clock.now
        let request = await enrichment.begin()
        let working = await published.newest { $0.isWorking(.readingPhotos) }
        #expect(working.entries.first == ActivityEntry(kind: .readingPhotos, state: .working(since: started), troubles: [downloads]))

        await enrichment.stop([])
        await enrichment.end(covering: request)
        let upToDate = await published.newest { $0.entries.allSatisfy { $0.state == .upToDate } }
        let troubles = upToDate.entries.flatMap(\.troubles)
        #expect(troubles.isEmpty)
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
        #expect(presentation.footer == nil)
    }

    /// Nothing runs or waits: the popover says so in its header alone, with no row.
    @Test func withEverythingUpToDateThePopoverListsNoRow() {
        let presentation = ActivityPresentation.map(ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .readingPhotos, state: .upToDate), ActivityEntry(kind: .namingPlaces, state: .upToDate),
        ]))
        #expect(presentation.line == "Up to date")
        #expect(presentation.lineDetail == nil)
        #expect(presentation.lineStatus == .upToDate)
        #expect(presentation.header == "Up to date")
        #expect(presentation.rows.isEmpty)
        #expect(presentation.footer == nil)
    }

    /// Only what runs or waits is listed, each named by what it does, with what stops it in a
    /// sentence; the rest is one line. The line names the work that has run longest.
    @Test func thePopoverListsWhatRunsOrWaitsAndSaysWhatStopsIt() {
        let snapshot = ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .readingPhotos, state: .stuck, troubles: [
                OwnerTrouble(.downloadsFailed, count: 11), OwnerTrouble(.serverDidNotAnswer, count: 2999),
            ]),
            ActivityEntry(kind: .findingPeople, state: .working(since: now.addingTimeInterval(-600))),
            ActivityEntry(kind: .namingPlaces, state: .upToDate),
            ActivityEntry(kind: .preparingSearch, state: .working(since: now.addingTimeInterval(-3600))),
            ActivityEntry(kind: .describingPhotos, state: .paused(.lowPower), troubles: [OwnerTrouble(.appleIntelligenceNotResponding)]),
        ])
        let presentation = ActivityPresentation.map(snapshot, uncheckedFaces: MediaCount(photos: 8412))
        #expect(presentation.line == "Preparing search")
        #expect(presentation.lineDetail == "and 3 more")
        #expect(presentation.lineStatus == .working)
        #expect(presentation.header == "Working on 2 things")
        #expect(presentation.rows.map(\.title) == ["Reading photos", "Finding people", "Preparing search", "Describing photos"])
        #expect(presentation.rows.map(\.details) == [
            [
                "11 items didn’t download. Otos will try again.",
                "The server didn’t answer for 2,999 items. Otos will try again.",
            ],
            ["8,412 photos to check"],
            [],
            ["Paused in Low Power Mode.", "Apple Intelligence isn’t responding. Otos will try again."],
        ])
        #expect(presentation.rows.map(\.status) == [.waiting, .working, .working, .waiting])
        #expect(presentation.footer == "Everything else is up to date")
        #expect(presentation.accessibilityLabel == "Activity, Preparing search, and 3 more")
    }

    /// With nothing working, the line names what waits and, for one waiting row alone, what
    /// stops it.
    @Test func withNothingWorkingTheLineSaysWhatWaitsAndWhy() {
        let one = ActivityPresentation.map(ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .readingPhotos, state: .upToDate),
            ActivityEntry(kind: .describingPhotos, state: .stuck, troubles: [OwnerTrouble(.appleIntelligenceNotResponding)]),
        ]))
        #expect(one.line == "Describing photos")
        #expect(one.lineDetail == "Apple Intelligence isn’t responding")
        #expect(one.lineStatus == .waiting)
        #expect(one.header == "Waiting on 1 thing")
        #expect(one.footer == "Everything else is up to date")

        let two = ActivityPresentation.map(ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .readingPhotos, state: .paused(.thermal)),
            ActivityEntry(kind: .namingPlaces, state: .stuck, troubles: [OwnerTrouble(.placeNamesFailed)]),
        ]))
        #expect(two.line == "Reading photos")
        #expect(two.lineDetail == "and 1 more")
        #expect(two.header == "Waiting on 2 things")
        #expect(two.rows.map(\.details) == [
            ["Paused while the Mac cools down."], ["Place names couldn’t be looked up. Otos will try again."],
        ])
        #expect(two.footer == nil, "nothing else is watched")
    }

    /// Every cause reads as a sentence that says what is wrong and what happens next or what
    /// to do; a count is exact and singular for one.
    @Test func everyTroubleSaysWhatIsWrongAndWhatHappensNext() {
        let texts = OwnerTrouble.Cause.allCases.map { ActivityPresentation.troubleText(OwnerTrouble($0, count: 1)) }
        #expect(texts.allSatisfy { $0.hasSuffix(".") && !$0.localizedCaseInsensitiveContains("waiting") })
        #expect(ActivityPresentation.troubleText(OwnerTrouble(.downloadsFailed, count: 1)) == "1 item didn’t download. Otos will try again.")
        #expect(ActivityPresentation.troubleText(OwnerTrouble(.appleIntelligenceOff))
            == "Turn on Apple Intelligence in System Settings to describe photos.")
        #expect(Set(texts).count == texts.count, "no two causes read alike")
    }

    @Test func accountsAreListedOnlyWhileTheySyncOrWait() {
        let accounts = [
            ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .online, isSyncing: true)),
            ActivityAccount(name: "Cabin", status: ImmichAccountStatus(reach: .offline)),
            ActivityAccount(name: "Old", status: ImmichAccountStatus(reach: .signedOut)),
            ActivityAccount(name: "Work", status: ImmichAccountStatus(reach: .online)),
        ]
        let presentation = ActivityPresentation.map(ActivitySnapshot(watching: true), accounts: accounts)
        #expect(presentation.rows.map(\.title) == ["Syncing Home", "Syncing Cabin", "Syncing Old"])
        #expect(presentation.rows.map(\.details) == [
            [], ["The server isn’t answering. Otos will try again."], ["You’re signed out of this account."],
        ])
        #expect(presentation.line == "Syncing Home")
        #expect(presentation.footer == "Everything else is up to date")
    }

    @Test func theDuplicatesBarSaysItIsStillLookingOnlyWhileNothingWouldMove() {
        let tally = DuplicatesTally(itemsWithDuplicates: 3, noun: .photos, itemsToMove: [], bytesToMove: 0, needingChoice: 0)
        #expect(DuplicatesBarPresentation.map(tally, stillLooking: true).secondaryLine == "Still looking for duplicates")
        #expect(DuplicatesBarPresentation.map(tally, stillLooking: false).secondaryLine == nil)
    }
}
