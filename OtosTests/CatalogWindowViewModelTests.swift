import Foundation
@testable import OtosKit
import Testing

@Suite(.testDirectory)
struct CatalogWindowViewModelTests {
    @MainActor
    @Test func activeStateSubscriptionDoesNotRetainViewModel() async throws {
        let store = CatalogStore(location: .inMemory)
        let builds = AsyncValueRecorder<CatalogQueryRequest>()
        var projection: CatalogProjection? = CatalogProjection(
            cadence: .milliseconds(10),
            stateBuilder: { libraries, _, request in
                await builds.append(request)
                return CatalogWindowState(
                    title: "Test",
                    libraries: libraries,
                    removableSources: [],
                    mediaGrid: CatalogMediaGridState(
                        descriptor: request.descriptor,
                        orderedAssetIDs: []
                    ),
                    filterOptions: .empty,
                    resolvedSidebarSelection: request.descriptor.scope,
                    mediaEmptyState: .noMedia,
                    deviceConnectionBanner: nil,
                    queryGeneration: request.generation
                )
            }
        )
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        weak let weakProjection = projection
        var model: CatalogWindowViewModel? = try CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: #require(projection),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
        )
        projection = nil
        weak let weakModel = model

        model?.start()
        _ = await builds.waitForValues { !$0.isEmpty }
        model = nil

        try await waitUntil { weakModel == nil }

