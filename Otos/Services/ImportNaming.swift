import Foundation

nonisolated struct CaptureWallComponents: Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    var dateTimeFileName: String {
        String(format: "%04d%02d%02d_%02d%02d%02d", year, month, day, hour, minute, second)
    }

    var yearMonthFolder: String {
        String(format: "%04d/%02d", year, month)
    }
}

nonisolated enum ImportNaming {
    static func timestamp(
        wallCompact: Int64?,
        fallbackModifiedAt: Date?,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> CaptureWallComponents? {
        if let wallCompact, let components = components(fromCompact: wallCompact) {
            return CaptureWallComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: components.hour,
                minute: components.minute,
                second: components.second
            )
        }
        guard let fallbackModifiedAt else { return nil }
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let components = localCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fallbackModifiedAt
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second
        else { return nil }
        return CaptureWallComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    }

    private static func components(fromCompact compact: Int64) -> CaptureWallComponents? {
        guard compact >= 1_000_000_000_000, compact <= 99_999_999_999_999 else { return nil }
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
        else { return nil }
        return CaptureWallComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }
}
