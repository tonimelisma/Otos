import Foundation
import OSLog

/// A bounded load a background owner runs that holds a lot of memory or reads a lot of the
/// catalog at once (ADR 0055): what `LoadAdmission` runs one at a time.
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
    /// One request to the system language model for a photo's description
    /// (`PhotoDescriptionWriter`). A cold request makes the system load its 3B model and image
    /// encoder into the model's service: on the owner's 16 GB Mac the machine's compressor grew
    /// 1.5 GB in those 3.6 s and the kernel went to warning, beside a People pass
    /// (`docs/research/2026-11-17-launch-pressure-dips.md`). Its room decides by
    /// `BackgroundWork.description`, which also holds it while the person is in the app.
    case description
    /// Readying search's queries: the text encoder's load and first prediction, and, for the
    /// first query the window's first grid readies (`PhotoSearchIndex.prepareWhenAdmitted`),
    /// the vectors read ahead and the shown scope's slots. Asked by the first grid it runs
    /// last (`runsLast`); asked by a query or the intent to search, the user waits on it
    /// (`LoadWaiter.user`).
    case searchPrepare

    /// The order loads asked for before the window's first grid run in once it paints: the
    /// worst first click first (People), then the duplicate groups, then the index only a
    /// search needs, then the pairing nothing shows until it lands, then the derived folder,
    /// then the first description, then readying the first search query. Declaration order.
    var launchRank: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    /// The kind of work the background room decides this load's start by (ADR 0057).
    var work: BackgroundWork {
        self == .description ? .description : .heavyLoad
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
/// the one running, and while one runs no waiting load is granted. While the background room
/// holds a load's kind (`room(_:)`, ADR 0057), that load waits, except the one the view needs;
/// the rest start in the step that opens the room — one, since one runs at a time, and the
/// next at its release.
///
/// When the room's memory hold begins, the background load granted last is the one that ran
/// into it (`pressureRaisers`, with the kernel's available share at its grant): loads run one
/// at a time, so it is the load the machine was carrying when the level rose. It is admitted
/// against the room it took: it starts again only when the kernel reports more available
/// memory than it started with then (`headroomWanted` asks the room to read the kernel until
/// it does), and behind every other waiting load, so the room reopens on the loads that did
/// not raise the pressure and sees each alone. Once it runs to its release with no hold
/// beginning, it is no longer marked. An unread share admits it, behind the others: an error
/// is not a fact. `shutdown` refuses every waiting load and every later request, and grants
/// nothing again.
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
        /// What the background room holds now, per kind of load (ADR 0057): a held load waits,
        /// except the one the current view needs.
        case room(LoadRoomHolds)
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
    private(set) var room = LoadRoomHolds.open
    /// Loads granted, by kind: what a test counts to see a held load start exactly once.
    private(set) var granted: [BackgroundLoad: Int] = [:]
    /// The background load granted most recently, the available share it was granted into,
    /// and whether a memory hold began since.
    private(set) var lastGranted: LastGrant?
    /// Loads that ran into the room's last memory holds, each with the kernel's available
    /// share (percent) at the grant that ran into it: it starts again only with more.
    private(set) var pressureRaisers: [BackgroundLoad: Int?] = [:]

    struct LastGrant: Equatable, Sendable {
        let load: BackgroundLoad
        let availablePercent: Int?
        var ranIntoHold: Bool
    }

    /// The available share above which a waiting load that raised the pressure may start:
    /// the smallest such need not met now, or nil when none waits on one. The shell asks the
    /// room to read the kernel until the share passes it, since nothing reports a rise.
    var headroomWanted: Int? {
        waiting.compactMap { waiting -> Int? in
            guard room.hold(for: waiting.load) == nil, let need = pressureRaisers[waiting.load] ?? nil,
                  !hasHeadroom(for: waiting.load) else { return nil }
            return need
        }.min()
    }

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
            if let ended = running, ended.request == request {
                running = nil
                // A load that ran to its release with no hold beginning is not behind again.
                if let last = lastGranted, last.load == ended.load, !last.ranIntoHold {
                    pressureRaisers[ended.load] = nil
                }
            } else if let index = runningForUser.firstIndex(where: { $0.request == request }) {
                runningForUser.remove(at: index)
            } else {
                return []
            }
        case let .want(load):
            wanted = load
        case let .room(holds):
            if holds.memory, !room.memory, let last = lastGranted {
                pressureRaisers[last.load] = .some(last.availablePercent)
                lastGranted?.ranIntoHold = true
            }
            room = holds
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
        // The load the view cannot show its answer without starts whatever the room holds;
        // any other waits while the room holds its kind, a load that ran into a memory hold
        // waits for more room than it took, and it, or one that runs last, waits behind the
        // rest.
        let wantedIndex = wanted.flatMap { load in waiting.firstIndex { $0.load == load } }
        let startable = waiting.indices.filter {
            room.hold(for: waiting[$0].load) == nil && hasHeadroom(for: waiting[$0].load)
        }
        let index = wantedIndex ?? startable.min { lhs, rhs in
            (order(of: waiting[lhs].load), lhs) < (order(of: waiting[rhs].load), rhs)
        }
        guard let index else { return [] }
        let next = waiting.remove(at: index)
        running = next
        granted[next.load, default: 0] += 1
        lastGranted = LastGrant(load: next.load, availablePercent: room.availablePercent, ranIntoHold: false)
        return [.grant(next.request, next.load)]
    }

    /// Whether the kernel now reports more available memory than `load` started with when it
    /// raised the pressure. True for a load that never did, and when either share is unread.
    private func hasHeadroom(for load: BackgroundLoad) -> Bool {
        guard let need = pressureRaisers[load] ?? nil, let available = room.availablePercent else { return true }
        return available > need
    }

    /// Where a waiting load stands among the startable ones: those asked for first, then
    /// those that ran into a memory hold, then readying a search.
    private func order(of load: BackgroundLoad) -> Int {
        if load.runsLast {
            return 2
        }
        return pressureRaisers[load] != nil ? 1 : 0
    }
}

