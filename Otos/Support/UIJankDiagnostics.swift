import AppKit
import Foundation
import OSLog
import Synchronization

/// UI jank diagnostics guide
///
/// The monitor samples the active app's main run loop in debug builds. The
/// ViewModel supplies only the latest scalar grid handoff, so a delayed timer can
/// be correlated with catalog work without retaining a `CatalogWindowState` or
/// its asset dictionary. Frequent state and collection activity uses OSLog
/// (`op=`/`key=value`) for the agent and interval signposts for Instruments; a
/// main-thread stall emits one structured `.fault op=mainThreadStall` line.
///
/// Attribution: the tick runs only once the main thread is free again, so it
/// can flag a stall with the state around it (bracketedOp, currentOperation,
/// lastLongOperation) but cannot see what held the thread. A watcher on a
/// thread of its own (`StalledThreadWatcher`) samples the main thread's stack
/// while the stall lasts, and the tick reports those stacks as
/// `op=mainThreadStall.stack` lines carrying the stall's `stallID`
/// (`script/stall-stacks.sh` reads them back). A bracketedOp field states a fact (no bracketed
/// operation was in flight or recently completed) rather than implying a cause,
/// and a stall without a bracket is not a finding of "nothing was running."
nonisolated struct CatalogGridHandoff: Equatable {
    let updateID: Int
    let itemCount: Int
    let previousItemCount: Int
    let itemDelta: Int
    let selection: String
    let emptyState: String
    let mediaContentChanged: Bool
    let detailRefreshGeneration: UInt64
    let timestamp: ContinuousClock.Instant
}

nonisolated struct MainRunLoopOperationToken: Equatable {
    fileprivate let id: Int
}

/// A scope intent's surface painted (`op=ui.sidebarSelectionToPaint phase=finish`):
/// `revision` counts these reports.
nonisolated struct SidebarPaintReport: Equatable, Sendable {
    let revision: UInt64
    let scope: SidebarSelection
    let surface: String
    let milliseconds: Int
}

/// An act whose result the window shows in the step that applies it (DES-120): a choice
/// (Like, Dislike, Mark as Not Rated) or Move to Trash.
nonisolated enum WindowAct: Equatable, Sendable {
    case choice(MediaChoice)
    case moveToTrash

    /// The act's name in `op=ui.actToResult` lines: `liked`, `disliked`, `notRated`, `moveToTrash`.
    var name: String {
        switch self {
        case let .choice(choice): choice.rawValue
        case .moveToTrash: "moveToTrash"
        }
    }
}

/// An act's result reached the grid (`op=ui.actToResult phase=finish`): `revision` counts
/// these reports.
nonisolated struct ActResultReport: Equatable, Sendable {
    let revision: UInt64
    let act: WindowAct
    let surface: String
    let milliseconds: Int
}

@MainActor
final class MainRunLoopStallMonitor {
    private struct OperationRecord {
        let id: Int
        let name: String
        let startedAt: ContinuousClock.Instant
    }

    private struct CompletedOperationRecord {
        let name: String
        let durationMs: Int
        let finishedAt: ContinuousClock.Instant
    }

    /// One in-flight sidebar/filter/sort intent awaiting the structural apply that
    /// renders it. Begins in `CatalogWindowViewModel.setQueryDescriptor` when the
    /// scope changes and completes in the grid controller's `completeStructuralApply`
    /// for the same scope, so click→paint latency is measurable end to end.
    /// A newer intent abandons a pending one — its interval is closed and logged
    /// as abandoned, so a navigation the user moved on from never reads as one
    /// that hung. A pending that never reaches an apply of its scope and is never
    /// superseded holds at most one interval open.
    private struct PendingIntentToPaint {
        let signpost: OSSignpostIntervalState
        let scope: SidebarSelection
        let startedAt: ContinuousClock.Instant
    }

    private var timer: Timer?
    private var expectedFire: ContinuousClock.Instant?
    private var nextUpdateID = 0
    private var nextOperationID = 0
    private var latestHandoff: CatalogGridHandoff?
    private var operationStack: [OperationRecord] = []
    private var lastLongOperation: CompletedOperationRecord?
    private var pendingIntentToPaint: PendingIntentToPaint?
    private var paintReports: UInt64 = 0

