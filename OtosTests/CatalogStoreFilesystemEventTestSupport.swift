import Foundation
@testable import Otos
import Testing

func recordingScanner(_ recorder: FilesystemEventScanInvocationRecorder) -> CatalogScanner {
    CatalogScanner { rootPath, _, _, _ in
        await recorder.record(rootPath)
        return []
    }
}

func recordingLiveScanner(_ recorder: FilesystemEventScanInvocationRecorder) -> CatalogScanner {
    CatalogScanner { rootPath, cadence, diagnostics, batchHandler in
        await recorder.record(rootPath)
        return try await CatalogScanner.live.scanRoot(rootPath, cadence, diagnostics, batchHandler)
    }
}

func deferredHangingScanner(
    probe: FilesystemScanProbe,
    recorder: FilesystemEventScanInvocationRecorder
) -> CatalogScanner {
    CatalogScanner { rootPath, _, _, _ in
        let invocation = await probe.beginInvocation()
        await recorder.record(rootPath)
        if invocation == 2 {
            await probe.waitForRelease(invocation)
        }
        return []
    }
}

func firstScanHangingScanner(
    probe: FilesystemScanProbe,
    recorder: FilesystemEventScanInvocationRecorder
) -> CatalogScanner {
    CatalogScanner { rootPath, _, _, _ in
        let invocation = await probe.beginInvocation()
        await recorder.record(rootPath)
        if invocation == 1 {
            await probe.waitForRelease(invocation)
        }
        return []
    }
}

actor FilesystemEventScanInvocationRecorder {
    private var paths: [LibraryRootPath] = []
    private var waiters: [(Int, CheckedContinuation<[LibraryRootPath], Never>)] = []

    func record(_ path: LibraryRootPath) {
        paths.append(path)
        resumeWaiters()
    }

    func invocations() -> [LibraryRootPath] {
        paths
    }

    func waitForInvocationCount(_ expectedCount: Int) async throws {
        _ = try await withTestTimeout("scan invocation count") {
            await self.waitForInvocationCountUnbounded(expectedCount)
        }
    }

    private func waitForInvocationCountUnbounded(_ expectedCount: Int) async -> [LibraryRootPath] {
        if paths.count >= expectedCount {
            return paths
        }
        return await withCheckedContinuation { continuation in
            waiters.append((expectedCount, continuation))
            resumeWaiters()
        }
    }

    private func resumeWaiters() {
        var remaining: [(Int, CheckedContinuation<[LibraryRootPath], Never>)] = []
        for waiter in waiters {
            if paths.count >= waiter.0 {
                waiter.1.resume(returning: paths)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

actor FilesystemScanProbe {
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
        try await withTestTimeout("filesystem scan invocation count") {
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

func waitForFilesystemRescan(
    store: CatalogStore,
    recorder: FilesystemEventScanInvocationRecorder,
    baseline: Int,
    expectedAdditional: Int = 1
) async throws {
    let changes = await store.changeNotifications()
    if try await filesystemRescanFinished(
        store: store,
        recorder: recorder,
        baseline: baseline,
        expectedAdditional: expectedAdditional
    ) {
        return
    }
    try await withTestTimeout("filesystem rescan") {
        for await _ in changes where try await filesystemRescanFinished(
            store: store,
            recorder: recorder,
            baseline: baseline,
            expectedAdditional: expectedAdditional
        ) {
            return
        }
        throw AsyncTestTimeoutError.streamEnded("filesystem rescan")
    }
}

func waitForFilesystemDiagnostic(
    _ url: URL,
    matching predicate: @escaping @Sendable (CatalogDiagnosticEvent) -> Bool
) async throws -> CatalogDiagnosticEvent {
    try await withTestTimeout("filesystem diagnostic") {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while !Task.isCancelled {
            if let data = try? Data(contentsOf: url) {
                let events = data.split(separator: 0x0A).compactMap { line in
                    try? decoder.decode(CatalogDiagnosticEvent.self, from: Data(line))
                }
                if let event = events.first(where: predicate) {
                    return event
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }
}

private func filesystemRescanFinished(
    store: CatalogStore,
    recorder: FilesystemEventScanInvocationRecorder,
    baseline: Int,
    expectedAdditional: Int
) async throws -> Bool {
    let snapshot = try await catalogStoreTestState(store)
    let count = await recorder.invocations().count
    return !snapshot.isScanning && count == baseline + expectedAdditional
}

func assertInvocationCountStays(
    _ recorder: FilesystemEventScanInvocationRecorder,
    baseline: Int,
    duration: Duration
) async throws {
    try await Task.sleep(for: duration)
    #expect(await recorder.invocations().count == baseline)
}
