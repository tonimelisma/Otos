import Foundation
import OSLog
import Synchronization

/// A bounded load a background owner runs that holds a lot of memory or reads a lot of the
/// catalog at once (plan 0116 bet 6): what `LoadAdmission` runs one at a time.
nonisolated enum BackgroundLoad: String, CaseIterable, Sendable {
    /// One People pass: the snapshot, the gallery, and assignment when its inputs moved
    /// (`PeopleAssignment`).
    case people
    /// One duplicates build (`DuplicatesProjection`).
    case duplicates
    /// The search index's first load of every stored embedding (`PhotoSearchIndex`).
    case searchIndex
    /// One account's mirror pairing, a write walk over each mirrored library
    /// (`ImmichCatalogSync`).
    case immichMirror
    /// The launch's look at the derived folder, and its reconciliation when one is owed
    /// (`CatalogStore.reconcileDerivedFilesIfOwed`): after every load a view shows.
    case derivedFolder
    /// Readying search's queries: the text encoder's load and first prediction, and, for the
    /// first query the window's first grid readies (`PhotoSearchIndex.prepareWhenAdmitted`),
    /// the vectors read ahead and the shown scope's slots. Asked by the first grid it runs
    /// last (`runsLast`); asked by a query or the intent to search, the user waits on it
    /// (`LoadWaiter.user`).
    case searchPrepare

    /// The order loads asked for before the window's first grid run in once it paints: the
    /// worst first click first (People), then the duplicate groups, then the index only a
    /// search needs, then the pairing nothing shows until it lands, then the derived folder,
    /// then readying the first search query. Declaration order.
    var launchRank: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    /// A load that waits behind every other one waiting, whenever it asked: readying a search
    /// nobody has asked for yet goes after everything a view shows.
    var runsLast: Bool {
        self == .searchPrepare
    }

    /// The load a query's view cannot show its answer without: a search needs the index, and
    /// People, a person, Duplicates and a group need their owner's build. Nil for the rest.
    static func needed(by descriptor: CatalogQueryDescriptor) -> BackgroundLoad? {
        if descriptor.search != nil {
            return .searchIndex
        }
        switch descriptor.scope.sidebarRow {
        case .people: return .people
        case .duplicates: return .duplicates
        default: return nil
        }
    }
}

/// Who waits on a load. A background owner's load takes its turn; a load the user is waiting
/// on (a query's text encoder) runs at once, whatever runs or waits, and no waiting load
/// starts while it runs: the user's wait is never spent behind loads nobody asked for.
nonisolated enum LoadWaiter: String, Sendable {
    case background
    case user
}

nonisolated extension TaskPriority {
    /// What every background owner's tasks run at: below the window's `.userInitiated`, so
    /// eight owner steps on the cooperative pool never hold back a visible tile's read (ADR
    /// 0032 rule 6). `.medium` rather than lower, so the walks that make visible thumbnails
    /// still run promptly when the window is idle.
    static let backgroundOwner: TaskPriority = .medium
}

