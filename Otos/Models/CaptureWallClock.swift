import Foundation
import MediaMetadata

/// Capture-wall naming fact
///
/// Import destination folders and date-time names use the local wall clock when
/// and where the item was captured — never a UTC-anchored timestamp without a
/// recoverable capture zone, and never a fabricated planning/copy time.
///
/// Selection prefers local-authority candidates (`localFloating` /
/// `localWithOffset`) in role order original → digitized → quickTimeCreation →
/// quickTimeContentCreate. Absolute candidates (container creation, GPS, bare-Z)
/// are excluded. The compact integer is `YYYYMMDDHHMMSS` so naming can format
/// components verbatim without zone math.
nonisolated enum CaptureWallClock {
    /// Role precedence for naming. Matches plan 0055 contract item 6.
    static let namingRolePrecedence = [
        "original",
        "digitized",
        "quickTimeCreation",
        "quickTimeContentCreate",
    ]

    struct Selection: Equatable, Sendable {
        let compact: Int64
        let precision: String
    }

    struct Components: Equatable, Sendable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
    }

    /// Selects the embedded local wall clock from persisted timestamp records.
    static func select(from records: [CaptureTimestampRecord]) -> Selection? {
        let byRole = Dictionary(grouping: records, by: \.role)
        for role in namingRolePrecedence {
            guard let candidates = byRole[role] else {
                continue
            }
            if let local = candidates.first(where: isLocalAuthority),
               let selection = selection(from: local)
            {
                return selection
            }
        }
        return nil
    }

    /// Selects from live MediaMetadata timestamps using `captureLocalComponents`
    /// so absolute UTC wall clocks are structurally unusable for naming.
    static func select(from timestamps: CaptureTimestamps) -> Selection? {
        let ordered: [(String, CaptureTime?)] = [
            ("original", timestamps.original),
            ("digitized", timestamps.digitized),
            ("quickTimeCreation", timestamps.quickTimeCreation),
            ("quickTimeContentCreate", timestamps.quickTimeContentCreate),
        ]
        for (role, time) in ordered {
            guard let time, let local = time.captureLocalComponents else {
                continue
            }
            _ = role
            let compact =
                Int64(local.year) * 10_000_000_000
                    + Int64(local.month) * 100_000_000
                    + Int64(local.day) * 1_000_000
                    + Int64(local.hour) * 10000
                    + Int64(local.minute) * 100
                    + Int64(local.second)
            return Selection(compact: compact, precision: time.precision.rawValue)
        }
        return nil
    }

    static func isLocalAuthority(_ record: CaptureTimestampRecord) -> Bool {
        switch record.precision {
        case "localFloating", "localWithOffset":
            true
        default:
            false
        }
    }

    static func selection(from record: CaptureTimestampRecord) -> Selection? {
        guard let year = record.year,
              let month = record.month,
              let day = record.day,
              let hour = record.hour,
              let minute = record.minute,
              let second = record.second,
              let precision = record.precision,
              isLocalAuthority(record),
              (1 ... 12).contains(month),
              (1 ... 31).contains(day),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute),
              (0 ... 60).contains(second)
        else {
            return nil
        }
        // YYYYMMDDHHMMSS — e.g. 20260101120000
        let compact =
            Int64(year) * 10_000_000_000
                + Int64(month) * 100_000_000
                + Int64(day) * 1_000_000
                + Int64(hour) * 10000
                + Int64(minute) * 100
                + Int64(second)
        return Selection(compact: compact, precision: precision)
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