/// What the background room holds for each kind of load `LoadAdmission` runs (ADR 0057).
nonisolated struct LoadRoomHolds: Equatable, Sendable {
    /// The hold on a People pass, a duplicates build, the search index's build, a mirror
    /// pairing, the derived folder's look and readying search (`BackgroundWork.heavyLoad`).
    var heavyLoad: BackgroundHold?
    /// The hold on a description request (`BackgroundWork.description`).
    var description: BackgroundHold?
    /// The kernel's available memory share (percent) at the room's last read, or nil unread.
    var availablePercent: Int?

    static let open = LoadRoomHolds(heavyLoad: nil, description: nil)

    init(heavyLoad: BackgroundHold?, description: BackgroundHold?, availablePercent: Int? = nil) {
        self.heavyLoad = heavyLoad
        self.description = description
        self.availablePercent = availablePercent
    }

    init(_ conditions: MachineConditions, availablePercent: Int?) {
        self.init(
            heavyLoad: conditions.hold(for: .heavyLoad), description: conditions.hold(for: .description),
            availablePercent: availablePercent
        )
    }

    func hold(for load: BackgroundLoad) -> BackgroundHold? {
        load.work == .description ? description : heavyLoad
    }

    /// The room holds for memory pressure: it holds every kind alike.
    var memory: Bool {
        heavyLoad == .memoryWarning || heavyLoad == .memoryCritical
    }
}

