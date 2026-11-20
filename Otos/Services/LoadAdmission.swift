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
    /// (`docs/research/2026-11-17-launch-pressure-dips.md`). It takes the turn, so no heavy
    /// background load runs beside it, but its cost is accepted (the owner, 2026-11-18: "OS
    /// will swap running apps"): the room holds it only for what it holds a description for
    /// (`BackgroundWork.description`: critical memory, heat, Low Power Mode), a grant of it
    /// measures no cost, and the load the current view needs starts beside it.
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

    /// The kernel's available share (percent) below which the owner's Mac has gone to
    /// memory-pressure warning: across the tours of `docs/research/2026-11-17-launch-pressure-dips.md`
    /// the kernel read warning at as much as 31 % available, never above, and returned to normal
    /// only at 33 % or more. A heavy load that raised the pressure is admitted against this line
    /// plus what it was seen to cost (`LoadAdmissionMachine.RoomNeed`).
    static let warningLinePercent = 32

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
/// needs (`want`) goes before every other waiting one; it does not stop the one running. While
/// a description request holds the turn, the view's load starts beside it (`beside`) in the
/// step it is wanted or asked: a request runs up to 11 s, and a click is never answered behind
/// one. A load the user waits on (`requestForUser`) is granted at once, before the first grid
/// and beside the one running, and while one runs no waiting load is granted. While the
/// background room holds a load's kind (`room(_:)`, ADR 0057), that load waits, except the one
/// the view needs; the rest start in the step that opens the room — one, since one runs at a
/// time, and the next at its release.
///
/// A heavy load that raised the pressure is admitted against the room it was seen to take
/// (`roomNeeds`): it starts in the background only while the kernel reports at least
/// `RoomNeed.requiredPercent` available, the warning line plus its cost. No load has a
/// requirement until a grant of it raises the pressure. When the room's memory hold begins,
/// the background load granted last is the one that ran into it: loads run one at a time, so
/// it is the load the machine was carrying when the level rose. Its measured cost is the share
/// at its grant less the lowest share read since, the hold's own read included, and its
/// requirement ratchets to the largest of what it was, the line plus that cost, and one point
/// above the share it was granted at — so a grant that raised the pressure is never repeated
/// into the same room. The requirement never falls in the session. Such a load also waits
/// behind every other waiting load, so the room reopens on the loads that did not raise the
/// pressure and sees each alone. A description is never measured: its cost is the owner's to
/// accept (2026-11-18), so its grant, and a grant beside it, leave no load to blame. Nor does
/// it ever wait for headroom. `headroomRequired` asks the room to read the kernel until the
/// share reaches a waiting load's requirement. An unread share admits a load: an error is not
/// a fact. `shutdown` refuses every waiting load and every later request, and grants nothing
/// again.
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
        /// The user now waits on a load of this kind that is waiting: each waiting request of
        /// it becomes one the user waits on, granted at once (a People pass owed to the user's
        /// own act, asked before the act and still waiting in the room's hold).
        case promote(BackgroundLoad)
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
    /// The load the current view needs, granted beside a running description: no other load
    /// is granted while it runs.
    private(set) var beside: Waiting?
    /// The loads the user waits on that run now: no waiting load is granted beside them.
    private(set) var runningForUser: [Waiting] = []
    /// In the order they run when nothing is wanted.
    private(set) var waiting: [Waiting] = []
    private(set) var wanted: BackgroundLoad?
    private(set) var room = LoadRoomHolds.open
    /// Loads granted, by kind: what a test counts to see a held load start exactly once.
    private(set) var granted: [BackgroundLoad: Int] = [:]
    /// The heavy load granted alone most recently, the available shares read since its grant,
    /// and whether a memory hold began since; nil once a description is granted, which is
    /// never measured.
    private(set) var lastGranted: LastGrant?
    /// What each heavy load needs of the room to start, as learned in this session: none until
    /// a grant of it raised the pressure.
    private(set) var roomNeeds: [BackgroundLoad: RoomNeed] = [:]

    struct LastGrant: Equatable, Sendable {
        let load: BackgroundLoad
        /// The kernel's available share (percent) at the grant, or nil unread.
        let availablePercent: Int?
        /// The lowest share read from the grant until a memory hold began, or nil unread.
        var lowestPercent: Int?
        var ranIntoHold: Bool
    }

    /// What a load needs of the room to start.
    struct RoomNeed: Equatable, Sendable {
        /// The kernel's available share (percent) at or above which it may start, or nil when
        /// no read share gave one.
        var requiredPercent: Int?
        /// How many of its grants raised the pressure in this session.
        var raises = 0

        /// The need after `grant` raised the pressure: the largest of the requirement before,
        /// the warning line plus the cost it was seen to take, and one point above the share it
        /// was granted at. A grant whose share was unread measures nothing and moves nothing.
        func raised(by grant: LastGrant) -> RoomNeed {
            var required = requiredPercent
            if let granted = grant.availablePercent {
                let measured = grant.lowestPercent.map { BackgroundLoad.warningLinePercent + granted - $0 }
                required = [required, measured, granted + 1].compactMap(\.self).max()
            }
            return RoomNeed(requiredPercent: required, raises: raises + 1)
        }
    }

    /// The available share a waiting load needs and the room does not give now: the smallest
    /// such requirement among loads the room does not hold, or nil when none waits on one. The
    /// shell asks the room to read the kernel until the share reaches it, since nothing reports
    /// a rise.
    var headroomRequired: Int? {
        waiting.compactMap { waiting -> Int? in
            guard room.hold(for: waiting.load) == nil, !hasHeadroom(for: waiting.load) else { return nil }
            return roomNeeds[waiting.load]?.requiredPercent
        }.min()
    }

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    /// Every load running now: the turn's, the view's beside a description, and the user's.
    var runningLoads: [BackgroundLoad] {
        [running, beside].compactMap(\.self).map(\.load) + runningForUser.map(\.load)
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
        case let .promote(load):
            guard !isShutDown else { return [] }
            let promoted = waiting.filter { $0.load == load }
            waiting.removeAll { $0.load == load }
            runningForUser += promoted
            return promoted.map { .grant($0.request, $0.load) }
        case let .withdraw(request):
            guard let index = waiting.firstIndex(where: { $0.request == request }) else { return [] }
            waiting.remove(at: index)
            return [.refuse(request)]
        case let .release(request):
            if let ended = running, ended.request == request {
                running = nil
            } else if let ended = beside, ended.request == request {
                beside = nil
            } else if let index = runningForUser.firstIndex(where: { $0.request == request }) {
                runningForUser.remove(at: index)
            } else {
                return []
            }
        case let .want(load):
            wanted = load
        case let .room(holds):
            applyRoom(holds)
        case .shutdown:
            guard !isShutDown else { return [] }
            isShutDown = true
            let refused = waiting.map { Effect.refuse($0.request) }
            waiting = []
            return refused
        }
        return grantIfIdle()
    }

    /// What the room holds now; the grant that ran into a memory hold beginning is charged
    /// the cost it was seen to take (`RoomNeed.raised(by:)`).
    private mutating func applyRoom(_ holds: LoadRoomHolds) {
        if var last = lastGranted, !last.ranIntoHold {
            if let available = holds.availablePercent {
                last.lowestPercent = min(last.lowestPercent ?? available, available)
            }
            // Each grant raises the pressure at most once: a later hold with no grant
            // between is the same room, not a new cost.
            if holds.memory, !room.memory {
                last.ranIntoHold = true
                roomNeeds[last.load] = (roomNeeds[last.load] ?? RoomNeed()).raised(by: last)
            }
            lastGranted = last
        }
        room = holds
    }

    private mutating func grantIfIdle() -> [Effect] {
        guard isOpen, !isShutDown, beside == nil, runningForUser.isEmpty, !waiting.isEmpty else { return [] }
        // The load the view cannot show its answer without starts whatever the room holds;
        // any other waits while the room holds its kind or gives less than it needs, and one
        // that raised the pressure, or one that runs last, waits behind the rest.
        let wantedIndex = wanted.flatMap { load in waiting.firstIndex { $0.load == load } }
        if let running {
            // A description's turn yields to the view: its load starts beside the request.
            // Two run at once, so neither is measured.
            guard running.load == .description, let wantedIndex else { return [] }
            let next = waiting.remove(at: wantedIndex)
            beside = next
            granted[next.load, default: 0] += 1
            lastGranted = nil
            return [.grant(next.request, next.load)]
        }
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
        // The pressure a description raises is its own, accepted cost: it is charged to no load.
        lastGranted = next.load == .description ? nil : LastGrant(
            load: next.load, availablePercent: room.availablePercent, lowestPercent: room.availablePercent,
            ranIntoHold: false
        )
        return [.grant(next.request, next.load)]
    }

    /// Whether the kernel now reports at least the share `load` needs. True for a load with no
    /// requirement (a description always), and when the share is unread.
    func hasHeadroom(for load: BackgroundLoad) -> Bool {
        guard let required = roomNeeds[load]?.requiredPercent, let available = room.availablePercent else { return true }
        return available >= required
    }

    /// Where a waiting load stands among the startable ones: those asked for first, then
    /// those that raised the pressure in this session, then readying a search.
    private func order(of load: BackgroundLoad) -> Int {
        if load.runsLast {
            return 2
        }
        return (roomNeeds[load]?.raises ?? 0) > 0 ? 1 : 0
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
/// needs goes first, beside a description request if one runs (`LoadAdmissionMachine`). A
/// load the user waits on (`LoadWaiter.user`) runs at once and holds the waiting ones back
/// while it runs.
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
        // Every step tells the room the share a waiting load needs, in the step's order: a
        // request that waits for headroom, a release that leaves one first in line, a read
        // that gives one enough. Nothing reports a rise in available memory, so the room
        // reads the kernel on its look while a requirement stands unmet (ADR 0057).
        let admission = Admission(LoadAdmissionMachine(isOpen: isOpen)) { [weak room] machine in
            room?.wantHeadroom(atLeast: machine.headroomRequired)
        }
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

    /// The user now waits on `load`: a request of it that waits is granted at once, as a load
    /// the user waits on (`LoadWaiter.user`). Nothing waiting, nothing changes.
    func promote(_ load: BackgroundLoad) {
        admission.perform(.promote(load))
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
        // A background request the user came to wait on (`promote`) was granted as theirs.
        let grantedFor: LoadWaiter = admission.machine.runningForUser.contains { $0.request == request } ? .user : waiter
        OtosLog.performance.noticeOperation("load.admission", phase: "granted", fields: [
            "load": load.rawValue, "request": "\(request)", "waiter": grantedFor.rawValue,
            "waitMs": "\(DiagnosticsTiming.milliseconds(since: asked))",
            // The turn is held at this priority: one below the owners' holds every waiting
            // load behind work the system throttles.
            "priority": "\(Task.currentPriority.rawValue)",
        ])
        let started = ContinuousClock.now
        defer {
            askRoom()
            admission.release(request)
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

    /// What the background room holds `load`'s kind for now, or nil: what an owner names in
    /// its status while its load waits (`heldBy`). Reads the kernel's level first.
    func hold(for load: BackgroundLoad) -> BackgroundHold? {
        room?.hold(for: load.work)
    }

    /// Tells the machine what the room holds as of now: the room reads the kernel's level for
    /// the question once, for every kind (ADR 0057).
    private func askRoom() {
        guard let room else { return }
        room.readMemory(.decision)
        Self.tell(admission, room)
    }

    /// Performs the room's holds and share. Logs each beginning and end of the room's memory
    /// hold with the loads that ran up to it (`op=load.admission phase=memoryHold held=
    /// running=`): what the scorecard attributes a session's pressure by, since a description's
    /// is accepted (ADR 0015). Logs the grant the machine found had raised the pressure in this
    /// step (`phase=pressureRaised`) with the shares it was measured between and the
    /// requirement it now has.
    private static func tell(_ admission: Admission<LoadAdmissionMachine>, _ room: BackgroundRoom) {
        let holds = LoadRoomHolds(room.conditions, availablePercent: room.availablePercent)
        typealias Raise = (LoadAdmissionMachine.LastGrant, LoadAdmissionMachine.RoomNeed)
        let (turned, raised) = admission.performReading(.room(holds)) { before, after -> ([BackgroundLoad]?, Raise?) in
            let turned = before.room.memory != after.room.memory ? before.runningLoads : nil
            guard let grant = after.lastGranted, let need = after.roomNeeds[grant.load],
                  need.raises > (before.roomNeeds[grant.load]?.raises ?? 0) else { return (turned, nil) }
            return (turned, (grant, need))
        }
        if let running = turned {
            OtosLog.performance.noticeOperation("load.admission", phase: "memoryHold", fields: [
                "held": "\(holds.memory)", "memory": holds.heavyLoad?.rawValue ?? "open",
                "running": running.isEmpty ? "none" : running.map(\.rawValue).joined(separator: ","),
                "available": holds.availablePercent.map { "\($0)" } ?? "unknown",
            ])
        }
        guard let (grant, need) = raised else { return }
        OtosLog.performance.noticeOperation("load.admission", phase: "pressureRaised", fields: [
            "load": grant.load.rawValue, "memory": holds.heavyLoad?.rawValue ?? "open",
            "availableAtGrant": grant.availablePercent.map { "\($0)" } ?? "unknown",
            "lowestAvailable": grant.lowestPercent.map { "\($0)" } ?? "unknown",
            "available": holds.availablePercent.map { "\($0)" } ?? "unknown",
            "requiredPercent": need.requiredPercent.map { "\($0)" } ?? "unknown",
            "raises": "\(need.raises)",
        ])
    }
}
