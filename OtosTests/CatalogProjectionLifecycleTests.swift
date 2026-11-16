import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogProjectionLifecycleTests {
    /// A projection's publication loop must end when the projection does, not merely
    /// skip a beat. Both long-lived loops hold their owner weakly across an indefinite
    /// wait and must *exit* when that upgrade fails. A loop that only skipped would run
    /// `while !Task.isCancelled` forever — doing nothing each pass, but holding `store`
    /// strongly through its closure and so keeping the whole `CatalogStore` alive. One
    /// orphan per projection accumulates across a test run until the process deadlocks
    /// mid-suite.
    ///
    /// Proven by ownership, not by timing: a sentinel only the store's scanner holds is
    /// released exactly when the store is, and reports it. A loop that still retained
    /// the store would keep the sentinel alive, and the release would never be reported.
    @Test func releasingAProjectionEndsItsLoopsAndReleasesTheStore() async throws {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let storeReleased = ReleaseSignal()
        do {
            let sentinel = ReleaseSentinel(storeReleased)
            let scanner = CatalogScanner { _, _, _ in
                _ = sentinel
                return .empty
            }
            let store = makeTestStore(location: .inMemory, scanner: scanner)
            let projection = CatalogProjection(cadence: .milliseconds(10))
            let stream = await projection.states(store: store, initialDescriptor: .default)
            let recordingTask = Task {
                for await _ in stream {}
            }
            // The loops hold the store from the moment they are created; the first
            // publication shows the projection is live before it is released.
            try await waitUntil { await projection.publicationCount >= 1 }
            recordingTask.cancel()
            _ = projection
        }

        // The loops wake on their cadence; after their next pass each must observe a
        // nil owner and return, dropping the store with them. A released projection
        // that kept its CatalogStore alive never reports this.
        await storeReleased.wait()
    }

    @Test func coalescedRemoveAndSamePathReaddResetsSelection() async throws {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = makeTestStore(location: .inMemory, scanner: scanner)
        let projection = CatalogProjection(cadence: .milliseconds(50))
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
        #expect(try await store.removeLibrary(path: rootPath) == .removed)
        try await store.addLibrary(url: rootURL)

        let readded = try await recorder.waitForLast { state in
            state.libraries.map(\.path) == [rootPath]
                && state.resolvedSidebarSelection == .library(rootPath)
        }
        #expect(readded.mediaGrid.scope == .library(rootPath))
    }

    @Test func normalizationDoesNotOverwriteNewerSidebarIntent() async throws {
        let missing = SidebarSelection.library(
            LibraryRootPath(rawValue: "/Users/example/Missing")
        )
        let newer = SidebarSelection.library(
            LibraryRootPath(rawValue: "/Users/example/Newer")
        )
        let gate = ArrivalGate()
        let store = makeTestStore(location: .inMemory)
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
        await gate.waitForArrivals(1)
        await projection.updateSidebarSelection(newer)
        await gate.open()

        let latest = try await recorder.waitForLast { state in
            state.resolvedSidebarSelection == newer
        }
        #expect(latest.resolvedSidebarSelection == newer)
    }
}

private typealias LifecycleStateRecorder = AsyncValueRecorder<CatalogWindowState>

/// Builds states whose resolved selection normalizes `missing` to All Media, holding
/// every build for `missing` at `gate` so a newer intent can arrive mid-build.
private func selectionNormalizingProjection(
    missing: SidebarSelection,
    gate: ArrivalGate
) -> CatalogProjection {
    CatalogProjection(cadence: .milliseconds(10)) { _, _, request in
        let selection = request.descriptor.scope
        if selection == missing {
            await gate.arrive()
        }
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
        let states = await waitForValues { states in
            states.last.map(predicate) ?? false
        }
        return try #require(states.last)
    }
}