/// Load admission guide
///
/// The one owner of when a heavy background load may run (ADR 0055): the search
/// index's first load, a People pass, a duplicates build, an account's mirror pairing, a
/// description request. Each holds hundreds of megabytes, in Otos or in the system language
/// model's service, or reads much of the catalog, and on a 16 GB Mac with little free memory,
/// two at once pushed the footprint to 3.8 GB and paid every read cold, and a cold description
/// beside a People pass took the machine to memory-pressure warning. They
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
    /// Reads the process's footprint for the line a release logs: a kernel call
    /// (`task_info`) that can stall under memory pressure.
    private let footprint: @Sendable () -> UInt64?
    /// Where that read runs, after the release has granted the next load and the releasing
    /// owner has gone on: a stalled read holds back neither, nor a cooperative thread. At the
    /// owners' QoS class, never below it (PR 895).
    private static let releaseSampling = DispatchQueue(label: "net.melisma.Otos.loadAdmission.released", qos: .default)

    /// Tells the machine each time the background room's holds change.
    private let roomObservation: BackgroundRoomObservation?
    /// Asked at each decision the machine makes for a background load: a request and a
    /// release, so a grant never stands on a level the room has not read since.
    private let room: BackgroundRoom?

    /// Closed until `open()`. An owner a test makes alone gets an open admission of its own.
    /// `footprint` is the process's own unless a test scripts it. With a `room`, a background
    /// load waits while the room holds its kind (ADR 0057), except the one the current view
    /// needs; it starts in the step that delivers the conditions that open the room.
    init(
        isOpen: Bool = false,
        room: BackgroundRoom? = nil,
        footprint: @escaping @Sendable () -> UInt64? = ProcessResourceSample.currentFootprintBytes
    ) {
        let admission = Admission(LoadAdmissionMachine(isOpen: isOpen))
        self.admission = admission
        self.footprint = footprint
        self.room = room
        roomObservation = room.map { room in
            room.observe { [weak room] in
                // The handler runs in the step that applied the change: the conditions it
                // reads are the ones just applied, with no second read of the kernel.
                guard let room else { return }
                Self.tell(admission, room)
            }
        }
        // Read after the observer is in place, so no change falls between the two.
        if let room {
            room.readMemory(.decision)
            Self.tell(admission, room)
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
    }

    /// Runs `body` once `load` is admitted, and releases the admission when it ends. Throws
    /// `CancellationError` without running it when the caller's task is cancelled while it
    /// waits, or the admission shuts down first. A load `for: .user` is admitted at once.
    func run<T>(_ load: BackgroundLoad, for waiter: LoadWaiter = .background, _ body: () async throws -> T) async throws -> T {
        let asked = ContinuousClock.now
        askRoom()
        let request = try await admission.admit(LoadAdmissionMachine.Ask(load: load, waiter: waiter))
        OtosLog.performance.noticeOperation("load.admission", phase: "granted", fields: [
            "load": load.rawValue, "request": "\(request)", "waiter": waiter.rawValue,
            "waitMs": "\(DiagnosticsTiming.milliseconds(since: asked))",
            // The turn is held at this priority: one below the owners' holds every waiting
            // load behind work the system throttles.
            "priority": "\(Task.currentPriority.rawValue)",
        ])
        let started = ContinuousClock.now
        defer {
            askRoom()
            admission.release(request)
            // A release can leave a load that raised the pressure first in line.
            room?.wantHeadroom(above: admission.machine.headroomWanted)
            // The footprint each load leaves: memory a load freed stays counted until reused,
            // and asking malloc to return it returns nothing on macOS 27
            // (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). Read once the
            // next load is granted, on a queue of its own: a measurement never sits between a
            // release and the next grant, nor holds the releasing owner.
            let ms = DiagnosticsTiming.milliseconds(since: started)
            let footprint = footprint
            Self.releaseSampling.async {
                OtosLog.performance.noticeOperation("load.admission", phase: "released", fields: [
                    "load": load.rawValue, "request": "\(request)", "ms": "\(ms)",
                    "footprintAfterMB": footprint().map { "\($0 / 1_048_576)" } ?? "unknown",
                ])
            }
        }
        return try await body()
    }

    /// Why `load` would wait now, or nil: what an owner names in its status while it waits
    /// (`heldBy`). The room's hold for its kind (reading the kernel's level first), else
    /// `memoryHeadroom` while it waits for more room than it took when it raised the pressure.
    func hold(for load: BackgroundLoad) -> BackgroundHold? {
        if let hold = room?.hold(for: load.work) {
            return hold
        }
        let machine = admission.machine
        guard let need = machine.pressureRaisers[load] ?? nil, let available = machine.room.availablePercent,
              available <= need else { return nil }
        return .memoryHeadroom
    }

    /// Tells the machine what the room holds as of now: the room reads the kernel's level for
    /// the question once, for every kind (ADR 0057).
    private func askRoom() {
        guard let room else { return }
        room.readMemory(.decision)
        Self.tell(admission, room)
    }

    /// Performs the room's holds and share, logs each load the machine found had run into a
    /// memory hold that began in this step (`op=load.admission phase=pressureRaised`), and asks
    /// the room for the share a waiting load needs.
    private static func tell(_ admission: Admission<LoadAdmissionMachine>, _ room: BackgroundRoom) {
        let holds = LoadRoomHolds(room.conditions, availablePercent: room.availablePercent)
        let (raised, wanted) = admission.performReading(.room(holds)) { before, after in
            (after.pressureRaisers.filter { before.pressureRaisers[$0.key] == nil }, after.headroomWanted)
        }
        for (load, available) in raised.sorted(by: { $0.key.launchRank < $1.key.launchRank }) {
            OtosLog.performance.noticeOperation("load.admission", phase: "pressureRaised", fields: [
                "load": load.rawValue, "memory": holds.heavyLoad?.rawValue ?? "open",
                "availableAtGrant": available.map { "\($0)" } ?? "unknown",
                "available": holds.availablePercent.map { "\($0)" } ?? "unknown",
            ])
        }
        room.wantHeadroom(above: wanted)
    }
}
