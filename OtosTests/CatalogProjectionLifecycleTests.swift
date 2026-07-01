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
        let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
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
                && state.resolvedSidebarSelection == .allMedia
        }
        #expect(readded.mediaGrid.scope == .allMedia)
    }

    @Test func removedSelectionRemainsAllMediaWhenSamePathIsReadded() async throws {
        let temp = try makeProjectionLifecycleTemporaryDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let scanner = CatalogScanner { _, _, _, _ in [] }
        let store = CatalogStore(location: .inMemory, scanner: scanner, diagnostics: nil)
        let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
        let recorder = LifecycleStateRecorder()
        let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
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
        #expect(readded.resolvedSidebarSelection == .allMedia)
        #expect(readded.mediaGrid.scope == .allMedia)
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
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            diagnostics: nil,
            stateBuilder: { _, _, selection in
                await gate.pauseIfNeeded(selection)
                let resolved = selection == missing ? SidebarSelection.allMedia : selection
                return CatalogWindowState(
                    title: "Selection",
                    libraries: [],
                    mediaGrid: CatalogMediaGridState(
                        scope: resolved,
                        orderedAssetIDs: []
                    ),
                    resolvedSidebarSelection: resolved,
                    mediaEmptyState: .noMedia
                )
            }
        )
        let recorder = LifecycleStateRecorder()
        let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
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

private actor LifecycleStateRecorder {
    private var states: [CatalogWindowState] = []

    func append(_ state: CatalogWindowState) {
        states.append(state)
    }

    func waitForLast(
        matching predicate: (CatalogWindowState) -> Bool
    ) async throws -> CatalogWindowState {
        for _ in 0 ..< 100 {
            if let last = states.last, predicate(last) {
                return last
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CatalogProjectionLifecycleTestError.timedOut
    }
}

private actor SelectionBuildGate {
    private let blockedSelection: SidebarSelection
    private var isPaused = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(blockedSelection: SidebarSelection) {
        self.blockedSelection = blockedSelection
    }

    func pauseIfNeeded(_ selection: SidebarSelection) async {
        guard selection == blockedSelection else {
            return
        }
        isPaused = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async throws {
        for _ in 0 ..< 100 {
            if isPaused {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CatalogProjectionLifecycleTestError.timedOut
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
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