    /// One act awaiting the grid change that shows its result: the tiles' badges
    /// reconfigured (a choice) or the items gone from an applied structure (Move to Trash).
    /// Begins where the act's intent is applied and ends in the grid controller. A newer act
    /// abandons a pending one, so at most one interval is open; an act whose items are not
    /// in the grid (the loupe, a filtered-out photo) stays pending until then.
    private struct PendingActToResult {
        let act: WindowAct
        let ids: Set<MediaAssetID>
        let startedAt: ContinuousClock.Instant
    }

    private var pendingActToResult: PendingActToResult?
    private var actReports: UInt64 = 0
    /// Told each time an act's result reaches the grid: the fact the window's owner
    /// republishes for whoever waits on it (a sandboxed tour).
    var onActResult: ((ActResultReport) -> Void)?
    /// Told each time a scope intent's surface paints: the fact the window's owner republishes
    /// for whoever waits on a paint (the tour) and checkpoints resources at.
    var onIntentPainted: ((SidebarPaintReport) -> Void)?
    /// Samples the main thread's stack while a stall lasts; present while started.
    private var watcher: StalledThreadWatcher?
    private var nextStallID = 0
    /// Optional MainActor-safe extra fields (e.g. mutation-gate exclusivity) sampled at stall time.
    var additionalStallFields: (() -> [String: String])?
    // time: measurement — the sampling period of the stall monitor
    private let interval = Duration.milliseconds(100)
    private let stallThreshold = Duration.milliseconds(100)
    private let longOperationThresholdMs = 100

    isolated deinit {
        timer?.invalidate()
        watcher?.stop()
    }

    func reserveUpdateID() -> Int {
        nextUpdateID += 1
        return nextUpdateID
    }

    func recordGridHandoff(_ handoff: CatalogGridHandoff) {
        latestHandoff = handoff
    }

    /// Starts the click→paint interval for a sidebar/scope intent. Called from the
    /// single query-descriptor writer when the scope changes on a user intent.
    /// Returns whether a still-pending intent was abandoned to make room.
    @discardableResult
    func beginIntentToPaint(scope: SidebarSelection) -> Bool {
        let abandoned = pendingIntentToPaint != nil
        if let pending = pendingIntentToPaint {
            pendingIntentToPaint = nil
            OtosSignpost.ui.endInterval("SidebarSelectionToPaint", pending.signpost)
            OtosLog.ui.noticeOperation(
                "ui.sidebarSelectionToPaint",
                phase: "abandoned",
                fields: [
                    "scope": pending.scope.diagnosticDescription,
                    "supersededBy": scope.diagnosticDescription,
                    "ms": "\(DiagnosticsTiming.milliseconds(since: pending.startedAt))",
                ]
            )
        }
        pendingIntentToPaint = PendingIntentToPaint(
            signpost: OtosSignpost.ui.beginInterval("SidebarSelectionToPaint"),
            scope: scope,
            startedAt: .now
        )
        OtosLog.ui.noticeOperation(
            "ui.sidebarSelectionToPaint",
            phase: "start",
            fields: ["scope": scope.diagnosticDescription]
        )
        return abandoned
    }

    /// Ends the click→paint interval when the surface that draws the intent's scope gets its
    /// content: a structural apply of the media grid (`surface` "grid"), or the state apply
    /// that hands a pane drawn in its place (`CatalogDetailSurface`) what it draws, which
    /// SwiftUI renders in the same main-thread turn. Returns whether a pending measurement
    /// was completed; a non-matching scope (an unrelated enrichment/scroll apply) leaves the
    /// pending interval untouched.
    @discardableResult
    func completeIntentToPaint(appliedScope: SidebarSelection, surface: String = "grid") -> Bool {
        guard let pending = pendingIntentToPaint, pending.scope == appliedScope else {
            return false
        }
        pendingIntentToPaint = nil
        OtosSignpost.ui.endInterval("SidebarSelectionToPaint", pending.signpost)
        let ms = DiagnosticsTiming.milliseconds(since: pending.startedAt)
        OtosLog.ui.noticeOperation(
            "ui.sidebarSelectionToPaint",
            phase: "finish",
            fields: ["scope": appliedScope.diagnosticDescription, "surface": surface, "ms": "\(ms)"]
        )
        paintReports &+= 1
        onIntentPainted?(SidebarPaintReport(revision: paintReports, scope: appliedScope, surface: surface, milliseconds: ms))
        return true
    }