/// Load admission machine guide
///
/// Which heavy load runs, as a pure machine (ADR 0032's second shape, like
/// `ImportSessionMachine`): `handle(_:)` is the only writer of its state and returns what the
/// shell must do. At most one load runs. Nothing runs before `open` — the window's first grid
/// (`op=launch.firstGrid`) — so no load competes with the window's first read. A load asked
/// for before then waits in `BackgroundLoad.launchRank` order; after it, in the order asked,
/// so a load that asks again (a People pass after each batch of faces) goes behind the loads
/// already waiting and never starves them. A load that runs last (`BackgroundLoad.runsLast`)
/// goes behind every other waiting one, whenever it asked. The load the window's current view
/// needs (`want`) goes before every other waiting one; it does not stop the one running. A load
/// the user waits on (`requestForUser`) is granted at once, before the first grid and beside
/// the one running, and while one runs no waiting load is granted. `shutdown` refuses
/// every waiting load and every later request, and grants nothing again.
nonisolated struct LoadAdmissionMachine: AdmissionMachine, Equatable {
    typealias Request = AdmissionRequest

    struct Ask: Equatable, Sendable {
        let load: BackgroundLoad
        let waiter: LoadWaiter
    }

    static func requested(_ request: Request, _ ask: Ask) -> Event {
        switch ask.waiter {
        case .background: .request(request, ask.load)
        case .user: .requestForUser(request, ask.load)
        }
    }

    static func withdrawn(_ request: Request) -> Event {
        .withdraw(request)
    }

    static func released(_ request: Request) -> Event {
        .release(request)
    }

    static func resolution(of effect: Effect) -> (request: Request, granted: Bool) {
        switch effect {
        case let .grant(request, _): (request, true)
        case let .refuse(request): (request, false)
        }
    }

    enum Event: Equatable, Sendable {
        /// The window's first grid painted.
        case open
        case request(Request, BackgroundLoad)
        /// A load the user waits on: granted at once.
        case requestForUser(Request, BackgroundLoad)
        /// The asker stopped waiting (its task was cancelled): a waiting request is dropped.
        case withdraw(Request)
        /// A granted load ended, however it ended.
        case release(Request)
        /// The load the window's current view needs, or none.
        case want(BackgroundLoad?)
        case shutdown
    }

    enum Effect: Equatable, Sendable {
        case grant(Request, BackgroundLoad)
        /// The request never runs: the asker hears `CancellationError`.
        case refuse(Request)
    }

    struct Waiting: Equatable, Sendable {
        let request: Request
        let load: BackgroundLoad
    }

    private(set) var isOpen = false
    private(set) var isShutDown = false
    private(set) var running: Waiting?
    /// The loads the user waits on that run now: no waiting load is granted beside them.
    private(set) var runningForUser: [Waiting] = []
    /// In the order they run when nothing is wanted.
    private(set) var waiting: [Waiting] = []
    private(set) var wanted: BackgroundLoad?
    /// Set by the first release after `open` that leaves no load running or waiting: the loads
    /// the launch asked for have all run. Only a release sets it, so an admission that opens
    /// before any load has asked is not drained. Never cleared: a load asked later runs after.
    private(set) var hasDrainedSinceOpen = false

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .open:
            guard !isOpen else { return [] }
            isOpen = true
            // Stable: two loads of one kind keep the order they asked in.
            waiting = waiting.enumerated().sorted { lhs, rhs in
                (lhs.element.load.launchRank, lhs.offset) < (rhs.element.load.launchRank, rhs.offset)
            }.map(\.element)
        case let .request(request, load):
            guard !isShutDown else { return [.refuse(request)] }
            waiting.append(Waiting(request: request, load: load))
        case let .requestForUser(request, load):
            guard !isShutDown else { return [.refuse(request)] }
            runningForUser.append(Waiting(request: request, load: load))
            return [.grant(request, load)]
        case let .withdraw(request):
            guard let index = waiting.firstIndex(where: { $0.request == request }) else { return [] }
            waiting.remove(at: index)
            return [.refuse(request)]
        case let .release(request):
            if running?.request == request {
                running = nil
            } else if let index = runningForUser.firstIndex(where: { $0.request == request }) {
                runningForUser.remove(at: index)
            } else {
                return []
            }
            if isOpen, running == nil, runningForUser.isEmpty, waiting.isEmpty {
                hasDrainedSinceOpen = true
            }
        case let .want(load):
            wanted = load
        case .shutdown:
            guard !isShutDown else { return [] }
            isShutDown = true
            let refused = waiting.map { Effect.refuse($0.request) }
            waiting = []
            return refused
        }
        return grantIfIdle()
    }

    private mutating func grantIfIdle() -> [Effect] {
        guard isOpen, !isShutDown, running == nil, runningForUser.isEmpty, !waiting.isEmpty else { return [] }
        let index = wanted.flatMap { load in waiting.firstIndex { $0.load == load } }
            ?? waiting.firstIndex { !$0.load.runsLast } ?? 0
        let next = waiting.remove(at: index)
        running = next
        return [.grant(next.request, next.load)]
    }
}

