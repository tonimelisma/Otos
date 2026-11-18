import Foundation
import Synchronization

/// What the machine reports about room for heavy background work: every field is a fact a
/// platform source reports, never a guess from time.
nonisolated struct MachineConditions: Equatable, Sendable {
    /// The machine's memory-pressure level: the kernel's current level when the room reads
    /// it (`MemoryPressureReader`), else the memory-pressure source's last report.
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

    /// A machine with room for everything: what an owner a test makes alone runs under.
    static let roomy = MachineConditions(memory: .normal, thermal: .nominal, lowPower: false)

    /// Why `work` may not start now, or nil when it may (ADR 0057).
    ///
    /// - Memory at `critical` holds every kind.
    /// - Memory at `warning` holds every kind but a description. A download, a text page and
    ///   a heavy load each hold hundreds of megabytes in Otos or in a process it drives, or
    ///   fill the file cache with an original. A description's memory is the system language
    ///   model's, which macOS swaps out with the other apps (the owner, 2026-11-18); a
    ///   description held at warning loaded the model, raised the level and was held again,
    ///   over and over.
    /// - A `serious` or `critical` thermal state holds every kind: the system is throttling.
    /// - Low Power Mode holds every kind: the person asked the Mac to spend less.
    func hold(for work: BackgroundWork) -> BackgroundHold? {
        switch memory {
        case .critical: return .memoryCritical
        case .warning where work != .description: return .memoryWarning
        case .warning, .normal: break
        }
        if thermal == .serious || thermal == .critical {
            return .thermal
        }
        if lowPower {
            return .lowPower
        }
        return nil
    }

    var logFields: [String: String] {
        ["memory": memory.rawValue, "thermal": SystemPressure.thermalName(thermal), "lowPower": "\(lowPower)"]
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

/// Why a kind of background work is held: what a waiting owner's status names (`heldBy=`).
nonisolated enum BackgroundHold: String, Sendable {
    case memoryWarning
    case memoryCritical
    case thermal
    case lowPower
}

/// Where the room reads the kernel's memory-pressure level, and when it looks again while the
/// level it holds is above normal (ADR 0057).
nonisolated struct MemoryPressureReader: Sendable {
    /// The kernel's level now, or nil when it cannot be read.
    let read: @Sendable () -> KernelMemoryPressure?
    /// Returns when the room should read the level again; throws once the room is gone.
    let nextLook: @Sendable () async throws -> Void

    /// How often a held level is read again: the kernel smooths a fall in pressure over 5 s
    /// before it lowers the level, so a closer look finds no newer fact.
    static let lookInterval = Duration.seconds(5)

    /// The live kernel (`SystemPressure.kernelMemory()`).
    static let kernel = MemoryPressureReader(read: SystemPressure.kernelMemory) {
        // The kernel reports a return to normal only to a process it told of the warning,
        // and a rise in available memory to none; the room looks only while it waits on one.
        // time: poll — time decides only how often the kernel is read, never what it says.
        try await Task.sleep(for: lookInterval)
    }
}

/// Why the room read the kernel's level: what `op=system.pressure` names as `cause`.
nonisolated enum MemoryPressureRead: String, Sendable {
    /// The app's start.
    case launch
    /// An owner asked whether a unit may start (`hold(for:)`, `untilOpen(for:)`).
    case decision
    /// The memory-pressure source reported a change (`sourceReported(_:)`).
    case sourceReport
    /// The held level above normal, read again (`MemoryPressureReader.nextLook`).
    case recheck
}

/// Background room guide (ADR 0057)
///
/// The one owner of whether heavy background work may start now. It holds the machine's
/// conditions (`MachineConditions`: memory pressure, thermal state, Low Power Mode) and answers, for each kind of work (`BackgroundWork`), whether
/// it is held and why (`MachineConditions.hold(for:)`). How many of a kind run at once stays
/// its owner's (one description, one text-reading helper, the materializer's per-root and
/// byte caps, one heavy load); the room decides only whether any new one starts.
///
/// Memory pressure is read, not heard. With a `MemoryPressureReader`, each decision —
/// `hold(for:)` and `untilOpen(for:)` — first reads the kernel's current level, inside the
/// room's lock, so no unit starts on a level older than its own question. The
/// memory-pressure source (`sourceReported(_:)`) is only a doorbell: the kernel tells it of
/// a warning in one process at a time, and of the return to normal only in a process it told
/// of the warning, so its reports come late or never. On a report the room reads the kernel,
/// and the kernel's level wins. Reopening waits on the kernel's level read normal. When the
/// source announced the rise, the kernel owes this process the return to normal, and the
/// room waits for that report. Since nothing reports a return to normal to a process the
/// kernel did not tell, the room otherwise reads the level again on the reader's cadence
/// while, and only while, the level it holds is above normal: one loop, woken by a doorbell
/// rung when the level rises, holding the room weakly and ending with it. The same loop reads
/// the kernel while a load waits for more available memory than the last read gave
/// (`wantHeadroom(atLeast:)`, `LoadAdmission`), and the read that finds enough tells every
/// observer. Without a reader (a test's scripted room), the source's report is the level.
///
/// Every owner of heavy work asks before it starts a unit: a serial owner waits in
/// `untilOpen(for:)`, which returns at once when the kind is open and otherwise in the step
/// that delivers the conditions that open it, each waiter exactly once (ADR 0032 rule 8). An
/// owner with an admission machine of its own (the materializer, `LoadAdmission`) reads
/// `hold(for:)` in its decision and is told of every change through `observe(_:)`, whose
/// handler runs synchronously in the step that applied the change — a platform report, a
/// recheck, or a decision whose read found a new level — after the lock is released, so it
/// can ring a doorbell or perform an admission event without a hop. A handler may call
/// `hold(for:)`: its read finds the level just applied, so the nesting ends there. A unit
/// already running is not stopped by a hold, except where its owner says it can stop safely
/// (the text reader ends its helper at `critical`, its reading staying owed).
///
/// Each change logs `op=background.room phase=changed` with the conditions and, for every
/// kind, its hold or `open`. Each kernel read whose level differs from the last one logged
/// logs `op=system.pressure phase=changed` (the first, at launch, `phase=launch`) with the
/// kernel's numbers, the read's cause and the source's last report, and each source report
/// logs `phase=sourceReport` beside the kernel's level: the log carries the kernel's level
/// over the session whether or not the source announced it.
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
        /// The kernel level the last `op=system.pressure` line named (`unknown` when unread).
        var loggedKernel: String?
        /// The memory-pressure source's last report, or nil before its first.
        var source: MachineConditions.Memory?
        /// The source reported a level above normal since the level held was last normal: the
        /// kernel tells this process of the return to normal, so the room waits for that
        /// report and does not look.
        var sourceOwesReturn = false
        /// The kernel's available share (percent) at the last read that gave one.
        var available: Int?
        /// The share at which a waiting load may start (`wantHeadroom(atLeast:)`): the room
        /// reads the kernel on its look while the share is below it.
        var headroomRequired: Int?
        /// How many times the kernel's level was read: what a test counts.
        var kernelReads = 0
        /// The loop that reads a held level again.
        var recheck: Task<Void, Never>?
    }

    /// An `op=system.pressure` line a change decided on, written after the lock is released.
    private struct PressureLine {
        let phase: String
        let fields: [String: String]
    }

    /// What one change decided under the lock: its lines, and, when the conditions changed,
    /// the new ones with the waiters they open and the observers to tell.
    private struct Applied {
        var lines: [PressureLine]
        var conditions: MachineConditions?
        var resumed: [CheckedContinuation<Void, any Error>] = []
        var observers: [@Sendable () -> Void] = []
    }

    private let state: Mutex<State>
    private let memory: MemoryPressureReader?
    /// Rung when the level the room holds is above normal: wakes the recheck loop.
    private let recheckDoorbell: AsyncStream<Void>.Continuation?

    /// `memory` reads the kernel's level at each decision; without it (a test's scripted
    /// room) the level is whatever `deliver(_:)`, `update(_:)` or `sourceReported(_:)` set.
    init(conditions: MachineConditions = .roomy, memory: MemoryPressureReader? = nil) {
        state = Mutex(State(conditions: conditions))
        self.memory = memory
        guard let memory else {
            recheckDoorbell = nil
            return
        }
        let (doorbell, ring) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        recheckDoorbell = ring
        // Holds the room weakly across every wait: the room's end finishes the doorbell and
        // cancels the look, and the loop ends.
        let loop = Task { [weak self] in
            for await _ in doorbell {
                while self?.needsLook == true {
                    do {
                        try await memory.nextLook()
                    } catch {
                        return
                    }
                    self?.readMemory(.recheck)
                }
            }
        }
        state.withLock { $0.recheck = loop }
        if conditions.memory != .normal {
            ring.yield()
        }
    }

    deinit {
        recheckDoorbell?.finish()
        state.withLock { $0.recheck }?.cancel()
    }

    var conditions: MachineConditions {
        state.withLock { $0.conditions }
    }

    /// The room looks again only while a fact it waits on has no report: the level held is
    /// above normal and the source has not announced the rise, or a load waits for more
    /// available memory than the kernel last reported.
    private var needsLook: Bool {
        state.withLock { Self.needsLook($0) }
    }

    private static func needsLook(_ state: State) -> Bool {
        if state.conditions.memory != .normal, !state.sourceOwesReturn {
            return true
        }
        guard let required = state.headroomRequired, let available = state.available else { return false }
        return available < required
    }

    /// The kernel's available memory share (percent) at the room's last read, or nil unread.
    var availablePercent: Int? {
        state.withLock { $0.available }
    }

    /// A load waits until the kernel reports at least `percent` available (nil: none waits).
    /// While the share read last is below it, the room reads the kernel on its look, since
    /// nothing reports a rise; the read that finds it reached tells every observer.
    func wantHeadroom(atLeast percent: Int?) {
        let look = state.withLock { state -> Bool in
            state.headroomRequired = percent
            return Self.needsLook(state)
        }
        if look {
            recheckDoorbell?.yield()
        }
    }

    /// Whether the room looks again at the held level now: what a test reads.
    var looksAgain: Bool {
        needsLook
    }

    /// Why `work` may not start now, or nil. Reads the kernel's level first.
    func hold(for work: BackgroundWork) -> BackgroundHold? {
        readMemory(.decision)
        return state.withLock { $0.conditions.hold(for: work) }
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

    /// How many times the kernel's level was read.
    var kernelReads: Int {
        state.withLock { $0.kernelReads }
    }

    /// The platform's newest conditions, whole: what a test delivers.
    func deliver(_ conditions: MachineConditions) {
        update { $0 = conditions }
    }

    /// One report changes the conditions (a source changes only the field it reports).
    /// Opens every waiter whose kind they open, and tells every observer, in this step.
    func update(_ change: (inout MachineConditions) -> Void) {
        apply { state in
            change(&state.conditions)
            return []
        }
    }

    /// Reads the kernel's level now and holds it. `fields` go on the `phase=launch` line.
    /// Does nothing without a reader.
    func readMemory(_ cause: MemoryPressureRead, fields: [String: String] = [:]) {
        guard let memory else { return }
        apply { state in
            Self.read(memory, into: &state, cause: cause, fields: fields).map { [$0] } ?? []
        }
    }

    /// The memory-pressure source reported `level`: the room reads the kernel and holds the
    /// kernel's level; without a reader, or when the kernel cannot be read, it holds the report.
    func sourceReported(_ level: MachineConditions.Memory) {
        apply { state in
            state.source = level
            state.conditions.memory = level
            if level != .normal {
                state.sourceOwesReturn = true
            }
            guard let memory else {
                return [PressureLine(phase: "sourceReport", fields: ["source": level.rawValue])]
            }
            let changed = Self.read(memory, into: &state, cause: .sourceReport, fields: [:])
            let report = PressureLine(phase: "sourceReport", fields: [
                "source": level.rawValue, "level": state.loggedKernel ?? "unknown",
            ])
            return [report] + (changed.map { [$0] } ?? [])
        }
    }

    /// Reads the kernel into `state`, and returns the line to log when its level differs
    /// from the last one logged. An unread level changes nothing: an error is not a fact.
    private static func read(
        _ memory: MemoryPressureReader,
        into state: inout State,
        cause: MemoryPressureRead,
        fields: [String: String]
    ) -> PressureLine? {
        state.kernelReads += 1
        let kernel = memory.read()
        let level = kernel?.level.rawValue ?? "unknown"
        if let kernel {
            state.conditions.memory = kernel.level
            if let available = kernel.availablePercent {
                state.available = Int(available)
            }
        }
        guard cause == .launch || state.loggedKernel != level else { return nil }
        state.loggedKernel = level
        var line = fields
        line.merge(kernel?.logFields ?? ["systemLevel": "unknown", "availablePercent": "unknown"]) { _, kernel in kernel }
        line["level"] = level
        line["cause"] = cause.rawValue
        line["source"] = state.source?.rawValue ?? "none"
        return PressureLine(phase: cause == .launch ? "launch" : "changed", fields: line)
    }

    /// Applies one change under the lock, then, outside it, logs it, opens every waiter whose
    /// kind it opens, rings the recheck loop while the level is above normal, and tells every
    /// observer.
    private func apply(_ change: (inout State) -> [PressureLine]) {
        let applied = state.withLock { state -> Applied in
            let before = state.conditions
            let lines = change(&state)
            let conditions = state.conditions
            if conditions.memory == .normal {
                // The episode the source announced is over; a later rise the room finds by its
                // own read is one the source may never announce.
                state.sourceOwesReturn = false
            }
            // A share that reaches the one a load waits for is a fact its owner hears, whatever
            // else changed; it is asked again by the owner when it still waits.
            let headroom = state.headroomRequired.flatMap { required in state.available.map { $0 >= required } } ?? false
            if headroom {
                state.headroomRequired = nil
            }
            guard before != conditions else {
                return Applied(lines: lines, observers: headroom ? Array(state.observers.values) : [])
            }
            let open = state.waiters.filter { conditions.hold(for: $0.value.work) == nil }
            for (key, waiter) in open {
                state.waiters[key] = nil
                state.admitted[waiter.work, default: 0] += 1
            }
            return Applied(
                lines: lines, conditions: conditions,
                resumed: open.map(\.value.continuation), observers: Array(state.observers.values)
            )
        }
        for line in applied.lines {
            OtosLog.performance.noticeOperation("system.pressure", phase: line.phase, fields: line.fields)
        }
        guard let conditions = applied.conditions else {
            for observer in applied.observers {
                observer()
            }
            return
        }
        let resumed = applied.resumed
        let observers = applied.observers
        var fields = conditions.logFields
        for work in BackgroundWork.allCases {
            fields[work.rawValue] = conditions.hold(for: work)?.rawValue ?? "open"
        }
        fields["resumed"] = "\(resumed.count)"
        OtosLog.performance.noticeOperation("background.room", phase: "changed", fields: fields)
        if conditions.memory != .normal {
            recheckDoorbell?.yield()
        }
        for continuation in resumed {
            continuation.resume()
        }
        for observer in observers {
            observer()
        }
    }

    /// Returns once `work` may start: at once when it is open, else when conditions that open
    /// it are delivered. Reads the kernel's level first. Throws `CancellationError` when the
    /// caller's task is cancelled first.
    func untilOpen(for work: BackgroundWork) async throws {
        readMemory(.decision)
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

    /// Calls `handler` after every change of conditions applied from now on, until the
    /// returned observation is dropped or ended. The handler reads what it needs from the room
    /// (`hold(for:)`), so two changes applied at once on two threads never leave it with the
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
