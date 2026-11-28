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

        /// What its work has left, which the board reads once its work moves.
        private var left: Int?

        /// How many of what is left wait out a failure.
        private var parked = 0

        /// Sets what is left as a pass that wrote `finished` items' results would leave it,
        /// alongside whatever else moved the owed set, `parked` of it waiting out a failure.
        func count(_ left: Int, finished: Int = 0, parked: Int = 0) {
            self.left = left
            self.parked = parked
            activity.wrote(max(finished, 1))
            activity.finished(finished)
        }

        func progress(for _: ActivityKind) async -> WorkProgress? {
            left.map { activity.progress(left: $0, parked: parked) }
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
        await board.watch([.init(kind: .scanningFaces, owner: faces), .init(kind: .lookingUpPlaces, owner: places)], room: nil)

        let idle = await published.newest { $0.watching }
        #expect(idle.entries == [
            ActivityEntry(kind: .scanningFaces, state: .upToDate), ActivityEntry(kind: .lookingUpPlaces, state: .upToDate),
        ], "every watched kind is listed, with its status")

        let started = clock.now
        let request = await faces.begin()
        let working = await published.newest { $0.isWorking(.scanningFaces) }
        #expect(working.entries == [
            ActivityEntry(kind: .scanningFaces, state: .working(since: started)), ActivityEntry(kind: .lookingUpPlaces, state: .upToDate),
        ])

        clock.advance(90)
        await faces.end(covering: request)
        let settled = await published.newest { !$0.isWorking(.scanningFaces) }
        #expect(settled.entries.first == ActivityEntry(kind: .scanningFaces, state: .upToDate))
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
        await board.watch([.init(kind: .writingDescriptions, owner: descriptions)], room: room)
        _ = await published.newest { $0.watching }
        await descriptions.begin()
        await descriptions.holdNow { room.hold(for: .description) }
        _ = await published.newest { $0.isWorking(.writingDescriptions) }

        room.deliver(MachineConditions(memory: .normal, thermal: .nominal, lowPower: true))
        let held = await published.newest { $0.entries.first?.state == .paused(.lowPower) }
        #expect(!held.isWorking(.writingDescriptions))
        await board.shutdown()
    }

    /// An owner at rest that says what stops its work waits on it; a backoff wake alone is no
    /// trouble; once nothing stops it, it is up to date.
    @Test func anOwnerWaitsOnWhatItSaysStopsItAndIsUpToDateWithoutIt() async {
        let board = ActivityBoard()
        let enrichment = ScriptedOwner("enrichment")
        let places = ScriptedOwner("placeNames")
        let published = Published(board)
        await board.watch(
            [.init(kind: .makingThumbnails, owner: enrichment), .init(kind: .lookingUpPlaces, owner: places)], room: nil
        )
        _ = await published.newest { $0.watching }

        let provider = OwnerTrouble(.providerNotAnswering)
        await enrichment.stop([provider, OwnerTrouble(.diskFull, count: 0)])
        await places.backOff(OwnerWake(kind: .backoff, at: ContinuousClock.now.advanced(by: .seconds(60))))
        board.ring()
        let waiting = await published.newest { $0.entries.first?.state == .waiting }
        #expect(waiting.entries == [
            ActivityEntry(kind: .makingThumbnails, state: .waiting, troubles: [provider]),
            ActivityEntry(kind: .lookingUpPlaces, state: .upToDate),
        ], "a counted trouble that stops nothing is none, and a wake alone is no trouble")

        await enrichment.stop([])
        board.ring()
        let upToDate = await published.newest { $0.entries.allSatisfy { $0.state == .upToDate } }
        #expect(upToDate.entries.flatMap(\.troubles).isEmpty)
        await board.shutdown()
    }

    /// A kind whose every item left waits out a failure waits, and keeps waiting while its
    /// owner retries them — busy, moving nothing — with what stopped it still said, so the
    /// row neither flickers to working nor drops its reason; it works again only once an item
    /// finishes and work it can move is left. A working kind's troubles ride along.
    @Test func aRetryThatMovesNothingKeepsAKindWaitingUntilAnItemFinishes() async {
        let clock = TestClock()
        let board = ActivityBoard(now: { clock.now })
        let enrichment = ScriptedOwner("enrichment")
        let published = Published(board)
        await board.watch([.init(kind: .makingThumbnails, owner: enrichment)], room: nil)
        _ = await published.newest { $0.watching }

        let provider = OwnerTrouble(.providerNotAnswering)
        await enrichment.stop([provider])
        await enrichment.count(10, parked: 10)
        board.ring()
        let retry = await enrichment.begin()
        let parked = await published.newest { $0.entries.first?.progress?.parked == 10 }
        #expect(parked.entries.first?.state == .waiting, "busy with parked items alone is no work")

        // The retry is running; its owner no longer says what stopped it, and it moves nothing.
        await enrichment.stop([])
        await enrichment.count(10, parked: 9)
        board.ring()
        let retrying = await published.newest { $0.entries.first?.progress?.parked == 9 }
        #expect(retrying.entries.first == ActivityEntry(
            kind: .makingThumbnails, state: .waiting, troubles: [provider],
            progress: ActivityProgress(done: 0, total: 10, parked: 9)
        ), "a retry keeps the kind waiting, and what stopped it is still said")

        let started = clock.now
        await enrichment.stop([provider])
        await enrichment.count(8, finished: 2)
        board.ring()
        let moving = await published.newest { $0.isWorking(.makingThumbnails) }
        #expect(moving.entries.first == ActivityEntry(
            kind: .makingThumbnails, state: .working(since: started), troubles: [provider],
            progress: ActivityProgress(done: 2, total: 10)
        ))

        await enrichment.stop([])
        await enrichment.count(0, finished: 8)
        await enrichment.end(covering: retry)
        let settled = await published.newest { $0.entries.first?.state == .upToDate }
        #expect(settled.entries.first?.progress == nil)
        await board.shutdown()
    }

    /// An owner that is only a kind's detail — the downloads behind the photos to show —
    /// never makes the kind work; its run is the working kind's line while the run is
    /// background work.
    @Test func aDetailOwnerSaysHowTheWorkGoesButNeverWhetherItWorks() async {
        let board = ActivityBoard()
        let enrichment = ScriptedOwner("enrichment")
        let downloads = ScriptedOwner("materialization")
        let published = Published(board)
        await board.watch(
            [.init(kind: .makingThumbnails, owner: enrichment), .init(kind: .makingThumbnails, owner: downloads, isDetail: true)],
            room: nil
        )
        _ = await published.newest { $0.watching }

        let alone = await downloads.begin()
        await enrichment.stop([OwnerTrouble(.providerNotAnswering)])
        board.ring()
        let detailOnly = await published.newest { !$0.entries.isEmpty && $0.entries[0].troubles.count == 1 }
        #expect(detailOnly.entries.first?.state == .waiting, "a download alone does not make the kind work")
        await enrichment.stop([])
        await downloads.end(covering: alone)
        _ = await published.newest { $0.entries.first?.state == .upToDate }
        await board.shutdown()
    }
}

