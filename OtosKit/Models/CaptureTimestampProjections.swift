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
/// selections answer the catalog's questions: `captureWallClock` names a file, puts it on a
/// day and orders the timeline (`CaptureWallClock`, `best_capture_local`), and
/// `captureInstant` pins the moment (`capture_instant_unix`), which places a file without a
/// wall clock (`CaptureLocalTime`). Otos restates neither precedence.
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

/// When an item was taken, as a clock where it was taken read: a local wall-clock time with
/// no zone (ADR 0039). It is what the timeline orders by, what puts an item on a day, and
/// what Info shows, so a photo taken at 08:00 on 25 April in Tokyo is a 25 April photo,
/// shown at 08:00, wherever and in whatever zone the Mac is now.
///
/// `seconds` counts the reading from 1970-01-01 00:00 on the same clock: the reading taken
/// as if it were UTC. That makes it comparable, indexable (`best_capture_local`) and
/// zone-free; it is never an instant, so it is never handed to an API that wants one
/// without `presentationDate(in:)`.
///
/// The catalog's value is the library's capture wall clock where the file has one
/// (`capture_wall_compact`), else the item's absolute time read in the zone Otos assumed
/// for it (`CaptureLocalTime.assumedUTCOffset`).
nonisolated struct CaptureLocalTime: Comparable, Hashable, Sendable {
    let seconds: Double

    init(seconds: Double) {
        self.seconds = seconds
    }

    /// The reading a clock in `timeZone` shows at `date`.
    init(readingOf date: Date, in timeZone: TimeZone = .current) {
        seconds = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
    }

    /// The first moment of `day` on any clock: midnight of that reading.
    init?(startOf day: CalendarDay) {
        guard let start = day.start(in: .gmt) else {
            return nil
        }
        seconds = start.timeIntervalSince1970
    }

    /// The midnight that starts the day numbered `dayNumber`.
    init(dayNumber: Int) {
        seconds = Double(dayNumber) * 86400
    }

    /// The day this time falls on, counted in days from 1970-01-01 on the clock it was read
    /// from: equal for every reading of one day, and cheap to compare.
    var dayNumber: Int {
        Int((seconds / 86400).rounded(.down))
    }

    /// The day this time falls on, on the clock it was read from.
    var day: CalendarDay {
        CalendarDay(Date(timeIntervalSince1970: seconds), timeZone: .gmt)
    }

    /// The instant a clock in `timeZone` shows this reading, which is what a formatter or
    /// calendar in that zone needs to write the time as it was taken. A reading the zone
    /// skips (the hour a daylight-saving change removes) resolves to the next reading it has.
    func presentationDate(in timeZone: TimeZone = .current) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let reading = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: Date(timeIntervalSince1970: seconds)
        )
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        return local.date(from: reading) ?? Date(timeIntervalSince1970: seconds - Double(timeZone.secondsFromGMT()))
    }

    /// This reading written with `style`, as the clock it was read from shows it: the style's
    /// calendar and locale are kept, its zone is the reading's own.
    func formatted(_ style: Date.FormatStyle) -> String {
        var reading = style
        reading.timeZone = .gmt
        return Date(timeIntervalSince1970: seconds).formatted(reading)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds < rhs.seconds
    }

    /// The UTC offset Otos reads an item's absolute time with when its file records no wall
    /// clock: the offset of `timeZone` — the Mac's zone when Otos records that time — at that
    /// time. Lightroom and Photos assume the computer's zone at import the same way. The
    /// assumption is kept while the absolute time it was made for is unchanged to the second, so an item
    /// does not move between days when the Mac changes zone; it is made again only when that
    /// time changes (`assumed_utc_offset_seconds`).
    static func assumedUTCOffset(
        for absolute: Double?,
        previousAbsolute: Double?,
        previousOffset: Int?,
        timeZone: TimeZone = .current
    ) -> Int? {
        guard let absolute else {
            return nil
        }
        // To the second, as the scan compares file dates: a sub-second difference is the
        // same time.
        if let previousOffset, let previousAbsolute, previousAbsolute.rounded(.down) == absolute.rounded(.down) {
            return previousOffset
        }
        return timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: absolute))
    }
}
