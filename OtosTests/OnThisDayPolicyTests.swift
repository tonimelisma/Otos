import CoreGraphics
import Foundation
import GRDB
@testable import OtosKit
import Testing

/// The pure halves of On This Day (ADR 0049): the anniversary match the gateway selects
/// with, the anniversaries the scope's items group into, the story's moves and timing, and the
/// words the surfaces use.
struct OnThisDayPolicyTests {
    private static let root = LibraryRootPath(rawValue: "/Users/example/Pictures")

    private static func zone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? .gmt
    }

    private static func calendar(_ zone: String) -> Calendar {
        CalendarDay.calendar(in: Self.zone(zone))
    }

    private static func instant(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Double {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))?.timeIntervalSince1970 ?? 0
    }

    private static func id(_ name: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: name))
    }

    // MARK: - Anniversary match

    /// A local capture time as `best_capture_local` stores it: the reading counted on a UTC
    /// calendar.
    private static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ second: Int = 0) -> Double {
        instant(calendar("UTC"), year, month, day, hour) + Double(second)
    }

    /// Which of `times` the match selects, evaluated by SQLite itself as the gateway's read
    /// does.
    private static func selected(by match: AnniversaryMatch?, from times: [Double]) throws -> [Double] {
        let match = try #require(match)
        let queue = try DatabaseQueue()
        return try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (best_capture_local DOUBLE)")
            for time in times {
                try db.execute(sql: "INSERT INTO t VALUES (?)", arguments: [time])
            }
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            return try Double.fetchAll(
                db,
                sql: "SELECT best_capture_local FROM t WHERE \(match.sql(column: "best_capture_local")) ORDER BY 1",
                arguments: [match.end, match.date]
            )
        }
    }

    /// The day's month and day before the day's own year — the first and last second of
    /// it, a century back alike — never the days around it, this year, or an undated row.
    @Test func yearsMatchTheDayInEveryEarlierYearAndNothingElse() throws {
        let match = AnniversaryMatch.years(for: CalendarDay(year: 2026, month: 11, day: 9))
        let times = [
            Self.local(2025, 11, 9), Self.local(2023, 11, 9, 23, 3599), Self.local(1904, 11, 9, 12),
            Self.local(2025, 11, 8, 23, 3599), Self.local(2025, 11, 10),
            Self.local(2026, 11, 9, 8), Self.local(2025, 10, 9),
        ]

        #expect(try Self.selected(by: match, from: times) == [
            Self.local(1904, 11, 9, 12), Self.local(2023, 11, 9, 23, 3599), Self.local(2025, 11, 9),
        ])
    }

    /// The day of the month in every earlier month, never in the day's own month; a month
    /// without the day (31 April) has nothing to match.
    @Test func monthsMatchTheDayOfTheMonthInEveryEarlierMonth() throws {
        let match = AnniversaryMatch.months(for: CalendarDay(year: 2026, month: 6, day: 31))
        let times = [
            Self.local(2026, 5, 31), Self.local(2026, 4, 30), Self.local(2026, 5, 1), Self.local(2025, 12, 31, 18),
            Self.local(1950, 1, 31), Self.local(2026, 6, 1), Self.local(2026, 5, 30),
        ]

        #expect(try Self.selected(by: match, from: times) == [
            Self.local(1950, 1, 31), Self.local(2025, 12, 31, 18), Self.local(2026, 5, 31),
        ])
    }

    /// Clocks went forward on 30 March 2025 and back on 26 October 2025 in Helsinki, but a
    /// photo's day is a day of its own clock's readings: midnight to midnight, whatever the
    /// zone did that day.
    @Test func aDaylightSavingDayIsADayOfLocalTime() throws {
        let spring = AnniversaryMatch.years(for: CalendarDay(year: 2026, month: 3, day: 30))
        let autumn = AnniversaryMatch.years(for: CalendarDay(year: 2026, month: 10, day: 26))
        let around: (Int, Int) -> [Double] = { month, day in
            [Self.local(2025, month, day - 1, 23, 3599), Self.local(2025, month, day), Self.local(2025, month, day, 23, 3599),
             Self.local(2025, month, day + 1)]
        }

        #expect(try Self.selected(by: spring, from: around(3, 30)) == [Self.local(2025, 3, 30), Self.local(2025, 3, 30, 23, 3599)])
        #expect(try Self.selected(by: autumn, from: around(10, 26)) == [Self.local(2025, 10, 26), Self.local(2025, 10, 26, 23, 3599)])
    }

    @Test func aLeapDayMatchesOnlyLeapYears() throws {
        let match = AnniversaryMatch.years(for: CalendarDay(year: 2028, month: 2, day: 29))
        let times = [Self.local(2024, 2, 29), Self.local(2023, 3, 1), Self.local(2020, 2, 29), Self.local(2023, 2, 28)]

        #expect(try Self.selected(by: match, from: times) == [Self.local(2020, 2, 29), Self.local(2024, 2, 29)])
        #expect(CalendarDay(year: 2023, month: 2, day: 29).start(in: Self.zone("UTC")) == nil)
    }

    // MARK: - Anniversaries

    @Test func yearsAreContiguousRunsNewestFirstWithTheirKeyItem() throws {
        let utc = Self.calendar("UTC")
        let day = CalendarDay(year: 2026, month: 11, day: 9)
        let ids = ["a", "b", "c", "d"].map(Self.id)
        let buckets: [Date?] = [
            utc.date(from: DateComponents(year: 2025, month: 11, day: 9)),
            utc.date(from: DateComponents(year: 2023, month: 11, day: 9)),
            utc.date(from: DateComponents(year: 2023, month: 11, day: 9)),
            utc.date(from: DateComponents(year: 2019, month: 11, day: 9)),
        ]

        let years = try #require(OnThisDayAnniversaryPolicy.anniversaries(
            day: day,
            orderedIDs: ids,
            dayBuckets: buckets,
            timeZone: Self.zone("UTC")
        ))

        #expect(years.map(\.day.year) == [2025, 2023, 2019])
        #expect(years.map(\.keyItem) == [ids[0], ids[1], ids[3]])
        #expect(years.map(\.count) == [1, 2, 1])
        #expect(years[1].indexes == 1 ..< 3)
        #expect(years[1].day == CalendarDay(year: 2023, month: 11, day: 9))
        #expect(OnThisDayAnniversaryPolicy.interval(years[0], today: day) == .years(1))
        #expect(OnThisDayAnniversaryPolicy.interval(years[2], today: day) == .years(7))
        #expect(CatalogOnThisDayState(day: day, anniversaries: years).isYears)
        // Buckets that do not pair with the IDs say nothing.
        #expect(OnThisDayAnniversaryPolicy.anniversaries(
            day: day,
            orderedIDs: ids,
            dayBuckets: [],
            timeZone: Self.zone("UTC")
        ) == nil)
    }

    /// A scope that matched earlier months groups into one run per month, newest first, and
    /// each run's distance is in months — past a year too, never a rounded year.
    @Test func monthsAreRunsNewestFirstAndCountedInMonths() throws {
        let utc = Self.calendar("UTC")
        let day = CalendarDay(year: 2026, month: 11, day: 12)
        let ids = ["a", "b", "c", "d"].map(Self.id)
        let buckets: [Date?] = [
            utc.date(from: DateComponents(year: 2026, month: 10, day: 12)),
            utc.date(from: DateComponents(year: 2026, month: 10, day: 12)),
            utc.date(from: DateComponents(year: 2026, month: 8, day: 12)),
            utc.date(from: DateComponents(year: 2025, month: 9, day: 12)),
        ]

        let months = try #require(OnThisDayAnniversaryPolicy.anniversaries(
            day: day,
            orderedIDs: ids,
            dayBuckets: buckets,
            timeZone: Self.zone("UTC")
        ))

        #expect(months.map(\.day) == [
            CalendarDay(year: 2026, month: 10, day: 12),
            CalendarDay(year: 2026, month: 8, day: 12),
            CalendarDay(year: 2025, month: 9, day: 12),
        ])
        #expect(months.map(\.count) == [2, 1, 1])
        #expect(months.map { OnThisDayAnniversaryPolicy.interval($0, today: day) } == [.months(1), .months(3), .months(14)])
        #expect(!CatalogOnThisDayState(day: day, anniversaries: months).isYears)
    }

    // MARK: - Story moves

    private static func storyFixture() -> (ids: [MediaAssetID], anniversaries: [OnThisDayAnniversary]) {
        let ids = ["y1a", "y1b", "y3a", "y3b", "y3c"].map(id)
        let day = CalendarDay(year: 2025, month: 11, day: 9)
        let years = [
            OnThisDayAnniversary(day: day, keyItem: ids[0], firstIndex: 0, count: 2),
            OnThisDayAnniversary(day: day.inYear(2023), keyItem: ids[2], firstIndex: 2, count: 3),
        ]
        return (ids, years)
    }

    @Test func aStoryStartsAtTheChosenAnniversaryOrTheNewestAndMovesAcrossThem() throws {
        let (ids, years) = Self.storyFixture()
        let day = CalendarDay(year: 2025, month: 11, day: 9)

        #expect(StoryPlaybackPolicy.start(anniversary: nil, anniversaries: years, orderedIDs: ids) == ids[0])
        #expect(StoryPlaybackPolicy.start(anniversary: day.inYear(2023), anniversaries: years, orderedIDs: ids) == ids[2])
        #expect(StoryPlaybackPolicy.start(anniversary: day.inYear(1999), anniversaries: years, orderedIDs: ids) == ids[0])
        #expect(StoryPlaybackPolicy.start(anniversary: nil, anniversaries: [], orderedIDs: []) == nil)
        // Across the year boundary, both ways; nothing past either end.
        #expect(StoryPlaybackPolicy.next(after: ids[1], in: ids) == ids[2])
        #expect(StoryPlaybackPolicy.previous(before: ids[2], in: ids) == ids[1])
        #expect(StoryPlaybackPolicy.next(after: ids[4], in: ids) == nil)
        #expect(StoryPlaybackPolicy.previous(before: ids[0], in: ids) == nil)
        let place = try #require(StoryPlaybackPolicy.place(of: ids[3], anniversaries: years, orderedIDs: ids))
        #expect(place.anniversary.day.year == 2023)
        #expect(place.position == 2)
    }

    @Test func aRemovedItemLeavesTheStoryOnItsSurvivor() {
        let (ids, _) = Self.storyFixture()

        #expect(StoryPlaybackPolicy.survivor(of: ids[2], previousOrderedIDs: ids, survivingOrderedIDs: ids) == ids[2])
        let withoutCurrent = ids.filter { $0 != ids[2] }
        #expect(StoryPlaybackPolicy.survivor(of: ids[2], previousOrderedIDs: ids, survivingOrderedIDs: withoutCurrent) == ids[3])
        let withoutLast = Array(ids.dropLast())
        #expect(StoryPlaybackPolicy.survivor(of: ids[4], previousOrderedIDs: ids, survivingOrderedIDs: withoutLast) == ids[3])
        #expect(StoryPlaybackPolicy.survivor(of: ids[0], previousOrderedIDs: ids, survivingOrderedIDs: []) == nil)
    }

    @Test func aHoldStartsOnlyOnceThePictureIsSettledAndTheItemIsNoPlayableVideo() {
        #expect(StoryPlaybackPolicy.holdCanStart(kind: .image, pane: .shown, video: .notVideo))
        #expect(StoryPlaybackPolicy.holdCanStart(kind: .raw, pane: .none, video: .notVideo))
        // Waiting on bytes, or on the kind, never starts the hold.
        #expect(!StoryPlaybackPolicy.holdCanStart(kind: .image, pane: .awaited, video: .notVideo))
        #expect(!StoryPlaybackPolicy.holdCanStart(kind: nil, pane: .shown, video: .notVideo))
        // A video plays to its own end; only one without a player holds.
        #expect(!StoryPlaybackPolicy.holdCanStart(kind: .video, pane: .shown, video: .playing))
        #expect(!StoryPlaybackPolicy.holdCanStart(kind: .video, pane: .shown, video: .preparing))
        #expect(StoryPlaybackPolicy.holdCanStart(kind: .video, pane: .shown, video: .unavailable))
    }

    @Test func aPausedHoldKeepsItsRemainderAndResumesFromIt() {
        let start = ContinuousClock.now
        let hold = StoryHold(startingAt: start)

        let paused = hold.pausing(at: start + .seconds(2))
        #expect(paused.remaining == .seconds(3))
        #expect(paused.countingSince == nil)
        // Time passing while paused changes nothing.
        #expect(paused.fraction(at: start + .seconds(60)) == 0.4)

        let resumed = paused.resuming(at: start + .seconds(60))
        #expect(resumed.remaining == .seconds(3))
        #expect(resumed.fraction(at: start + .seconds(61)) == 0.6)
        #expect(resumed.fraction(at: start + .seconds(90)) == 1)
        #expect(StoryHold(startingAt: nil).fraction(at: start) == 0)
    }

    // MARK: - The calendar

    /// On This Day counts Gregorian days and years in the user's zone whatever calendar the
    /// user reads dates in: under the Japanese calendar the year is an era year (Reiwa 5 is
    /// 2023) and under the Buddhist one 2566, so neither could compare with a capture year.
    @Test func daysAndYearsAreGregorianWhateverTheUsersCalendar() throws {
        #expect(CalendarDay.calendar().identifier == .gregorian)
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = .current
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = .current
        let instant = try #require(CalendarDay(year: 2023, month: 11, day: 9).start())
        // The user's calendars name the year differently…
        #expect(japanese.component(.year, from: instant) == 5)
        #expect(buddhist.component(.year, from: instant) == 2566)
        // …while the scope's day, its match and its years stay Gregorian.
        #expect(CalendarDay(instant) == CalendarDay(year: 2023, month: 11, day: 9))
        let match = try #require(AnniversaryMatch.years(for: CalendarDay(year: 2026, month: 11, day: 9)))
        #expect(match.date == "11-09")
        #expect(match.end == Self.local(2026, 1, 1))
    }

    // MARK: - Covers

    /// A card draws the cover it painted for its key item, else the store's decode for it —
    /// so a card made again shows the cover at once — and a cover painted for another key
    /// item never.
    @Test func aCardDrawsItsKeyItemsCoverAndNeverAnotherItems() throws {
        let key = Self.id("key")
        let painted = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let stored = try #require(CGContext(
            data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())

        #expect(OnThisDayCover.displayed(painted: (key, painted), keyItem: key, stored: stored) === painted)
        #expect(OnThisDayCover.displayed(painted: nil, keyItem: key, stored: stored) === stored)
        #expect(OnThisDayCover.displayed(painted: (Self.id("other"), painted), keyItem: key, stored: stored) === stored)
        #expect(OnThisDayCover.displayed(painted: (Self.id("other"), painted), keyItem: key, stored: nil) == nil)
    }

    // MARK: - Words

    @Test func theSurfacesWordTheirFactsInTheUsersLocale() {
        let british = Locale(identifier: "en_GB")
        let gregorian = Calendar(identifier: .gregorian)
        let year = OnThisDayAnniversary(
            day: CalendarDay(year: 2023, month: 11, day: 9),
            keyItem: Self.id("a"),
            firstIndex: 0,
            count: 14
        )
        let today = CalendarDay(year: 2026, month: 11, day: 9)

        #expect(OnThisDayPresentation.ago(.years(1)) == "1 year ago")
        #expect(OnThisDayPresentation.ago(.years(3)) == "3 years ago")
        #expect(OnThisDayPresentation.ago(.months(1)) == "1 month ago")
        #expect(OnThisDayPresentation.ago(.months(14)) == "14 months ago")
        #expect(OnThisDayPresentation.dayTitle(today, locale: british, calendar: gregorian) == "9 November")
        #expect(OnThisDayPresentation.cardCaption(year, locale: british, calendar: gregorian) == "9 Nov 2023 · 14")
        #expect(OnThisDayPresentation.cardAccessibilityLabel(year, today: today, locale: british, calendar: gregorian)
            == "3 years ago, 14 items, 9 November 2023")
        #expect(OnThisDayPresentation.fullDate(year.day, locale: british, calendar: gregorian) == "9 November 2023")
        #expect(OnThisDayPresentation.barSummary(itemCount: 14, runCount: 4, isYears: true)
            == "14 photos and videos from 4 years")
        #expect(OnThisDayPresentation.barSummary(itemCount: 1, runCount: 1, isYears: true) == "1 photo or video from 1 year")
        #expect(OnThisDayPresentation.barSummary(itemCount: 612, runCount: 4, isYears: false)
            == "612 photos and videos from 4 months")
        #expect(OnThisDayPresentation.barSummary(itemCount: 1, runCount: 1, isYears: false) == "1 photo or video from 1 month")
        // The bar claims emptiness only once the scope is known to be empty.
        #expect(OnThisDayPresentation.barSummary(nil, emptyState: .checkingLibraries) == "")
        #expect(OnThisDayPresentation.barSummary(nil, emptyState: .nothingOnThisDay(today))
            == "No photos or videos from earlier years or months")
        #expect(OnThisDayPresentation.barSummary(
            CatalogOnThisDayState(day: today, anniversaries: [year]),
            emptyState: .noMedia
        ) == "14 photos and videos from 1 year")
        #expect(OnThisDayPresentation.position(4, of: 12) == "4/12")
        #expect(OnThisDayPresentation.emptyMessage(today, locale: british, calendar: gregorian)
            == "Photos and videos taken on 9 November in earlier years, or on this day in earlier months, appear here.")
        let lastMonth = OnThisDayAnniversary(
            day: CalendarDay(year: 2026, month: 10, day: 9),
            keyItem: Self.id("b"),
            firstIndex: 0,
            count: 1
        )
        #expect(OnThisDayPresentation.cardAccessibilityLabel(lastMonth, today: today, locale: british, calendar: gregorian)
            == "1 month ago, 1 item, 9 October 2026")
    }

    // MARK: - Search

    /// A search on On This Day only narrows: its order stays the scope's, so each year is
    /// still one contiguous run; elsewhere relevance orders as chosen (ADR 0048, 0049).
    @Test func aSearchOnOnThisDayNarrowsWithoutReorderingItsYears() throws {
        let search = try #require(CatalogSearch(text: "beach"))
        #expect(search.order == .relevance)
        let onThisDay = CatalogQueryDescriptor(
            scope: .onThisDay(CalendarDay(year: 2026, month: 11, day: 9)),
            search: search
        )
        #expect(onThisDay.effectiveSearch?.order == .sort)
        #expect(onThisDay.effectiveSearch?.text == "beach")
        #expect(onThisDay.search?.order == .relevance)
        let allMedia = CatalogQueryDescriptor(scope: .allMedia, search: search)
        #expect(allMedia.effectiveSearch?.order == .relevance)
        #expect(!allMedia.groupsByDay)

        let ids = ["a", "b", "c"].map(Self.id)
        let scores: [MediaAssetID: Float] = [ids[0]: 0.1, ids[1]: 0.9, ids[2]: 0.5]
        let buckets: [Date?] = [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 86400)]
        let narrowed = try CatalogWindowPolicy.searched(
            ids: ids, dayBuckets: buckets, coordinates: [], scores: scores,
            order: #require(onThisDay.effectiveSearch).order
        )
        #expect(narrowed.ids == ids)
        #expect(narrowed.dayBuckets == buckets)
    }
}
