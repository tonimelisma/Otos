import Foundation
@testable import OtosKit

extension MaterializationResult {
    static var testMaterialized: MaterializationResult {
        MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 0)
    }
}

enum AsyncTestTimeoutError: Error, CustomStringConvertible {
    case timedOut(String)
    case streamEnded(String)

    var description: String {
        switch self {
        case let .timedOut(label):
            "Timed out waiting for \(label)"
        case let .streamEnded(label):
            "Stream ended while waiting for \(label)"
        }
    }
}

func withTestTimeout<Value: Sendable>(
    _ label: String,
    timeout: Duration = .seconds(10),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let resolver = AsyncTestTimeoutResolver(continuation: continuation)
        let operationTask = Task {
            do {
                let value = try await operation()
                await resolver.resolve(returning: value)
            } catch {
                await resolver.resolve(throwing: error)
            }
        }
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            operationTask.cancel()
            await resolver.resolve(throwing: AsyncTestTimeoutError.timedOut(label))
        }
        Task {
            await resolver.setTasks(operationTask: operationTask, timeoutTask: timeoutTask)
        }
    }
}

/// Waits until the projection has no pending or in-flight publication, so a test can
/// assert on a settled `orderQueryCount` without guessing a sleep duration. Polls actor
/// state rather than sleeping a fixed interval — a fixed sleep is either flaky under
/// parallel-suite load or needlessly slow, and usually both (plan 0065 Stage 4).
func waitForProjectionQuiescence(
    _ projection: CatalogProjection,
    timeout: Duration = .seconds(5)
) async throws {
    try await withTestTimeout("projection quiescence", timeout: timeout) {
        while await !projection.isQuiescent {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor AsyncTestTimeoutResolver<Value: Sendable> {
    private let continuation: CheckedContinuation<Value, any Error>
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, any Error>?
    private var didResolve = false

    init(continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func setTasks(operationTask: Task<Void, Never>, timeoutTask: Task<Void, any Error>) {
        if didResolve {
            operationTask.cancel()
            timeoutTask.cancel()
        } else {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
        }
    }

    func resolve(returning value: Value) {
        guard !didResolve else {
            return
        }
        didResolve = true
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil
        continuation.resume(returning: value)
    }

    func resolve(throwing error: any Error) {
        guard !didResolve else {
            return
        }
        didResolve = true
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil
        continuation.resume(throwing: error)
    }
}

actor AsyncValueRecorder<Value: Sendable> {
    private struct Waiter {
        let predicate: @Sendable ([Value]) -> Bool
        let continuation: CheckedContinuation<[Value], Never>
    }

    private var values: [Value] = []
    private var waiters: [UUID: Waiter] = [:]

    func append(_ value: Value) {
        values.append(value)
        resumeSatisfiedWaiters()
    }

    func snapshot() -> [Value] {
        values
    }

    func count() -> Int {
        values.count
    }

    func waitForValues(
        matching predicate: @escaping @Sendable ([Value]) -> Bool
    ) async -> [Value] {
        if predicate(values) {
            return values
        }

        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(predicate: predicate, continuation: continuation)
            resumeSatisfiedWaiters()
        }
    }

    private func resumeSatisfiedWaiters() {
        let satisfiedIDs = waiters.compactMap { id, waiter in
            waiter.predicate(values) ? id : nil
        }
        for id in satisfiedIDs {
            waiters.removeValue(forKey: id)?.continuation.resume(returning: values)
        }
    }
}

actor ManualSleepGate {
    private var sleepRequestCount = 0
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for _: Duration) async {
        sleepRequestCount += 1
        resumeCountWaiters()
        await withCheckedContinuation { continuation in
            sleepers.append(continuation)
        }
    }

    func waitForSleepRequestCount(_ expectedCount: Int) async throws {
        try await withTestTimeout("manual sleep requests") {
            await self.waitForSleepRequestCountUnbounded(expectedCount)
        }
    }

    private func waitForSleepRequestCountUnbounded(_ expectedCount: Int) async {
        if sleepRequestCount >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((expectedCount, continuation))
            resumeCountWaiters()
        }
    }

    func releaseNext() {
        guard !sleepers.isEmpty else {
            return
        }
        sleepers.removeFirst().resume()
    }

    func releaseAll() {
        let currentSleepers = sleepers
        sleepers.removeAll()
        for sleeper in currentSleepers {
            sleeper.resume()
        }
    }

    private func resumeCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if sleepRequestCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}