    /// Starts the act→result interval for an act on `ids`, abandoning a pending one.
    func beginActToResult(_ act: WindowAct, ids: some Sequence<MediaAssetID>, now: ContinuousClock.Instant = .now) {
        if let pending = pendingActToResult {
            OtosLog.ui.noticeOperation("ui.actToResult", phase: "abandoned", fields: [
                "act": pending.act.name,
                "supersededBy": act.name,
                "ms": "\(DiagnosticsTiming.milliseconds(since: pending.startedAt))",
            ])
        }
        let ids = Set(ids)
        pendingActToResult = PendingActToResult(act: act, ids: ids, startedAt: now)
        OtosLog.ui.noticeOperation("ui.actToResult", phase: "start", fields: ["act": act.name, "count": "\(ids.count)"])
    }

    /// The grid drew `id`'s tile from the tile store, which holds a choice from the step that
    /// applied it: a pending choice on it has its result on screen. Any render counts — the
    /// choice's own reconfigure, or the tile laid out later when it was not on screen then.
    @discardableResult
    func completeChoiceToResult(rendered id: MediaAssetID) -> Bool {
        guard let pending = pendingActToResult, case .choice = pending.act, pending.ids.contains(id) else {
            return false
        }
        return completeActToResult(pending, surface: "grid")
    }

    /// The grid committed `grid`: a pending Move to Trash whose items it no longer shows has
    /// its result on screen.
    @discardableResult
    func completeTrashToResult(committed grid: CatalogMediaGridState) -> Bool {
        guard let pending = pendingActToResult, pending.act == .moveToTrash,
              !pending.ids.contains(where: grid.content.contains)
        else {
            return false
        }
        return completeActToResult(pending, surface: "grid")
    }

    private func completeActToResult(_ pending: PendingActToResult, surface: String) -> Bool {
        pendingActToResult = nil
        let ms = DiagnosticsTiming.milliseconds(since: pending.startedAt)
        OtosLog.ui.noticeOperation("ui.actToResult", phase: "finish", fields: [
            "act": pending.act.name, "count": "\(pending.ids.count)", "surface": surface, "ms": "\(ms)",
        ])
        actReports &+= 1
        onActResult?(ActResultReport(revision: actReports, act: pending.act, surface: surface, milliseconds: ms))
        return true
    }

    func beginOperation(_ name: String, now: ContinuousClock.Instant = .now) -> MainRunLoopOperationToken {
        nextOperationID += 1
        let record = OperationRecord(id: nextOperationID, name: name, startedAt: now)
        operationStack.append(record)
        return MainRunLoopOperationToken(id: record.id)
    }

    func endOperation(_ token: MainRunLoopOperationToken, now: ContinuousClock.Instant = .now) {
        guard let index = operationStack.lastIndex(where: { $0.id == token.id }) else {
            return
        }
        let record = operationStack.remove(at: index)
        let durationMs = DiagnosticsTiming.milliseconds(from: record.startedAt, to: now)
        lastLongOperation = CompletedOperationRecord(
            name: record.name,
            durationMs: durationMs,
            finishedAt: now
        )
    }

