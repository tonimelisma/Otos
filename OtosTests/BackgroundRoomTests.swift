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
        let loads = [BackgroundLoad.duplicates, .searchIndex, .people].map { load in
            Task {
                try await admission.run(load) { order.withLock { $0.append(load) } }
            }
        }
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
