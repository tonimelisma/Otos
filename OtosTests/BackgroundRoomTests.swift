import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The background room (ADR 0057): heavy work waits while the machine reports no room for
/// it, and starts exactly once in the step that delivers the conditions that open it. Every
/// condition here is scripted; nothing waits on time.
@Suite(.testScope)
struct BackgroundRoomTests {
    static let warning = MachineConditions(memory: .warning, thermal: .nominal, lowPower: false, userInApp: false)
    static let critical = MachineConditions(memory: .critical, thermal: .nominal, lowPower: false, userInApp: false)

    /// One candidate whose preview does not exist: a reading of it answers `.undecodable`.
    static func page(in directory: URL) -> [SearchTextCandidate] {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        return [SearchTextCandidate(id: id, previewPath: "missing.heic", source: "preview")]
    }

    /// What each condition holds, kind by kind.
    @Test func eachConditionHoldsTheKindsItShould() {
        for work in BackgroundWork.allCases {
            #expect(MachineConditions.roomy.hold(for: work) == nil)
            #expect(Self.warning.hold(for: work) == .memoryWarning)
            #expect(Self.critical.hold(for: work) == .memoryCritical)
            var hot = MachineConditions.roomy
            hot.thermal = .serious
            #expect(hot.hold(for: work) == .thermal)
            hot.thermal = .fair
            #expect(hot.hold(for: work) == nil)
            var saving = MachineConditions.roomy
            saving.lowPower = true
            #expect(saving.hold(for: work) == .lowPower)
        }
        var inApp = MachineConditions.roomy
        inApp.userInApp = true
        #expect(inApp.hold(for: .description) == .userInApp)
        for work in BackgroundWork.allCases where work != .description {
            #expect(inApp.hold(for: work) == nil)
        }
    }

    /// At `warning` no waiter is let start; at `normal` each is let start once, and a second
    /// hold and opening admits nothing more.
    @Test func heldWaitersStartExactlyOnceWhenTheRoomOpens() async throws {
        let room = BackgroundRoom(conditions: Self.warning)
        let started = Mutex(0)
        let waiters = (0 ..< 3).map { _ in
            Task {
                try await room.untilOpen(for: .description)
                started.withLock { $0 += 1 }
            }
        }
        try await waitUntil { room.counts.waiting[.description] == 3 }
        #expect(started.withLock { $0 } == 0)
        #expect(room.counts.admitted[.description] == nil)

        room.deliver(.roomy)
        for waiter in waiters {
            try await waiter.value
        }
        #expect(started.withLock { $0 } == 3)
        #expect(room.counts.admitted[.description] == 3)
        #expect(room.counts.held[.description] == 3)

        room.deliver(Self.warning)
        room.deliver(.roomy)
        #expect(room.counts.admitted[.description] == 3)
        #expect(room.counts.waiting.isEmpty)
    }

    /// A waiter whose task is cancelled stops waiting and is never let start.
    @Test func aCancelledWaiterWithdraws() async throws {
        let room = BackgroundRoom(conditions: Self.warning)
        let waiter = Task { try await room.untilOpen(for: .textReading) }
        try await waitUntil { room.counts.waiting[.textReading] == 1 }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(room.counts.waiting.isEmpty)
        room.deliver(.roomy)
        #expect(room.counts.admitted[.textReading] == nil)
    }

    /// A kind the conditions do not hold starts at once, beside a held one.
    @Test func anOpenKindDoesNotWaitBesideAHeldOne() async throws {
        var inApp = MachineConditions.roomy
        inApp.userInApp = true
        let room = BackgroundRoom(conditions: inApp)
        try await room.untilOpen(for: .textReading)
        #expect(room.counts.admitted[.textReading] == 1)
        #expect(room.hold(for: .description) == .userInApp)
    }

    /// A held room grants only the load the view needs; the others start, each once, in
    /// their order, in the step that opens it (ADR 0055, ADR 0057).
    @Test func aHeldRoomGrantsOnlyTheWantedHeavyLoad() async throws {
        let room = BackgroundRoom(conditions: Self.warning)
        let admission = LoadAdmission(isOpen: true, room: room)
        let order = Mutex<[BackgroundLoad]>([])
        admission.want(.people)
        // Each asks once the one before is waiting: their order is the test's, not the
        // scheduler's.
        var loads: [Task<Void, any Error>] = []
        for (asked, load) in [BackgroundLoad.duplicates, .searchIndex].enumerated() {
            loads.append(Task { try await admission.run(load) { order.withLock { $0.append(load) } } })
            try await waitUntil { admission.snapshot.waiting.count == asked + 1 }
        }
        loads.append(Task { try await admission.run(.people) { order.withLock { $0.append(.people) } } })
        try await waitUntil { order.withLock { $0 } == [.people] }
        try await waitUntil { admission.snapshot.waiting.count == 2 && admission.snapshot.running == nil }
        #expect(admission.snapshot.granted == [.people: 1])

        room.deliver(.roomy)
        for load in loads {
            try await load.value
        }
        #expect(order.withLock { $0 } == [.people, .duplicates, .searchIndex])
        #expect(admission.snapshot.granted == [.people: 1, .duplicates: 1, .searchIndex: 1])
    }

