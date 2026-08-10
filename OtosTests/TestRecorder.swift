import Synchronization

/// Concurrency-safe accumulator for test doubles. Replaces nine hand-rolled
/// unchecked-Sendable + NSLock classes (ARC-042, plan 0072 Stage 4).
final class TestRecorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    func record(_ value: Value) {
        storage.withLock { $0.append(value) }
    }

    var values: [Value] {
        storage.withLock { $0 }
    }

    var count: Int {
        storage.withLock { $0.count }
    }
}

/// Counter specialization — the most common case.
final class TestCounter: Sendable {
    private let storage = Mutex(0)
    func increment() {
        storage.withLock { $0 += 1 }
    }

    func incrementAndGet() -> Int {
        storage.withLock { $0 += 1
            return $0
        }
    }

    var value: Int {
        storage.withLock { $0 }
    }
}
