import Foundation
@testable import Otos
import Testing

struct CatalogStoreLifecycleRaceTests {
    @Test func concurrentStartupAndMutationShareOneInitialLoad() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate = InitialLoadGate()
        let scanner = CatalogScanner { _, _, _, _ in [] }
        let store = CatalogStore(
            location: .inMemory,
            scanner: scanner,
            diagnostics: nil,
            initialLoadDidRead: {
                await gate.pause()
            }
        )

        let startup = Task {
            try await store.start(scansSavedLibraries: false)
        }
        try await gate.waitForArrivalCount(1)
        let mutation = Task {
            try await store.addLibrary(url: root)
        }

        // The mutation enters while the first load is deliberately suspended.
        // One arrival proves it joined that load rather than starting a second
        // database read that could later replace the mutation's memory state.
        try await assertArrivalCountStays(gate, expectedCount: 1, duration: .milliseconds(50))
        let arrivalCount = await gate.arrivalCount()
        #expect(arrivalCount == 1)
        await gate.releaseAll()
        try await startup.value
        try await mutation.value

        let snapshot = try await catalogStoreTestState(store)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        #expect(snapshot.libraries.map(\.path) == [rootPath])
    }

    @Test func mutationFirstStartupStillScansLoadedRootsExactlyOnce() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let savedRoot = temp.appending(path: "Saved", directoryHint: .isDirectory)
        let addedRoot = temp.appending(path: "Added", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: savedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: addedRoot, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let emptyScanner = CatalogScanner { _, _, _, _ in [] }

        let firstStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: emptyScanner,
            diagnostics: nil
        )
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: savedRoot)
        _ = try await waitForCatalogStoreState(firstStore) { !$0.isScanning }

        let recorder = ScanInvocationRecorder()
        let recordingScanner = CatalogScanner { rootPath, _, _, _ in
            await recorder.record(rootPath)
            return []
        }
        let secondStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: recordingScanner,
            diagnostics: nil
        )

        // Mutation initialization must not consume the saved root's launch scan.
        // The newly added root separately owns its immediate scan.
        try await secondStore.addLibrary(url: addedRoot)
        try await secondStore.start()
        try await recorder.waitForInvocationCount(2)
        _ = try await waitForCatalogStoreState(secondStore) { !$0.isScanning }

        let savedPath = try CatalogPath.normalizedDirectoryPath(for: savedRoot)
        let addedPath = try CatalogPath.normalizedDirectoryPath(for: addedRoot)
        let invocations = await recorder.invocations()
        #expect(invocations.count { $0 == savedPath } == 1)
        #expect(invocations.count { $0 == addedPath } == 1)
    }

    @Test func staleCallbacksCannotMutateSamePathReplacementScan() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let diagnosticsURL = temp.appending(path: "diagnostics/catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: diagnosticsURL, isEnabled: true)
        let probe = ControlledScanProbe()
        let scanner = CatalogScanner { _, _, _, batchHandler in
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
            try? await batchHandler([file])
            return [file.relativePath]
        }
        let store = CatalogStore(
            location: .inMemory,
            scanner: scanner,
            diagnostics: diagnostics
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        try await probe.waitForInvocationCount(1)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)

        try await store.removeLibrary(path: rootPath)
        try await store.addLibrary(url: root)
        try await probe.waitForInvocationCount(2)

        await probe.release(1)
        _ = try await waitForCatalogDiagnostics(diagnosticsURL) { contents in
            contents.contains("\"operation\":\"catalog.scan.staleCallback\"")
                && contents.contains("\"callback\":\"completion\"")
        }
        let replacementStillActive = try await catalogStoreTestState(store)
        #expect(replacementStillActive.isScanning)
        #expect(replacementStillActive.testAssets.isEmpty)

        await probe.release(2)
        let completed = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        #expect(completed.testAssets.map(\.relativePath.rawValue) == ["replacement.jpg"])
    }
}

private actor InitialLoadGate {
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func pause() async {
        arrivals += 1
        resumeArrivalWaiters()
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func arrivalCount() -> Int {
        arrivals
    }

    func waitForArrivalCount(_ expectedCount: Int) async throws {
        try await withTestTimeout("initial load arrival count") {
            await self.waitForArrivalCountUnbounded(expectedCount)
        }
    }

    private func waitForArrivalCountUnbounded(_ expectedCount: Int) async {
        if arrivals >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append((expectedCount, continuation))
            resumeArrivalWaiters()
        }
    }

    func releaseAll() {
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    private func resumeArrivalWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in arrivalWaiters {
            if arrivals >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        arrivalWaiters = remaining
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

    func waitForInvocationCount(_ expectedCount: Int) async throws {
        _ = try await withTestTimeout("scan invocation count") {
            await self.waitForValues { paths in
                paths.count >= expectedCount
            }
        }
    }
}

private actor ControlledScanProbe {
    private var invocationCount = 0
    private var releasedInvocations = Set<Int>()
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var invocationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func beginInvocation() -> Int {
        invocationCount += 1
        resumeInvocationWaiters()
        return invocationCount
    }

    func waitForInvocationCount(_ expectedCount: Int) async throws {
        try await withTestTimeout("controlled scan invocation count") {
            await self.waitForInvocationCountUnbounded(expectedCount)
        }
    }

    private func waitForInvocationCountUnbounded(_ expectedCount: Int) async {
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

private enum CatalogLifecycleTestError: Error {
    case timedOut
}

private func assertArrivalCountStays(
    _ gate: InitialLoadGate,
    expectedCount: Int,
    duration: Duration
) async throws {
    try await Task.sleep(for: duration)
    #expect(await gate.arrivalCount() == expectedCount)
}

private func waitForCatalogDiagnostics(
    _ url: URL,
    matching predicate: @escaping @Sendable (String) -> Bool
) async throws -> String {
    try await withTestTimeout("catalog diagnostics") {
        while !Task.isCancelled {
            let data = try? Data(contentsOf: url)
            let contents = data.flatMap { String(data: $0, encoding: .utf8) }
            if let contents, predicate(contents) {
                return contents
            }
            await Task.yield()
        }
        throw CancellationError()
    }
}
