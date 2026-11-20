import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The heavy background loads run one at a time, none before the window's first grid, the one
/// the view needs first, and none after teardown (ADR 0055). The machine is tested as a
/// sequence of events; the shell and its owners with each competing event delivered while a
/// load is held at its suspension.
struct LoadAdmissionMachineTests {
    @Test func nothingRunsBeforeTheFirstGridAndThenInLaunchOrder() {
        var machine = LoadAdmissionMachine()
        #expect(machine.handle(.request(1, .searchIndex)).isEmpty)
        #expect(machine.handle(.request(2, .immichMirror)).isEmpty)
        #expect(machine.handle(.request(3, .people)).isEmpty)
        #expect(machine.running == nil)

        #expect(machine.handle(.open) == [.grant(3, .people)])
        #expect(machine.handle(.release(3)) == [.grant(1, .searchIndex)])
        #expect(machine.handle(.release(1)) == [.grant(2, .immichMirror)])
    }

    @Test func aSecondLoadWaitsForTheFirstToEnd() {
        var machine = LoadAdmissionMachine(isOpen: true)
        #expect(machine.handle(.request(1, .people)) == [.grant(1, .people)])
        #expect(machine.handle(.request(2, .duplicates)).isEmpty)
        #expect(machine.running?.request == 1)
        // A release that names no running load changes nothing.
        #expect(machine.handle(.release(2)).isEmpty)
        #expect(machine.handle(.release(1)) == [.grant(2, .duplicates)])
    }

    @Test func theLoadTheViewNeedsGoesFirstWithoutStoppingTheRunningOne() {
        var machine = LoadAdmissionMachine(isOpen: true)
        #expect(machine.handle(.request(1, .people)) == [.grant(1, .people)])
        #expect(machine.handle(.request(2, .duplicates)).isEmpty)
        #expect(machine.handle(.request(3, .searchIndex)).isEmpty)
        #expect(machine.handle(.want(.searchIndex)).isEmpty)
        #expect(machine.running?.request == 1)
        #expect(machine.handle(.release(1)) == [.grant(3, .searchIndex)])
        #expect(machine.handle(.want(nil)).isEmpty)
        #expect(machine.handle(.release(3)) == [.grant(2, .duplicates)])
    }

    /// The user comes to wait on a load already waiting (a People pass owed to their act):
    /// it is granted at once as theirs, and holds the waiting ones back while it runs. With
    /// none of its kind waiting, nothing changes.
    @Test func aWaitingLoadTheUserComesToWaitOnRunsAtOnce() {
        var machine = LoadAdmissionMachine(isOpen: true)
        #expect(machine.handle(.request(1, .duplicates)) == [.grant(1, .duplicates)])
        #expect(machine.handle(.request(2, .searchIndex)).isEmpty)
        #expect(machine.handle(.request(3, .people)).isEmpty)
        #expect(machine.handle(.promote(.people)) == [.grant(3, .people)])
        #expect(machine.runningForUser.map(\.request) == [3])
        #expect(machine.waiting.map(\.request) == [2])
        #expect(machine.handle(.promote(.people)).isEmpty)
        // The user's load holds the waiting one back after the turn's load ends.
        #expect(machine.handle(.release(1)).isEmpty)
        #expect(machine.handle(.release(3)) == [.grant(2, .searchIndex)])
        _ = machine.handle(.request(4, .people))
        _ = machine.handle(.shutdown)
        #expect(machine.handle(.promote(.people)).isEmpty)
    }

    @Test func aWantedLoadQueuedBeforeTheFirstGridRunsFirst() {
        var machine = LoadAdmissionMachine()
        _ = machine.handle(.request(1, .people))
        _ = machine.handle(.request(2, .searchIndex))
        _ = machine.handle(.want(.searchIndex))
        #expect(machine.handle(.open) == [.grant(2, .searchIndex)])
    }

