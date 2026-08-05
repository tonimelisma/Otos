import Foundation

nonisolated enum DiagnosticsTiming {
    static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    static func milliseconds(since start: Date, now: Date = Date()) -> Int {
        milliseconds(from: start, to: now)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        max(Int(seconds(duration) * 1000), 0)
    }

    /// `Duration` as a fractional second count. `Duration.components.attoseconds` is
    /// the sub-second remainder, not "the whole duration in tiny units" — reading it
    /// alone silently discards every whole second, which is why this is the one place
    /// in the repo allowed to read it (enforced by `script/ci-text-hygiene.sh`).
    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        milliseconds(start.duration(to: end))
    }

    /// Microsecond resolution for sub-millisecond pipeline steps (membership
    /// validation, scoped-map construction, equality) whose cost rounds to zero in
    /// milliseconds but still matters when comparing per-publication stage costs.
    static func microseconds(since start: Date, now: Date = Date()) -> Int {
        max(0, Int((now.timeIntervalSince(start) * 1_000_000).rounded()))
    }
}
