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

    @Test func aKindWorksFromItsFirstRequestAndFinishesWhenItsOwnerSettles() async {
        let clock = TestClock()
        let board = ActivityBoard(now: { clock.now })
        let faces = ScriptedOwner("previewFaces")
        let places = ScriptedOwner("placeNames")
        let published = Published(board)
        await board.watch([.init(kind: .findingFaces, owner: faces), .init(kind: .namingPlaces, owner: places)], room: nil)

        let idle = await published.newest { $0.watching }
        #expect(idle.entries.isEmpty, "an owner that never worked is not listed")

        let started = clock.now
        let request = await faces.begin()
        let working = await published.newest { $0.isWorking(.findingFaces) }
        #expect(working.entries == [ActivityEntry(kind: .findingFaces, state: .working(since: started, heldBy: nil))])

        clock.advance(90)
        await faces.end(covering: request)
        let finished = await published.newest { !$0.isWorking(.findingFaces) }
        #expect(finished.entries == [ActivityEntry(kind: .findingFaces, state: .finished(at: started.addingTimeInterval(90)))])
        await board.shutdown()
    }

    @Test func aKindServedByTwoOwnersWorksWhileEitherDoesAndIsHeldOnlyWhenBothAre() async {
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
        // One of two held: the kind still works unheld.
        let oneHeld = await published.newest { $0.isWorking(.findingDuplicates) }
        #expect(oneHeld.entries.first?.state == .working(since: started, heldBy: nil))

        await signatures.hold(.thermal)
        let bothHeld = await published.newest {
            $0.entries.first?.state == .working(since: started, heldBy: .thermal)
        }
        #expect(bothHeld.isWorking(.findingDuplicates))

        clock.advance(5)
        await signatures.hold(nil)
        await groups.hold(nil)
        await groups.end(covering: groupsRequest)
        // The other still works: the stretch keeps its start.
        let stillWorking = await published.newest {
            $0.entries.first?.state == .working(since: started, heldBy: nil)
        }
        #expect(stillWorking.isWorking(.findingDuplicates))

        await signatures.end(covering: signaturesRequest)
        let finished = await published.newest { !$0.isWorking(.findingDuplicates) }
        #expect(finished.entries == [ActivityEntry(kind: .findingDuplicates, state: .finished(at: started.addingTimeInterval(5)))])
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
        let held = await published.newest {
            guard case .working(_, .lowPower) = $0.entries.first?.state else { return false }
            return true
        }
        #expect(held.isWorking(.describingPhotos))
        await board.shutdown()
    }
}

struct ActivityPresentationTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")
    /// 2026-11-21 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_262_400)

    private func map(
        _ snapshot: ActivitySnapshot, accounts: [ActivityAccount] = [], unchecked: MediaCount? = nil
    ) -> ActivityPresentation {
        .map(snapshot, accounts: accounts, uncheckedFaces: unchecked, now: now, calendar: calendar, locale: locale)
    }

    @Test func beforeTheOwnersAreWatchedNothingIsClaimed() {
        let presentation = map(ActivitySnapshot())
        #expect(presentation.line == nil)
        #expect(presentation.lineDetail == nil)
        #expect(!presentation.isWorking)
    }

    @Test func nothingWorkingReadsUpToDate() {
        let presentation = map(ActivitySnapshot(watching: true))
        #expect(presentation.line == "Up to date")
        #expect(presentation.header == "Up to date")
        #expect(presentation.working.isEmpty)
    }

    @Test func theLineNamesTheWorkThatHasRunLongestAndCountsTheRest() {
        let snapshot = ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .findingFaces, state: .working(since: now.addingTimeInterval(-600), heldBy: nil)),
            ActivityEntry(kind: .preparingSearch, state: .working(since: now.addingTimeInterval(-3600), heldBy: nil)),
            ActivityEntry(kind: .namingPlaces, state: .finished(at: now.addingTimeInterval(-60))),
        ])
        let presentation = map(snapshot, unchecked: MediaCount(photos: 8412))
        #expect(presentation.line == "Preparing search")
        #expect(presentation.lineDetail == "and 1 more")
        #expect(presentation.header == "Working on 2 things")
        #expect(presentation.working.map(\.title) == ["Finding faces", "Preparing search"])
        #expect(presentation.working.first?.detail == "8,412 photos to check")
        #expect(presentation.working.first?.time == "Since 11:50")
        #expect(presentation.finished.map(\.title) == ["Places named"])
        #expect(presentation.finished.first?.time == "11:59")
        #expect(presentation.accessibilityLabel == "Activity, Preparing search, and 1 more")
    }

    @Test func aHeldKindSaysWhyOnTheLineAndInItsRow() {
        let snapshot = ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .describingPhotos, state: .working(since: now, heldBy: .lowPower)),
        ])
        let presentation = map(snapshot)
        #expect(presentation.line == "Describing photos")
        #expect(presentation.lineDetail == "Paused in Low Power Mode")
        #expect(presentation.working.first?.detail == "Paused in Low Power Mode")
    }

    @Test func accountsShowTheirSyncAndTheirLastSyncButNotASignedOutOne() {
        let yesterday = now.addingTimeInterval(-86400)
        let accounts = [
            ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .online, isSyncing: true, lastSynced: yesterday)),
            ActivityAccount(name: "Cabin", status: ImmichAccountStatus(reach: .offline, lastSynced: yesterday)),
            ActivityAccount(name: "Old", status: ImmichAccountStatus(reach: .signedOut, lastSynced: yesterday)),
        ]
        let presentation = map(ActivitySnapshot(watching: true), accounts: accounts)
        #expect(presentation.working.map(\.title) == ["Syncing Home"])
        #expect(presentation.finished.map(\.title) == ["Cabin synced"])
        #expect(presentation.finished.first?.time.contains("20 Nov") == true, "another day names the day")
        #expect(presentation.line == "Syncing Home")
    }

    @Test func finishedWorkIsListedNewestFirst() {
        let snapshot = ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .readingPhotos, state: .finished(at: now.addingTimeInterval(-300))),
            ActivityEntry(kind: .findingDuplicates, state: .finished(at: now.addingTimeInterval(-60))),
        ])
        #expect(map(snapshot).finished.map(\.title) == ["Duplicates checked", "Photos read"])
    }

    @Test func theDuplicatesBarSaysItIsStillLookingOnlyWhileNothingWouldMove() {
        let tally = DuplicatesTally(itemsWithDuplicates: 3, noun: .photos, itemsToMove: [], bytesToMove: 0, needingChoice: 0)
        #expect(DuplicatesBarPresentation.map(tally, stillLooking: true).secondaryLine == "Still looking for duplicates")
        #expect(DuplicatesBarPresentation.map(tally, stillLooking: false).secondaryLine == nil)
    }
}
