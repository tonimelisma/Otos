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
// An owner that works a backlog — a walk over the library's owed rows, such as enrichment's
// hashing and downloads of rows off screen, the search index's embeddings and texts, the
// descriptions — reports so itself (`QuiescentOwner.worksBacklog`): everything it owes, runs
// and holds is that walk, and no request waits on anything else. On a large cloud library the
// walk lasts hours, so a session may never see the owner quiescent; it is settled
// (`settledFact`): quiescent, or working only its backlog. Quiescence is never relaxed by it.
//
// A request covered is the third fact (`untilCovered(_:)`, ADR 0032 rule 2): the pass that
// answered that request succeeded, whatever was asked since. It is monotone, so a caller that
// needs one build — the duplicate groups the launch owed — waits on it rather than on the
// owner owing nothing, which a stream of later requests can put off for the whole session.
//
// Caught up to a moment is the fourth (`untilCaughtUp(throughDelivery:)`): the owner acted on
// the Store changes yielded to it by then and covered every request it had taken after them
// (`owedMark`, `covers(_:)`), or it is settled. Also monotone: while a backlog writes, the
// owners that read what it writes are asked again and again and are rarely all settled at one
// instant, but each covers what it owed at a moment. That is what a launch's settlement waits
// for (`LaunchSettlement.launchWork`), and a session that changed the catalog after its launch
// (`CatalogWindowViewModel.untilOwnersCaughtUp()`).
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
/// As a settled fact (`settledFact`) it may instead say the owner was working only its
/// backlog (`backlog`).
nonisolated struct OwnerQuiescence: Equatable, Sendable {
    let owner: String
    /// The wake still armed, if any: the owner is quiet until it rings.
    let wake: OwnerWake?
    /// Moves with every input the owner took — a request, a Store change acted on — so two
    /// facts with one revision say nothing reached it between them.
    let revision: UInt64
    let work: OwnerWork
    /// The owner was not quiescent but working only its backlog (`QuiescentOwner.worksBacklog`):
    /// its revision moves with that work, so it says nothing about the instant. Only a settled
    /// fact is one.
    var backlog = false
}

/// One owner caught up to a moment (`QuiescentOwner.untilCaughtUp`): `backlog` when it was by
/// working only its backlog rather than by covering what it owed.
nonisolated struct OwnerCaughtUp: Equatable, Sendable {
    let owner: String
    let backlog: Bool
}

/// How far a launch's background work has settled, each stage reached after the one before
/// (`CatalogWindowViewModel`'s owner start): each names only what its consumer needs, and each
/// is reachable on a library whose enrichment, search index and descriptions work a backlog
/// for hours.
///
/// - `duplicatesBuilt`: the duplicate groups the launch owed are built and published — the
///   duplicates owner covered its launch request (`DuplicatesProjection.untilLaunchBuildPublished`),
///   whatever enrichment's digests ask of it later. What the tour's Duplicates step waits on,
///   with the window showing them.
/// - `launchWork`: every owner caught up to the moment all of them had started
///   (`BackgroundOwnerQuiescence.untilCaughtUp`): the requests owed then are covered, or the
///   owner works only its backlog (`QuiescentOwner.worksBacklog`), while a backlog and what it
///   asks of the owners after it may still be owed. What a settled tour waits on: a person's
///   session meets the window with the backlogs still walking.
/// - `ownersQuiescent`: every owner quiescent at one instant: nothing is owed anywhere.
nonisolated enum LaunchSettlement: String, Sendable, Comparable {
    case duplicatesBuilt
    case launchWork
    case ownersQuiescent

    private var stage: Int {
        switch self {
        case .duplicatesBuilt: 0
        case .launchWork: 1
        case .ownersQuiescent: 2
        }
    }

    static func < (lhs: LaunchSettlement, rhs: LaunchSettlement) -> Bool {
        lhs.stage < rhs.stage
    }
}

