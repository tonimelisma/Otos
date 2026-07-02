@testable import Otos
import Testing

struct CatalogWindowViewModelQueryIntentTests {
    @MainActor
    @Test func staleProjectedStateDoesNotRollbackNewerQueryIntent() async throws {
        let store = CatalogStore(location: .inMemory, diagnostics: nil)
        let gate = WindowStateBuildGate()
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            diagnostics: nil,
            stateBuilder: { libraries, _, descriptor in
                let buildNumber = await gate.record(descriptor)
                return testWindowState(buildNumber: buildNumber, libraries: libraries, descriptor: descriptor)
            }
        )
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: projection,
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )

        model.start()
        try await gate.waitForBuildCount(1)
        model.setSortField(.name)
        await gate.releaseNext()

        _ = try await waitForWindowState(model) { state in
            state.title == "Build 1"
        }
        try await gate.waitForBuildCount(2)
        #expect(model.queryDescriptor.sort.field == .name)

        model.setMediaFilter(MediaFilter(kinds: [.image]))
        #expect(model.queryDescriptor.sort.field == .name)
        #expect(model.queryDescriptor.filter.kinds == [.image])

        await gate.releaseAll()
        let descriptors = try await withTestTimeout("target query descriptor") {
            await gate.waitForDescriptors { descriptors in
                descriptors.contains(CatalogQueryDescriptor(
                    scope: .allMedia,
                    filter: MediaFilter(kinds: [.image]),
                    sort: .defaultForField(.name)
                ))
            }
        }
        await gate.releaseAll()
        #expect(descriptors.last?.sort.field == .name)
    }
}

private func testWindowState(
    buildNumber: Int,
    libraries: [CatalogLibraryState],
    descriptor: CatalogQueryDescriptor
) -> CatalogWindowState {
    CatalogWindowState(
        title: "Build \(buildNumber)",
        libraries: libraries,
        mediaGrid: CatalogMediaGridState(
            descriptor: descriptor,
            orderedAssetIDs: []
        ),
        filterOptions: .empty,
        resolvedSidebarSelection: descriptor.scope,
        mediaEmptyState: .noMedia
    )
}

@MainActor
private func waitForWindowState(
    _ model: CatalogWindowViewModel,
    predicate: @escaping @MainActor @Sendable (CatalogWindowState) -> Bool
) async throws -> CatalogWindowState {
    let stream = windowStateStream(model, timeout: .seconds(10))
    for await state in stream where predicate(state) {
        return state
    }
    throw AsyncTestTimeoutError.timedOut("window state")
}

private actor WindowStateBuildGate {
    private var descriptors: [CatalogQueryDescriptor] = []
    private var pausedBuilds: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var descriptorWaiters: [
        (@Sendable ([CatalogQueryDescriptor]) -> Bool, CheckedContinuation<[CatalogQueryDescriptor], Never>)
    ] = []

    func record(_ descriptor: CatalogQueryDescriptor) async -> Int {
        descriptors.append(descriptor)
        resumeWaiters()
        let buildNumber = descriptors.count
        await withCheckedContinuation { continuation in
            pausedBuilds.append(continuation)
        }
        return buildNumber
    }

    func waitForBuildCount(_ expectedCount: Int) async throws {
        try await withTestTimeout("window state gated build count") {
            await self.waitForBuildCountUnbounded(expectedCount)
        }
    }

    private func waitForBuildCountUnbounded(_ expectedCount: Int) async {
        if descriptors.count >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((expectedCount, continuation))
            resumeWaiters()
        }
    }

    func waitForDescriptors(
        matching predicate: @escaping @Sendable ([CatalogQueryDescriptor]) -> Bool
    ) async -> [CatalogQueryDescriptor] {
        if predicate(descriptors) {
            return descriptors
        }
        return await withCheckedContinuation { continuation in
            descriptorWaiters.append((predicate, continuation))
            resumeWaiters()
        }
    }

    func releaseNext() {
        guard !pausedBuilds.isEmpty else {
            return
        }
        pausedBuilds.removeFirst().resume()
    }

    func releaseAll() {
        let builds = pausedBuilds
        pausedBuilds.removeAll()
        for build in builds {
            build.resume()
        }
    }

    private func resumeWaiters() {
        var remainingCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if descriptors.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remainingCountWaiters.append(waiter)
            }
        }
        countWaiters = remainingCountWaiters

        var remainingDescriptorWaiters: [
            (@Sendable ([CatalogQueryDescriptor]) -> Bool, CheckedContinuation<[CatalogQueryDescriptor], Never>)
        ] = []
        for waiter in descriptorWaiters {
            if waiter.0(descriptors) {
                waiter.1.resume(returning: descriptors)
            } else {
                remainingDescriptorWaiters.append(waiter)
            }
        }
        descriptorWaiters = remainingDescriptorWaiters
    }
}
