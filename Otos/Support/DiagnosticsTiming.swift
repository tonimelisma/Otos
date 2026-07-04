import Foundation

nonisolated enum DiagnosticsTiming {
    static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    static func milliseconds(since start: Date, now: Date = Date()) -> Int {
        milliseconds(from: start, to: now)
    }

    /// Microsecond resolution for sub-millisecond pipeline steps (membership
    /// validation, scoped-map construction, equality) whose cost rounds to zero in
    /// milliseconds but still matters when comparing per-publication stage costs.
    static func microseconds(since start: Date, now: Date = Date()) -> Int {
        max(0, Int((now.timeIntervalSince(start) * 1_000_000).rounded()))
    }
}