    @Test func aLoadThatAsksAgainGoesBehindTheLoadsAlreadyWaiting() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.request(1, .people))
        _ = machine.handle(.request(2, .searchIndex))
        #expect(machine.handle(.release(1)) == [.grant(2, .searchIndex)])
        _ = machine.handle(.request(3, .people))
        _ = machine.handle(.request(4, .duplicates))
        #expect(machine.handle(.release(2)) == [.grant(3, .people)])
        _ = machine.handle(.request(5, .people))
        #expect(machine.handle(.release(3)) == [.grant(4, .duplicates)])
    }

    /// Readying a search runs behind every other waiting load, whenever it asked: before the
    /// first grid and after it, behind a People pass that asked later.
    @Test func readyingASearchRunsBehindEveryOtherLoad() {
        var machine = LoadAdmissionMachine()
        _ = machine.handle(.request(1, .searchPrepare))
        _ = machine.handle(.request(2, .derivedFolder))
        _ = machine.handle(.request(3, .immichMirror))
        #expect(machine.handle(.open) == [.grant(3, .immichMirror)])
        _ = machine.handle(.request(4, .people))
        #expect(machine.handle(.release(3)) == [.grant(2, .derivedFolder)])
        #expect(machine.handle(.release(2)) == [.grant(4, .people)])
        #expect(machine.handle(.release(4)) == [.grant(1, .searchPrepare)])
    }

    /// A load the user waits on (a query's encoder) is granted at once beside the running one,
    /// ahead of the loads waiting, and none of them starts while it runs.
    @Test func aLoadTheUserWaitsOnRunsAtOnceAndHoldsTheWaitingOnesBack() {
        var machine = LoadAdmissionMachine(isOpen: true)
        #expect(machine.handle(.request(1, .people)) == [.grant(1, .people)])
        #expect(machine.handle(.request(2, .duplicates)).isEmpty)
        #expect(machine.handle(.request(3, .searchPrepare)).isEmpty)
        #expect(machine.handle(.requestForUser(4, .searchPrepare)) == [.grant(4, .searchPrepare)])
        #expect(machine.running?.request == 1)
        #expect(machine.runningForUser.map(\.request) == [4])
        #expect(machine.handle(.release(1)).isEmpty, "nothing waiting starts beside the user's load")
        #expect(machine.handle(.release(4)) == [.grant(2, .duplicates)])
        #expect(machine.runningForUser.isEmpty)
    }

    /// The user's load does not wait for the first grid; shutdown refuses it like any other.
    @Test func aLoadTheUserWaitsOnRunsBeforeTheFirstGridAndNeverAfterShutdown() {
        var machine = LoadAdmissionMachine()
        #expect(machine.handle(.requestForUser(1, .searchPrepare)) == [.grant(1, .searchPrepare)])
        #expect(machine.handle(.request(2, .people)).isEmpty)
        #expect(machine.handle(.open).isEmpty)
        #expect(machine.handle(.release(1)) == [.grant(2, .people)])
        _ = machine.handle(.shutdown)
        #expect(machine.handle(.requestForUser(3, .searchPrepare)) == [.refuse(3)])
    }

    @Test func aWithdrawnRequestNeverRuns() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.request(1, .people))
        _ = machine.handle(.request(2, .duplicates))
        #expect(machine.handle(.withdraw(2)) == [.refuse(2)])
        #expect(machine.handle(.withdraw(1)).isEmpty)
        #expect(machine.handle(.release(1)).isEmpty)
        #expect(machine.running == nil)
    }

    @Test func shutdownRefusesEveryWaitingAndLaterLoad() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.request(1, .people))
        _ = machine.handle(.request(2, .duplicates))
        _ = machine.handle(.request(3, .searchIndex))
        #expect(machine.handle(.shutdown) == [.refuse(2), .refuse(3)])
        #expect(machine.handle(.release(1)).isEmpty)
        #expect(machine.handle(.request(4, .people)) == [.refuse(4)])
        #expect(machine.running == nil)
    }

    /// A description asked for before the first grid runs after the launch's other loads and
    /// before readying a search.
    @Test func theFirstDescriptionRunsAfterTheLaunchsLoads() {
        var machine = LoadAdmissionMachine()
        _ = machine.handle(.request(1, .searchPrepare))
        _ = machine.handle(.request(2, .description))
        _ = machine.handle(.request(3, .people))
        #expect(machine.handle(.open) == [.grant(3, .people)])
        #expect(machine.handle(.release(3)) == [.grant(2, .description)])
        #expect(machine.handle(.release(2)) == [.grant(1, .searchPrepare)])
    }

    /// The heavy load granted last when the memory hold begins ran into it: at the reopen
    /// exactly one load starts, not that one, and it runs only after the others waiting, for the
    /// session.
    @Test func atTheReopenOneLoadStartsAndNotTheOneThatRanIntoTheHold() {
        var machine = LoadAdmissionMachine(isOpen: true)
        #expect(machine.handle(.request(1, .people)) == [.grant(1, .people)])
        _ = machine.handle(.request(2, .duplicates))
        _ = machine.handle(.request(3, .searchIndex))
        #expect(machine.handle(.room(Self.warning(available: nil))).isEmpty)
        #expect(machine.roomNeeds[.people]?.raises == 1)
        #expect(machine.handle(.release(1)).isEmpty, "nothing starts while the room holds")
        _ = machine.handle(.request(4, .people))

        #expect(machine.handle(.room(.open)) == [.grant(2, .duplicates)], "one at a time")
        #expect(machine.handle(.release(2)) == [.grant(3, .searchIndex)])
        _ = machine.handle(.request(5, .duplicates))
        #expect(machine.handle(.release(3)) == [.grant(5, .duplicates)], "a load asked later still goes first")
        #expect(machine.handle(.release(5)) == [.grant(4, .people)])
        #expect(machine.handle(.release(4)).isEmpty)
        #expect(machine.roomNeeds[.people]?.raises == 1, "a clean run does not forget the raise")
    }

    /// Each grant raises the pressure at most once, a hold that is not for memory marks
    /// nothing, and an unread share measures nothing.
    @Test func aGrantRaisesThePressureOnceAndOnlyForMemory() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.request(1, .duplicates))
        _ = machine.handle(.release(1))
        _ = machine.handle(.request(2, .people))
        _ = machine.handle(.room(Self.warning(available: nil)))
        _ = machine.handle(.release(2))
        _ = machine.handle(.room(.open))
        _ = machine.handle(.room(Self.warning(available: nil)))
        #expect(machine.roomNeeds[.people] == LoadAdmissionMachine.RoomNeed(requiredPercent: nil, raises: 1))
        #expect(machine.roomNeeds[.duplicates] == nil)
        _ = machine.handle(.room(.open))
        #expect(machine.handle(.request(3, .people)) == [.grant(3, .people)], "unread, it starts")
        _ = machine.handle(.room(LoadRoomHolds(heavyLoad: .memoryCritical, description: .memoryCritical)))
        _ = machine.handle(.release(3))
        #expect(machine.roomNeeds[.people]?.raises == 2)
        _ = machine.handle(.room(.open))
        _ = machine.handle(.request(4, .duplicates))
        _ = machine.handle(.room(LoadRoomHolds(heavyLoad: .thermal, description: .thermal)))
        #expect(machine.roomNeeds[.duplicates] == nil, "a thermal hold is no memory cost")
    }

    /// A description needs no share: at normal and at warning, with little available, it is
    /// granted at once, asks the room for no share, and a heavy load at warning waits.
    @Test func aDescriptionStartsAtNormalAndAtWarningWhateverIsAvailable() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.room(Self.open(available: 20)))
        #expect(machine.handle(.request(1, .description)) == [.grant(1, .description)])
        #expect(machine.headroomRequired == nil)
        _ = machine.handle(.release(1))
        _ = machine.handle(.room(Self.warning(available: 25)))
        #expect(machine.handle(.request(2, .people)).isEmpty, "a heavy load waits at warning")
        #expect(machine.handle(.request(3, .description)) == [.grant(3, .description)])
        #expect(machine.headroomRequired == nil)
        #expect(machine.roomNeeds.isEmpty)
    }

    /// A description waits while the room holds its kind — critical memory, heat, Low Power
    /// Mode — and starts in the step that clears it.
    @Test func aHeldDescriptionStartsInTheStepThatClearsTheHold() {
        for hold in [BackgroundHold.memoryCritical, .thermal, .lowPower] {
            var machine = LoadAdmissionMachine(isOpen: true)
            _ = machine.handle(.room(LoadRoomHolds(heavyLoad: hold, description: hold)))
            #expect(machine.handle(.request(1, .description)).isEmpty)
            #expect(machine.handle(.room(Self.warning(available: 25))) == [.grant(1, .description)])
        }
    }

    /// A description that fell is charged to no load: the pressure it raised marks neither it
    /// nor the heavy load granted before it, the next description starts at once, and the heavy
    /// load waits only while the room holds it.
    @Test func aDescriptionThatRaisedThePressureIsChargedToNoLoad() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.room(Self.open(available: 70)))
        #expect(machine.handle(.request(1, .people)) == [.grant(1, .people)])
        _ = machine.handle(.release(1))
        #expect(machine.handle(.request(2, .description)) == [.grant(2, .description)])
        #expect(machine.lastGranted == nil)
        _ = machine.handle(.room(Self.open(available: 28)))
        _ = machine.handle(.room(Self.warning(available: 31)))
        #expect(machine.roomNeeds.isEmpty)
        _ = machine.handle(.request(3, .people))
        #expect(machine.handle(.release(2)).isEmpty, "the People pass waits at warning")
        #expect(machine.handle(.request(4, .description)) == [.grant(4, .description)])
        _ = machine.handle(.release(4))
        #expect(machine.handle(.room(Self.open(available: 40))) == [.grant(3, .people)], "no requirement")
    }

    /// A description's turn yields to the view: the load the view needs is granted beside a
    /// running description in the step it is wanted or asked, while a load nobody waits on
    /// still waits; nothing else starts while the two run, and the next waiting load starts
    /// once both ended. Neither grant measures a cost.
    @Test func theViewsLoadStartsBesideARunningDescription() {
        var machine = LoadAdmissionMachine(isOpen: true)
        #expect(machine.handle(.request(1, .description)) == [.grant(1, .description)])
        #expect(machine.handle(.request(2, .duplicates)).isEmpty)
        #expect(machine.handle(.request(3, .people)).isEmpty, "not wanted, it waits")
        #expect(machine.handle(.want(.people)) == [.grant(3, .people)])
        #expect(machine.running?.request == 1)
        #expect(machine.beside?.request == 3)
        #expect(machine.lastGranted == nil)
        #expect(machine.handle(.release(1)).isEmpty, "one heavy load at a time beside the view's")
        #expect(machine.handle(.request(4, .description)).isEmpty)
        #expect(machine.handle(.release(3)) == [.grant(2, .duplicates)])

        _ = machine.handle(.release(2))
        #expect(machine.handle(.release(4)).isEmpty)
        _ = machine.handle(.request(5, .description))
        #expect(machine.handle(.request(6, .people)) == [.grant(6, .people)], "asked while wanted, at once")
        #expect(machine.runningLoads == [.description, .people])
    }

    /// Only a description yields its turn: with a heavy load running, the view's load waits for
    /// it (ADR 0055, decision 3).
    @Test func aHeavyLoadRunningKeepsItsTurnFromTheView() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.request(1, .duplicates))
        _ = machine.handle(.want(.people))
        #expect(machine.handle(.request(2, .people)).isEmpty)
        #expect(machine.handle(.release(1)) == [.grant(2, .people)])
    }

    /// A second grant that raised the pressure ratchets the requirement past the share it was
    /// granted at, so it is never retried into the same room; a clean run never lowers it.
    @Test func theRequirementRatchetsAfterASecondRaise() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.room(Self.open(available: 70)))
        _ = machine.handle(.request(1, .people))
        _ = machine.handle(.room(Self.warning(available: 25)))
        _ = machine.handle(.release(1))
        // 32 + (70 − 25).
        #expect(machine.roomNeeds[.people]?.requiredPercent == 77)

        _ = machine.handle(.room(Self.open(available: 78)))
        #expect(machine.handle(.request(2, .people)) == [.grant(2, .people)])
        _ = machine.handle(.room(Self.warning(available: 60)))
        _ = machine.handle(.release(2))
        // The cost seen (32 + 18) is below the requirement: it ratchets past the grant's share.
        #expect(machine.roomNeeds[.people] == LoadAdmissionMachine.RoomNeed(requiredPercent: 79, raises: 2))

        _ = machine.handle(.room(Self.open(available: 78)))
        #expect(machine.handle(.request(3, .people)).isEmpty, "not granted into the room it raised")
        #expect(machine.headroomRequired == 79)
        #expect(machine.handle(.room(Self.open(available: 90))) == [.grant(3, .people)])
        _ = machine.handle(.release(3))
        #expect(machine.roomNeeds[.people]?.requiredPercent == 79, "a clean run lowers nothing")
    }

    /// A heavy load that raised the pressure is admitted against what it took; the lowest share
    /// read while it ran counts, not only the warning's; the view's load starts whatever.
    @Test func aHeavyLoadThatRaisedThePressureNeedsWhatItTook() {
        var machine = LoadAdmissionMachine(isOpen: true)
        _ = machine.handle(.room(Self.open(available: 50)))
        _ = machine.handle(.request(1, .people))
        _ = machine.handle(.room(Self.open(available: 28)))
        _ = machine.handle(.room(Self.warning(available: 30)))
        _ = machine.handle(.release(1))
        // 32 + (50 − 28).
        #expect(machine.roomNeeds[.people]?.requiredPercent == 54)
        _ = machine.handle(.room(Self.open(available: 53)))
        #expect(machine.handle(.request(2, .people)).isEmpty)
        #expect(machine.headroomRequired == 54)
        #expect(machine.handle(.want(.people)) == [.grant(2, .people)], "the view's load starts whatever")
    }

    static func open(available: Int) -> LoadRoomHolds {
        LoadRoomHolds(heavyLoad: nil, description: nil, availablePercent: available)
    }

    /// What the room holds at warning: every heavy load, and no description.
    static func warning(available: Int?) -> LoadRoomHolds {
        LoadRoomHolds(heavyLoad: .memoryWarning, description: nil, availablePercent: available)
    }

    @Test func aViewNeedsTheLoadItCannotAnswerWithout() {
        #expect(BackgroundLoad.needed(by: CatalogQueryDescriptor(scope: .people)) == .people)
        #expect(BackgroundLoad.needed(by: CatalogQueryDescriptor(scope: .duplicates)) == .duplicates)
        #expect(BackgroundLoad.needed(by: CatalogQueryDescriptor(scope: .allMedia)) == nil)
        var search = CatalogQueryDescriptor(scope: .allMedia)
        search.search = CatalogSearch(text: "dog")
        #expect(BackgroundLoad.needed(by: search) == .searchIndex)
    }
}