/// Load admission guide
///
/// The one owner of when a heavy background load may run (plan 0116 bet 6): the search
/// index's first load, a People pass, a duplicates build, an account's mirror pairing. Each
/// holds hundreds of megabytes or reads much of the catalog, and on a 16 GB Mac with little
/// free memory, two at once pushed the footprint to 3.8 GB and paid every read cold. They
/// run one at a time, none before the window's first grid, and the one the current view
/// needs goes first (`LoadAdmissionMachine`). A load the user waits on (`LoadWaiter.user`)
/// runs at once and holds the waiting ones back while it runs.
///
/// An owner wraps its load in `run(_:_:)`, which waits for the grant, runs the body on the
/// caller's actor, and releases when the body returns or throws, so a load can never keep
/// the admission. The window opens it at its first grid (`open()`), says what its view needs
/// on every query (`want(_:)`), and shuts it at teardown (`shutdown()`). All three are
/// synchronous, so the main actor calls them in the step that applies the intent, without a
/// hop. The machine and its waiters live in the shared shell (`Admission`): a waiting caller
/// whose task is cancelled withdraws its request at once and hears `CancellationError`, and
/// so does every waiting caller at shutdown: a load queued at teardown never starts.
///
/// A load must not wait on another admitted load from inside its body; none does — each
/// reads and writes the Store and computes off its actor.
final nonisolated class LoadAdmission: Sendable {
    private let admission: Admission<LoadAdmissionMachine>
    /// Who waits for the launch's loads to have run (`untilDrained()`), resumed in the release
    /// that drains them. Taken only after the admission's own lock is released.
    private let drainWaiters = Mutex<[UUID: CheckedContinuation<Void, any Error>]>([:])

    /// Closed until `open()`. An owner a test makes alone gets an open admission of its own.
    init(isOpen: Bool = false) {
        admission = Admission(LoadAdmissionMachine(isOpen: isOpen))
    }

    /// Returns once the loads the launch asked for have all run (`hasDrainedSinceOpen`): at
    /// once when they have, else in the release that drains them. Throws `CancellationError`
    /// when the caller's task is cancelled first, or at shutdown.
    func untilDrained() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume: Result<Void, any Error>? = drainWaiters.withLock { waiters in
                    // Read under the waiters' lock, which `settleDrained` also takes after every
                    // release: a drain before this point is seen here, one after it finds the
                    // waiter registered.
                    let machine = admission.machine
                    if machine.hasDrainedSinceOpen {
                        return .success(())
                    }
                    if machine.isShutDown || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    waiters[id] = continuation
                    return nil
                }
                if let resume {
                    continuation.resume(with: resume)
                }
            }
        } onCancel: {
            drainWaiters.withLock { $0.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Resumes the drain's waiters once it has happened, or fails them at shutdown. Called
    /// after every release and at shutdown, outside the admission's lock.
    private func settleDrained() {
        let (resumed, drained): ([CheckedContinuation<Void, any Error>], Bool) = drainWaiters.withLock { waiters in
            let machine = admission.machine
            guard machine.hasDrainedSinceOpen || machine.isShutDown, !waiters.isEmpty else {
                return ([], false)
            }
            let all = Array(waiters.values)
            waiters = [:]
            return (all, machine.hasDrainedSinceOpen)
        }
        for waiter in resumed {
            if drained {
                waiter.resume()
            } else {
                waiter.resume(throwing: CancellationError())
            }
        }
    }

    /// The machine as it is now: what a test reads to see which load runs and which wait.
    var snapshot: LoadAdmissionMachine {
        admission.machine
    }

    /// The window's first grid painted: loads may run.
    func open() {
        admission.perform(.open)
    }

    /// The load the window's current view needs, or nil: it runs next.
    func want(_ load: BackgroundLoad?) {
        admission.perform(.want(load))
    }

    /// Teardown: every waiting load is refused and none is granted again.
    func shutdown() {
        admission.perform(.shutdown)
        settleDrained()
    }

    /// Runs `body` once `load` is admitted, and releases the admission when it ends. Throws
    /// `CancellationError` without running it when the caller's task is cancelled while it
    /// waits, or the admission shuts down first. A load `for: .user` is admitted at once.
    func run<T>(_ load: BackgroundLoad, for waiter: LoadWaiter = .background, _ body: () async throws -> T) async throws -> T {
        let asked = ContinuousClock.now
        let request = try await admission.admit(LoadAdmissionMachine.Ask(load: load, waiter: waiter))
        OtosLog.performance.noticeOperation("load.admission", phase: "granted", fields: [
            "load": load.rawValue, "request": "\(request)", "waiter": waiter.rawValue,
            "waitMs": "\(DiagnosticsTiming.milliseconds(since: asked))",
        ])
        let started = ContinuousClock.now
        defer {
            admission.release(request)
            settleDrained()
            // The footprint each load leaves: memory a load freed stays counted until reused,
            // and asking malloc to return it returns nothing on macOS 27
            // (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`).
            OtosLog.performance.noticeOperation("load.admission", phase: "released", fields: [
                "load": load.rawValue, "request": "\(request)",
                "ms": "\(DiagnosticsTiming.milliseconds(since: started))",
                "footprintAfterMB": "\(ProcessResourceSample.current().footprintBytes / 1_048_576)",
            ])
        }
        return try await body()
    }
}
