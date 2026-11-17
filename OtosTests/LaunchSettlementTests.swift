import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// A launch's settlement names only what each consumer needs, and each stage is reached on a
/// library whose backlog lasts hours: the Duplicates step needs the build the launch owed, not
/// every build enrichment's digests will ask for; a settled tour needs the launch's own
/// requests covered, not every backlog walked. Scripted owners deliver each fact at the step
/// that makes it, so nothing here waits on time.
@Suite(.testScope)
struct LaunchSettlementTests {
    /// An owner whose requests, passes, held work and backlog the test sets, each step
    /// settling its waiters as a real owner's does.
    private actor ScriptedOwner: QuiescentOwner {
        let activity: OwnerActivity
        private(set) var holdsWork = false
        private(set) var worksBacklog = false

        init(_ name: String) {
            activity = OwnerActivity(owner: name)
        }

        /// A request taken and its pass begun: the owner owes and runs it.
        @discardableResult
        func beginRequestedPass() -> UInt64 {
            let request = activity.request()
            activity.beginPass()
            settleQuiescence()
            return request
        }

        func endPass(covering request: UInt64) {
            activity.endPass(covering: request)
            settleQuiescence()
        }

        /// A pass that failed: its request stays owed (ADR 0032 rule 4).
        func failPass() {
            activity.endPass(covering: nil)
            settleQuiescence()
        }

        func hasCovered(_ request: UInt64) -> Bool {
            activity.hasCovered(request)
        }

        /// A pass begun on what is owed: returns the request it answers.
        func beginPass() -> UInt64 {
            let request = activity.beginPass()
            settleQuiescence()
            return request
        }

        /// Another request taken while a pass runs or before the next one begins.
        func ask() {
            activity.request()
            settleQuiescence()
        }

        /// The Store yields a change to this owner's subscription.
        func deliverChange() {
            activity.deliveries.recordDelivery()
            settleQuiescence()
        }

        /// The owner takes up a delivered change, which asks it for a pass, and begins it.
        func actOnChangeAsking() -> UInt64 {
            let request = activity.request()
            activity.actedOnChange()
            activity.beginPass()
            settleQuiescence()
            return request
        }

        func set(holdsWork: Bool, worksBacklog: Bool) {
            self.holdsWork = holdsWork
            self.worksBacklog = worksBacklog
            settleQuiescence()
        }

        func ringIdle() {}
    }

    /// The Duplicates step's fact is the launch's build covered and published. While
    /// enrichment's digests ask for more builds, and a later build runs, the launch's build
    /// stays covered: the stage is reached without the duplicates owner ever owing nothing.
    @Test func theLaunchsDuplicatesBuildIsCoveredWhileLaterBuildsAreOwed() async throws {
        let store = makeTestStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        let first = ArrivalGate()
        let later = ArrivalGate()
        let builds = Mutex(0)
        let launchBuild = CatalogDuplicatesState(groups: [])
        let duplicates = DuplicatesProjection(store: store, builder: { _, _ in
            let index = builds.withLock { count in
                count += 1
                return count
            }
            if index == 1 {
                await first.arrive()
                return launchBuild
            }
            await later.arrive()
            return launchBuild
        })
        let published = AsyncValueRecorder<CatalogDuplicatesState>()
        let consumer = Task {
            for await built in duplicates.builds {
                await published.append(built)
            }
        }
        await duplicates.start()
        await duplicates.request()
        let reached = Mutex(false)
        let stage = Task {
            try await duplicates.untilLaunchBuildPublished()
            reached.withLock { $0 = true }
        }
        await first.waitForArrivals(1)
        #expect(!reached.withLock { $0 }, "the launch's build is held, so it is not covered")
        // Enrichment writes a digest: the projection asks for another build.
        await duplicates.request()
        await first.open()
        try await stage.value
        #expect(reached.withLock { $0 })
        await later.waitForArrivals(1)
        #expect(await duplicates.quiescence == nil, "a later build runs: the owner is not quiescent")
        #expect(await published.waitForValues(matching: { !$0.isEmpty }).first == launchBuild)

        await later.open()
        duplicates.stop()
        await consumer.value
        await store.shutdown()
    }

