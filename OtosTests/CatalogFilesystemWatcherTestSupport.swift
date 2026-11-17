import Foundation
@testable import OtosKit
import Synchronization

/// Filesystem watcher test harness
///
/// Watchers that never create an `FSEventStream`: `noop` ignores everything, and the
/// `testing` variants hand the test an `emit` that calls the handler the Store
/// registered, so a test delivers an event at exactly the point it chooses. None of them
/// offers a change journal unless the test scripts one (`scripted`): a root they watch has
/// no history, as on a volume that keeps none, so every launch walks it.
extension CatalogFilesystemWatcher {
    static let noop = CatalogFilesystemWatcher(
        probe: { _ in nil },
        start: { _ in },
        watch: { _, _ in },
        unwatch: { _ in },
        stop: {}
    )

    /// The live watcher with its journal hidden: live events, and no history, so a test
    /// that relaunches a Store gets the launch walk it relies on. The stream ignores events
    /// this process causes, so a test's own writes reach a Store only through its walks.
    static func liveWithoutHistory() -> CatalogFilesystemWatcher {
        var watcher = CatalogFilesystemWatcher.live()
        watcher.probe = { root in
            LiveFilesystemJournal.probe(root).map {
                FilesystemJournalProbe(volumeUUID: nil, currentEventID: $0.currentEventID, rootIdentity: $0.rootIdentity)
            }
        }
        return watcher
    }

    /// Test harness that invokes the registered handler without `FSEventStream`.
    static func testing() -> (watcher: CatalogFilesystemWatcher, emit: @Sendable (FilesystemEvent) -> Void) {
        let harness = ScriptedCatalogFilesystemWatcher()
        return (harness.watcher, harness.emit)
    }

    static func testingWithRootInspection() -> (
        CatalogFilesystemWatcherInspection
    ) {
        let harness = ScriptedCatalogFilesystemWatcher()
        return CatalogFilesystemWatcherInspection(watcher: harness.watcher, emit: harness.emit, roots: harness.roots)
    }
}

nonisolated struct CatalogFilesystemWatcherInspection {
    let watcher: CatalogFilesystemWatcher
    let emit: @Sendable (FilesystemEvent) -> Void
    let roots: @Sendable () -> [LibraryRootPath]
}

/// A scripted change journal: the test says what each root's probe reads, sees each root
/// watched and from which event ID, and delivers events and the end of a replay itself
/// (`emit`, `emitHistoryDone`). A root watched from an ID is answered `historyDone` only
/// when the test sends it, so a replay's events are delivered at exactly the point the test
/// chooses; one watched from now is never sent one.
final nonisolated class ScriptedCatalogFilesystemWatcher: Sendable {
    struct Watch: Equatable {
        let root: LibraryRootPath
        let since: UInt64?
    }

    private struct State {
        var handler: (@Sendable (FilesystemWatcherDelivery) -> Void)?
        var probes: [LibraryRootPath: FilesystemJournalProbe] = [:]
        var watched: [LibraryRootPath] = []
        var watches: [Watch] = []
    }

    private let state = Mutex(State())

    var watcher: CatalogFilesystemWatcher {
        CatalogFilesystemWatcher(
            probe: { [self] root in state.withLock { $0.probes[root] } },
            start: { [self] handler in state.withLock { $0.handler = handler } },
            watch: { [self] root, since in
                state.withLock { state in
                    guard !state.watched.contains(root) else {
                        return
                    }
                    state.watched.append(root)
                    state.watches.append(Watch(root: root, since: since))
                }
            },
            unwatch: { [self] root in state.withLock { $0.watched.removeAll { $0 == root } } },
            stop: { [self] in
                state.withLock { state in
                    state.watched = []
                    state.handler = nil
                }
            }
        )
    }

    func setProbe(_ probe: FilesystemJournalProbe?, for root: LibraryRootPath) {
        state.withLock { $0.probes[root] = probe }
    }

    /// Every watch the Store asked for, in order.
    func watches() -> [Watch] {
        state.withLock { $0.watches }
    }

    func roots() -> [LibraryRootPath] {
        state.withLock { $0.watched }
    }

    func emit(_ event: FilesystemEvent) {
        let handler = state.withLock { $0.handler }
        handler?(.event(event))
    }

    func emitHistoryDone(_ root: LibraryRootPath) {
        let handler = state.withLock { $0.handler }
        handler?(.historyDone(root))
    }
}