    /// The text reader starts no helper while the room holds text reading; the page stops
    /// before its first reading, and reads once the room opens.
    @Test func theTextReaderStartsNoHelperWhileHeld() async throws {
        let room = BackgroundRoom(conditions: Self.warning)
        let starts = Mutex(0)
        let reader = SearchTextReader(startSession: {
            starts.withLock { $0 += 1 }
            return RecognizingSession { _ in [] }
        }, room: room)
        let directory = try makeTestDirectory()
        let page = Self.page(in: directory)
        #expect(await reader.read(page, directory: directory) == .held(before: [], attempted: 0))
        #expect(starts.withLock { $0 } == 0)

        room.deliver(.roomy)
        #expect(await reader.read(page, directory: directory) == .read([]))
        #expect(starts.withLock { $0 } == 1)
    }

    /// A helper idle between pages is let go in the step the hold is delivered: the next page
    /// after the room opens starts a new one.
    @Test func anIdleHelperIsLetGoWhenTheRoomHolds() async throws {
        let room = BackgroundRoom()
        let closed = Mutex(0)
        let starts = Mutex(0)
        let reader = SearchTextReader(startSession: {
            starts.withLock { $0 += 1 }
            return ClosingSession { closed.withLock { $0 += 1 } }
        }, room: room)
        let directory = try makeTestDirectory()
        let page = Self.page(in: directory)
        _ = await reader.read(page, directory: directory)
        #expect(starts.withLock { $0 } == 1)

        room.deliver(Self.warning)
        #expect(closed.withLock { $0 } == 1)
        room.deliver(.roomy)
        _ = await reader.read(page, directory: directory)
        #expect(starts.withLock { $0 } == 2)
        #expect(closed.withLock { $0 } == 1)
    }

    /// The kernel at `warning` and a source that never says so: every decision reads the
    /// kernel, so no kind is let start — a serial waiter waits, and a heavy load asked for
    /// after the kernel rose is not granted though the admission last heard `normal`.
    @Test func aWarningTheSourceNeverAnnouncedHoldsEveryKind() async throws {
        let kernel = ScriptedKernel(.normal)
        let room = BackgroundRoom(memory: kernel.reader)
        let admission = LoadAdmission(isOpen: true, room: room)
        #expect(admission.snapshot.roomHeld == false)

        kernel.set(.warning)
        for work in BackgroundWork.allCases {
            #expect(room.hold(for: work) == .memoryWarning)
        }
        let waiter = Task { try await room.untilOpen(for: .description) }
        try await waitUntil { room.counts.waiting[.description] == 1 }
        let ran = Mutex(false)
        let load = Task { try await admission.run(.duplicates) { ran.withLock { $0 = true } } }
        try await waitUntil { admission.snapshot.waiting.count == 1 }
        #expect(admission.snapshot.granted.isEmpty)
        #expect(ran.withLock { $0 } == false)
        #expect(room.counts.admitted.isEmpty)

        room.sourceReported(.normal)
        kernel.set(.normal)
        room.sourceReported(.normal)
        try await waiter.value
        try await load.value
        #expect(ran.withLock { $0 })
        #expect(room.counts.admitted[.description] == 1)
    }

    /// The kernel back at `normal` and a source that stays silent: the room, holding a level
    /// above normal, looks again, and the held waiter starts in the step of that look.
    @Test func aReturnToNormalTheSourceNeverAnnouncedResumesHeldOwnersAtTheNextLook() async throws {
        let kernel = ScriptedKernel(.warning)
        let room = BackgroundRoom(memory: kernel.reader)
        let waiter = Task { try await room.untilOpen(for: .textReading) }
        try await waitUntil { room.counts.waiting[.textReading] == 1 }
        try await waitUntil { kernel.looking }

        // A look while the kernel still says warning opens nothing, and the room looks again.
        kernel.tick()
        try await waitUntil { kernel.looks == 2 && kernel.looking }
        #expect(room.counts.waiting[.textReading] == 1)

        kernel.set(.normal)
        kernel.tick()
        try await waiter.value
        #expect(room.counts.admitted[.textReading] == 1)
        #expect(room.conditions.memory == .normal)

        // A later rise found by a decision arms the look again.
        kernel.set(.critical)
        #expect(room.hold(for: .download) == .memoryCritical)
        try await waitUntil { kernel.looks == 3 && kernel.looking }
    }