    func start() {
        #if DEBUG
            guard timer == nil else {
                return
            }

            expectedFire = ContinuousClock.now.advanced(by: interval)
            // The timer is scheduled on the main run loop, so its block already runs on
            // the main thread: ticking there directly measures the run loop's lateness,
            // where a `Task` hop would add its own scheduling delay to every sample.
            let timer = Timer(timeInterval: DiagnosticsTiming.seconds(interval), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            // `start` runs on the main thread (the monitor is main-actor isolated), so the
            // calling thread is the one to watch.
            let watcher = StalledThreadWatcher(watching: .current())
            self.watcher = watcher
            watcher.start()
            OtosLog.performance.debug("Main run loop stall monitor started")
        #else
            return
        #endif
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        expectedFire = nil
        latestHandoff = nil
        operationStack.removeAll()
        lastLongOperation = nil
        pendingIntentToPaint = nil
    }

    private func tick(now: ContinuousClock.Instant = .now) {
        // The samples are of the silence this tick ends: a stall reports them, and
        // anything else (an inactive app's coalesced timer, a lateness under the
        // threshold) discards them.
        let samples = watcher?.takeSamples() ?? []
        watcher?.beat()
        guard let expectedFire = activeExpectedFire(now: now) else {
            return
        }

        let lateness = expectedFire.duration(to: now)
        self.expectedFire = now.advanced(by: interval)
        guard lateness >= stallThreshold else {
            return
        }

        recordStall(stallMs: DiagnosticsTiming.milliseconds(lateness), now: now, samples: samples)
    }

    private func activeExpectedFire(now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        // Inactive apps are eligible for timer coalescing and App Nap. A late
        // main-run-loop timer in that state is not evidence of user-visible
        // jank, so reset the baseline until the app is active again.
        guard NSApplication.shared.isActive else {
            expectedFire = now.advanced(by: interval)
            return nil
        }

        guard let expectedFire else {
            expectedFire = now.advanced(by: interval)
            return nil
        }
        return expectedFire
    }

    private func recordStall(stallMs: Int, now: ContinuousClock.Instant, samples: [StackSample]) {
        nextStallID += 1
        let stallID = nextStallID
        let latestHandoff = latestHandoff
        let currentOperation = operationStack.last
        let lastLongOperation = lastLongOperation
        let extraFields = additionalStallFields?() ?? [:]
        let fields = stallFields(
            stallMs: stallMs,
            now: now,
            latestHandoff: latestHandoff,
            currentOperation: currentOperation,
            lastLongOperation: lastLongOperation,
            extraFields: extraFields
        )
        recordStallDiagnostic(fields.merging(["stallID": "\(stallID)", "stackSamples": "\(samples.count)"]) { $1 })
        for line in StallStackReport.lines(stallID: stallID, samples: samples) {
            OtosLog.performance.notice("op=mainThreadStall.stack \(otosLogFields(line.fields), privacy: .public)")
        }
    }

    private func stallFields(
        stallMs: Int,
        now: ContinuousClock.Instant,
        latestHandoff: CatalogGridHandoff?,
        currentOperation: OperationRecord?,
        lastLongOperation: CompletedOperationRecord?,
        extraFields: [String: String]
    ) -> [String: String] {
        var fields = [
            "stallMs": "\(stallMs)",
            "thresholdMs": "\(DiagnosticsTiming.milliseconds(stallThreshold))",
            "intervalMs": "\(DiagnosticsTiming.milliseconds(interval))",
        ]
        if let latestHandoff {
            fields["latestUpdateID"] = "\(latestHandoff.updateID)"
            fields["latestItems"] = "\(latestHandoff.itemCount)"
            fields["latestPreviousItems"] = "\(latestHandoff.previousItemCount)"
            fields["latestItemDelta"] = "\(latestHandoff.itemDelta)"
            fields["latestSelection"] = latestHandoff.selection
            fields["latestEmptyState"] = latestHandoff.emptyState
            fields["mediaContentChanged"] = "\(latestHandoff.mediaContentChanged)"
            fields["detailRefreshGeneration"] = "\(latestHandoff.detailRefreshGeneration)"
            fields["latestHandoffAgeMs"] = "\(DiagnosticsTiming.milliseconds(since: latestHandoff.timestamp, now: now))"
        }
        // Prefer the in-flight operation over a finished long op so stalls during
        // reconfigure are not blamed on a completed applyStructure.
        if let currentOperation {
            let ageMs = DiagnosticsTiming.milliseconds(since: currentOperation.startedAt, now: now)
            fields["currentOperation"] = currentOperation.name
            fields["currentOperationAgeMs"] = "\(ageMs)"
        }
        if let lastLongOperation {
            let ageMs = DiagnosticsTiming.milliseconds(since: lastLongOperation.finishedAt, now: now)
            fields["lastLongOperation"] = lastLongOperation.name
            fields["lastLongOperationMs"] = "\(lastLongOperation.durationMs)"
            fields["lastLongOperationAgeMs"] = "\(ageMs)"
        }
        for (key, value) in extraFields {
            fields[key] = value
        }
        return fields
    }

    private func recordStallDiagnostic(_ fields: [String: String]) {
        let bracketedOp = fields["currentOperation"] ?? fields["lastLongOperation"] ?? "unattributed"
        OtosLog.performance.fault(
            "op=mainThreadStall bracketedOp=\(bracketedOp, privacy: .public) \(otosLogFields(fields), privacy: .public)"
        )
    }
}

// MARK: - Stacks of a stalled main thread

/// One reading of a thread's call stack: return addresses, innermost first, with the
/// image and nearest symbol `dladdr` names for each, read after the thread was resumed.
nonisolated struct StackSample: Equatable, Sendable {
    struct Frame: Hashable, Sendable {
        /// The image's file name (`Otos`, `libsystem_kernel.dylib`).
        let image: String
        /// The address's offset into its image, which `atos -l 0` resolves offline.
        let offset: UInt
        /// The nearest symbol the image names, mangled as stored; nil when it names none.
        let symbol: String?
    }

    let frames: [Frame]
}

/// Reads another thread's call stack by suspending it, reading its registers, walking
/// its frame-pointer chain inside its own stack, and resuming it.
///
/// While the thread is suspended nothing here allocates, locks or logs: the suspended
/// thread may hold the allocator's or the logging system's lock, and taking either then
/// would deadlock both threads. The return addresses go into a buffer allocated before
/// the suspension; naming them (`dladdr`, which takes dyld's lock) happens after resume.
nonisolated enum ThreadStackSampler {
    /// The deepest stack a sample keeps.
    static let maximumFrames = 64

    /// A thread to sample and the bounds of its stack, which every frame pointer read
    /// must fall inside.
    struct Target: Sendable {
        let port: mach_port_t
        let stackLow: UInt
        let stackHigh: UInt

        /// The calling thread.
        static func current() -> Target {
            target(of: pthread_self())
        }

        private static func target(of thread: pthread_t) -> Target {
            let high = UInt(bitPattern: pthread_get_stackaddr_np(thread))
            return Target(
                port: pthread_mach_thread_np(thread),
                stackLow: high - UInt(pthread_get_stacksize_np(thread)),
                stackHigh: high
            )
        }
    }

    /// The target's stack, innermost frame first; nil when the thread could not be
    /// suspended or read (it ended, or this architecture has no reader).
    static func sample(_ target: Target) -> StackSample? {
        let addresses = UnsafeMutableBufferPointer<UInt>.allocate(capacity: maximumFrames)
        defer { addresses.deallocate() }
        let count = readReturnAddresses(target, into: addresses)
        guard count > 0 else {
            return nil
        }
        return StackSample(frames: addresses.prefix(count).map(frame(at:)))
    }

    #if arch(arm64)
        /// The pointer bits of an address: return addresses saved by arm64e system code
        /// carry a pointer-authentication signature in the bits above the 47-bit user
        /// address space.
        private static let addressMask: UInt = 0x7FFF_FFFF_FFFF

        private static func readReturnAddresses(_ target: Target, into buffer: UnsafeMutableBufferPointer<UInt>) -> Int {
            guard thread_suspend(target.port) == KERN_SUCCESS else {
                return 0
            }
            defer { thread_resume(target.port) }
            var state = arm_thread_state64_t()
            var stateCount = mach_msg_type_number_t(
                MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
            )
            let status = withUnsafeMutablePointer(to: &state) { pointer in
                pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                    thread_get_state(target.port, ARM_THREAD_STATE64, $0, &stateCount)
                }
            }
            guard status == KERN_SUCCESS else {
                return 0
            }
            buffer[0] = UInt(state.__pc) & addressMask
            var count = 1
            var framePointer = UInt(state.__fp)
            // Each frame record is (caller's frame pointer, return address). A pointer
            // outside the stack, misaligned, or not moving outward ends the walk, so a
            // frame built without a frame pointer can never send the read astray.
            while count < buffer.count,
                  framePointer >= target.stackLow,
                  framePointer + 16 <= target.stackHigh,
                  framePointer & 0xF == 0,
                  let record = UnsafePointer<UInt>(bitPattern: framePointer)
            {
                let returnAddress = record[1] & addressMask
                guard returnAddress != 0 else {
                    break
                }
                buffer[count] = returnAddress
                count += 1
                let caller = record[0]
                guard caller > framePointer else {
                    break
                }
                framePointer = caller
            }
            return count
        }
    #else
        private static func readReturnAddresses(_: Target, into _: UnsafeMutableBufferPointer<UInt>) -> Int {
            0
        }
    #endif

