import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// An edit target whose original could not be read when it opened (ADR 0036): the pane says
/// so instead of waiting on facts that never come, and the photo opens again on the next
/// catalog change, target refresh or change at its original's path, never on a timer
/// (ADR 0033).
///
/// The original's status is a stub that reads as unreadable until the test lets it be read,
/// and the path's changes a stream the test yields to, so each test delivers one signal at
/// the step it means.
@Suite(.testScope)
@MainActor
struct EditOpenFailureTests {
    // Validates: APP-046, APP-055
    @Test func aFailedOpenSaysTheOriginalIsUnreadableAndTheNextFileEventOpensIt() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let status = OriginalStatusStub(path: library.ids[0].fileURL)
            let changes = OriginalChangesStub()
            let model = library.makeEditModel(originalStatus: status.read, originalChanges: changes.stream)
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntilFailedAndWatched(model, status: status, changes: changes)

            #expect(model.editSession.isOriginalUnreadable)
            #expect(!model.editSession.canEdit)
            #expect(model.editSession.editPhotoFacts == nil)
            #expect(model.editSession.editHistogram == nil)

            status.release()
            // What a file event for the photo reaches the window as: a publication whose
            // rows changed (`detailRefreshGeneration`).
            var next = model.state
            next.mediaGrid.detailRefreshGeneration &+= 1
            model.applyState(next)

            try await waitUntil { model.editSession.editHistogram != nil }
            #expect(model.editSession.editTarget?.open == .opened)
            #expect(!model.editSession.isOriginalUnreadable)
            #expect(model.editSession.canEdit)
        }
    }

    // Validates: APP-046
    /// The original comes back exactly as it was — a volume mounted again — so no catalog row
    /// changes; the change at its path opens it.
    @Test func aChangeAtTheOriginalsPathOpensItWithNoCatalogChange() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let status = OriginalStatusStub(path: library.ids[0].fileURL)
            let changes = OriginalChangesStub()
            let model = library.makeEditModel(originalStatus: status.read, originalChanges: changes.stream)
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntilFailedAndWatched(model, status: status, changes: changes)
            let published = model.appliedStateCount

            status.release()
            changes.yield()

            try await waitUntil { model.editSession.editHistogram != nil }
            #expect(model.editSession.editTarget?.open == .opened)
            #expect(model.appliedStateCount == published)
        }
    }

    // Validates: APP-046
    /// An original that returned between the failed read and the watch's start is found by
    /// the one look taken once the watch is armed.
    @Test func anOriginalBackBeforeTheWatchStartedIsOpened() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let status = OriginalStatusStub(path: library.ids[0].fileURL, failures: 1)
            let changes = OriginalChangesStub()
            let model = library.makeEditModel(originalStatus: status.read, originalChanges: changes.stream)
            model.toggleInspector(.edit)
            model.selectAll()

            try await waitUntil { model.editSession.editHistogram != nil }
            #expect(model.editSession.editTarget?.open == .opened)
            #expect(status.failed == 1)
            #expect(changes.yields == 0)
        }
    }

    // Validates: APP-046
    /// The same photo's target writers (here, opening it in the loupe) open it again too: the
    /// refresh holds only for a target that is open or opening.
    @Test func aTargetRefreshOpensAPhotoWhoseOpenFailed() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let status = OriginalStatusStub(path: id.fileURL)
            let changes = OriginalChangesStub()
            let model = library.makeEditModel(originalStatus: status.read, originalChanges: changes.stream)
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntilFailedAndWatched(model, status: status, changes: changes)

            status.release()
            model.setViewMode(.loupe)

            try await waitUntil { model.editSession.canEdit && model.editSession.editHistogram != nil }
            #expect(model.editSession.editTarget?.id == id)
            #expect(!model.editSession.isOriginalUnreadable)
        }
    }

    /// The open failed, its path is watched, and the look taken once the watch was armed found
    /// the original still unreadable: the open's ask and that look's.
    private func waitUntilFailedAndWatched(
        _ model: CatalogWindowViewModel,
        status: OriginalStatusStub,
        changes: OriginalChangesStub
    ) async throws {
        try await waitUntil {
            model.editSession.isOriginalUnreadable && changes.watches == 1 && status.failed >= 2
        }
        try #require(model.editSession.editTarget?.open == .failed(.notLocal))
    }
}

/// An original's status that cannot be read for `path` until the test releases it, or for
/// its first `failures` asks; any other path reads as the file's own.
final nonisolated class OriginalStatusStub: Sendable {
    private struct State {
        var released = false
        var failuresLeft: Int?
        var failed = 0
    }

    private let path: String
    private let state: Mutex<State>

    init(path: URL, failures: Int? = nil) {
        self.path = path.path(percentEncoded: false)
        state = Mutex(State(failuresLeft: failures))
    }

    /// How many asks about the path read as unreadable.
    var failed: Int {
        state.withLock { $0.failed }
    }

    func release() {
        state.withLock { $0.released = true }
    }

    var read: @Sendable (URL) -> FileMaterializationStatus {
        { [self] url in
            guard url.path(percentEncoded: false) == path else {
                return FileMaterialization.status(of: url)
            }
            let fails = state.withLock { state in
                let fails = if let left = state.failuresLeft {
                    left > 0
                } else {
                    !state.released
                }
                if fails {
                    state.failed += 1
                    state.failuresLeft = state.failuresLeft.map { $0 - 1 }
                }
                return fails
            }
            return fails ? .unknown : FileMaterialization.status(of: url)
        }
    }
}

/// Changes at originals' paths, delivered when the test yields.
final nonisolated class OriginalChangesStub: Sendable {
    private struct State {
        var continuations: [AsyncStream<Void>.Continuation] = []
        var yields = 0
    }

    private let state = Mutex(State())

    /// How many watches were started.
    var watches: Int {
        state.withLock { $0.continuations.count }
    }

    var yields: Int {
        state.withLock { $0.yields }
    }

    func yield() {
        let continuations = state.withLock { state in
            state.yields += 1
            return state.continuations
        }
        for continuation in continuations {
            continuation.yield()
        }
    }

    var stream: @Sendable (URL) -> AsyncStream<Void> {
        { [self] _ in
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            state.withLock { $0.continuations.append(continuation) }
            return stream
        }
    }
}