    /// The source and the kernel disagree: the kernel's current level wins, either way.
    @Test func theKernelsLevelWinsOverTheSourcesReport() {
        let kernel = ScriptedKernel(.normal)
        let room = BackgroundRoom(memory: kernel.reader)
        room.sourceReported(.warning)
        #expect(room.conditions.memory == .normal)
        #expect(room.hold(for: .download) == nil)

        kernel.set(.warning)
        room.sourceReported(.normal)
        #expect(room.conditions.memory == .warning)
        #expect(room.hold(for: .download) == .memoryWarning)
    }

    /// A source report is a doorbell: a held waiter starts in the report's step when the
    /// kernel's level it reads is normal, with no look on time.
    @Test func aSourceReportReadsTheKernelAndOpensTheRoomInItsStep() async throws {
        let kernel = ScriptedKernel(.warning)
        let room = BackgroundRoom(memory: kernel.reader)
        let waiter = Task { try await room.untilOpen(for: .heavyLoad) }
        try await waitUntil { room.counts.waiting[.heavyLoad] == 1 }
        let reads = room.kernelReads
        kernel.set(.normal)
        room.sourceReported(.normal)
        #expect(room.kernelReads == reads + 1)
        try await waiter.value
        #expect(room.counts.admitted[.heavyLoad] == 1)
    }

    /// A kernel that cannot be read changes nothing: the level held stays, and the source's
    /// report is the level then.
    @Test func anUnreadKernelLeavesTheLevelToTheSource() {
        let kernel = ScriptedKernel(nil)
        let room = BackgroundRoom(conditions: Self.warning, memory: kernel.reader)
        #expect(room.hold(for: .download) == .memoryWarning)
        room.sourceReported(.normal)
        #expect(room.hold(for: .download) == nil)
    }

    /// The look is the room's: once the room is gone, the look waiting is cancelled.
    @Test func aRoomThatEndsStopsLooking() async throws {
        let kernel = ScriptedKernel(.warning)
        var room: BackgroundRoom? = BackgroundRoom(memory: kernel.reader)
        #expect(room?.hold(for: .download) == .memoryWarning)
        try await waitUntil { kernel.looking }
        room = nil
        try await waitUntil { kernel.cancelledLooks == 1 }
        #expect(room == nil)
    }
}

/// A kernel whose level the test sets, and whose looks run only when the test ticks.
final nonisolated class ScriptedKernel: Sendable {
    private struct State {
        var level: MachineConditions.Memory?
        var look: CheckedContinuation<Void, any Error>?
        var looks = 0
        var cancelledLooks = 0
    }

    private let state: Mutex<State>

    init(_ level: MachineConditions.Memory?) {
        state = Mutex(State(level: level))
    }

    var reader: MemoryPressureReader {
        MemoryPressureReader(
            read: { [self] in state.withLock { $0.level }.map { KernelMemoryPressure(level: $0, availablePercent: 50) } },
            nextLook: { [self] in try await nextLook() }
        )
    }

    func set(_ level: MachineConditions.Memory?) {
        state.withLock { $0.level = level }
    }

    /// A look is waiting for the test's tick.
    var looking: Bool {
        state.withLock { $0.look != nil }
    }

    /// How many looks began.
    var looks: Int {
        state.withLock { $0.looks }
    }

    var cancelledLooks: Int {
        state.withLock { $0.cancelledLooks }
    }

    /// Ends the waiting look: the room reads the level again.
    func tick() {
        state.withLock { state in
            defer { state.look = nil }
            return state.look
        }?.resume()
    }

    private func nextLook() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    if Task.isCancelled {
                        state.cancelledLooks += 1
                        return true
                    }
                    state.looks += 1
                    state.look = continuation
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            state.withLock { state in
                defer { state.look = nil }
                if state.look != nil {
                    state.cancelledLooks += 1
                }
                return state.look
            }?.resume(throwing: CancellationError())
        }
    }
}

/// A session in the test's process that counts how often it is let go.
final class ClosingSession: SearchTextSession {
    let end: @Sendable () async -> Void = {}
    let closeNow: @Sendable () -> Void

    init(closed: @escaping @Sendable () -> Void) {
        closeNow = closed
    }

    func read(_: URL) -> SearchTextPreviewReading {
        .undecodable
    }
}
