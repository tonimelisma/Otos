import Foundation

nonisolated enum DiagnosticsTiming {
    static func milliseconds(since start: Date, now: Date = Date()) -> Int {
        max(0, Int((now.timeIntervalSince(start) * 1000).rounded()))
    }
}
