import Foundation
import Synchronization

/// What the machine and the app report about room for heavy background work: every field is
/// a fact a platform source or the app's own state reports, never a guess from time.
nonisolated struct MachineConditions: Equatable, Sendable {
    /// The system's memory-pressure level (`DispatchSource.makeMemoryPressureSource`).
    enum Memory: String, Sendable, Comparable {
        case normal
        case warning
        case critical

        private var rank: Int {
            switch self {
            case .normal: 0
            case .warning: 1
            case .critical: 2
            }
        }

        static func < (lhs: Memory, rhs: Memory) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    var memory: Memory
    /// `ProcessInfo.thermalState`.
    var thermal: ProcessInfo.ThermalState
    /// `ProcessInfo.isLowPowerModeEnabled`.
    var lowPower: Bool
    /// Otos is the active app (`NSApplication.isActive`): the person is using it.
    var userInApp: Bool

    /// A machine with room for everything: what an owner a test makes alone runs under.
    static let roomy = MachineConditions(memory: .normal, thermal: .nominal, lowPower: false, userInApp: false)

    /// Why `work` may not start now, or nil when it may (ADR 0057).
    ///
    /// - Memory at `warning` or `critical` holds every kind: each holds hundreds of megabytes
    ///   in Otos or in a process it drives, or fills the file cache with an original.
    /// - A `serious` or `critical` thermal state holds every kind: the system is throttling.
    /// - Low Power Mode holds every kind: the person asked the Mac to spend less.
    /// - A description waits while the person is in the app: each request runs the system
    ///   language model's service, about 450 MB more than at rest, beside the window.
    func hold(for work: BackgroundWork) -> BackgroundHold? {
        switch memory {
        case .critical: return .memoryCritical
        case .warning: return .memoryWarning
        case .normal: break
        }
        if thermal == .serious || thermal == .critical {
            return .thermal
        }
        if lowPower {
            return .lowPower
        }
        if work == .description, userInApp {
            return .userInApp
        }
        return nil
    }

    var logFields: [String: String] {
        [
            "memory": memory.rawValue, "thermal": SystemPressure.thermalName(thermal),
            "lowPower": "\(lowPower)", "userInApp": "\(userInApp)",
        ]
    }
}

/// A kind of heavy background work: what `BackgroundRoom` holds or lets start.
nonisolated enum BackgroundWork: String, CaseIterable, Sendable {
    /// A background download of a cloud original, for enrichment to hash and render it
    /// (`MaterializationCoordinator`, background priority). A download the person asked for
    /// (a photo opened, an export) is never held.
    case download
    /// A page of text reading in its helper process (`SearchTextReader`).
    case textReading
    /// One request to the system language model for a description (`PhotoDescriptionWriter`).
    case description
    /// A heavy background load (`LoadAdmission`, `LoadWaiter.background`): a People pass, a
    /// duplicates build, the search index's build, a mirror pairing. The load the current
    /// view needs and a load the person waits on are never held.
    case heavyLoad
}

/// Why a kind of background work is held.
nonisolated enum BackgroundHold: String, Sendable {
    case memoryWarning
    case memoryCritical
    case thermal
    case lowPower
    case userInApp
}

/// Background room guide (ADR 0057)
///
/// The one owner of whether heavy background work may start now. It holds the machine's
/// conditions as the platform reports them (`MachineConditions`: memory pressure, thermal
/// state, Low Power Mode, whether the person is in the app) and answers, for each kind of
/// work (`BackgroundWork`), whether it is held and why (`MachineConditions.hold(for:)`).
/// How many of a kind run at once stays its owner's (one description, one text-reading
/// helper, the materializer's per-root and byte caps, one heavy load); the room decides only
/// whether any new one starts.
///
/// Every owner of heavy work asks before it starts a unit: a serial owner waits in
/// `untilOpen(for:)`, which returns at once when the kind is open and otherwise in the step
/// that delivers the conditions that open it, each waiter exactly once (ADR 0032 rule 8: the
/// owner holds what blocks it and is woken by the fact that ends the wait; no timer). An
/// owner with an admission machine of its own (the materializer, `LoadAdmission`) reads
/// `hold(for:)` in its decision and is told of every change through `observe(_:)`, whose
/// handler runs synchronously in the delivering step, after the lock is released, so it
/// can ring a doorbell or perform an admission event without a hop. A unit already running
/// is not stopped by a hold, except where its owner says it can stop safely (the text reader
/// ends its helper at `critical`, its reading staying owed).
///
/// Each change logs `op=background.room phase=changed` with the conditions and, for every
/// kind, its hold or `open`, so a session's log says when and why each kind waited.
///
/// The live conditions come from `MachineConditionsMonitor`; a test delivers its own.
final nonisolated class BackgroundRoom: Sendable {
    private struct State {
        var conditions: MachineConditions
        var waiters: [UInt64: (work: BackgroundWork, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var observers: [UInt64: @Sendable () -> Void] = [:]
        var next: UInt64 = 0
        /// How many times each kind was let start, waited or not: what a test counts.
        var admitted: [BackgroundWork: Int] = [:]
        /// How many waits each kind began while held.
        var held: [BackgroundWork: Int] = [:]
    }

    private let state: Mutex<State>

    init(conditions: MachineConditions = .roomy) {
        state = Mutex(State(conditions: conditions))
    }

    var conditions: MachineConditions {
        state.withLock { $0.conditions }
    }

    /// Why `work` may not start now, or nil.
    func hold(for work: BackgroundWork) -> BackgroundHold? {
        state.withLock { $0.conditions.hold(for: work) }
    }

    /// What was let start and what waited, by kind.
    var counts: (admitted: [BackgroundWork: Int], held: [BackgroundWork: Int], waiting: [BackgroundWork: Int]) {
        state.withLock { state in
            var waiting: [BackgroundWork: Int] = [:]
            for waiter in state.waiters.values {
                waiting[waiter.work, default: 0] += 1
            }
            return (state.admitted, state.held, waiting)
        }
    }

    /// The platform's newest conditions, whole: what a test delivers.
    func deliver(_ conditions: MachineConditions) {
        update { $0 = conditions }
    }

    /// One report changes the conditions (a source changes only the field it reports).
    /// Opens every waiter whose kind they open, and tells every observer, in this step.
    func update(_ change: (inout MachineConditions) -> Void) {
        let (conditions, resumed, observers) = state.withLock { state -> (MachineConditions?, [CheckedContinuation<Void, any Error>], [@Sendable () -> Void]) in
            var conditions = state.conditions
            change(&conditions)
            guard state.conditions != conditions else { return (nil, [], []) }
            state.conditions = conditions
            let open = state.waiters.filter { conditions.hold(for: $0.value.work) == nil }
            for (key, waiter) in open {
                state.waiters[key] = nil
                state.admitted[waiter.work, default: 0] += 1
            }
            return (conditions, open.map(\.value.continuation), Array(state.observers.values))
        }
        guard let conditions else { return }
        var fields = conditions.logFields
        for work in BackgroundWork.allCases {
            fields[work.rawValue] = conditions.hold(for: work)?.rawValue ?? "open"
        }
        fields["resumed"] = "\(resumed.count)"
        OtosLog.performance.noticeOperation("background.room", phase: "changed", fields: fields)
        for continuation in resumed {
            continuation.resume()
        }
        for observer in observers {
            observer()
        }
    }

    /// Returns once `work` may start: at once when it is open, else when conditions that open
    /// it are delivered. Throws `CancellationError` when the caller's task is cancelled first.
    func untilOpen(for work: BackgroundWork) async throws {
        let key = state.withLock { state -> UInt64? in
            if state.conditions.hold(for: work) == nil {
                state.admitted[work, default: 0] += 1
                return nil
            }
            state.next &+= 1
            state.held[work, default: 0] += 1
            return state.next
        }
        guard let key else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = state.withLock { state -> (any Error)?? in
                    // Read under the lock `onCancel` takes, and again for the conditions: a
                    // delivery between the first look and here opened nothing for this key.
                    if Task.isCancelled {
                        return .some(CancellationError())
                    }
                    if state.conditions.hold(for: work) == nil {
                        state.admitted[work, default: 0] += 1
                        return .some(nil)
                    }
                    state.waiters[key] = (work, continuation)
                    return .none
                }
                switch resume {
                case .none: break
                case .some(nil): continuation.resume()
                case let .some(error?): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: key) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Calls `handler` after every change of conditions delivered from now on, until the
    /// returned observation is dropped or ended. The handler reads what it needs from the room
    /// (`hold(for:)`), so two changes delivered at once on two threads never leave it with the
    /// older one.
    func observe(_ handler: @escaping @Sendable () -> Void) -> BackgroundRoomObservation {
        let key = state.withLock { state in
            state.next &+= 1
            state.observers[state.next] = handler
            return state.next
        }
        return BackgroundRoomObservation { [weak self] in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: key) }
        }
    }
}

/// An observer of a `BackgroundRoom`: ends when dropped.
final nonisolated class BackgroundRoomObservation: Sendable {
    private let ending: Mutex<(@Sendable () -> Void)?>

    init(end: @escaping @Sendable () -> Void) {
        ending = Mutex(end)
    }

    func end() {
        let end = ending.withLock { ending in
            defer { ending = nil }
            return ending
        }
        end?()
    }

    deinit {
        end()
    }
}