@Suite(.testScope)
struct LoadAdmissionTests {
    /// The footprint a release logs is read after the release: a read that stalls (`task_info`
    /// under memory pressure) holds back neither the next load's grant nor the owner whose
    /// load ended.
    @Test func aStalledFootprintReadHoldsBackNoGrantAndNoOwner() async throws {
        let stalled = DispatchSemaphore(value: 0)
        let admission = LoadAdmission(isOpen: true) {
            stalled.wait()
            return 0
        }
        defer {
            for _ in 0 ..< 2 {
                stalled.signal()
            }
        }
        let held = ArrivalGate()
        let first = Task {
            try await admission.run(.people) { await held.arrive() }
        }
        await held.waitForArrivals(1)
        let next = Task {
            try await admission.run(.duplicates) { await held.arrive() }
        }
        try await waitUntil { admission.snapshot.waiting.count == 1 }

        await held.open()
        try await first.value
        try await next.value
        #expect(admission.snapshot.running == nil)
        #expect(await held.arrivalCount == 2)
    }

    @Test func twoLoadsNeverRunTogether() async throws {
        let admission = LoadAdmission(isOpen: true)
        let held = ArrivalGate()
        let second = Mutex(false)
        let first = Task {
            try await admission.run(.people) { await held.arrive() }
        }
        await held.waitForArrivals(1)
        let next = Task {
            try await admission.run(.duplicates) { second.withLock { $0 = true } }
        }
        try await waitUntil { admission.snapshot.waiting.count == 1 }
        #expect(second.withLock { $0 } == false)

        await held.open()
        try await first.value
        try await next.value
        #expect(second.withLock { $0 })
        #expect(admission.snapshot.running == nil)
    }

