import Foundation
@testable import OtosKit
import Testing

/// Once every background owner has done what it owes, a catalog with nothing new costs
/// nothing (plan 0116): no store change, no write, and at most a few reads per owner. An
/// owner that writes while idle wakes every owner that reads what it wrote, and one that reads
/// a whole set on a timer reads it cold on a Mac under memory pressure; the owner's
/// four-minute tour found both kinds (`copies` announced 227 times by digests no other file
/// held, PR #809).
///
/// Every owner starts on a generated catalog of the owner's shape as the app starts them
/// (`RunningBackgroundOwners`: at the first grid, under the window's one `LoadAdmission`), an
/// account's sync with them. Settled is a fact, not a quiet window: every owner reports that
/// it owes nothing and runs nothing at one instant (`BackgroundOwnerQuiescence`). Then each
/// owner's wake path is rung once with no input changed (`QuiescentOwner.ringIdle`), and the
/// owners are awaited to settle again. That round is measured twice over: by the Store's own
/// use (`CatalogStore.use()`: changes by kind, transactions by role and operation), and by each
/// owner in its own units (`OwnerWork`: passes, reads, rows, rows written). No time is waited.
@Suite(.testScope, .serialized)
struct BackgroundOwnersIdleTests {
    /// Reads one owner may issue in the idle round: the first page of its walk, and the next
    /// that says it is empty, or its keyed read.
    static let readsPerOwner = 2
    /// Rows those reads may return: an owner rung with nothing owed finds nothing to visit.
    static let rowsPerOwner = 0

    @Test func everyBackgroundOwnerIsQuietOnceItsWorkIsDone() async throws {
        let rounds = try await Self.measure(scale: 0.01, named: "small")
        // Every owner the app starts reported its quiescence, the account's sync among them.
        #expect(Set(rounds.map(\.owner)) == Self.owners, "\(rounds.map(\.owner))")
    }

    /// The same round at the owner's size, on demand (`OTOS_SCALE_TEST=1`).
    @Test(.enabled(if: StallReproductionTests.ownerSize))
    func everyBackgroundOwnerIsQuietOnceItsWorkIsDoneAtTheOwnersSize() async throws {
        let rounds = try await Self.measure(scale: 1, named: "owner")
        #expect(Set(rounds.map(\.owner)) == Self.owners, "\(rounds.map(\.owner))")
    }

    static let owners: Set<String> = [
        "projection", "duplicates", "people", "peopleGallery", "derivedFolder", "materialization", "enrichment",
        "renderSignatures", "previewFaces", "placeNames", "searchIndex", "descriptions", "metadataRefresh", "immichSync",
    ]

    private static func measure(scale: Double, named name: String) async throws -> [OwnerRound] {
        // Each phase's length is logged (`op=ownersIdle.phase`), so a run that takes long says
        // which phase took it.
        var phase = PhaseClock(test: name)
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: scale)
        phase.ended("catalogMade")
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        phase.ended("storeStarted")
        // Every backoff an owner arms is a day long (`RunningBackgroundOwners.Backoffs`): the
        // retry a failure owes (enrichment's download, the search model's load, a description)
        // never comes due inside the round, however slowly a loaded Mac runs it, so the round
        // measures only what the ring moved and the test's length is its work.
        let owners = try RunningBackgroundOwners(
            store: store,
            thumbnails: directory.appending(path: "Thumbnails", directoryHint: .isDirectory),
            account: catalog.account,
            backoffs: .beyondTheRun
        )
        await owners.start(store: store)
        phase.ended("ownersStarted")
        let settled = try await owners.untilQuiescent(store: store)
        phase.ended("settled")

        let before = store.use()
        for owner in await owners.quiescentOwners() {
            await owner.ringIdle()
        }
        let rung = try await owners.untilQuiescent(store: store)
        phase.ended("rung")
        // A wake an owner named when it settled that came due within the round would be an
        // input, not idle work: none may, which the deadlines the owners named say.
        let due = OwnerRound.dueWakes(settled, by: .now)
        #expect(due.isEmpty, "named wakes came due within the round: \(due)")
        let idle = IdleUse(from: before, to: store.use())
        let rounds = OwnerRound.between(settled, rung)
        // Every original is dataless and no download succeeds, as on a cloud-only library: what
        // enrichment holds stays within its claim window and hand-off however many rows wait,
        // or every pass walks a growing set (ENR-009).
        let demands = await owners.enrichment.schedule.materializations.count
        let demandBound = await owners.enrichment.claimWindowLimit + owners.enrichment.handoffPolicy.globalOutstandingLimit
        // Every transaction of the session — the open, every owner's settling and the idle
        // round — is accounted to the operation that ran it (`CatalogWriter`, the lanes), so
        // the scorecard can say whose a write was.
        let unnamed = store.use().connections.holds.filter { $0.operation == CatalogConnectionActivity.unnamed }
        #expect(unnamed.isEmpty, "unnamed transactions: \(unnamed.map { "\($0.role):\($0.count)" })")
        await owners.shutdown()
        await store.shutdown()
        let report = "settled: \(OwnerRound.summary(settled))\nidle store: \(idle.summary)\nidle owners:\n"
            + rounds.map { "  \($0.summary)" }.joined(separator: "\n") + "\n"
        // The on-demand run at the owner's size leaves its report for the record; the suite's
        // own run says it in a failure's message.
        if name == "owner" {
            try IdleUse.write(report, named: name)
        }

