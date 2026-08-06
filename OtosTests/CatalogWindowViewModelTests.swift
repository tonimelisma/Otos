import Foundation
@testable import Otos
import Testing

struct CatalogWindowViewModelTests {
    @MainActor
    @Test func activeStateSubscriptionDoesNotRetainViewModel() async throws {
        let store = CatalogStore(location: .inMemory)
        let buildProbe = WindowStateBuildProbe()
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            stateBuilder: { libraries, _, request in
                await buildProbe.recordBuild()
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
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        var model: CatalogWindowViewModel? = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: projection,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
        )
        weak let weakModel = model

        model?.start()
        try await buildProbe.waitForBuildCount(1)
        model = nil

        try await waitForCondition { weakModel == nil }
        let buildCountAfterTermination = try await waitForBuildsToQuiesce(
            buildProbe,
            quietDuration: .milliseconds(40)
        )

        await store.shutdown()
        try await waitForNoAdditionalBuilds(buildProbe, duration: .milliseconds(40))
        #expect(await buildProbe.buildCount == buildCountAfterTermination)
    }

    @MainActor
    @Test func storeChangesUpdateWindowState() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
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
        let temp = try makeTemporaryDirectory()
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
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
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
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
        )

        model.start()
        model.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
        }

        model.selectSidebar(.library(rootPath))
        try await store.removeLibrary(path: rootPath)

        let state = try await waitForWindowState(model) { state in
            state.libraries.isEmpty && state.resolvedSidebarSelection == .allMedia
        }
        #expect(model.sidebarSelection == .allMedia)
        #expect(state.title == "All Media")
    }

    @MainActor
    @Test func startIsIdempotentAndAddRemoveIntentsRouteToStore() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
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

    @MainActor
    @Test func addRemoveCommandsExecuteInSubmissionOrder() async throws {
        let temp = try makeTemporaryDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = CatalogStore(location: .inMemory, scanner: scanner)
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
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
        let temp = try makeTemporaryDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = CatalogStore(location: .inMemory, scanner: scanner)
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
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

    @MainActor
    @Test func endingViewModelDropsQueuedMutationAfterCurrentMutation() async throws {
        let temp = try makeTemporaryDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let loadGate = ViewModelInitialLoadGate()
        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = CatalogStore(
            location: .inMemory,
            scanner: scanner,
            initialLoadDidRead: {
                await loadGate.pause()
            }
        )
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        var model: CatalogWindowViewModel? = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
        )
        weak let weakModel = model
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstURL)

        model?.start()
        model?.addLibrary(url: firstURL)
        model?.addLibrary(url: secondURL)
        try await loadGate.waitUntilPaused()
        model = nil
        try await waitForCondition { weakModel == nil }

        await loadGate.release()
        try await store.start(scansSavedLibraries: false)
        await yieldForQueuedMutationCancellation()
        let paths = try await catalogStoreTestState(store).libraries.map(\.path)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)
        #expect(!paths.contains(secondPath))
        #expect(paths.isEmpty || paths == [firstPath])
    }

    @MainActor
    @Test func rapidSidebarIntentsResolveToLatestSelection() async throws {
        let temp = try makeTemporaryDirectory()
        let picturesURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let archiveURL = temp.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: picturesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferences: tempDefaults.defaults
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

@MainActor
private func waitForCondition(
    timeout: Duration = .seconds(2),
    predicate: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate() {
            return
        }
        await Task.yield()
    }
    if predicate() {
        return
    }
    throw CatalogWindowViewModelTestError.timedOut
}

private func yieldForQueuedMutationCancellation() async {
    for _ in 0 ..< 10 {
        await Task.yield()
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url)
}

private enum CatalogWindowViewModelTestError: Error {
    case timedOut
}

private actor WindowStateBuildProbe {
    private(set) var buildCount = 0
    private var buildWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func recordBuild() {
        buildCount += 1
        resumeBuildWaiters()
    }

    func waitForBuildCount(_ expectedCount: Int) async throws {
        try await withTestTimeout("window state build count") {
            await self.waitForBuildCountUnbounded(expectedCount)
        }
    }

    private func waitForBuildCountUnbounded(_ expectedCount: Int) async {
        if buildCount >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            buildWaiters.append((expectedCount, continuation))
            resumeBuildWaiters()
        }
    }

    private func resumeBuildWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in buildWaiters {
            if buildCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        buildWaiters = remaining
    }
}

private actor ViewModelInitialLoadGate {
    private var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        resumePauseWaiters()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPaused() async throws {
        try await withTestTimeout("view model initial load pause") {
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
        continuation?.resume()
        continuation = nil
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

private func waitForNoAdditionalBuilds(
    _ probe: WindowStateBuildProbe,
    duration: Duration
) async throws {
    let baseline = await probe.buildCount
    try await Task.sleep(for: duration)
    #expect(await probe.buildCount == baseline)
}

private func waitForBuildsToQuiesce(
    _ probe: WindowStateBuildProbe,
    quietDuration: Duration,
    timeout: Duration = .seconds(2)
) async throws -> Int {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var baseline = await probe.buildCount
    while clock.now < deadline {
        try await Task.sleep(for: quietDuration)
        let current = await probe.buildCount
        if current == baseline {
            return current
        }
        baseline = current
    }
    throw CatalogWindowViewModelTestError.timedOut
}
