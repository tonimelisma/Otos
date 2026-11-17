import Foundation
@testable import OtosKit
import Testing

@Suite(.serialized, .testScope)
struct CatalogWindowViewModelQueryIntentTests {
    @MainActor
    @Test func normalizedNoOpQueryIntentDoesNotBumpOrRollbackGeneration() async throws {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let (model, gate) = makeQueryIntentModel(temp: temp)

        model.start()
        await gate.waitForBuildCount(1)
        model.setSortOrder(.dateNewest)
        await gate.releaseAll()
        _ = try await waitForWindowState(model) { state in
            state.title == "Build 1"
        }

        let requests = await waitForRequestsReleasingBuilds(gate) { requests in
            requests.count >= 1
        }

        #expect(model.queryDescriptor == .default)
        #expect(model.state.queryGeneration == 0)
        #expect(requests.allSatisfy { $0.descriptor == .default && $0.generation == 0 })
    }

    @MainActor
    @Test func staleProjectedStateDoesNotRollbackToggledBackQueryIntent() async throws {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let (model, gate) = makeQueryIntentModel(temp: temp)

        model.start()
        await gate.waitForBuildCount(1)
        // A sort chosen and toggled back while the first build is parked: whichever builds
        // for the sort left run or are superseded (ADR 0005), what the window shows in the
        // end is the default the user came back to, and no state rolls the intent back.
        model.setSortOrder(.filenameAscending)
        model.setSortOrder(.dateNewest)
        #expect(model.queryDescriptor == .default)

        await gate.open()
        let settled = try await waitForWindowState(model) { state in
            state.title.hasPrefix("Build") && state.queryDescriptor == .default
        }
        await gate.close()
        #expect(settled.queryDescriptor == .default)
        #expect(model.queryDescriptor == .default)

        let staleGeneration = model.state.queryGeneration
        model.setMediaFilter(MediaFilter(kinds: [.image]))
        let expectedDescriptor = CatalogQueryDescriptor(
            scope: .allMedia,
            filter: MediaFilter(kinds: [.image]),
            sort: .defaultOrder
        )
        #expect(model.queryDescriptor == expectedDescriptor)

        let requests = await waitForRequestsReleasingBuilds(gate) { requests in
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
    matching predicate: @escaping @Sendable ([CatalogQueryRequest]) -> Bool
) async -> [CatalogQueryRequest] {
    await gate.open()
    let requests = await gate.waitForRequests(matching: predicate)
    await gate.close()
    return requests
}

@MainActor
private func makeQueryIntentModel(temp: PreferencesDomain)
    -> (model: CatalogWindowViewModel, gate: WindowStateBuildGate)
{
    let store = makeTestStore(location: .inMemory)
    let gate = WindowStateBuildGate()
    let projection = CatalogProjection(
        volumeCapacity: ampleVolumeCapacity,
        cadence: .milliseconds(10),
        stateBuilder: { libraries, _, request in
            let buildNumber = await gate.record(request)
            return testWindowState(buildNumber: buildNumber, libraries: libraries, request: request)
        }
    )
    let model = CatalogWindowViewModel(
        catalogStore: store,
        catalogProjection: projection,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: temp,
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
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

private actor WindowStateBuildGate {
    private var requests: [CatalogQueryRequest] = []
    private var pausedBuilds: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var requestWaiters: [
        (@Sendable ([CatalogQueryRequest]) -> Bool, CheckedContinuation<[CatalogQueryRequest], Never>)
    ] = []

    func record(_ request: CatalogQueryRequest) async -> Int {
        requests.append(request)
        resumeWaiters()
        let buildNumber = requests.count
        guard !isOpen else {
            return buildNumber
        }
        await withCheckedContinuation { continuation in
            pausedBuilds.append(continuation)
        }
        return buildNumber
    }

    func waitForBuildCount(_ expectedCount: Int) async {
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

    /// Lets every held and later build through until `close()`.
    func open() {
        isOpen = true
        releaseAll()
    }

    func close() {
        isOpen = false
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
