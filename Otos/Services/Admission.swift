import Foundation
import Synchronization

/// One ask an admission machine decides: numbered by its shell (`Admission`) in the order
/// asked.
typealias AdmissionRequest = UInt64

/// A pure machine that decides which asks run and which wait (ADR 0032's second shape):
/// `handle(_:)` is the only writer of its state and returns what the shell must do. Its own
/// events (a load admission's `open`, `want` and `shutdown`) travel beside the three every
/// machine answers: an ask, a waiter that stopped waiting, and a granted ask that ended.
nonisolated protocol AdmissionMachine: Sendable {
    associatedtype Ask: Sendable
    associatedtype Event: Sendable
    associatedtype Effect: Sendable

    static func requested(_ request: AdmissionRequest, _ ask: Ask) -> Event
    /// The asker's task was cancelled while it waited: a waiting request is dropped.
    static func withdrawn(_ request: AdmissionRequest) -> Event
    /// A granted request ended, however it ended.
    static func released(_ request: AdmissionRequest) -> Event
    /// The request an effect decides, and whether it may run (otherwise its asker hears
    /// `CancellationError`).
    static func resolution(of effect: Effect) -> (request: AdmissionRequest, granted: Bool)

    mutating func handle(_ event: Event) -> [Effect]
}

/// Admission guide
///
/// The one shell around an admission machine: the machine and every waiter's continuation
/// live in one `Mutex`, a machine step and the continuations its effects name are taken in
/// one hold of the lock, and a continuation is resumed only after the lock is released, so
/// no event falls between a decision and the waiter it names and no lock is held across an
/// await. A waiter whose task is cancelled withdraws at once and hears `CancellationError`.
/// Two machines use it: `LoadAdmissionMachine`, which runs heavy background loads one at a
/// time (`LoadAdmission`), and `ReadAdmissionMachine`, which admits the catalog's background
/// reads a few at a time (`CatalogReadAdmission`).
///
/// A granted request holds its turn until `release(_:)`, which the caller makes on every
/// exit; an admitted body never waits on another request of the same admission.
final nonisolated class Admission<Machine: AdmissionMachine>: Sendable {
    private struct State {
        var machine: Machine
        var next: AdmissionRequest = 0
        var waiters: [AdmissionRequest: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state: Mutex<State>
    /// Called with the machine after every step, inside the lock, so successive steps reach it
    /// in their order: what a shell keeps in step with the machine (`LoadAdmission` tells the
    /// background room the share a waiting load needs). It must not call this admission.
    private let afterStep: (@Sendable (Machine) -> Void)?

    init(_ machine: Machine, afterStep: (@Sendable (Machine) -> Void)? = nil) {
        state = Mutex(State(machine: machine))
        self.afterStep = afterStep
    }

    /// The machine as it is now: what a test reads to see what runs and what waits.
    var machine: Machine {
        state.withLock { $0.machine }
    }

    /// Waits until the machine grants `ask` and returns its request, which the caller
    /// releases when its work ends. Throws `CancellationError` when the caller's task is
    /// cancelled while it waits, or the machine refuses the ask.
    func admit(_ ask: Machine.Ask) async throws -> AdmissionRequest {
        let request = state.withLock { state in
            state.next &+= 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumptions = state.withLock { state in
                    state.waiters[request] = continuation
                    // Read under the lock that `onCancel` takes: a cancellation before this
                    // point is seen here, one after it finds the request waiting.
                    if Task.isCancelled {
                        return Self.take([(request, false)], from: &state)
                    }
                    return step(Machine.requested(request, ask), in: &state)
                }
                Self.resume(resumptions)
            }
        } onCancel: {
            perform(Machine.withdrawn(request))
        }
        return request
    }

    /// A granted request ended: its turn passes on.
    func release(_ request: AdmissionRequest) {
        perform(Machine.released(request))
    }

    func perform(_ event: Machine.Event) {
        Self.resume(state.withLock { step(event, in: &$0) })
    }

    /// Performs `event` and returns what `read` makes of the machine before and after it, in
    /// the same hold of the lock: a change no other event can fall inside.
    func performReading<T>(_ event: Machine.Event, _ read: (Machine, Machine) -> T) -> T {
        let (resumptions, value) = state.withLock { state in
            let before = state.machine
            let resumptions = step(event, in: &state)
            return (resumptions, read(before, state.machine))
        }
        Self.resume(resumptions)
        return value
    }

    private typealias Resumption = (continuation: CheckedContinuation<Void, any Error>, granted: Bool)

    private func step(_ event: Machine.Event, in state: inout State) -> [Resumption] {
        let resumptions = Self.take(state.machine.handle(event).map(Machine.resolution(of:)), from: &state)
        afterStep?(state.machine)
        return resumptions
    }

    private static func take(
        _ resolutions: [(request: AdmissionRequest, granted: Bool)],
        from state: inout State
    ) -> [Resumption] {
        resolutions.compactMap { resolution in
            state.waiters.removeValue(forKey: resolution.request).map { ($0, resolution.granted) }
        }
    }

    /// After the lock is released: a resumed task may ask again at once.
    private static func resume(_ resumptions: [Resumption]) {
        for resumption in resumptions {
            if resumption.granted {
                resumption.continuation.resume()
            } else {
                resumption.continuation.resume(throwing: CancellationError())
            }
        }
    }
}