extension ActivityBoardTests {
    /// A stretch's tally: `done` is what the owner finished since the stretch began and
    /// `total` is that and what is left, so the bar moves only as the owner finishes items; an
    /// item that leaves the owed set by no work of the owner's is never counted as done; the
    /// tally ends with the stretch.
    @Test func aStretchCountsOnlyWhatItsOwnerFinished() async {
        let board = ActivityBoard()
        let enrichment = ScriptedOwner("enrichment")
        let published = Published(board)
        await board.watch([.init(kind: .makingThumbnails, owner: enrichment)], room: nil)
        _ = await published.newest { $0.watching }

        await enrichment.count(100, finished: 7)
        let request = await enrichment.begin()
        let first = await published.newest { $0.entries.first?.progress != nil }
        #expect(first.entries.first?.progress == ActivityProgress(done: 0, total: 100), "what was finished before the stretch is not its")

        await enrichment.count(60, finished: 40)
        board.ring()
        let finished = await published.newest { $0.entries.first?.progress?.done == 40 }
        #expect(finished.entries.first?.progress == ActivityProgress(done: 40, total: 100))

        await enrichment.count(30)
        board.ring()
        let fell = await published.newest { $0.entries.first?.progress?.total == 70 }
        #expect(fell.entries.first?.progress == ActivityProgress(done: 40, total: 70), "a fall no work made lowers the total, never done")

        await enrichment.count(45)
        board.ring()
        let rose = await published.newest { $0.entries.first?.progress?.total == 85 }
        #expect(rose.entries.first?.progress == ActivityProgress(done: 40, total: 85), "added items raise the total, done stays")

        await enrichment.end(covering: request)
        let settled = await published.newest { $0.entries.first?.state == .upToDate }
        #expect(settled.entries.first?.progress == nil)

        await enrichment.count(5)
        let again = await enrichment.begin()
        let next = await published.newest { $0.entries.first?.progress?.total == 5 }
        #expect(next.entries.first?.progress == ActivityProgress(done: 0, total: 5), "the next stretch counts from its own start")
        await enrichment.end(covering: again)
        await board.shutdown()
    }
}

