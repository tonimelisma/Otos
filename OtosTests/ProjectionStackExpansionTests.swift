import Foundation
@testable import OtosKit
import Testing

/// ADR 0052: expanding a stack is a window intent outside the descriptor, so it re-collapses
/// the order the projection last published and never runs the order query again.
@Suite(.testScope)
struct ProjectionStackExpansionTests {
    @Test func expandingAStackReCollapsesThePublishedOrderWithoutAQuery() async throws {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for name in ["DSC1.ARW", "DSC1.JPG", "DSC2.JPG"] {
            try Data(name.utf8).write(to: rootURL.appending(path: name))
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        let jpeg1 = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "DSC1.JPG"))
        let raw1 = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "DSC1.ARW"))
        let jpeg2 = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "DSC2.JPG"))

        let projection = CatalogProjection(cadence: .milliseconds(10))
        let initial = CatalogQueryRequest(descriptor: .default, generation: 0)
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let stream = await projection.states(store: store, initialRequest: initial)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recordingTask.cancel() }
        let collapsed = await recorder.waitForValues {
            $0.last.map { Set($0.mediaGrid.orderedAssetIDs) == [jpeg1, jpeg2] } ?? false
        }
        try await waitForProjectionQuiescence(projection)
        let pair = try #require(collapsed.last?.mediaGrid.stacks.collapsed(shownBy: jpeg1))
        let queriesBefore = await projection.orderQueryCount

        // The window sends the descriptor the projection resolved (the one library), as the
        // view model takes it up with each state, and the same generation.
        let resolved = try CatalogQueryRequest(descriptor: #require(collapsed.last?.queryDescriptor), generation: 0)
        var expanded = resolved
        expanded.expandedStacks = [pair.id]
        await projection.updateQueryRequest(expanded)
        let shown = await recorder.waitForValues {
            $0.last.map { $0.mediaGrid.orderedAssetIDs.count == 3 } ?? false
        }
        try await waitForProjectionQuiescence(projection)
        #expect(shown.last.map { Set($0.mediaGrid.orderedAssetIDs) } == [raw1, jpeg1, jpeg2])
        #expect(shown.last?.mediaGrid.stacks.expanded(shownBy: raw1) == pair)
        #expect(await projection.orderQueryCount == queriesBefore)

        // Collapsing again is the same pure pass.
        await projection.updateQueryRequest(resolved)
        _ = await recorder.waitForValues {
            $0.last.map { $0.mediaGrid.orderedAssetIDs.count == 2 } ?? false
        }
        try await waitForProjectionQuiescence(projection)
        #expect(await projection.orderQueryCount == queriesBefore)
        await store.shutdown()
    }
}