    /// A window read is never answered behind a description: with a request held in flight at
    /// its suspension, the People view's pass is granted and runs to its end while the request
    /// is still under way, and a duplicates build nobody waits on still waits for the request.
    @Test func theViewsLoadIsNotDelayedBehindADescriptionInFlight() async throws {
        let admission = LoadAdmission(isOpen: true)
        let request = ArrivalGate()
        let described = Task { try await admission.run(.description) { await request.arrive() } }
        await request.waitForArrivals(1)
        let built = Mutex(false)
        let duplicates = Task { try await admission.run(.duplicates) { built.withLock { $0 = true } } }
        try await waitUntil { admission.snapshot.waiting.count == 1 }

        admission.want(.people)
        let shown = try await admission.run(.people) { admission.snapshot.runningLoads }
        #expect(shown == [.description, .people])
        #expect(admission.snapshot.running?.load == .description, "the request is still under way")
        #expect(built.withLock { $0 } == false)

        await request.open()
        try await described.value
        try await duplicates.value
        #expect(built.withLock { $0 })
        #expect(admission.snapshot.granted == [.description: 1, .people: 1, .duplicates: 1])
    }

    @Test func theViewsLoadRunsBeforeTheLoadsAskedFirst() async throws {
        let admission = LoadAdmission()
        let order = Mutex<[BackgroundLoad]>([])
        let people = Task {
            try await admission.run(.people) { order.withLock { $0.append(.people) } }
        }
        try await waitUntil { admission.snapshot.waiting.count == 1 }
        let search = Task {
            try await admission.run(.searchIndex) { order.withLock { $0.append(.searchIndex) } }
        }
        try await waitUntil { admission.snapshot.waiting.count == 2 }
        admission.want(.searchIndex)
        admission.open()
        try await people.value
        try await search.value
        #expect(order.withLock { $0 } == [.searchIndex, .people])
    }

