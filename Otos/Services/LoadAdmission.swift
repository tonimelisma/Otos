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
    /// Readying the first query (`PhotoSearchIndex.prepareWhenAdmitted`): the text encoder's
    /// load, the vectors read ahead, the shown scope's slots. It runs last (`runsLast`).
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
/// needs (`want`) goes before every other waiting one; it does not stop the one running. `shutdown` refuses
/// every waiting load and every later request, and grants nothing again.
nonisolated struct LoadAdmissionMachine: Equatable, Sendable {
    typealias Request = UInt64

    enum Event: Equatable, Sendable {
        /// The window's first grid painted.
        case open
        case request(Request, BackgroundLoad)
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
    /// In the order they run when nothing is wanted.
    private(set) var waiting: [Waiting] = []
    private(set) var wanted: BackgroundLoad?

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
        case let .withdraw(request):
            guard let index = waiting.firstIndex(where: { $0.request == request }) else { return [] }
            waiting.remove(at: index)
            return [.refuse(request)]
        case let .release(request):
            guard running?.request == request else { return [] }
            running = nil
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
        guard isOpen, !isShutDown, running == nil, !waiting.isEmpty else { return [] }
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
/// needs goes first (`LoadAdmissionMachine`).
///
/// An owner wraps its load in `run(_:_:)`, which waits for the grant, runs the body on the
/// caller's actor, and releases when the body returns or throws, so a load can never keep
/// the admission. The window opens it at its first grid (`open()`), says what its view needs
/// on every query (`want(_:)`), and shuts it at teardown (`shutdown()`). All three are
/// synchronous, so the main actor calls them in the step that applies the intent, without a
/// hop. State lives in one `Mutex` and changes only in the machine's `handle(_:)`; a
/// continuation is resumed after the lock is released. A waiting caller whose task is
/// cancelled withdraws its request at once and hears `CancellationError`, and so does every
/// waiting caller at shutdown: a load queued at teardown never starts.
///
/// A load must not wait on another admitted load from inside its body; none does — each
/// reads and writes the Store and computes off its actor.
final nonisolated class LoadAdmission: Sendable {
    private struct State {
        var machine: LoadAdmissionMachine
        var next: LoadAdmissionMachine.Request = 0
        var waiters: [LoadAdmissionMachine.Request: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state: Mutex<State>

    /// Closed until `open()`. An owner a test makes alone gets an open admission of its own.
    init(isOpen: Bool = false) {
        state = Mutex(State(machine: LoadAdmissionMachine(isOpen: isOpen)))
    }

    /// The machine as it is now: what a test reads to see which load runs and which wait.
    var snapshot: LoadAdmissionMachine {
        state.withLock { $0.machine }
    }

    /// The window's first grid painted: loads may run.
    func open() {
        perform(.open)
    }

    /// The load the window's current view needs, or nil: it runs next.
    func want(_ load: BackgroundLoad?) {
        perform(.want(load))
    }

    /// Teardown: every waiting load is refused and none is granted again.
    func shutdown() {
        perform(.shutdown)
    }

    /// Runs `body` once `load` is admitted, and releases the admission when it ends. Throws
    /// `CancellationError` without running it when the caller's task is cancelled while it
    /// waits, or the admission shuts down first.
    func run<T>(_ load: BackgroundLoad, _ body: () async throws -> T) async throws -> T {
        let request = try await admit(load)
        let started = ContinuousClock.now
        defer {
            let relief = Self.returnFreedPages()
            perform(.release(request))
            OtosLog.performance.noticeOperation("load.admission", phase: "released", fields: [
                "load": load.rawValue, "request": "\(request)",
                "ms": "\(DiagnosticsTiming.milliseconds(since: started))",
                "returnedMB": "\(relief.returned / 1_048_576)",
                "footprintBeforeMB": "\(relief.before / 1_048_576)", "footprintAfterMB": "\(relief.after / 1_048_576)",
            ])
        }
        return try await body()
    }

    /// Returns the pages malloc holds freed to the system, as every admitted load ends: a load
    /// frees hundreds of megabytes of rows, vectors and scratch at once, and malloc keeps freed
    /// pages dirty in its zones for reuse, where they still count in the process's footprint
    /// (measured on the owner's library: 0.4 to 1.2 GB of empty small-zone pages after People's
    /// passes). Returns the bytes released and the footprint before and after.
    static func returnFreedPages() -> (returned: Int, before: UInt64, after: UInt64) {
        let before = ProcessResourceSample.current().footprintBytes
        let returned = malloc_zone_pressure_relief(nil, 0)
        return (returned, before, ProcessResourceSample.current().footprintBytes)
    }

    private func admit(_ load: BackgroundLoad) async throws -> LoadAdmissionMachine.Request {
        let request = state.withLock { state in
            state.next &+= 1
            return state.next
        }
        let asked = ContinuousClock.now
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumptions = state.withLock { state in
                    state.waiters[request] = continuation
                    // Read under the lock that `onCancel` takes: a cancellation before this
                    // point is seen here, one after it finds the request waiting.
                    if Task.isCancelled {
                        return Self.take([.refuse(request)], from: &state)
                    }
                    return Self.step(.request(request, load), in: &state)
                }
                Self.resume(resumptions)
            }
        } onCancel: {
            perform(.withdraw(request))
        }
        OtosLog.performance.noticeOperation("load.admission", phase: "granted", fields: [
            "load": load.rawValue, "request": "\(request)",
            "waitMs": "\(DiagnosticsTiming.milliseconds(since: asked))",
        ])
        return request
    }

    private func perform(_ event: LoadAdmissionMachine.Event) {
        Self.resume(state.withLock { Self.step(event, in: &$0) })
    }

    private typealias Resumption = (continuation: CheckedContinuation<Void, any Error>, granted: Bool)

    /// The machine's step and the continuations its effects name, taken in one hold of the
    /// lock, so no event can fall between a decision and the waiter it names.
    private static func step(_ event: LoadAdmissionMachine.Event, in state: inout State) -> [Resumption] {
        take(state.machine.handle(event), from: &state)
    }

    private static func take(_ effects: [LoadAdmissionMachine.Effect], from state: inout State) -> [Resumption] {
        effects.compactMap { effect in
            switch effect {
            case let .grant(request, _):
                state.waiters.removeValue(forKey: request).map { ($0, true) }
            case let .refuse(request):
                state.waiters.removeValue(forKey: request).map { ($0, false) }
            }
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
