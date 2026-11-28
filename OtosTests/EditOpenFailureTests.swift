import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// An edit target whose original could not be read when it opened (ADR 0036): the pane says
/// so instead of waiting on facts that never come, and the photo opens again on the next
/// catalog change or target refresh — never on a timer (ADR 0033).
@Suite(.testScope)
@MainActor
struct EditOpenFailureTests {
    @Test func aFailedOpenSaysTheOriginalIsUnreadableAndTheNextFileEventOpensIt() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let status = OriginalStatusFailingOnce(path: id.fileURL.path(percentEncoded: false))
            let model = library.makeEditModel(originalStatus: status.read)
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.isOriginalUnreadable || model.editSession.canEdit }

            try #require(model.editSession.editTarget?.open == .failed)
            #expect(model.editSession.isOriginalUnreadable)
            #expect(!model.editSession.canEdit)
            #expect(model.editSession.editPhotoFacts == nil)
            #expect(model.editSession.editHistogram == nil)

            // What a file event for the photo reaches the window as: a publication whose
            // rows changed (`detailRefreshGeneration`).
            var next = model.state
            next.mediaGrid.detailRefreshGeneration &+= 1
            model.applyState(next)

            try await waitUntil { model.editSession.editHistogram != nil }
            #expect(model.editSession.editTarget?.open == .opened)
            #expect(!model.editSession.isOriginalUnreadable)
            #expect(model.editSession.canEdit)
            #expect(status.failures == 1)
        }
    }

    /// The same photo's target writers (here, opening it in the loupe) open it again too: the
    /// refresh holds only for a target that is open or opening.
    @Test func aTargetRefreshOpensAPhotoWhoseOpenFailed() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let status = OriginalStatusFailingOnce(path: id.fileURL.path(percentEncoded: false))
            let model = library.makeEditModel(originalStatus: status.read)
            model.toggleInspector(.edit)
            model.selectAll()
            try await waitUntil { model.editSession.isOriginalUnreadable || model.editSession.canEdit }
            try #require(model.editSession.isOriginalUnreadable)

            model.setViewMode(.loupe)

            try await waitUntil { model.editSession.canEdit && model.editSession.editHistogram != nil }
            #expect(model.editSession.editTarget?.id == id)
            #expect(!model.editSession.isOriginalUnreadable)
        }
    }
}

/// An original's status that cannot be read the first time `path` is asked about, as a
/// transient `lstat` failure reads, and is the file's own after that.
final nonisolated class OriginalStatusFailingOnce: Sendable {
    private let path: String
    private let failed = Mutex(0)

    init(path: String) {
        self.path = path
    }

    var failures: Int {
        failed.withLock { $0 }
    }

    var read: @Sendable (URL) -> FileMaterializationStatus {
        { [self] url in
            let fails = url.path(percentEncoded: false) == path && failed.withLock { count in
                guard count == 0 else { return false }
                count = 1
                return true
            }
            return fails ? .unknown : FileMaterialization.status(of: url)
        }
    }
}
