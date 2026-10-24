import Foundation

/// Elapsed-time arithmetic for diagnostics and process-local deadlines.
///
/// Every duration Otos measures inside one process is taken on `ContinuousClock`: it is
/// monotonic, so a wall-clock change or a sync adjustment never shortens, lengthens or
/// reverses an interval, and it keeps counting across system sleep. `Date` is kept for
/// facts that outlive the process or are shown to a person — a persisted timestamp, a
/// capture time — and is never used to measure an interval.
nonisolated enum DiagnosticsTiming {
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

    static func milliseconds(
        since start: ContinuousClock.Instant,
        now: ContinuousClock.Instant = .now
    ) -> Int {
        milliseconds(from: start, to: now)
    }

    /// Microsecond resolution for sub-millisecond pipeline steps (membership
    /// validation, scoped-map construction, equality) whose cost rounds to zero in
    /// milliseconds but still matters when comparing per-publication stage costs.
    static func microseconds(
        since start: ContinuousClock.Instant,
        now: ContinuousClock.Instant = .now
    ) -> Int {
        max(0, Int((seconds(start.duration(to: now)) * 1_000_000).rounded()))
    }
}
