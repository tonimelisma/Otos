import AppKit
import Foundation
@testable import OtosKit
import Synchronization

extension MaterializationResult {
    static var testMaterialized: MaterializationResult {
        MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 0)
    }
}

enum AsyncTestTimeoutError: Error, CustomStringConvertible {
    case streamEnded(String)

    var description: String {
        switch self {
        case let .streamEnded(label):
            "Stream ended while waiting for \(label)"
        }
    }
}

/// Runs `work`, a call that blocks its thread while other work it waits for runs elsewhere,
/// on a serial queue of its own, and suspends until it returns. The work is Vision's
/// requests and Core Image's RAW support wait, which production runs only on its owners'
/// queues (`FaceAnalyzer`, `SearchImageEmbedder`, a render lane; ADR 0032 rule 6).
///
/// A test calling it from its own body would hold a cooperative-pool thread for the whole
/// wait, and the pool has about one thread per core at a priority. On GitHub's 3-core runner
/// four such tests held every default-priority thread, so the work they waited for (Vision's
/// own queue, a `DispatchQueue.global()` block) never got a thread and no test ran at all
/// (`docs/research/2026-11-25-ci-runner-cooperative-pool-deadlock.md`). A serial queue of its
/// own gets a thread of its own, as each owner's queue does.
///
/// Swift Testing ties `#expect` and `#require` to the test's task, so `work` only makes the
/// call and returns what it reported; the test checks it after.
func offThePool<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue(label: "net.melisma.Otos.tests.blocking").async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Waits until `condition` holds, re-checking it every `interval`.
///
/// There is deliberately no deadline. A wall-clock limit on a wait for progress
/// measures machine load, not correctness: under the full parallel suite the awaited
/// work can lag for seconds, and the limit then fails a test whose state was still on
/// its way. A condition that never holds is a hang. The wait sleeps between checks, so
/// a hung test host consumes almost no CPU and `script/check.sh`'s stall detector
/// reports it. Never replace the sleep with `Task.yield()`: a spinning wait keeps the
/// host busy and hides the hang from that detector.
func waitUntil(
    every interval: Duration = .milliseconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async throws {
    try await waitForValue(every: interval) { try await condition() ? () : nil }
}

/// Waits until `produce` returns a value, re-asking every `interval`, and returns it.
/// The same no-deadline rule as `waitUntil` applies.
func waitForValue<Value>(
    every interval: Duration = .milliseconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ produce: () async throws -> Value?
) async throws -> Value {
    while true {
        if let value = try await produce() {
            return value
        }
        // time: poll — the condition is in-process state nothing reports; no deadline
        try await Task.sleep(for: interval)
    }
}

/// Suspends until everything already enqueued on the main queue has run: it enqueues
/// a marker and resumes when the marker runs, and the main queue is FIFO. Deferred
/// AppKit work (a post-layout retry, a diffable apply's completion) lands this way.
/// It suspends rather than turning a nested run loop: a test runs as a main-queue
/// job, and the main queue does not drain re-entrantly beneath one.
@MainActor
func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// Waits until the grid controller has applied `grid` — its order and its day buckets, the
/// two values a structural apply installs (`MediaGridMutationGate`), so a change of days
/// alone is waited on as surely as a reorder — with no mutation in flight, then drains the
/// main queue so the apply's completion block has run.
@MainActor
func awaitGridShows(_ controller: MediaGridViewController, _ grid: CatalogMediaGridState) async throws {
    let gate = controller.mutationGate
    try await waitUntil {
        gate.showsDisplayedOrder(grid) && gate.inFlight == .none
    }
    await drainMainQueue()
}

extension MediaGridViewController {
    /// Puts `next` on screen synchronously, the way a reloading structural apply does, for
    /// a test that installs a grid without driving the mutation gate.
    func show(_ next: MediaGridStructure) {
        structure = next
        collectionView.reloadData()
    }
}

/// Suspends until the calling task is cancelled. A fake uses it for work that never
/// finishes on its own, so nothing about the fake depends on how long a test runs.
func suspendUntilCancelled() async {
    let (stream, continuation) = AsyncStream<Never>.makeStream()
    await withTaskCancellationHandler {
        for await _ in stream {}
    } onCancel: {
        continuation.finish()
    }
}

/// Waits until the projection has no pending or in-flight publication, so a test can
/// assert on a settled `orderQueryCount` without guessing a sleep duration.
func waitForProjectionQuiescence(_ projection: CatalogProjection) async throws {
    try await waitUntil { await projection.isQuiescent }
}

/// Waits until the projection is quiescent and `recorder` holds what it last published, and
/// returns what `recorder` holds. The recorder takes each state from its stream on a task of
/// its own, so a quiescent projection can have published a state the recorder has not yet
/// appended; its last value is read only once it is that publication.
///
/// Both are asked again on every look. A quiescent projection can still publish: the People
/// and duplicates owners hand it their builds whenever they finish (`publishPeople`,
/// `publishDuplicates`), which `isQuiescent` does not wait for. Waiting for the recorder to
/// hold one publication read once waits forever when such a build lands after that read: the
/// recorder's last value is then the newer state, never the one asked for.
func waitForProjectionQuiescence(
    _ projection: CatalogProjection,
    recordedBy recorder: AsyncValueRecorder<CatalogWindowState>
) async throws -> [CatalogWindowState] {
    try await waitForValue {
        guard await projection.isQuiescent else {
            return nil
        }
        let published = await projection.lastPublishedState
        let recorded = await recorder.snapshot()
        return recorded.last == published ? recorded : nil
    }
}

/// Holds work at a suspension point a test chose until the test opens the gate, so the
/// test can deliver a competing event at exactly that point instead of hoping a
/// scheduler interleaves it there.
///
/// Every `arrive()` is counted and held while the gate is closed; `open()` resumes all
/// of them and lets every later arrival straight through, so no caller is ever stranded
/// or overwritten by the next one.
actor ArrivalGate {
    private var arrivals = 0
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Records an arrival and, while the gate is closed, suspends until it opens.
    func arrive() async {
        arrivals += 1
        let reached = arrivalWaiters.filter { $0.count <= arrivals }
        arrivalWaiters.removeAll { $0.count <= arrivals }
        reached.forEach { $0.continuation.resume() }
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { held.append($0) }
    }

    var arrivalCount: Int {
        arrivals
    }

    /// Returns once `count` arrivals have reached the gate.
    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else {
            return
        }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let released = held
        held.removeAll()
        released.forEach { $0.resume() }
    }
}