    private static func frame(at address: UInt) -> StackSample.Frame {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase else {
            return StackSample.Frame(image: "?", offset: address, symbol: nil)
        }
        let path = info.dli_fname.map { String(cString: $0) } ?? "?"
        return StackSample.Frame(
            image: path.split(separator: "/").last.map(String.init) ?? path,
            offset: address - UInt(bitPattern: base),
            symbol: info.dli_sname.map { String(cString: $0) }
        )
    }
}

/// Samples a thread's stack while it stops answering, so a stall's report says what that
/// thread was doing rather than only that it was late.
///
/// The watched thread calls `beat()` whenever it runs (the stall monitor's tick, every
/// 100 ms). The watcher runs on a thread of its own, the one place that can see a stall
/// while it is happening: from the second missed beat on, it samples the watched thread
/// every 50 ms and keeps the samples until the watched thread, running again, takes them.
final nonisolated class StalledThreadWatcher: Sendable {
    /// A beat older than this is a stall in progress: one tick period (100 ms) plus half.
    static let silenceThreshold = Duration.milliseconds(150)
    /// The most samples one stall keeps; a longer stall keeps its first ones.
    static let maximumSamples = 100

    private let target: ThreadStackSampler.Target
    private let lastBeat: Atomic<UInt64>
    private let isStopped = Atomic<Bool>(false)
    private let samples = Mutex<[StackSample]>([])

    init(watching target: ThreadStackSampler.Target) {
        self.target = target
        lastBeat = Atomic(Self.now())
    }

    /// Starts the watcher's thread; it ends after `stop()`.
    func start() {
        let thread = Thread { [self] in
            watch()
        }
        thread.name = "net.melisma.Otos.stallWatcher"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        isStopped.store(true, ordering: .relaxed)
    }

    /// The watched thread is running.
    func beat() {
        lastBeat.store(Self.now(), ordering: .relaxed)
    }

    /// The samples taken since the last call, oldest first.
    func takeSamples() -> [StackSample] {
        samples.withLock { taken in
            defer { taken.removeAll(keepingCapacity: true) }
            return taken
        }
    }

    private func watch() {
        let threshold = UInt64(DiagnosticsTiming.milliseconds(Self.silenceThreshold)) * 1_000_000
        while !isStopped.load(ordering: .relaxed) {
            // time: measurement — the watcher's sampling period while a stall lasts
            Thread.sleep(forTimeInterval: 0.05)
            guard Self.now() &- lastBeat.load(ordering: .relaxed) >= threshold else {
                continue
            }
            let full = samples.withLock { $0.count >= Self.maximumSamples }
            guard !full, let sample = ThreadStackSampler.sample(target) else {
                continue
            }
            samples.withLock { $0.append(sample) }
        }
    }

    /// Nanoseconds on the clock `ContinuousClock` reads, as a value an atomic can hold.
    private static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }
}

