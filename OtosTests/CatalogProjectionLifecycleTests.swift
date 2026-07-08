import Foundation
@testable import Otos
import Testing

struct CatalogProjectionLifecycleTests {
    @Test func coalescedRemoveAndSamePathReaddResetsSelection() async throws {
        let temp = try makeProjectionLifecycleTemporaryDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let scanner = CatalogScanner { _, _, _, _ in [] }
        let store = CatalogStore(location: .inMemory, scanner: scanner, diagnostics: nil)
        let projection = CatalogProjection(cadence: .milliseconds(50), diagnostics: nil)
        let recorder = LifecycleStateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recordingTask.cancel() }

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        await projection.updateSidebarSelection(.library(rootPath))
        _ = try await recorder.waitForLast { state in
            state.resolvedSidebarSelection == .library(rootPath)
        }

        // Both mutations finish before Projection's next publication tick. The
        // final snapshot contains the same path, so only the typed removal event
        // can preserve the fact that the selected root instance disappeared.
        try await store.removeLibrary(path: rootPath)
        try await store.addLibrary(url: rootURL)

        let readded = try await recorder.waitForLast { state in
            state.libraries.map(\.path) == [rootPath]
                && state.resolvedSidebarSelection == .library(rootPath)
        }
        #expect(readded.mediaGrid.scope == .library(rootPath))
    }

    @Test func removedSelectionRemainsAllMediaWhenSamePathIsReadded() async throws {
        let temp = try makeProjectionLifecycleTemporaryDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let scanner = CatalogScanner { _, _, _, _ in [] }
        let store = CatalogStore(location: .inMemory, scanner: scanner, diagnostics: nil)
        let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
        let recorder = LifecycleStateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recordingTask.cancel() }

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        await projection.updateSidebarSelection(.library(rootPath))
        _ = try await recorder.waitForLast { state in
            state.resolvedSidebarSelection == .library(rootPath)
        }

        try await store.removeLibrary(path: rootPath)
        _ = try await recorder.waitForLast { state in
            state.libraries.isEmpty && state.resolvedSidebarSelection == .allMedia
        }

        try await store.addLibrary(url: rootURL)
        let readded = try await recorder.waitForLast { state in
            state.libraries.map(\.path) == [rootPath]
        }
        #expect(readded.resolvedSidebarSelection == .library(rootPath))
        #expect(readded.mediaGrid.scope == .library(rootPath))
    }

    @Test func normalizationDoesNotOverwriteNewerSidebarIntent() async throws {
        let missing = SidebarSelection.library(
            LibraryRootPath(rawValue: "/Users/example/Missing")
        )
        let newer = SidebarSelection.library(
            LibraryRootPath(rawValue: "/Users/example/Newer")
        )
        let gate = SelectionBuildGate(blockedSelection: missing)
        let store = CatalogStore(location: .inMemory, diagnostics: nil)
        let projection = selectionNormalizingProjection(missing: missing, gate: gate)
        let recorder = LifecycleStateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recordingTask.cancel() }

        try await store.start(scansSavedLibraries: false)
        _ = try await recorder.waitForLast { $0.resolvedSidebarSelection == .allMedia }
        await projection.updateSidebarSelection(missing)
        try await gate.waitUntilPaused()
        await projection.updateSidebarSelection(newer)
        await gate.release()

        let latest = try await recorder.waitForLast { state in
            state.resolvedSidebarSelection == newer
        }
        #expect(latest.resolvedSidebarSelection == newer)
    }
}

private typealias LifecycleStateRecorder = AsyncValueRecorder<CatalogWindowState>

private func selectionNormalizingProjection(
    missing: SidebarSelection,
    gate: SelectionBuildGate
) -> CatalogProjection {
    CatalogProjection(cadence: .milliseconds(10), diagnostics: nil) { _, _, request in
        let selection = request.descriptor.scope
        await gate.pauseIfNeeded(selection)
        let resolved = selection == missing ? SidebarSelection.allMedia : selection
        return CatalogWindowState(
            title: "Selection",
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(
                descriptor: CatalogQueryDescriptor(
                    scope: resolved,
                    filter: request.descriptor.filter,
                    sort: request.descriptor.sort
                ),
                orderedAssetIDs: []
            ),
            filterOptions: .empty,
            resolvedSidebarSelection: resolved,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil,
            queryGeneration: request.generation
        )
    }
}

private extension AsyncValueRecorder where Value == CatalogWindowState {
    func waitForLast(
        matching predicate: @escaping @Sendable (CatalogWindowState) -> Bool
    ) async throws -> CatalogWindowState {
        let states = try await withTestTimeout("projection lifecycle state") {
            await self.waitForValues { states in
                states.last.map(predicate) ?? false
            }
        }
        guard let last = states.last else {
            throw CatalogProjectionLifecycleTestError.timedOut
        }
        return last
    }
}

private actor SelectionBuildGate {
    private let blockedSelection: SidebarSelection
    private var isPaused = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedSelection: SidebarSelection) {
        self.blockedSelection = blockedSelection
    }

    func pauseIfNeeded(_ selection: SidebarSelection) async {
        guard selection == blockedSelection else {
            return
        }
        isPaused = true
        resumePauseWaiters()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async throws {
        try await withTestTimeout("selection build pause") {
            await self.waitUntilPausedUnbounded()
        }
    }

    private func waitUntilPausedUnbounded() async {
        if isPaused {
            return
        }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
            resumePauseWaiters()
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func resumePauseWaiters() {
        guard isPaused else {
            return
        }
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private enum CatalogProjectionLifecycleTestError: Error {
    case timedOut
}

private func makeProjectionLifecycleTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