    /// A settled launch waits for every owner's launch requests and passes over a backlog:
    /// with enrichment working its backlog the round is caught up once the launch owner's pass
    /// is covered, reports which owner was on its backlog, and is no quiescence.
    @Test func aSettledLaunchSettlesWhileABacklogPassRuns() async throws {
        let launch = ScriptedOwner("people")
        let enrichment = ScriptedOwner("enrichment")
        let request = await launch.beginRequestedPass()
        // Enrichment's own launch signal is answered; it holds hashes of rows off screen.
        await enrichment.endPass(covering: enrichment.beginRequestedPass())
        await enrichment.set(holdsWork: true, worksBacklog: false)

        let caughtUp = Mutex<[OwnerCaughtUp]?>(nil)
        let round = Task {
            let facts = try await BackgroundOwnerQuiescence.untilCaughtUp([launch, enrichment])
            caughtUp.withLock { $0 = facts }
        }
        // Enrichment holding a visible row's claim is the window's work: not caught up.
        #expect(await enrichment.settledFact == nil)
        await enrichment.set(holdsWork: true, worksBacklog: true)
        #expect(await enrichment.settledFact?.backlog == true)
        #expect(caughtUp.withLock { $0 } == nil, "the launch owner's pass is not covered yet")
        await launch.endPass(covering: request)
        try await round.value

        let facts = try #require(caughtUp.withLock { $0 })
        #expect(facts.map(\.owner) == ["people", "enrichment"])
        #expect(facts.filter(\.backlog).map(\.owner) == ["enrichment"])
        #expect(await enrichment.quiescence == nil, "a backlog still owed is no quiescence")
    }

    /// The settlement a 160,000-photo library never reached: enrichment's backlog writes rows
    /// all the time, and every write asks the owners that read them (render signatures here)
    /// for another pass, so that owner is never quiescent and never all settled at one instant
    /// with the others. Caught up is monotone: once the pass answering what it owed at the
    /// moment succeeds, later requests from the backlog do not put it off.
    @Test func anOwnerTheBacklogAsksAgainAndAgainStillCatchesUp() async throws {
        let renderSignatures = ScriptedOwner("renderSignatures")
        let owed = await renderSignatures.beginRequestedPass()
        let mark = await renderSignatures.owedMark
        // Enrichment writes a batch while the pass runs: the owner is asked again.
        await renderSignatures.ask()
        #expect(await renderSignatures.covers(mark) == false, "the pass answering the mark runs")
        await renderSignatures.endPass(covering: owed)
        // And again, before the next pass begins.
        await renderSignatures.ask()
        #expect(await renderSignatures.covers(mark))
        #expect(await renderSignatures.quiescence == nil, "still owed: the backlog's later asks")
        #expect(await renderSignatures.settledFact == nil, "not on a backlog of its own either")
        // The round, from a moment after all that, is caught up by the next pass.
        let round = Task { try await BackgroundOwnerQuiescence.untilCaughtUp([renderSignatures]) }
        let next = await renderSignatures.beginPass()
        await renderSignatures.endPass(covering: next)
        #expect(try await round.value == [OwnerCaughtUp(owner: "renderSignatures", backlog: false)])
    }

    /// The moment includes the Store changes already yielded to an owner: a change delivered
    /// before the round, which the owner takes up only after it, is acted on first, and the
    /// request it raised is covered before the owner counts as caught up.
    @Test func aChangeDeliveredBeforeTheMomentIsTakenUpAndItsRequestCovered() async throws {
        let people = ScriptedOwner("people")
        // The walk's last batch: the Store yielded it, the owner has not taken it up.
        await people.deliverChange()
        let caughtUp = Mutex(false)
        let round = Task {
            _ = try await BackgroundOwnerQuiescence.untilCaughtUp([people])
            caughtUp.withLock { $0 = true }
        }
        #expect(await people.quiescence == nil, "a change delivered and not acted on")
        let raised = await people.actOnChangeAsking()
        #expect(!caughtUp.withLock { $0 }, "the request the change raised is not covered yet")
        await people.endPass(covering: raised)
        try await round.value
        #expect(caughtUp.withLock { $0 })
    }

    /// A request covered is monotone: requests made after it never put it off, and a pass
    /// that failed covers nothing.
    @Test func aCoveredRequestStaysCoveredWhateverIsAskedLater() async throws {
        let owner = ScriptedOwner("duplicates")
        let launchRequest = await owner.beginRequestedPass()
        #expect(launchRequest == OwnerActivity.firstRequest)
        let covered = Task { try await owner.untilCovered(launchRequest) }
        await owner.failPass()
        #expect(await owner.hasCovered(launchRequest) == false, "a failed pass covers nothing")
        let retry = await owner.beginRequestedPass()
        await owner.endPass(covering: retry)
        try await covered.value
        _ = await owner.beginRequestedPass()
        #expect(await owner.hasCovered(launchRequest))
        try await owner.untilCovered(launchRequest)
    }
}