/// What an owner holds at one instant, quiescent or not: what a session that ends before its
/// owners settle reports for each (`op=owners.status`), so "never quiescent" names the owner
/// and what it was doing rather than a dash.
nonisolated struct OwnerStatus: Equatable, Sendable {
    let owner: String
    /// Requests taken that no successful pass has answered yet.
    let owedRequests: UInt64
    /// Passes running now: a long walk (a backlog of descriptions or text to read) is one pass
    /// from its first page to its last.
    let runningPasses: Int
    /// Store changes delivered to it that it has not acted on yet.
    let unactedChanges: UInt64
    /// Work in flight of its own beyond its passes (a claim being read, a transfer, an apply).
    let holdsWork: Bool
    /// Everything it owes, runs and holds is its backlog (`QuiescentOwner.worksBacklog`).
    var worksBacklog = false
    let wake: OwnerWake?
    let work: OwnerWork

    var isQuiescent: Bool {
        owedRequests == 0 && runningPasses == 0 && unactedChanges == 0 && !holdsWork
    }

    /// The log fields of one owner that is not quiescent.
    var fields: [String: String] {
        [
            "owner": owner, "owedRequests": "\(owedRequests)", "runningPasses": "\(runningPasses)",
            "unactedChanges": "\(unactedChanges)", "holdsWork": "\(holdsWork)", "backlog": "\(worksBacklog)",
            "wake": wake.map(\.description) ?? "none", "passes": "\(work.passes)", "reads": "\(work.reads)",
            "rows": "\(work.rows)", "written": "\(work.written)",
        ]
    }
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
    private var waiters: [UUID: (wait: OwnerWait, continuation: CheckedContinuation<OwnerQuiescence?, any Error>)] = [:]

    /// The first request an owner takes: what an owner whose launch asks it once names as the
    /// launch's request.
    static let firstRequest: UInt64 = 1

    init(owner: String) {
        self.owner = owner
    }

    /// Nothing owed or running and every delivered Store change acted on: quiescent but for
    /// the work an owner holds beyond its passes.
    var owesNothing: Bool {
        requested == covered && running == 0 && actedOnEveryChange
    }

    /// Every Store change delivered to this owner has been acted on.
    var actedOnEveryChange: Bool {
        changesActedOn == deliveries.delivered
    }

    /// Whether the pass that answered `request` succeeded.
    func hasCovered(_ request: UInt64) -> Bool {
        covered >= request
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
        guard !holdsWork, owesNothing else {
            return nil
        }
        return OwnerQuiescence(owner: owner, wake: wake, revision: requested &+ inputs &+ changesActedOn, work: work)
    }

    /// The settled fact: quiescence, or, when the owner says everything it owes, runs and
    /// holds is its backlog (`worksBacklog`), a fact that says so.
    func settled(holdsWork: Bool, worksBacklog: Bool) -> OwnerQuiescence? {
        if let fact = quiescence(holdsWork: holdsWork) {
            return fact
        }
        guard worksBacklog else {
            return nil
        }
        return OwnerQuiescence(
            owner: owner, wake: wake, revision: requested &+ inputs &+ changesActedOn, work: work, backlog: true
        )
    }

    /// What the owner holds now, quiescent or not.
    func status(holdsWork: Bool, worksBacklog: Bool = false) -> OwnerStatus {
        let delivered = deliveries.delivered
        return OwnerStatus(
            owner: owner,
            owedRequests: requested &- covered,
            runningPasses: running,
            unactedChanges: delivered > changesActedOn ? delivered - changesActedOn : 0,
            holdsWork: holdsWork,
            worksBacklog: worksBacklog,
            wake: wake,
            work: work
        )
    }

    /// Resumes every waiter whose fact holds. The owner calls it after each step that can
    /// make one hold: a pass ends, a change is acted on, work in flight returns, a backlog
    /// walk begins.
    func settle(holdsWork: Bool, worksBacklog: Bool = false, covers: (OwnerMark) -> Bool) {
        for (id, waiter) in waiters {
            guard let fact = fact(for: waiter.wait, holdsWork: holdsWork, worksBacklog: worksBacklog, covers: covers) else {
                continue
            }
            waiters[id] = nil
            waiter.continuation.resume(returning: fact)
        }
    }

    /// The fact `wait` asks for now, if it holds: `.some(nil)` for a request covered, a change
    /// count acted on, or a mark caught up to by covering it.
    func fact(
        for wait: OwnerWait, holdsWork: Bool, worksBacklog: Bool, covers: (OwnerMark) -> Bool
    ) -> OwnerQuiescence?? {
        switch wait {
        case .quiescent:
            quiescence(holdsWork: holdsWork).map { .some($0) }
        case .settled:
            settled(holdsWork: holdsWork, worksBacklog: worksBacklog).map { .some($0) }
        case let .covered(request):
            hasCovered(request) ? .some(nil) : nil
        case let .actedOn(delivered):
            changesActedOn >= delivered ? .some(nil) : nil
        case let .caughtUp(mark):
            if covers(mark) {
                .some(nil)
            } else {
                settled(holdsWork: holdsWork, worksBacklog: worksBacklog).map { .some($0) }
            }
        }
    }

    /// Every request taken so far, as a mark (`QuiescentOwner.owedMark`'s default).
    var requestMark: OwnerMark {
        OwnerMark([requested])
    }

    func addWaiter(_ id: UUID, for wait: OwnerWait, _ continuation: CheckedContinuation<OwnerQuiescence?, any Error>) {
        waiters[id] = (wait, continuation)
    }

    func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

/// What a caller waits for an owner to report (see the guide).
nonisolated enum OwnerWait: Equatable, Sendable {
    /// It owes nothing and runs nothing.
    case quiescent
    /// It is quiescent, or working only its backlog.
    case settled
    /// The pass answering this request succeeded.
    case covered(UInt64)
    /// It has acted on this many Store changes delivered to it.
    case actedOn(UInt64)
    /// Every request in this mark is covered (`QuiescentOwner.covers(_:)`), or it is settled.
    case caughtUp(OwnerMark)
}

/// What an owner owed at one moment: its request revision of each kind it counts (most count
/// one; the projection counts its publications and its options reads apart). Covering a mark
/// is monotone: requests taken after it never put it off.
nonisolated struct OwnerMark: Equatable, Sendable {
    let revisions: [UInt64]

    init(_ revisions: [UInt64]) {
        self.revisions = revisions
    }
}

/// A background owner that reports its quiescence (see the guide).
nonisolated protocol QuiescentOwner: Actor {
    var activity: OwnerActivity { get }
    /// Work in flight the owner holds beyond its passes (a claim being read, a transfer, an
    /// apply). False for an owner whose passes are all its work.
    var holdsWork: Bool { get }
    /// Whether everything the owner owes, runs and holds now is its backlog: a walk over the
    /// library's owed rows that a session on a large library may never see end, with no
    /// request waiting on anything else (see the guide). The owner says so from its own state,
    /// and calls `settleQuiescence()` in the step that makes it true. False for an owner with
    /// no backlog: all its work is what it was asked.
    var worksBacklog: Bool { get }
    /// Rings the owner's wake path once, as an input it reads would, with no input changed:
    /// what a caller runs to see that a wake with nothing new costs nothing. An owner with no
    /// wake path (one pass a launch) does nothing.
    func ringIdle()
    /// Every request the owner has taken, as a mark `covers(_:)` later answers. The default
    /// is its activity's request revision; an owner that counts its requests itself says so.
    var owedMark: OwnerMark { get }
    /// Whether a pass that succeeded has answered every request in `mark`, and nothing the
    /// owner holds beyond what its mark counts is in flight.
    func covers(_ mark: OwnerMark) -> Bool
}

extension QuiescentOwner {
    var holdsWork: Bool {
        false
    }

    var worksBacklog: Bool {
        false
    }

    var owedMark: OwnerMark {
        activity.requestMark
    }

    /// The activity's request in `mark` covered, and no work of the owner's own in flight
    /// (`holdsWork`: a claim, a transfer, a preparation), which its request revision does not
    /// count. An owner on its backlog is caught up by being settled instead.
    func covers(_ mark: OwnerMark) -> Bool {
        !holdsWork && (mark.revisions.first.map { activity.hasCovered($0) } ?? true)
    }

    /// Store changes delivered to this owner so far.
    var deliveredChanges: UInt64 {
        activity.deliveries.delivered
    }

    /// The fact now, or nil while the owner owes or runs something.
    var quiescence: OwnerQuiescence? {
        activity.quiescence(holdsWork: holdsWork)
    }

    /// The settled fact now: quiescence, or one that says the owner works only its backlog.
    var settledFact: OwnerQuiescence? {
        activity.settled(holdsWork: holdsWork, worksBacklog: worksBacklog)
    }

    /// What the owner holds now, quiescent or not.
    var status: OwnerStatus {
        activity.status(holdsWork: holdsWork, worksBacklog: worksBacklog)
    }

    /// Resumes the waiters whose fact now holds.
    func settleQuiescence() {
        activity.settle(holdsWork: holdsWork, worksBacklog: worksBacklog) { covers($0) }
    }

    /// Returns once the owner is quiescent: at once when it is, else in the step that makes it
    /// so. Throws `CancellationError` when the caller's task is cancelled first.
    func untilQuiescent() async throws -> OwnerQuiescence {
        try await until(.quiescent) ?? quiescenceMissing()
    }

    /// Returns once the owner has caught up to a moment: it has acted on the `delivered` Store
    /// changes the Store had yielded to it by then, and then covered every request it had taken
    /// (`owedMark`, read once those are acted on), or it is settled: quiescent, or working only
    /// its backlog. Monotone, so requests taken later never put it off. Says whether the owner
    /// was caught up by working its backlog.
    func untilCaughtUp(throughDelivery delivered: UInt64) async throws -> OwnerCaughtUp {
        _ = try await until(.actedOn(delivered))
        let fact = try await until(.caughtUp(owedMark))
        return OwnerCaughtUp(owner: activity.owner, backlog: fact?.backlog == true)
    }

    /// Returns once the pass answering `request` has succeeded, whatever was asked since.
    func untilCovered(_ request: UInt64) async throws {
        _ = try await until(.covered(request))
    }

    private func quiescenceMissing() -> OwnerQuiescence {
        preconditionFailure("a quiescent or settled wait resumes with its fact")
    }

    private func until(_ wait: OwnerWait) async throws -> OwnerQuiescence? {
        if let fact = activity.fact(for: wait, holdsWork: holdsWork, worksBacklog: worksBacklog, covers: { covers($0) }) {
            return fact
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                activity.addWaiter(id, for: wait, continuation)
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

    /// Returns once every owner has caught up to the moment of the call
    /// (`QuiescentOwner.untilCaughtUp`): taken up the Store changes yielded to it by then and
    /// covered the requests it owed after them, or settled, an owner on its backlog among them.
    /// The delivery counts are read first, for every owner; the owners are then waited on in
    /// turn, in their start order, so a request one makes of a later one while answering its
    /// own (the projection of the duplicates owner, enrichment's writes of the walkers) is taken
    /// before the later one's mark is read. Every fact is monotone, so this is reached while a
    /// backlog's writes keep asking the owners after it for more, which no single instant at
    /// which all of them are settled is on a library whose enrichment backlog lasts hours.
    static func untilCaughtUp(_ owners: [any QuiescentOwner]) async throws -> [OwnerCaughtUp] {
        var delivered: [UInt64] = []
        for owner in owners {
            await delivered.append(owner.deliveredChanges)
        }
        var caughtUp: [OwnerCaughtUp] = []
        for (owner, count) in zip(owners, delivered) {
            try await caughtUp.append(owner.untilCaughtUp(throughDelivery: count))
        }
        return caughtUp
    }

    /// Every owner's status now, read in turn.
    static func statuses(of owners: [any QuiescentOwner]) async -> [OwnerStatus] {
        var statuses: [OwnerStatus] = []
        for owner in owners {
            await statuses.append(owner.status)
        }
        return statuses
    }

    /// `op=owners.status`: at `moment` (a session's end), how many owners were quiescent, and
    /// one `op=owners.pending` line for each that was not, with what it owed, ran and held. A
    /// session that never reported `op=owners.quiescent` is explained by these lines.
    static func logStatus(_ statuses: [OwnerStatus], moment: String) {
        let pending = statuses.filter { !$0.isQuiescent }
        OtosLog.performance.noticeOperation("owners.status", phase: moment, fields: [
            "owners": "\(statuses.count)", "quiescent": "\(statuses.count - pending.count)",
            "pending": pending.isEmpty ? "none" : pending.map(\.owner).joined(separator: ","),
        ])
        for status in pending {
            OtosLog.performance.noticeOperation("owners.pending", phase: moment, fields: status.fields)
        }
    }

    /// `op=owners.settled phase=<stage>`: when the launch first reached `stage`, from the launch,
    /// and which owners were still working their backlog then (`backlog=`, `none` when none).
    static func logSettled(_ stage: LaunchSettlement, sinceLaunch started: ContinuousClock.Instant, backlog: [String]) {
        OtosLog.performance.noticeOperation("owners.settled", phase: stage.rawValue, fields: [
            "ms": "\(DiagnosticsTiming.milliseconds(since: started))",
            "backlog": backlog.isEmpty ? "none" : backlog.joined(separator: ","),
        ])
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
