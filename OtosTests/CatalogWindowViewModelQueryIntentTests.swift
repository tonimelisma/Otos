@testable import Otos
import Testing

@Suite(.serialized)
struct CatalogWindowViewModelQueryIntentTests {
    @MainActor
    @Test func staleProjectedStateDoesNotRollbackNewerQueryIntent() async throws {
        let (model, gate) = makeQueryIntentModel()

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

        let requests = try await waitForRequestsReleasingBuilds(gate, "target query descriptor") { requests in
            requests.contains { request in
                request.descriptor == CatalogQueryDescriptor(
                    scope: .allMedia,
                    filter: MediaFilter(kinds: [.image]),
                    sort: .defaultForField(.name)
                )
                    && request.generation > 0
            }
        }
        await gate.releaseAll()
        #expect(requests.last?.descriptor.sort.field == .name)
    }

    @MainActor
    @Test func staleProjectedStateDoesNotRollbackToggledBackQueryIntent() async throws {
        let (model, gate) = makeQueryIntentModel()

        model.start()
        try await gate.waitForBuildCount(1)
        model.setSortField(.name)
        await gate.releaseNext()

        _ = try await waitForWindowState(model) { state in
            state.title == "Build 1"
        }
        try await gate.waitForBuildCount(2)

        model.setSortField(.bestDate)
        #expect(model.queryDescriptor == .default)

        await gate.releaseNext()
        _ = try await waitForWindowState(model) { state in
            state.title == "Build 2"
        }
        #expect(model.state.queryGeneration == 1)
        #expect(model.state.queryDescriptor.sort.field == .name)
        #expect(model.queryDescriptor == .default)

        let staleGeneration = model.state.queryGeneration
        model.setMediaFilter(MediaFilter(kinds: [.image]))
        let expectedDescriptor = CatalogQueryDescriptor(
            scope: .allMedia,
            filter: MediaFilter(kinds: [.image]),
            sort: .defaultOrder
        )
        #expect(model.queryDescriptor == expectedDescriptor)

        let requests = try await waitForRequestsReleasingBuilds(gate, "toggled-back query descriptor") { requests in
            requests.contains { request in
                request.descriptor == expectedDescriptor
                    && request.generation > staleGeneration
            }
        }
        await gate.releaseAll()
        #expect(requests.last?.descriptor == expectedDescriptor)
    }
}

private func waitForRequestsReleasingBuilds(
    _ gate: WindowStateBuildGate,
    _ description: String,
    matching predicate: @escaping @Sendable ([CatalogQueryRequest]) -> Bool
) async throws -> [CatalogQueryRequest] {
    let releaseTask = Task {
        while !Task.isCancelled {
            await gate.releaseAll()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    defer { releaseTask.cancel() }

    return try await withTestTimeout(description) {
        await gate.waitForRequests(matching: predicate)
    }
}

@MainActor
private func makeQueryIntentModel() -> (model: CatalogWindowViewModel, gate: WindowStateBuildGate) {
    let store = CatalogStore(location: .inMemory, diagnostics: nil)
    let gate = WindowStateBuildGate()
    let projection = CatalogProjection(
        cadence: .milliseconds(10),
        diagnostics: nil,
        stateBuilder: { libraries, _, request in
            let buildNumber = await gate.record(request)
            return testWindowState(buildNumber: buildNumber, libraries: libraries, request: request)
        }
    )
    let model = CatalogWindowViewModel(
        catalogStore: store,
        catalogProjection: projection,
        diagnostics: nil,
        startsStallMonitor: false,
        startsEnrichment: false
    )
    return (model, gate)
}

private func testWindowState(
    buildNumber: Int,
    libraries: [CatalogLibraryState],
    request: CatalogQueryRequest
) -> CatalogWindowState {
    CatalogWindowState(
        title: "Build \(buildNumber)",
        libraries: libraries,
        mediaGrid: CatalogMediaGridState(
            descriptor: request.descriptor,
            orderedAssetIDs: []
        ),
        filterOptions: .empty,
        resolvedSidebarSelection: request.descriptor.scope,
        mediaEmptyState: .noMedia,
        queryGeneration: request.generation
    )
}

private actor WindowStateBuildGate {
    private var requests: [CatalogQueryRequest] = []
    private var pausedBuilds: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var requestWaiters: [
        (@Sendable ([CatalogQueryRequest]) -> Bool, CheckedContinuation<[CatalogQueryRequest], Never>)
    ] = []

    func record(_ request: CatalogQueryRequest) async -> Int {
        requests.append(request)
        resumeWaiters()
        let buildNumber = requests.count
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
        if requests.count >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((expectedCount, continuation))
            resumeWaiters()
        }
    }

    func waitForRequests(
        matching predicate: @escaping @Sendable ([CatalogQueryRequest]) -> Bool
    ) async -> [CatalogQueryRequest] {
        if predicate(requests) {
            return requests
        }
        return await withCheckedContinuation { continuation in
            requestWaiters.append((predicate, continuation))
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
            if requests.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remainingCountWaiters.append(waiter)
            }
        }
        countWaiters = remainingCountWaiters

        var remainingRequestWaiters: [
            (@Sendable ([CatalogQueryRequest]) -> Bool, CheckedContinuation<[CatalogQueryRequest], Never>)
        ] = []
        for waiter in requestWaiters {
            if waiter.0(requests) {
                waiter.1.resume(returning: requests)
            } else {
                remainingRequestWaiters.append(waiter)
            }
        }
        requestWaiters = remainingRequestWaiters
    }
}