extension ActivityBoardTests {
    /// Two owners counting one kind — a still's faces and a video's — sum: what each finished
    /// since the stretch began, of that and what each has left.
    @Test func aKindCountedByTwoOwnersSumsWhatEachFinishedAndHasLeft() async {
        let board = ActivityBoard()
        let stills = ScriptedOwner("previewFaces")
        let videos = ScriptedOwner("enrichment")
        let published = Published(board)
        await board.watch(
            [.init(kind: .scanningFaces, owner: stills), .init(kind: .scanningFaces, owner: videos)], room: nil
        )
        _ = await published.newest { $0.watching }

        await stills.count(100, finished: 5)
        await videos.count(20, finished: 3)
        let stillsRequest = await stills.begin()
        let videosRequest = await videos.begin()
        let first = await published.newest { $0.entries.first?.progress?.total == 120 }
        #expect(first.entries.first?.progress == ActivityProgress(done: 0, total: 120))

        await stills.count(90, finished: 10)
        await videos.count(10, finished: 10)
        board.ring()
        let moved = await published.newest { $0.entries.first?.progress?.done == 20 }
        #expect(moved.entries.first?.progress == ActivityProgress(done: 20, total: 120))

        await stills.end(covering: stillsRequest)
        await videos.end(covering: videosRequest)
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
            ActivityEntry(kind: .makingThumbnails, state: .upToDate), ActivityEntry(kind: .lookingUpPlaces, state: .upToDate),
        ]))
        #expect(presentation.line == "Up to date")
        #expect(presentation.lineDetail == nil)
        #expect(presentation.lineStatus == .upToDate)
        #expect(presentation.header == "Up to date")
        #expect(presentation.rows.isEmpty)
        #expect(presentation.footer == nil)
    }

    /// Only what the user would notice is listed, each named by what it does with how many
    /// items it has left. An item failing on its own is never said: a row whose items all
    /// wait says only that they are tried again. The line names the work that has run longest.
    @Test func thePopoverListsWhatRunsOrWaitsAndSaysOnlyWhatTheUserWouldNotice() {
        let snapshot = ActivitySnapshot(watching: true, entries: [
            ActivityEntry(
                kind: .makingThumbnails, state: .waiting,
                troubles: [OwnerTrouble(.downloadsFailed, count: 11), OwnerTrouble(.serverDidNotAnswer, count: 114)],
                progress: ActivityProgress(done: 0, total: 125, parked: 125)
            ),
            ActivityEntry(kind: .scanningFaces, state: .working(since: now.addingTimeInterval(-600))),
            ActivityEntry(kind: .lookingUpPlaces, state: .upToDate),
            ActivityEntry(kind: .indexingForSearch, state: .working(since: now.addingTimeInterval(-3600))),
            ActivityEntry(kind: .writingDescriptions, state: .paused(.lowPower), troubles: [OwnerTrouble(.appleIntelligenceNotResponding)]),
        ])
        let presentation = ActivityPresentation.map(snapshot, uncheckedFaces: MediaCount(photos: 8412))
        #expect(presentation.line == "Indexing for search")
        #expect(presentation.lineDetail == "and 3 more")
        #expect(presentation.lineStatus == .working)
        #expect(presentation.header == "Working on 2 things")
        #expect(presentation.rows.map(\.title) == [
            "Making thumbnails", "Scanning for faces", "Indexing for search", "Writing descriptions",
        ])
        #expect(presentation.rows.map(\.details) == [
            ["125 photos and videos left", "Otos will try these again later."],
            ["8,412 photos to scan"],
            [],
            ["Paused in Low Power Mode.", "Apple Intelligence isn’t responding. Otos will try again."],
        ])
        #expect(presentation.rows.map(\.status) == [.waiting, .working, .working, .waiting])
        #expect(presentation.footer == "Everything else is up to date")
        #expect(presentation.accessibilityLabel == "Activity, Indexing for search, and 3 more")
    }

    /// With nothing working, the line names what waits and, for one waiting row alone, what
    /// stops it.
    @Test func withNothingWorkingTheLineSaysWhatWaitsAndWhy() {
        let one = ActivityPresentation.map(ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .makingThumbnails, state: .upToDate),
            ActivityEntry(kind: .writingDescriptions, state: .waiting, troubles: [OwnerTrouble(.appleIntelligenceNotResponding)]),
        ]))
        #expect(one.line == "Writing descriptions")
        #expect(one.lineDetail == "Apple Intelligence isn’t responding")
        #expect(one.lineStatus == .waiting)
        #expect(one.header == "Waiting on 1 thing")
        #expect(one.footer == "Everything else is up to date")

        let two = ActivityPresentation.map(ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .makingThumbnails, state: .paused(.thermal)),
            ActivityEntry(kind: .lookingUpPlaces, state: .waiting, troubles: [OwnerTrouble(.placeNamesFailed)]),
        ]))
        #expect(two.line == "Making thumbnails")
        #expect(two.lineDetail == "and 1 more")
        #expect(two.header == "Waiting on 2 things")
        #expect(two.rows.map(\.details) == [
            ["Paused while the Mac cools down."], ["Place names couldn’t be looked up. Otos will try again."],
        ])
        #expect(two.footer == nil, "nothing else is watched")
    }

    /// What the user can fix comes first, on the line too, whatever else works.
    @Test func whatNeedsTheUserComesFirst() {
        let presentation = ActivityPresentation.map(
            ActivitySnapshot(watching: true, entries: [
                ActivityEntry(kind: .scanningFaces, state: .working(since: now)),
                ActivityEntry(kind: .writingDescriptions, state: .waiting, troubles: [OwnerTrouble(.appleIntelligenceOff)]),
            ]),
            accounts: [ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .signedOut))]
        )
        #expect(presentation.lineStatus == .needsYou)
        #expect(presentation.line == "Writing descriptions")
        #expect(presentation.lineDetail == "and 2 more")
        #expect(presentation.header == "Working on 1 thing")
        #expect(presentation.rows.map(\.status) == [.working, .needsYou, .needsYou])
        #expect(presentation.rows.map(\.action) == [nil, nil, .openSettings("Open Settings…")])
        #expect(presentation.rows.last?.details == ["You’re signed out of this account. Sign in again in Settings."])
    }

    /// Each row is named for what Otos does, in the order the popover lists them, and the
    /// details the Info pane shows wait like any other work: a server that holds them back is
    /// a row that waits, saying only that they are tried again.
    @Test func eachRowIsNamedForWhatOtosDoes() {
        let all = ActivityPresentation.map(ActivitySnapshot(
            watching: true,
            entries: ActivityKind.allCases.map { ActivityEntry(kind: $0, state: .working(since: now)) }
        ))
        #expect(all.rows.map(\.title) == [
            "Making thumbnails", "Reading photo info", "Scanning for faces", "Looking up place names",
            "Indexing for search", "Writing descriptions", "Finding duplicates",
        ])

        let waiting = ActivityPresentation.map(ActivitySnapshot(watching: true, entries: [
            ActivityEntry(
                kind: .readingPhotoInfo, state: .waiting, troubles: [OwnerTrouble(.serverDidNotAnswer, count: 114)],
                progress: ActivityProgress(done: 0, total: 114, parked: 114)
            ),
        ]))
        #expect(waiting.rows.map(\.details) == [["114 photos and videos left", "Otos will try these again later."]])
        #expect(waiting.line == "Reading photo info")
    }

    /// Only what the user would notice reads as a sentence, saying what is wrong and what
    /// happens next or what to do; a source is named as the sidebar names it.
    @Test func onlyWhatTheUserWouldNoticeIsSaid() {
        let said = OwnerTrouble.Cause.allCases.filter { cause in
            ActivityPresentation.troubleText(OwnerTrouble(cause, count: 1)) != nil
        }
        #expect(said.allSatisfy { $0.standing == .needsYou || $0.standing == .unavailable })
        #expect(OwnerTrouble.Cause.allCases.filter { $0.standing == .needsYou || $0.standing == .unavailable } == said)
        let texts = said.compactMap { ActivityPresentation.troubleText(OwnerTrouble($0)) }
        #expect(texts.allSatisfy { $0.hasSuffix(".") && !$0.localizedCaseInsensitiveContains("waiting") })
        #expect(Set(texts).count == texts.count, "no two causes read alike")
        #expect(ActivityPresentation.troubleText(OwnerTrouble(.appleIntelligenceOff))
            == "Turn on Apple Intelligence in System Settings to describe photos.")

        let roll = LibraryRootPath(rawValue: "/Users/a/OneDrive/Camera Roll")
        let family = LibraryRootPath(rawValue: "/Users/a/OneDrive/Family")
        let names = [roll: "Camera Roll", family: "Family"]
        #expect(ActivityPresentation.troubleText(OwnerTrouble(.providerNotAnswering, sources: [roll]), sourceNames: names)
            == "“Camera Roll” isn’t answering. Otos will try again.")
        #expect(ActivityPresentation.troubleText(OwnerTrouble(.providerNotAnswering, sources: [roll, family]), sourceNames: names)
            == "“Camera Roll” and “Family” aren’t answering. Otos will try again.")
        #expect(ActivityPresentation.troubleText(OwnerTrouble(.providerNotAnswering, sources: [roll]))
            == "The cloud provider isn’t answering. Otos will try again.")
    }

    @Test func accountsAreListedOnlyWhileTheySyncOrWait() {
        let accounts = [
            ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .online, isSyncing: true)),
            ActivityAccount(name: "Cabin", status: ImmichAccountStatus(reach: .offline)),
            ActivityAccount(name: "Old", status: ImmichAccountStatus(reach: .signedOut)),
            ActivityAccount(name: "Work", status: ImmichAccountStatus(reach: .online)),
        ]
        let presentation = ActivityPresentation.map(ActivitySnapshot(watching: true), accounts: accounts)
        #expect(presentation.rows.map(\.title) == ["Syncing “Home”", "Syncing “Cabin”", "Syncing “Old”"])
        #expect(presentation.rows.map(\.details) == [
            [], ["The server isn’t answering. Otos will try again."],
            ["You’re signed out of this account. Sign in again in Settings."],
        ])
        #expect(presentation.line == "Syncing “Old”", "a signed-out account needs the user")
        #expect(presentation.footer == "Everything else is up to date")
    }

    /// The assets an account's server has not read yet are said on the account's row, so the
    /// photos Otos does not show yet are accounted for; an otherwise current account waits on
    /// its server for them.
    @Test func anAccountSaysWhatItsServerHasNotReadYet() {
        let current = ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .online, unread: 943))
        let presentation = ActivityPresentation.map(ActivitySnapshot(watching: true), accounts: [current])
        #expect(presentation.rows.map(\.details) == [
            ["The server hasn’t processed 943 photos and videos yet. They appear once it has."],
        ])
        #expect(presentation.rows.map(\.status) == [.waiting])
        #expect(presentation.line == "Syncing “Home”")

        let read = ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .online, unread: 0))
        #expect(ActivityPresentation.map(ActivitySnapshot(watching: true), accounts: [read]).rows.isEmpty)
        #expect(ActivityPresentation.unreadText(1) == "The server hasn’t processed 1 photo or video yet. They appear once it has.")
    }

    /// An account's pass says how far it is: its listing so far with no bar, since the stream
    /// names no total ahead; then its images of those owed, with a bar when they were counted;
    /// and a pass that ended shows only what stops it.
    @Test func anAccountsPassSaysHowFarItsListingAndImagesAre() {
        let syncing = { (progress: ImmichAccountStatus.SyncProgress?) in
            ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .online, isSyncing: true, progress: progress))
        }
        let rows = { (account: ActivityAccount) in
            ActivityPresentation.map(ActivitySnapshot(watching: true), accounts: [account]).rows
        }
        #expect(rows(syncing(.listing(listed: 18400))).map(\.details) == [["18,400 photos and videos so far"]])
        #expect(rows(syncing(.listing(listed: 1))).map(\.details) == [["1 photo or video so far"]])
        #expect(rows(syncing(.listing(listed: 18400))).map(\.bar) == [nil])
        #expect(rows(syncing(.listing(listed: 0))).map(\.details) == [[]])

        let images = rows(syncing(.images(done: 2100, total: 6000)))
        #expect(images.map(\.details) == [["2,100 of 6,000 thumbnails"]])
        #expect(images.map(\.bar) == [ActivityPresentation.Bar(done: 2100, total: 6000)])
        #expect(images.map(\.status) == [.working])
        // A count that failed: what was tried, with no bar and never "of 0".
        #expect(rows(syncing(.images(done: 64, total: nil))).map(\.details) == [["64 thumbnails so far"]])
        #expect(rows(syncing(.images(done: 64, total: nil))).map(\.bar) == [nil])

        let offline = rows(ActivityAccount(name: "Home", status: ImmichAccountStatus(reach: .offline)))
        #expect(offline.map(\.details) == [["The server isn’t answering. Otos will try again."]])
        #expect(offline.map(\.bar) == [nil])
    }

    /// Each row says how many items it has left, in its own words, with an exact bar while it
    /// works; a waiting or paused row keeps its count and draws no bar, since its work does not
    /// move; the downloads the photos to show wait on are that row's line, with their bytes
    /// when every size is on record.
    @Test func eachRowSaysWhatIsLeftWithABarOnlyWhileItWorks() {
        let run = TransferRun(done: 214, total: 1020, bytesDone: 3_200_000_000, bytesTotal: 9_800_000_000)
        let snapshot = ActivitySnapshot(watching: true, entries: [
            ActivityEntry(
                kind: .makingThumbnails, state: .working(since: now),
                progress: ActivityProgress(done: 12408, total: 52310), transfers: run
            ),
            ActivityEntry(kind: .scanningFaces, state: .working(since: now), progress: ActivityProgress(done: 40112, total: 52310)),
            ActivityEntry(kind: .lookingUpPlaces, state: .working(since: now), progress: ActivityProgress(done: 310, total: 1204)),
            ActivityEntry(kind: .indexingForSearch, state: .working(since: now), progress: ActivityProgress(done: 0, total: 1)),
            ActivityEntry(
                kind: .writingDescriptions, state: .waiting, troubles: [OwnerTrouble(.appleIntelligenceNotResponding)],
                progress: ActivityProgress(done: 8900, total: 47000, parked: 38100)
            ),
            ActivityEntry(kind: .findingDuplicates, state: .working(since: now), progress: ActivityProgress(done: 21000, total: 52310)),
        ])
        let presentation = ActivityPresentation.map(snapshot)
        let gigabytes = { (value: Double) in Int64(value * 1_000_000_000).formatted(.byteCount(style: .file)) }
        #expect(presentation.rows.map(\.details) == [
            ["39,902 photos and videos left", "Downloading 214 of 1,020 · \(gigabytes(3.2)) of \(gigabytes(9.8))"],
            ["12,198 photos and videos to scan"],
            ["894 locations to look up"],
            ["1 photo or video left"],
            ["38,100 photos left", "Apple Intelligence isn’t responding. Otos will try again."],
            ["31,310 photos and videos to compare"],
        ])
        typealias Bar = ActivityPresentation.Bar
        #expect(presentation.rows.map(\.bar) == [
            Bar(done: 12408, total: 52310), Bar(done: 40112, total: 52310), Bar(done: 310, total: 1204),
            Bar(done: 0, total: 1), nil, Bar(done: 21000, total: 52310),
        ])
        let paused = ActivityPresentation.map(ActivitySnapshot(watching: true, entries: [
            ActivityEntry(kind: .scanningFaces, state: .paused(.thermal), progress: ActivityProgress(done: 310, total: 1204)),
        ]))
        #expect(paused.rows.map(\.details).first?.first == "894 photos and videos to scan")
        #expect(paused.rows.map(\.bar) == [nil], "a paused row draws no bar")
        #expect(presentation.rows.allSatisfy { !$0.details.joined().contains("%") }, "no percentage, only counts")
        #expect(
            ActivityPresentation.transfersText(TransferRun(done: 0, total: 1, bytesDone: nil, bytesTotal: nil)) == "Downloading 0 of 1",
            "a run whose sizes are not all on record shows no bytes"
        )
    }

    @Test func theDuplicatesBarSaysItIsStillLookingOnlyWhileNothingWouldMove() {
        let tally = DuplicatesTally(itemsWithDuplicates: 3, noun: .photos, itemsToMove: [], bytesToMove: 0, needingChoice: 0)
        #expect(DuplicatesBarPresentation.map(tally, stillLooking: true).secondaryLine == "Still looking for duplicates")
        #expect(DuplicatesBarPresentation.map(tally, stillLooking: false).secondaryLine == nil)
    }
}
