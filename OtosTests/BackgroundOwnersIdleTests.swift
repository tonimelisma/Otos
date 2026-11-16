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
            if lastWindow.changes == 0, lastWindow.writes.isEmpty {
                settledAfter = windowIndex
                break
            }
        }

        let before = store.use()
        _ = try await store.pairMirroredCopies(account: catalog.account)
        // time: measurement — the idle period (`idle`).
        try await Task.sleep(for: Self.idle)
        let idle = IdleUse(from: before, to: store.use())
        // Every original is dataless and no download succeeds, as on a cloud-only library: what
        // enrichment holds stays within its claim window and hand-off however many rows wait,
        // or every pass walks a growing set (ENR-009).
        let demands = await owners.enrichment.schedule.materializations.count
        let demandBound = await owners.enrichment.claimWindowLimit + owners.enrichment.handoffPolicy.globalOutstandingLimit
        await owners.shutdown()
        await store.shutdown()
        try IdleUse.write(
            "settledAfter=\(settledAfter.map(String.init) ?? "never") lastSettleWindow: \(lastWindow.summary)\nidle: \(idle.summary)\n"
        )

        #expect(demands <= demandBound, "enrichment holds \(demands) demands, more than its window and hand-off (\(demandBound))")
        #expect(settledAfter != nil, "never a quiet window: \(lastWindow.summary)")
        #expect(idle.changes == 0, "\(idle.summary)")
        #expect(idle.writes.isEmpty, "\(idle.summary)")
        let heavy = idle.reads.filter { $0.value > Self.readsPerOperation }
        #expect(heavy.isEmpty, "\(idle.summary)")
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
