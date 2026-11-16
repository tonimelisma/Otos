import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogStoreLifecycleRaceTests {
    @Test func concurrentStartupAndMutationShareOneInitialLoad() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate = ArrivalGate()
        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = makeTestStore(
            location: .inMemory,
            scanner: scanner,
            initialLoadDidRead: {
                await gate.arrive()
            }
        )

        let startup = Task {
            try await store.start(scansSavedLibraries: false)
        }
        await gate.waitForArrivals(1)
        let mutation = Task {
            try await store.addLibrary(url: root)
        }

        // The mutation enters while the first load is deliberately suspended and
        // joins it, rather than starting a second database read that could later
        // replace the mutation's memory state.
        try await waitUntil { await store.joinedInitialLoadCount == 1 }
        #expect(await gate.arrivalCount == 1)
        await gate.open()
        try await startup.value
        try await mutation.value

        let snapshot = try await catalogStoreTestState(store)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        #expect(snapshot.libraries.map(\.path) == [rootPath])
    }

    @Test func mutationFirstStartupStillScansLoadedRootsExactlyOnce() async throws {
        let temp = try makeTestDirectory()
        let savedRoot = temp.appending(path: "Saved", directoryHint: .isDirectory)
        let addedRoot = temp.appending(path: "Added", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: savedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: addedRoot, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let emptyScanner = CatalogScanner { _, _, _ in .empty }

        let firstStore = makeTestStore(
            location: .databaseFile(databaseURL),
            scanner: emptyScanner
        )
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: savedRoot)
        _ = try await waitForCatalogStoreState(firstStore) { !$0.isScanning }

        let recorder = ScanInvocationRecorder()
        let recordingScanner = CatalogScanner { rootPath, _, _ in
            await recorder.record(rootPath)
            return .empty
        }
        let secondStore = makeTestStore(
            location: .databaseFile(databaseURL),
            scanner: recordingScanner
        )

        // Mutation initialization must not consume the saved root's launch scan.
        // The newly added root separately owns its immediate scan.
        try await secondStore.addLibrary(url: addedRoot)
        try await secondStore.start()
        await recorder.waitForInvocationCount(2)
        _ = try await waitForCatalogStoreState(secondStore) { !$0.isScanning }

        let savedPath = try CatalogPath.normalizedDirectoryPath(for: savedRoot)
        let addedPath = try CatalogPath.normalizedDirectoryPath(for: addedRoot)
        let invocations = await recorder.invocations()
        #expect(invocations.count { $0 == savedPath } == 1)
        #expect(invocations.count { $0 == addedPath } == 1)
    }

    @Test func staleCallbacksCannotMutateSamePathReplacementScan() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = ControlledScanProbe()
        let scanner = CatalogScanner { _, _, batchHandler in
            let invocation = await probe.beginInvocation()
            await probe.waitForRelease(invocation)
            let name = invocation == 1 ? "old.jpg" : "replacement.jpg"
            let file = ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: name),
                name: name,
                contentTypeIdentifier: "public.jpeg",
                byteSize: 1,
                createdAt: Date(timeIntervalSince1970: Double(invocation)),
                contentModifiedAt: Date(timeIntervalSince1970: Double(invocation))
            )
            // The first scanner deliberately ignores cancellation and calls
            // back late. Store ownership, not scanner cooperation, protects the
            // replacement root.
            let accepted: Bool
            do {
                try await batchHandler([file])
                accepted = true
            } catch {
                accepted = false
            }
            await probe.recordBatch(invocation, accepted: accepted)
            return .mediaOnly([file.relativePath])
        }
        let store = makeTestStore(
            location: .inMemory,
            scanner: scanner
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        await probe.waitForInvocationCount(1)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)

        #expect(try await store.removeLibrary(path: rootPath) == .removed)
        try await store.addLibrary(url: root)
        await probe.waitForInvocationCount(2)

        // The stale scanner's late batch is refused, and only once the store has
        // answered it is the catalog read, so an empty catalog means refused rather
        // than not yet delivered.
        await probe.release(1)
        #expect(await probe.batchOutcome(1) == false)
        let replacementStillActive = try await catalogStoreTestState(store)
        #expect(replacementStillActive.isScanning)
        #expect(replacementStillActive.testAssets.isEmpty)

        await probe.release(2)
        #expect(await probe.batchOutcome(2) == true)
        let completed = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        #expect(completed.testAssets.map(\.relativePath.rawValue) == ["replacement.jpg"])
    }
}

private typealias ScanInvocationRecorder = AsyncValueRecorder<LibraryRootPath>

private extension AsyncValueRecorder where Value == LibraryRootPath {
    func record(_ path: LibraryRootPath) {
        append(path)
    }

    func invocations() -> [LibraryRootPath] {
        snapshot()
    }

    func waitForInvocationCount(_ expectedCount: Int) async {
        _ = await waitForValues { paths in
            paths.count >= expectedCount
        }
    }
}

/// Holds each scanner invocation until the test releases it, and reports what the
/// store answered to that invocation's batch once the handler has returned.
private actor ControlledScanProbe {
    private var invocationCount = 0
    private var releasedInvocations = Set<Int>()
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var invocationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var batchOutcomes: [Int: Bool] = [:]
    private var batchWaiters: [Int: [CheckedContinuation<Bool, Never>]] = [:]

    func beginInvocation() -> Int {
        invocationCount += 1
        resumeInvocationWaiters()
        return invocationCount
    }

    func waitForInvocationCount(_ expectedCount: Int) async {
        if invocationCount >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            invocationWaiters.append((expectedCount, continuation))
            resumeInvocationWaiters()
        }
    }

    func waitForRelease(_ invocation: Int) async {
        if releasedInvocations.contains(invocation) {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters[invocation] = continuation
        }
    }

    func release(_ invocation: Int) {
        releasedInvocations.insert(invocation)
        releaseWaiters.removeValue(forKey: invocation)?.resume()
    }

    func recordBatch(_ invocation: Int, accepted: Bool) {
        batchOutcomes[invocation] = accepted
        batchWaiters.removeValue(forKey: invocation)?.forEach { $0.resume(returning: accepted) }
    }

    /// Whether the store accepted `invocation`'s batch, returned once its handler has.
    func batchOutcome(_ invocation: Int) async -> Bool {
        if let outcome = batchOutcomes[invocation] {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            batchWaiters[invocation, default: []].append(continuation)
        }
    }

    private func resumeInvocationWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in invocationWaiters {
            if invocationCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        invocationWaiters = remaining
    }
}
