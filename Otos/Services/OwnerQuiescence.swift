import Foundation
import OSLog
import Synchronization

// Owner quiescence guide (ADR 0032 rule 8, ADR 0033)
//
// A background owner is quiescent when it owes nothing and runs nothing: every request it
// took is covered by a pass that succeeded, no pass is running, it has acted on every Store
// change delivered to it, and it holds no work in flight of its own (a claim being read, a
// transfer, an apply). That is state the owner already holds, so it is reported as a fact
// (`OwnerQuiescence`), and awaited until it holds (`QuiescentOwner.untilQuiescent()`): a
// waiter is resumed in the synchronous step that makes the fact true, never by a timer.
//
// An owner that keeps a wake armed while it owes nothing now — a backoff after a failure, a
// retry pacing, a poll, a cadence — is still quiescent, and says which wake and when
// (`OwnerWake`): a caller asserts "quiet until that deadline" rather than waiting it out.
//
// What an owner did is counted in its own units (`OwnerWork`): passes started, reads it
// issued, rows those reads returned, rows it wrote. A caller compares two facts to see what
// one more round of its wake path cost.
//
// `OwnerActivity` is the bookkeeping every owner shares: the request revision, the pass in
// flight, the Store changes delivered against those acted on, the armed wake, the work
// tally and the waiters. It is a non-Sendable class held by its owner and used only on that
// owner's isolation; only its `deliveries` counter, which the Store increments as it yields,
// crosses. `BackgroundOwnerQuiescence.untilQuiescent(_:store:)` waits for several owners to
// be quiescent at one instant, which no single owner can say.

/// Requests made from outside an owner's isolation (a `nonisolated` doorbell), counted in the
/// step that rings: the owner compares the count with what it has taken up, which the stream
/// alone cannot say.
final nonisolated class RequestCount: Sendable {
    private let count = Mutex<UInt64>(0)

    var value: UInt64 {
        count.withLock { $0 }
    }

    func record() {
        count.withLock { $0 &+= 1 }
    }
}

/// A wake an owner keeps armed while it owes nothing now.
nonisolated struct OwnerWake: Equatable, Sendable, CustomStringConvertible {
    nonisolated enum Kind: String, Sendable {
        /// The pause after a failure before it tries again (`time: backoff`).
        case backoff
        /// A server polled because nothing reports its changes (`time: poll`).
        case poll
        /// A publication cadence that rings only when work is owed (`time: cadence`).
        case cadence
    }

    let kind: Kind
    /// When it rings; nil for a cadence, which rings every tick and finds nothing owed.
    let at: ContinuousClock.Instant?

    var description: String {
        guard let at else { return kind.rawValue }
        return "\(kind.rawValue)+\(DiagnosticsTiming.milliseconds(ContinuousClock.now.duration(to: at)))ms"
    }
}

/// What an owner has done since it was made, in its own units. Cumulative: a caller subtracts
/// two to see one round's cost.
nonisolated struct OwnerWork: Equatable, Sendable, CustomStringConvertible {
    /// Passes started.
    var passes = 0
    /// Reads the owner issued: a candidate page, a keyed read, a claim query.
    var reads = 0
    /// Rows those reads returned.
    var rows = 0
    /// Rows or results the owner wrote (a write of none is not counted).
    var written = 0

    static func - (lhs: OwnerWork, rhs: OwnerWork) -> OwnerWork {
        OwnerWork(
            passes: lhs.passes - rhs.passes, reads: lhs.reads - rhs.reads,
            rows: lhs.rows - rhs.rows, written: lhs.written - rhs.written
        )
    }

    var description: String {
        "passes=\(passes) reads=\(reads) rows=\(rows) written=\(written)"
    }
}

/// An owner's quiescence: it owes nothing and runs nothing, as of the step that reported it.
nonisolated struct OwnerQuiescence: Equatable, Sendable {
    let owner: String
    /// The wake still armed, if any: the owner is quiet until it rings.
    let wake: OwnerWake?
    /// Moves with every input the owner took — a request, a Store change acted on — so two
    /// facts with one revision say nothing reached it between them.
    let revision: UInt64
    let work: OwnerWork
}

