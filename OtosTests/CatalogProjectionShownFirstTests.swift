import Foundation
@testable import OtosKit
import Testing

/// Projection shows an act's result from what it holds, before the Store's write or a pass
/// (DES-120): a choice the shown filter excludes takes its item out, and an expansion is
/// published in the step that applies it.
@Suite(.testDirectory)
struct CatalogProjectionShownFirstTests {
    /// Liked only: a Dislike takes its photo out with no read; a withdrawn one brings it back;
    /// an undo held after it puts it back at once; the read of the landed write retires it.
    @Test func aChoiceTheFilterExcludesLeavesTheGridBeforeItsWrite() async throws {
        try await withCatalogedLibrary(fileCount: 3, fileNamePrefix: "chosen") { fixture in
            _ = try await fixture.store.setMediaChoices(Dictionary(uniqueKeysWithValues: fixture.ids.map { ($0, .liked) }))
            var filter = MediaFilter.all
            filter.choices = [.liked]
            let projection = CatalogProjection(cadence: .milliseconds(10))
            let recorder = AsyncValueRecorder<CatalogWindowState>()
            let stream = await projection.states(
                store: fixture.store,
                initialDescriptor: CatalogQueryDescriptor(scope: .library(fixture.rootPath), filter: filter)
            )
            let recordingTask = Task {
                for await state in stream {
                    await recorder.append(state)
                }
            }
            defer { recordingTask.cancel() }
            let shown = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == 3 }
            let order = try #require(shown.last).mediaGrid.orderedAssetIDs
            try await waitForProjectionQuiescence(projection)
            let reads = await projection.orderQueryCount

            await projection.apply(.choose([order[0]: .disliked], request: 1))
            _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == [order[1], order[2]] }
            await projection.apply(.choicesWithdrawn(request: 1))
            _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == order }
            #expect(await projection.orderQueryCount == reads, "neither the choice nor its withdrawal read the catalog")

            // A Like held after the Dislike, as an undo pressed before the write lands is.
            await projection.apply(.choose([order[0]: .disliked], request: 2))
            _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == [order[1], order[2]] }
            await projection.apply(.choose([order[0]: .liked], request: 3))
            _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == order }
            await projection.apply(.choicesWithdrawn(request: 3))

            // The Dislike lands and is read: the photo stays out, and the hold retires.
            _ = try await fixture.store.setMediaChoices([order[0]: .disliked])
            await projection.apply(.choicesLanded(request: 2))
            try await waitForProjectionQuiescence(projection)
            #expect(try #require(await recorder.snapshot().last).mediaGrid.orderedAssetIDs == [order[1], order[2]])
            #expect(await projection.holdsNothing)
        }
    }

    /// The expansion is published inside the intent that asks for it, from the collapse the
    /// last pass made, with no order read.
    @Test func anExpansionIsPublishedInTheStepThatAppliesIt() async throws {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for name in ["DSC1.ARW", "DSC1.JPG", "DSC2.JPG"] {
            try Data(name.utf8).write(to: rootURL.appending(path: name))
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        let jpeg1 = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "DSC1.JPG"))
        let raw1 = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "DSC1.ARW"))

        let projection = CatalogProjection(cadence: .milliseconds(10))
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let stream = await projection.states(store: store, initialRequest: CatalogQueryRequest(descriptor: .default, generation: 0))
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recordingTask.cancel() }
        let collapsed = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == 2 }
        try await waitForProjectionQuiescence(projection)
        let pair = try #require(collapsed.last?.mediaGrid.stacks.collapsed(shownBy: jpeg1))
        let published = await projection.publicationCount
        let queries = await projection.orderQueryCount

        var expanded = try CatalogQueryRequest(descriptor: #require(collapsed.last?.queryDescriptor), generation: 0)
        expanded.expandedStacks = [pair.id]
        await projection.apply(.query(expanded))
        #expect(await projection.publicationCount == published + 1, "published before any pass ran")
        let shown = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == 3 }
        #expect(shown.last?.mediaGrid.stacks.expanded(shownBy: raw1) == pair)
        try await waitForProjectionQuiescence(projection)
        #expect(await projection.orderQueryCount == queries)
        await store.shutdown()
    }
}
