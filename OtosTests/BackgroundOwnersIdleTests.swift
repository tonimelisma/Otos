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
/// Every owner runs on a generated catalog of the owner's shape (`RunningBackgroundOwners`) until a
/// whole window passes with no change and no write, and then one more window is measured,
/// with an Immich sync's mirror pass in it as a sync would run one. What each owner did in it
/// is read from the Store's own use (`CatalogStore.use()`: transactions by connection role and
/// operation, change notifications by kind), so a failure names the operation.
@Suite(.testScope, .serialized)
struct BackgroundOwnersIdleTests {
    /// The window a quiet catalog is judged over.
    /// time: measurement — the test measures what happens while nothing is asked; no owner
    /// can report that it will do nothing more.
    static let window: Duration = .seconds(3)
    /// The measured idle period: several windows, so an owner on a timer of a few seconds is
    /// in it.
    /// time: measurement — the idle period is the quantity measured.
    static let idle: Duration = .seconds(10)
    /// How many windows the owners get to finish what the generated backlog owes them.
    static let settleWindows = 60
    /// Read transactions one operation may run in the idle period: an owner woken by the
    /// mirror pass, or by its own timer, checks what it owes once.
    static let readsPerOperation = 2

    /// Operations an owner is known to run while idle, by the owner: each is
    /// an open defect, held as a known issue so the guard still fails for any other owner.
    static let knownIdleOperations: [String: String] = [
        "claimedEnrichmentCandidates": "EnrichmentCoordinator",
        "releaseEnrichmentClaims": "EnrichmentCoordinator",
    ]

    @Test func everyBackgroundOwnerIsQuietOnceItsWorkIsDone() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 0.01)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let owners = try RunningBackgroundOwners(store: store, thumbnails: directory.appending(path: "Thumbnails", directoryHint: .isDirectory))
        await owners.start(store: store)
        // An account's sync probes for its mirrors and pairs them once a pass.
        _ = try await store.mirrorProbes(account: catalog.account)
        _ = try await store.pairMirroredCopies(account: catalog.account)

        var settledAfter: Int?
        var lastWindow = IdleUse(from: store.use(), to: store.use())
        for windowIndex in 1 ... Self.settleWindows {
            let before = store.use()
            // time: measurement — one window of the settle (`window`).
            try await Task.sleep(for: Self.window)
            lastWindow = IdleUse(from: before, to: store.use())
            if lastWindow.changes == 0, lastWindow.writes(excluding: Self.knownIdleOperations).isEmpty {
                settledAfter = windowIndex
                break
            }
        }

        let before = store.use()
        _ = try await store.pairMirroredCopies(account: catalog.account)
        // time: measurement — the idle period (`idle`).
        try await Task.sleep(for: Self.idle)
        let idle = IdleUse(from: before, to: store.use())
        await owners.shutdown()
        await store.shutdown()
        try IdleUse.write(
            "settledAfter=\(settledAfter.map(String.init) ?? "never") lastSettleWindow: \(lastWindow.summary)\nidle: \(idle.summary)\n"
        )

        #expect(settledAfter != nil, "never a quiet window: \(lastWindow.summary)")
        #expect(idle.changes == 0, "\(idle.summary)")
        #expect(idle.writes(excluding: Self.knownIdleOperations).isEmpty, "\(idle.summary)")
        let heavy = idle.reads.filter { $0.value > Self.readsPerOperation && Self.knownIdleOperations[$0.key] == nil }
        #expect(heavy.isEmpty, "\(idle.summary)")
        withKnownIssue(
            """
            Open defect, EnrichmentCoordinator: while rows it can only read after a download \
            stay owed and each download fails, it keeps cycling them through the \
            materializer: each time a request ends it claims the next page \
            (`claimedEnrichmentCandidates`, most of it routed `materializationBound`) and \
            releases what it could not admit (`releaseEnrichmentClaims`), a write transaction \
            each, while nothing changes and nothing is announced. Intermittent: the cycle runs \
            in bursts, and a measured period can fall between two of them.
            """,
            isIntermittent: true
        ) {
            let known = idle.writes.filter { Self.knownIdleOperations[$0.key] != nil }
            #expect(known.isEmpty, "\(idle.summary)")
        }
    }
}

/// What the Store did between two of its use checkpoints.
struct IdleUse {
    let changes: Int
    let changeFacts: [String: Int]
    /// Write transactions by operation.
    let writes: [String: Int]
    /// Read transactions by operation.
    let reads: [String: Int]

    init(from before: CatalogStoreUse, to after: CatalogStoreUse) {
        changes = after.changes.notifications - before.changes.notifications
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

    /// The write transactions of every operation but `known`'s.
    func writes(excluding known: [String: String]) -> [String: Int] {
        writes.filter { known[$0.key] == nil }
    }

    var summary: String {
        func list(_ counts: [String: Int]) -> String {
            counts.isEmpty ? "none" : counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        }
        return "changes=\(changes) facts=\(list(changeFacts)) writes=\(list(writes)) reads=\(list(reads))"
    }

    static func write(_ text: String) throws {
        let url = SourceTree.root.appending(path: "build/background-owners-idle/idle.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