/// The bookkeeping behind an owner's quiescence (see the guide). Used only on its owner's
/// isolation.
final nonisolated class OwnerActivity {
    let owner: String
    /// Counted by the Store in the step it yields each change to this owner's subscription
    /// (`CatalogStore.changeNotifications(deliveries:)`).
    let deliveries = CatalogStore.DeliveryCount()
    /// Requests taken (ADR 0032 rule 2): bumped by `request()`, never cleared.
    private(set) var requested: UInt64 = 0
    /// The request the last pass that succeeded answered.
    private(set) var covered: UInt64 = 0
    /// Passes running: a count, so a pass that ends after teardown restarted the loop cannot
    /// mask a live one.
    private(set) var running = 0
    /// Inputs an owner with its own request counters took (`noteInput()`).
    private var inputs: UInt64 = 0
    private var changesActedOn: UInt64 = 0
    /// The wake the owner keeps armed while it owes nothing now.
    var wake: OwnerWake?
    var work = OwnerWork()
    private var waiters: [UUID: CheckedContinuation<OwnerQuiescence, any Error>] = [:]

    init(owner: String) {
        self.owner = owner
    }

    /// Records a request and returns its revision.
    @discardableResult
    func request() -> UInt64 {
        requested &+= 1
        return requested
    }

    /// Whether a request is not yet covered.
    var isOwed: Bool {
        requested != covered
    }

    /// An input to an owner that counts its own requests.
    func noteInput() {
        inputs &+= 1
    }

    /// A pass starts: returns the request it answers.
    @discardableResult
    func beginPass() -> UInt64 {
        running += 1
        work.passes += 1
        return requested
    }

    /// A pass ends; it covers `request` when it succeeded, nothing when it failed, so a failed
    /// pass leaves its request owed (ADR 0032 rule 4).
    func endPass(covering request: UInt64?) {
        running -= 1
        if let request {
            covered = max(covered, request)
        }
    }

    /// A Store change delivered to this owner has been acted on.
    func actedOnChange() {
        changesActedOn &+= 1
    }

    func read(rows: Int) {
        work.reads += 1
        work.rows += rows
    }

    func wrote(_ count: Int) {
        work.written += count
    }

    /// The fact, when the owner holds no other work (`holdsWork`) and this bookkeeping owes
    /// nothing.
    func quiescence(holdsWork: Bool) -> OwnerQuiescence? {
        guard !holdsWork, requested == covered, running == 0, changesActedOn == deliveries.delivered else {
            return nil
        }
        return OwnerQuiescence(owner: owner, wake: wake, revision: requested &+ inputs &+ changesActedOn, work: work)
    }

    /// Resumes every waiter when the fact holds. The owner calls it after each step that can
    /// make it hold: a pass ends, a change is acted on, work in flight returns.
    func settle(holdsWork: Bool) {
        guard !waiters.isEmpty, let fact = quiescence(holdsWork: holdsWork) else { return }
        let resumed = waiters
        waiters = [:]
        for waiter in resumed.values {
            waiter.resume(returning: fact)
        }
    }

    func addWaiter(_ id: UUID, _ continuation: CheckedContinuation<OwnerQuiescence, any Error>) {
        waiters[id] = continuation
    }

    func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

/// A background owner that reports its quiescence (see the guide).
nonisolated protocol QuiescentOwner: Actor {
    var activity: OwnerActivity { get }
    /// Work in flight the owner holds beyond its passes (a claim being read, a transfer, an
    /// apply). False for an owner whose passes are all its work.
    var holdsWork: Bool { get }
    /// Rings the owner's wake path once, as an input it reads would, with no input changed:
    /// what a caller runs to see that a wake with nothing new costs nothing. An owner with no
    /// wake path (one pass a launch) does nothing.
    func ringIdle()
}

extension QuiescentOwner {
    var holdsWork: Bool {
        false
    }

    /// The fact now, or nil while the owner owes or runs something.
    var quiescence: OwnerQuiescence? {
        activity.quiescence(holdsWork: holdsWork)
    }

    /// Resumes the waiters when the fact now holds.
    func settleQuiescence() {
        activity.settle(holdsWork: holdsWork)
    }

    /// Returns once the owner is quiescent: at once when it is, else in the step that makes it
    /// so. Throws `CancellationError` when the caller's task is cancelled first.
    func untilQuiescent() async throws -> OwnerQuiescence {
        if let fact = quiescence {
            return fact
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                activity.addWaiter(id, continuation)
            }
        } onCancel: {
            Task { await self.cancelQuiescenceWaiter(id) }
        }
    }

    private func cancelQuiescenceWaiter(_ id: UUID) {
        activity.cancelWaiter(id)
    }
}

/// Waits for several owners to be quiescent at one instant.
nonisolated enum BackgroundOwnerQuiescence {
    /// Returns every owner's fact once all of them hold at one instant: each is awaited in
    /// turn, then each is read again; when every second reading holds with the revision of
    /// the first and the Store announced nothing between, every owner was quiescent, and
    /// took no input, from the last first reading to the first second one. Otherwise an
    /// owner moved, and the round is run again on what moved it: no time is waited.
    static func untilQuiescent(_ owners: [any QuiescentOwner], store: CatalogStore) async throws -> [OwnerQuiescence] {
        while true {
            let changes = store.use().changes.notifications
            var first: [OwnerQuiescence] = []
            for owner in owners {
                try await first.append(owner.untilQuiescent())
            }
            var second: [OwnerQuiescence] = []
            for owner in owners {
                guard let fact = await owner.quiescence else { break }
                second.append(fact)
            }
            if second.map(\.revision) == first.map(\.revision), store.use().changes.notifications == changes {
                return second
            }
        }
    }

    /// `op=owners.quiescent`: when every owner first owed nothing, from the launch, with each
    /// one's armed wake and work.
    static func log(_ facts: [OwnerQuiescence], sinceLaunch started: ContinuousClock.Instant) {
        var fields = ["ms": "\(DiagnosticsTiming.milliseconds(since: started))", "owners": "\(facts.count)"]
        for fact in facts {
            fields[fact.owner] = "wake=\(fact.wake.map(\.description) ?? "none"),\(fact.work)"
                .replacingOccurrences(of: " ", with: ",")
        }
        OtosLog.performance.noticeOperation("owners.quiescent", phase: "reached", fields: fields)
    }
}
