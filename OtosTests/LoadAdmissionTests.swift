import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The heavy background loads run one at a time, none before the window's first grid, the one
/// the view needs first, and none after teardown (plan 0116 bet 6). The machine is tested as a
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

    /// The launch's loads have drained at the first release after the first grid that leaves
    /// none running or waiting; an admission that opens with nothing asked has not drained,
    /// and a load asked later does not undo it.
    @Test func theLaunchsLoadsDrainAtTheReleaseThatLeavesNoneWaiting() {
        var machine = LoadAdmissionMachine()
        _ = machine.handle(.request(1, .people))
        _ = machine.handle(.request(2, .duplicates))
        _ = machine.handle(.open)
        #expect(!machine.hasDrainedSinceOpen)
        _ = machine.handle(.release(1))
        #expect(!machine.hasDrainedSinceOpen)
        _ = machine.handle(.release(2))
        #expect(machine.hasDrainedSinceOpen)
        _ = machine.handle(.request(3, .people))
        #expect(machine.hasDrainedSinceOpen)

        var empty = LoadAdmissionMachine()
        _ = empty.handle(.open)
        _ = empty.handle(.want(.people))
        #expect(!empty.hasDrainedSinceOpen)
        // A load the user waits on, released while a background one waits, is no drain.
        var user = LoadAdmissionMachine(isOpen: true)
        _ = user.handle(.requestForUser(1, .searchPrepare))
        _ = user.handle(.request(2, .people))
        _ = user.handle(.release(1))
        #expect(!user.hasDrainedSinceOpen)
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
    /// A waiter for the drain is resumed in the release that drains the launch's loads, at
    /// once when they have drained, and with `CancellationError` at shutdown.
    @Test func aDrainWaiterIsResumedByTheReleaseThatDrains() async throws {
        let admission = LoadAdmission()
        let held = ArrivalGate()
        let load = Task {
            try await admission.run(.people) { await held.arrive() }
        }
        try await waitUntil { admission.snapshot.waiting.count == 1 }
        let drained = Mutex(false)
        let waiter = Task {
            try await admission.untilDrained()
            drained.withLock { $0 = true }
        }
        admission.open()
        await held.waitForArrivals(1)
        #expect(drained.withLock { $0 } == false)
        await held.open()
        try await load.value
        try await waiter.value
        #expect(drained.withLock { $0 })
        // Drained already: answered at once.
        try await admission.untilDrained()

        let closed = LoadAdmission()
        let never = Task { try await closed.untilDrained() }
        // Registered before or after it, the waiter hears the shutdown.
        closed.shutdown()
        await #expect(throws: CancellationError.self) { try await never.value }
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