/// The log lines that report a stall's stacks, each split into parts that fit one
/// unified-log message. Two samples of one stall rarely share a whole stack (the
/// innermost frames move), so three views count frames across samples, as a profiler
/// does:
/// - `kind=heaviest`: every frame with the number of samples it appears in, most first.
///   Its head is the trunk every sample shares: the run loop, and what it was serving.
/// - `kind=own`: the same count over Otos's own frames only, which name the Otos code on
///   the stack below the frameworks' trunk.
/// - `kind=leaf`: the innermost frame of each sample, by count: where the time was spent.
/// - `kind=stack`: each stack sampled more than once, most sampled first, whole.
nonisolated enum StallStackReport {
    /// The unified log keeps about 1,017 characters of a message and drops the rest
    /// (measured 2026-11-11); a part stays under this with room for its fields.
    static let partCharacterLimit = 900
    /// The frames each counted view keeps.
    static let maximumHeaviestFrames = 40
    /// The image Otos's own code is in: `Otos` installed, `Otos.debug.dylib` in a dev
    /// build, the test bundle's image under test.
    static let ownImage: String = {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else {
            return "?"
        }
        let path = String(cString: name)
        return path.split(separator: "/").last.map(String.init) ?? path
    }()

    /// The repeated stacks a stall reports.
    static let maximumStacks = 2
    /// The characters of a symbol a frame keeps.
    static let maximumSymbolCharacters = 300

    struct Line: Equatable {
        let fields: [String: String]
    }

    static func lines(stallID: Int, samples: [StackSample]) -> [Line] {
        guard !samples.isEmpty else {
            return []
        }
        var lines: [Line] = []
        let counted = [
            ("heaviest", heaviest(samples)),
            ("own", heaviest(samples) { $0.image == ownImage }),
            ("leaf", heaviest(samples.compactMap { $0.frames.first.map { StackSample(frames: [$0]) } })),
        ]
        for (kind, frames) in counted where !frames.isEmpty {
            lines += parts(of: frames).enumerated().map { index, part in
                Line(fields: [
                    "stallID": "\(stallID)", "kind": kind, "ofSamples": "\(samples.count)",
                    "part": "\(index + 1)", "frames": part.joined(separator: "|"),
                ])
            }
        }
        var counts: [[StackSample.Frame]: Int] = [:]
        var order: [[StackSample.Frame]] = []
        for sample in samples {
            if counts[sample.frames] == nil {
                order.append(sample.frames)
            }
            counts[sample.frames, default: 0] += 1
        }
        let repeated = order.enumerated()
            .filter { counts[$0.element]! > 1 }
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .prefix(maximumStacks)
            .map(\.element)
        for (stackIndex, frames) in repeated.enumerated() {
            for (partIndex, part) in parts(of: frames.map(text(of:))).enumerated() {
                lines.append(Line(fields: [
                    "stallID": "\(stallID)", "kind": "stack", "stack": "\(stackIndex + 1)",
                    "samples": "\(counts[frames]!)", "ofSamples": "\(samples.count)",
                    "part": "\(partIndex + 1)", "frames": part.joined(separator: "|"),
                ]))
            }
        }
        let partTotals = Dictionary(grouping: lines) { [$0.fields["kind"], $0.fields["stack"]] }.mapValues(\.count)
        return lines.map { line in
            var fields = line.fields
            fields["parts"] = "\(partTotals[[line.fields["kind"], line.fields["stack"]]]!)"
            return Line(fields: fields)
        }
    }

    /// `count*frame` for each frame `including` keeps, by the number of samples it appears
    /// in, most first; a tie goes to the frame nearer the stack's root, so the shared trunk
    /// reads outward-in.
    static func heaviest(
        _ samples: [StackSample],
        including: (StackSample.Frame) -> Bool = { _ in true }
    ) -> [String] {
        var counts: [StackSample.Frame: Int] = [:]
        var depthFromRoot: [StackSample.Frame: Int] = [:]
        for sample in samples {
            for (index, frame) in sample.frames.reversed().enumerated() {
                depthFromRoot[frame] = min(depthFromRoot[frame] ?? index, index)
            }
            for frame in Set(sample.frames) where including(frame) {
                counts[frame, default: 0] += 1
            }
        }
        return counts.keys
            .sorted { (counts[$0]!, -depthFromRoot[$0]!) > (counts[$1]!, -depthFromRoot[$1]!) }
            .prefix(maximumHeaviestFrames)
            .map { "\(counts[$0]!)*\(text(of: $0))" }
    }

    /// `image+0xoffset` with `:symbol` when the image names one. A space in a symbol (an
    /// Objective-C method's, `-[NSApplication sendEvent:]`) becomes `_`, because a space
    /// ends a `key=value` field for every reader of the line.
    static func text(of frame: StackSample.Frame) -> String {
        let location = "\(frame.image)+0x\(String(frame.offset, radix: 16))"
        guard let symbol = frame.symbol else {
            return location
        }
        return "\(location):\(symbol.prefix(maximumSymbolCharacters).replacing(" ", with: "_"))"
    }

    private static func parts(of frames: [String]) -> [[String]] {
        var parts: [[String]] = [[]]
        var length = 0
        for frame in frames {
            if !parts[parts.count - 1].isEmpty, length + frame.count + 1 > partCharacterLimit {
                parts.append([])
                length = 0
            }
            parts[parts.count - 1].append(frame)
            length += frame.count + 1
        }
        return parts
    }
}
