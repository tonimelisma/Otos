import Foundation
import MediaMetadata

/// Capture-wall naming fact
///
/// Import destination folders and date-time names use the local wall clock when
/// and where the item was captured — never a UTC-anchored timestamp without a
/// recoverable capture zone, and never a fabricated planning/copy time.
///
/// The wall clock is the library's own selection, `CaptureTimestamps.captureWallClock`
/// (ADR 0039): the first local-authority time (`localFloating` / `localWithOffset`) in
/// `wallClockPrecedence`, never an absolute one (container creation, GPS, bare-Z). It is
/// asked of the persisted records rather than a live read, so a reused overlay and a
/// re-read row name the same way. The compact integer is
/// `YYYYMMDDHHMMSS` so naming can format components verbatim without zone math.
nonisolated enum CaptureWallClock {
    struct Selection: Equatable, Sendable {
        let compact: Int64
        let precision: String
    }

    /// Precision marking a wall clock Otos *derived* rather than read from the file.
    ///
    /// A video's filesystem mtime is when recording stopped, so `mtime − duration` is
    /// its capture instant. This is the last resort for video when no local-authority
    /// embedded candidate exists — 100% of two roots' videos in one production
    /// catalog, whose names were otherwise wrong by each clip's own length. It is a
    /// distinct precision, not a silent substitution, so a derived wall is
    /// self-identifying wherever it is read (ENR-012).
    static let derivedFromDurationPrecision = "derivedFromDuration"

    /// The capture wall for a video with no embedded local-authority timestamp,
    /// derived from when recording stopped less how long it ran.
    ///
    /// Returns nil unless every input is present and the arithmetic lands on a real
    /// wall clock — a fabricated date is worse than none, and the planner already
    /// blocks an entry it cannot name.
    static func derivedFromDuration(
        modifiedAt: Date?,
        durationSeconds: Double?,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> Selection? {
        guard let modifiedAt,
              let durationSeconds,
              durationSeconds > 0,
              durationSeconds.isFinite
        else {
            return nil
        }
        let captured = modifiedAt.addingTimeInterval(-durationSeconds)
        var local = calendar
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: captured)
        guard let year = parts.year,
              let month = parts.month,
              let day = parts.day,
              let hour = parts.hour,
              let minute = parts.minute,
              let second = parts.second
        else {
            return nil
        }
        let compact = Int64(year) * 10_000_000_000
            + Int64(month) * 100_000_000
            + Int64(day) * 1_000_000
            + Int64(hour) * 10000
            + Int64(minute) * 100
            + Int64(second)
        guard components(fromCompact: compact) != nil else {
            return nil
        }
        return Selection(compact: compact, precision: derivedFromDurationPrecision)
    }

    struct Components: Equatable, Sendable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
    }

    /// The embedded local wall clock from persisted timestamp records: the library's
    /// `captureWallClock` (ADR 0039) as a compact integer and its precision.
    static func select(from records: [CaptureTimestampRecord]) -> Selection? {
        guard let time = CaptureTimestamps(records: records).captureWallClock?.time,
              let local = time.captureLocalComponents
        else {
            return nil
        }
        // YYYYMMDDHHMMSS — e.g. 20260101120000
        let compact =
            Int64(local.year) * 10_000_000_000
                + Int64(local.month) * 100_000_000
                + Int64(local.day) * 1_000_000
                + Int64(local.hour) * 10000
                + Int64(local.minute) * 100
                + Int64(local.second)
        return Selection(compact: compact, precision: time.precision.rawValue)
    }

    static func components(fromCompact compact: Int64) -> Components? {
        guard compact >= 1_000_000_000_000, compact <= 99_999_999_999_999 else {
            return nil
        }
        let year = Int(compact / 10_000_000_000)
        let month = Int((compact / 100_000_000) % 100)
        let day = Int((compact / 1_000_000) % 100)
        let hour = Int((compact / 10000) % 100)
        let minute = Int((compact / 100) % 100)
        let second = Int(compact % 100)
        guard (1 ... 12).contains(month),
              (1 ... 31).contains(day),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute),
              (0 ... 59).contains(second)
        else {
            return nil
        }
        return Components(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    }

    /// Interprets a compact local wall clock in the current calendar/time zone.
    static func date(fromCompact compact: Int64, calendar: Calendar = .current) -> Date? {
        guard let components = components(fromCompact: compact) else {
            return nil
        }
        var dateComponents = DateComponents()
        dateComponents.year = components.year
        dateComponents.month = components.month
        dateComponents.day = components.day
        dateComponents.hour = components.hour
        dateComponents.minute = components.minute
        dateComponents.second = components.second
        return calendar.date(from: dateComponents)
    }
}