    @Test func aWaiterWhoseTaskEndsStartsNothingAndFreesTheTurn() async throws {
        let admission = LoadAdmission(isOpen: true)
        let held = ArrivalGate()
        let ran = Mutex(false)
        let first = Task {
            try await admission.run(.people) { await held.arrive() }
        }
        await held.waitForArrivals(1)
        let waiter = Task {
            try await admission.run(.duplicates) { ran.withLock { $0 = true } }
        }
        try await waitUntil { admission.snapshot.waiting.count == 1 }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(admission.snapshot.waiting.isEmpty)

        await held.open()
        try await first.value
        #expect(ran.withLock { $0 } == false)
        #expect(admission.snapshot.running == nil)
    }

    @Test func shutdownDuringAQueuedLoadStartsNothing() async throws {
        let admission = LoadAdmission(isOpen: true)
        let held = ArrivalGate()
        let ran = Mutex(false)
        let first = Task {
            try await admission.run(.people) { await held.arrive() }
        }
        await held.waitForArrivals(1)
        let queued = Task {
            try await admission.run(.searchIndex) { ran.withLock { $0 = true } }
        }
        try await waitUntil { admission.snapshot.waiting.count == 1 }
        admission.shutdown()
        await #expect(throws: CancellationError.self) { try await queued.value }

        await held.open()
        try await first.value
        await #expect(throws: CancellationError.self) {
            try await admission.run(.duplicates) { ran.withLock { $0 = true } }
        }
        #expect(ran.withLock { $0 } == false)
    }

    /// A duplicates build is a heavy load and waits for the window's admission; the People
    /// gallery's read is the window's own and does not: it runs while the build waits, so
    /// People's first paint never queues behind a heavy load (ADR 0047, ADR 0055).
    @Test func theGalleryReadsWhileAHeavyLoadWaits() async throws {
        let temp = try makeTestDirectory()
        let store = makeTestStore(location: .databaseFile(temp.appending(path: "catalog.sqlite")), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let admission = LoadAdmission()
        let duplicates = ArrivalGate()
        let people = ArrivalGate()
        let projection = CatalogProjection(
            volumeCapacity: ampleVolumeCapacity,
            cadence: .milliseconds(10),
            duplicatesBuilder: { _, _ in
                await duplicates.arrive()
                return .empty
            },
            peopleBuilder: { _, _ in
                await people.arrive()
                return .empty
            },
            admission: admission
        )
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let consumer = Task {
            for await _ in stream {}
        }
        defer { consumer.cancel() }

        await people.waitForArrivals(1)
        try await waitUntil { admission.snapshot.waiting.count == 1 }
        #expect(await duplicates.arrivalCount == 0)
        #expect(admission.snapshot.waiting.first?.load == .duplicates)

        await people.open()
        admission.open()
        await duplicates.waitForArrivals(1)
        #expect(admission.snapshot.running?.load == .duplicates)
        await duplicates.open()
        try await waitUntil { await projection.duplicatesAreQuiescent }
        admission.shutdown()
        await store.shutdown()
    }

    /// The window opens the admission when it applies its first grid: a load asked for before
    /// the window starts runs only once the grid shows the loaded catalog.
    @MainActor
    @Test func heavyLoadsWaitForTheWindowsFirstGrid() async throws {
        let temp = try makeTestDirectory()
        let store = makeTestStore(location: .databaseFile(temp.appending(path: "catalog.sqlite")), scanCadence: .milliseconds(10))
        let admission = LoadAdmission()
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10)),
            loadAdmission: admission,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        let load = Task { @MainActor in
            try await admission.run(.people) { model.mediaEmptyState }
        }
        try await waitUntil { admission.snapshot.waiting.count == 1 }

        model.start()
        let seen = try await load.value
        #expect(seen != .loadingCatalog)
        #expect(admission.snapshot.isOpen)
        await store.shutdown()
    }

    /// The derived folder's launch load holds the admission's one turn while it runs, so it runs
    /// at the owners' priority, never below it: a load the system throttles would hold People,
    /// duplicates and the search index behind it (ADR 0055). Started from an owner's task, the
    /// look runs at that task's priority.
    @Test func theDerivedFolderLoadHoldsItsTurnAtTheOwnersPriority() async throws {
        let admission = LoadAdmission(isOpen: true)
        let looked = ArrivalGate()
        let priority = Mutex<TaskPriority?>(nil)
        let load = DerivedFolderLoad(admission: admission) {
            priority.withLock { $0 = Task.currentPriority }
            await looked.arrive()
        }
        // Not awaited: an awaiting test task would raise the starting task to its own priority.
        Task.detached(priority: .backgroundOwner) {
            await load.start()
        }
        await looked.waitForArrivals(1)
        #expect(admission.snapshot.running?.load == .derivedFolder)
        #expect(priority.withLock { $0 } == .backgroundOwner)

        await looked.open()
        _ = try await load.untilQuiescent()
        #expect(admission.snapshot.running == nil)
    }
}
