import Foundation
import MediaMetadata

/// The capture-timestamp roles Otos persists in `metadata_extra_json`: the library's own
/// roles (`CaptureTimestamps.Role`, whose raw values are its field names and are stable to
/// store), less the audio-only ones Otos never catalogs (MED-004).
///
/// `CaptureTimestampRecord.role` stays a `String` on purpose — the persisted JSON must
/// decode a role this build does not know rather than failing — but no code spells a role
/// as a literal.
nonisolated extension CaptureTimestamps.Role {
    static let cataloged: [CaptureTimestamps.Role] = allCases.filter { !$0.isAudioOnly }
}

nonisolated extension CaptureTimestampRecord {
    /// The record of one library timestamp, under its role.
    init(role: CaptureTimestamps.Role, time: CaptureTime) {
        self.init(
            role: role.rawValue,
            instant: time.instant,
            utcOffsetSeconds: time.utcOffsetSeconds,
            precision: time.precision.rawValue,
            year: time.year,
            month: time.month,
            day: time.day,
            hour: time.hour,
            minute: time.minute,
            second: time.second,
            fractionalSecondDigits: time.fractionalSecondDigits
        )
    }
}

nonisolated extension CaptureTime {
    /// The library's value for a stored record, or nil when the record is not a capture
    /// time this build can read: a precision it does not know, or wall-clock components
    /// missing or out of range. Such a record is left out of every selection rather than
    /// chosen and then failing.
    init?(record: CaptureTimestampRecord) {
        guard let precisionName = record.precision,
              let precision = Precision(rawValue: precisionName),
              let year = record.year,
              let month = record.month,
              let day = record.day,
              let hour = record.hour,
              let minute = record.minute,
              let second = record.second,
              (1 ... 12).contains(month),
              (1 ... 31).contains(day),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute),
              (0 ... 60).contains(second)
        else {
            return nil
        }
        self.init(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            utcOffsetSeconds: record.utcOffsetSeconds,
            instant: record.instant,
            precision: precision,
            fractionalSecondDigits: record.fractionalSecondDigits
        )
    }
}

/// The stored timestamps put back into the library's own value (ADR 0039), so its
/// selections answer the catalog's questions: `captureInstant` orders a file
/// (`capture_instant_unix`, which `best_capture_unix` falls back from to the file's
/// dates) and `captureWallClock` names it (`CaptureWallClock`). Otos restates neither
/// precedence.
///
/// `metadata.timestamps` is the one stored copy; both are derived from it where they are
/// written. A record of a role this build does not know, or one that is not a capture time
/// (`CaptureTime(record:)`), is left out.
nonisolated extension CaptureTimestamps {
    init(records: [CaptureTimestampRecord]) {
        self.init(entries: records.compactMap { record in
            guard let role = Role(rawValue: record.role), let time = CaptureTime(record: record) else {
                return nil
            }
            return (role, time)
        })
    }
}

nonisolated extension AssetMetadata {
    /// The instant the catalog sorts this file by (`capture_instant_unix`): the library's
    /// `captureInstant`, asked of the stored records.
    var captureInstant: Date? {
        CaptureTimestamps(records: timestamps).captureInstant?.time.instant
    }
}