        // Builds end with the projection: every loop it runs holds it weakly and exits
        // once it is gone, so a deallocated projection can never build again. The store
        // is shut down first because `shutdown()` legitimately emits a final change
        // that earns the still-alive projection one more build.
        await store.shutdown()
        try await waitUntil { weakProjection == nil }
    }

    @MainActor
    @Test func storeChangesUpdateWindowState() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
        )

        model.start()
        model.addLibrary(url: root)

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let state = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
                && state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["one.jpg"]
        }

        #expect(state.libraries.first?.availability == .available)
    }

    @MainActor
    @Test func sidebarSelectionChangesRouteThroughProjection() async throws {
        let temp = try makeTestDirectory()
        let picturesURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let archiveURL = temp.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: picturesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        let picturesPath = try CatalogPath.normalizedDirectoryPath(for: picturesURL)
        let archivePath = try CatalogPath.normalizedDirectoryPath(for: archiveURL)

        let scanner = fixedViewModelSelectionScanner(filesByRoot: [
            picturesPath: "one.jpg",
            archivePath: "two.jpg",
        ])
        let store = CatalogStore(
            location: .inMemory,
            scanner: scanner,
            scanCadence: .milliseconds(10)
        )
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
        )

        model.start()
        model.addLibrary(url: picturesURL)
        model.addLibrary(url: archiveURL)
        _ = try await waitForWindowState(model) { state in
            Set(state.libraries.map(\.path)) == [picturesPath, archivePath]
        }
        model.selectSidebar(.allMedia)
        _ = try await waitForWindowState(model) { state in
            state.mediaGrid.orderedAssetIDs.count == 2
        }

        model.selectSidebar(.library(picturesPath))

        let state = try await waitForWindowState(model) { state in
            state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["one.jpg"]
        }
        #expect(state.title == "Pictures")
        #expect(state.resolvedSidebarSelection == .library(picturesPath))
    }

    @MainActor
    @Test func removedSelectedLibraryResetsSidebarSelectionToAllMedia() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
        )

        model.start()
        model.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
        }

        model.selectSidebar(.library(rootPath))
        #expect(try await store.removeLibrary(path: rootPath) == .removed)

        let state = try await waitForWindowState(model) { state in
            state.libraries.isEmpty && state.resolvedSidebarSelection == .allMedia
        }
        #expect(model.sidebarSelection == .allMedia)
        #expect(state.title == "All Media")
    }

    @MainActor
    @Test func startIsIdempotentAndAddRemoveIntentsRouteToStore() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
        )

        model.start()
        model.start()
        model.addLibrary(url: root)

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let added = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
        }
        #expect(added.libraries.count == 1)

        model.removeLibrary(added.libraries[0].root)

        let removed = try await waitForWindowState(model) { state in
            state.libraries.isEmpty
        }
        #expect(removed.mediaGrid.orderedAssetIDs.isEmpty)
    }

    /// APP-007, DES-091: removing a library an import holds tells the user it will be
    /// removed when the import finishes, keeps it listed meanwhile, and removes it when
    /// the import releases it.
    @MainActor
    @Test func removingABusyLibraryShowsTheNoticeAndRemovesItWhenFree() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Holiday", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory, scanner: CatalogScanner { _, _, _ in .empty })
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            trashFiles: .refusing
        )
        model.start()
        model.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let added = try await waitForWindowState(model) { $0.libraries.map(\.path) == [rootPath] }
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
            for: rootPath,
            owner: .importPublication
        ) else {
            Issue.record("Expected to hold the library's namespace for this test")
            return
        }

        model.removeLibrary(added.libraries[0].root)
        let notice = try await waitForValue { model.libraryRemovalNotice }
        #expect(notice == LibraryRemovalNotice(displayName: "Holiday", waitingFor: .importPublication))
        #expect(LibraryRemovalNoticePresentation.title(for: notice) == "\u{201C}Holiday\u{201D} Is Busy")
        #expect(
            LibraryRemovalNoticePresentation.message(for: notice)
                == "It will be removed from Otos when its import finishes."
        )
        #expect(model.state.libraries.map(\.path) == [rootPath])

        model.dismissLibraryRemovalNotice()
        #expect(model.libraryRemovalNotice == nil)
        #expect(await store.releaseNamespaceMutationLease(lease))
        _ = try await waitForWindowState(model) { $0.libraries.isEmpty }
    }

    @MainActor
    @Test func addRemoveCommandsExecuteInSubmissionOrder() async throws {
        let temp = try makeTestDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = CatalogStore(location: .inMemory, scanner: scanner)
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
        )
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstURL)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)

        model.start()
        model.addLibrary(url: firstURL)
        model.removeLibrary(LibraryRoot(path: firstPath))
        model.addLibrary(url: secondURL)

        let state = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [secondPath]
        }
        #expect(state.libraries.map(\.path) == [secondPath])
        #expect(try await catalogStoreTestState(store).libraries.map(\.path) == [secondPath])
    }

    @MainActor
    @Test func failedMutationDoesNotTerminateOrderedConsumer() async throws {
        let temp = try makeTestDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = CatalogStore(location: .inMemory, scanner: scanner)
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
        )
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstURL)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)

        model.start()
        model.addLibrary(url: firstURL)
        model.addLibrary(url: firstURL)
        model.removeLibrary(LibraryRoot(path: firstPath))
        model.addLibrary(url: secondURL)

        let state = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [secondPath]
        }
        #expect(state.libraries.map(\.path) == [secondPath])
    }

    /// Ending the window ends its mutation lane: no command it accepted reaches the
    /// catalog once the window is gone. Both adds are accepted while the catalog's
    /// initial load is held, so neither can have written before the window ends. The
    /// one already waiting on the load is cancelled with the lane (its write checks
    /// cancellation before it starts), and the queued one never begins.
    ///
    /// "The lane has ended" is observed, not waited out: the mutation consumer is the
    /// last holder of the preview loader the window was given, so the loader's release
    /// is the consumer's end. A lane that outlived the window would still end — its
    /// stream finishes with the window — but only after running both adds, so the
    /// catalog check below fails rather than hangs.
    @MainActor
    @Test func endingViewModelStartsNoAcceptedMutation() async throws {
        let temp = try makeTestDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let loadGate = ArrivalGate()
        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = CatalogStore(
            location: .inMemory,
            scanner: scanner,
            initialLoadDidRead: {
                await loadGate.arrive()
            }
        )
        var previewLoader: FakePreviewLoader? = FakePreviewLoader()
        weak let weakPreviewLoader = previewLoader
        var model: CatalogWindowViewModel? = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            previewLoader: previewLoader,
            trashFiles: .refusing
        )
        previewLoader = nil
        weak let weakModel = model

        model?.start()
        model?.addLibrary(url: firstURL)
        model?.addLibrary(url: secondURL)
        await loadGate.waitForArrivals(1)
        model = nil
        try await waitUntil { weakModel == nil }

        await loadGate.open()
        try await waitUntil { weakPreviewLoader == nil }
        try await store.start(scansSavedLibraries: false)
        #expect(try await catalogStoreTestState(store).libraries.isEmpty)
    }

    @MainActor
    @Test func rapidSidebarIntentsResolveToLatestSelection() async throws {
        let temp = try makeTestDirectory()
        let picturesURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let archiveURL = temp.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: picturesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
        )

        model.start()
        model.addLibrary(url: picturesURL)
        model.addLibrary(url: archiveURL)
        _ = try await waitForWindowState(model) { $0.libraries.count == 2 }

        let picturesPath = try CatalogPath.normalizedDirectoryPath(for: picturesURL)
        let archivePath = try CatalogPath.normalizedDirectoryPath(for: archiveURL)
        model.selectSidebar(.library(picturesPath))
        model.selectSidebar(.allMedia)
        model.selectSidebar(.library(archivePath))

        let state = try await waitForWindowState(model) { state in
            state.resolvedSidebarSelection == .library(archivePath)
        }

        #expect(model.sidebarSelection == .library(archivePath))
        #expect(state.title == "Archive")
    }
}

private func writeFile(_ url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url)
}