actor AsyncValueRecorder<Value: Sendable> {
    private struct Waiter {
        let predicate: @Sendable ([Value]) -> Bool
        let continuation: CheckedContinuation<[Value], Never>
    }

    private var values: [Value] = []
    private var waiters: [UUID: Waiter] = [:]

    func append(_ value: Value) {
        values.append(value)
        resumeSatisfiedWaiters()
    }

    func snapshot() -> [Value] {
        values
    }

    func count() -> Int {
        values.count
    }

    func waitForValues(
        matching predicate: @escaping @Sendable ([Value]) -> Bool
    ) async -> [Value] {
        if predicate(values) {
            return values
        }

        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(predicate: predicate, continuation: continuation)
            resumeSatisfiedWaiters()
        }
    }

    private func resumeSatisfiedWaiters() {
        let satisfiedIDs = waiters.compactMap { id, waiter in
            waiter.predicate(values) ? id : nil
        }
        for id in satisfiedIDs {
            waiters.removeValue(forKey: id)?.continuation.resume(returning: values)
        }
    }
}

/// A one-shot fact a test waits on: set once, observed by every waiter, before or after.
actor ReleaseSignal {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Reports its own release. Held only by the object under test, it says when that object
/// was released: an ownership fact, not a guess about timing.
final class ReleaseSentinel: Sendable {
    private let signal: ReleaseSignal

    init(_ signal: ReleaseSignal) {
        self.signal = signal
    }

    deinit {
        let signal = signal
        Task { await signal.release() }
    }
}