        #expect(demands <= demandBound, "enrichment holds \(demands) demands, more than its window and hand-off (\(demandBound))")
        // No catalog change: a root's own state, an account's listing starting and ending, is
        // announced (`CatalogChangedRows.none`) and moves no read, once each per listing pass.
        let listings = rounds.first { $0.owner == "immichSync" }?.work.passes ?? 0
        #expect(idle.changes - idle.rootStateChanges == 0, "\(report)")
        #expect(idle.rootStateChanges <= 2 * listings, "\(idle.summary)")
        #expect(idle.writes.isEmpty, "\(idle.summary)")
        for round in rounds {
            #expect(round.work.written == 0, "\(round.summary)")
            #expect(round.work.reads <= Self.readsPerOwner, "\(round.summary)")
            #expect(round.work.rows <= Self.rowsPerOwner, "\(round.summary)")
        }
        return rounds
    }
}

/// Logs how long each phase of the guard took since the last one ended.
struct PhaseClock {
    let test: String
    private var last = ContinuousClock.now

    init(test: String) {
        self.test = test
    }

    mutating func ended(_ phase: String) {
        let now = ContinuousClock.now
        OtosLog.performance.noticeOperation("ownersIdle.phase", phase: phase, fields: [
            "test": test, "ms": "\(DiagnosticsTiming.milliseconds(last.duration(to: now)))",
        ])
        last = now
    }
}

/// One owner's idle round: what it did between two quiescent facts, and the wake it was left
/// quiet until.
struct OwnerRound {
    let owner: String
    let work: OwnerWork
    let wake: OwnerWake?

    static func between(_ settled: [OwnerQuiescence], _ rung: [OwnerQuiescence]) -> [OwnerRound] {
        let before = Dictionary(settled.map { ($0.owner, $0.work) }, uniquingKeysWith: { first, _ in first })
        return rung.map { fact in
            OwnerRound(owner: fact.owner, work: fact.work - (before[fact.owner] ?? OwnerWork()), wake: fact.wake)
        }
    }

    /// The owners whose named wake, armed when they settled, is due by `instant`: each as
    /// `owner:wake`. A wake still ahead of `instant` cannot have moved anything before it.
    static func dueWakes(_ settled: [OwnerQuiescence], by instant: ContinuousClock.Instant) -> [String] {
        settled.compactMap { fact in
            guard let wake = fact.wake, let at = wake.at, at <= instant else { return nil }
            return "\(fact.owner):\(wake.kind.rawValue)"
        }
    }

    static func summary(_ facts: [OwnerQuiescence]) -> String {
        facts.map { "\($0.owner)(wake=\($0.wake.map(\.description) ?? "none"))" }.joined(separator: " ")
    }

    var summary: String {
        "\(owner): \(work) quietUntil=\(wake.map(\.description) ?? "anInput")"
    }
}

/// What the Store did between two of its use checkpoints.
struct IdleUse {
    let changes: Int
    /// Changes that named a root's own state alone (`CatalogChangedRows.none`).
    let rootStateChanges: Int
    let changeFacts: [String: Int]
    /// Write transactions by operation.
    let writes: [String: Int]
    /// Read transactions by operation.
    let reads: [String: Int]

    init(from before: CatalogStoreUse, to after: CatalogStoreUse) {
        changes = after.changes.notifications - before.changes.notifications
        rootStateChanges = after.changes.rootState - before.changes.rootState
        changeFacts = after.changes.byFact.reduce(into: [:]) { facts, fact in
            let count = fact.value - (before.changes.byFact[fact.key] ?? 0)
            if count > 0 {
                facts[fact.key] = count
            }
        }
        let earlier = Dictionary(
            before.connections.holds.map { ("\($0.role)|\($0.operation)", $0.count) }, uniquingKeysWith: +
        )
        var writes: [String: Int] = [:]
        var reads: [String: Int] = [:]
        for hold in after.connections.holds {
            let count = hold.count - (earlier["\(hold.role)|\(hold.operation)"] ?? 0)
            guard count > 0 else { continue }
            if hold.role.hasSuffix("writer") {
                writes[hold.operation, default: 0] += count
            } else {
                reads[hold.operation, default: 0] += count
            }
        }
        self.writes = writes
        self.reads = reads
    }

    var summary: String {
        func list(_ counts: [String: Int]) -> String {
            counts.isEmpty ? "none" : counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        }
        return "changes=\(changes) rootState=\(rootStateChanges) facts=\(list(changeFacts)) writes=\(list(writes)) reads=\(list(reads))"
    }

    static func write(_ text: String, named name: String) throws {
        let url = SourceTree.root.appending(path: "build/background-owners-idle/\(name).txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
