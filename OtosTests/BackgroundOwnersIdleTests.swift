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
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: scale)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let owners = try RunningBackgroundOwners(
            store: store,
            thumbnails: directory.appending(path: "Thumbnails", directoryHint: .isDirectory),
            account: catalog.account
        )
        await owners.start(store: store)
        let settled = try await owners.untilQuiescent(store: store)

        let before = store.use()
        for owner in await owners.quiescentOwners() {
            await owner.ringIdle()
        }
        let rung = try await owners.untilQuiescent(store: store)
        let idle = IdleUse(from: before, to: store.use())
        let rounds = OwnerRound.between(settled, rung)
        // Every original is dataless and no download succeeds, as on a cloud-only library: what
        // enrichment holds stays within its claim window and hand-off however many rows wait,
        // or every pass walks a growing set (ENR-009).
        let demands = await owners.enrichment.schedule.materializations.count
        let demandBound = await owners.enrichment.claimWindowLimit + owners.enrichment.handoffPolicy.globalOutstandingLimit
        await owners.shutdown()
        await store.shutdown()
        try IdleUse.write(
            "settled: \(OwnerRound.summary(settled))\nidle store: \(idle.summary)\nidle owners:\n"
                + rounds.map { "  \($0.summary)" }.joined(separator: "\n") + "\n",
            named: name
        )

        #expect(demands <= demandBound, "enrichment holds \(demands) demands, more than its window and hand-off (\(demandBound))")
        // No catalog change: a root's own state, an account's listing starting and ending, is
        // announced (`CatalogChangedRows.none`) and moves no read, once each per listing pass.
        let listings = rounds.first { $0.owner == "immichSync" }?.work.passes ?? 0
        #expect(idle.changes - idle.rootStateChanges == 0, "\(idle.summary)")
        #expect(idle.rootStateChanges <= 2 * listings, "\(idle.summary)")
        #expect(idle.writes.isEmpty, "\(idle.summary)")
        let libraries = [catalog.pictures, catalog.archive].count
        for round in rounds {
            let check = {
                #expect(round.work.written == 0, "\(round.summary)")
                #expect(round.work.reads <= Self.readsPerOwner, "\(round.summary)")
                #expect(round.work.rows <= Self.rowsPerOwner + IdleBound.rows(of: round.owner, libraries: libraries), "\(round.summary)")
            }
            if let known = KnownIdleIssue.of(round.owner) {
                withKnownIssue(Comment(rawValue: known.reason), isIntermittent: known.isIntermittent, check)
            } else {
                check()
            }
        }
        return rounds
    }
}

/// Rows an owner's idle round reads that are owed though nothing new arrived, with why.
enum IdleBound {
    /// An account's sync reads one mirror probe per fixed library each pass (ADR 0054): a
    /// library's files gain the digests a mirror is learned from as enrichment hashes them,
    /// which no listing reports to the sync, so each pass asks.
    static func rows(of owner: String, libraries: Int) -> Int {
        owner == "immichSync" ? libraries : 0
    }
}

/// What an owner is known to do in the idle round, named so a fix shows as a known issue no
/// longer recorded (figures at 1% / the owner's size).
enum KnownIdleIssue: String {
    case peopleGallery, materialization

    /// What the owner does in the idle round.
    var reason: String {
        switch self {
        case .peopleGallery: "peopleGallery reads the gallery again on its own ring with nothing new (7 / 748 rows)"
        case .materialization:
            "materialization admits the downloads enrichment's retries hand it when their backoff comes due within the round "
                + "(37 at the owner's size)"
        }
    }

    static func of(_ owner: String) -> KnownIdleIssue? {
        KnownIdleIssue(rawValue: owner)
    }

    /// Whether it is recorded depends on a backoff coming due within the round.
    var isIntermittent: Bool {
        self == .materialization
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
