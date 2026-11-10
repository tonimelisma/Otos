import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// The pure halves of On This Day (ADR 0049): the anniversary ranges the gateway selects
/// with, the years the scope's items group into, the story's moves and timing, and the
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

    // MARK: - Anniversary ranges

    /// A local capture time as `best_capture_local` stores it: the reading counted on a UTC
    /// calendar.
    private static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Double {
        instant(calendar("UTC"), year, month, day, hour)
    }

    @Test func rangesCoverEachEarlierYearFromTheFloorAndNotTheDaysOwnYear() {
        let day = CalendarDay(year: 2026, month: 11, day: 9)

        let ranges = AnniversaryRanges.ranges(for: day, earliest: CaptureLocalTime(seconds: Self.local(2023, 2, 1, 12)))

        #expect(ranges.count == 3)
        #expect(ranges.first?.lowerBound == Self.local(2023, 11, 9))
        #expect(ranges.first?.upperBound == Self.local(2023, 11, 10))
        #expect(ranges.last?.lowerBound == Self.local(2025, 11, 9))
        // Nothing dated before the day's own year, or nothing dated at all: no range.
        #expect(AnniversaryRanges.ranges(for: day, earliest: CaptureLocalTime(seconds: Self.local(2026, 1, 1, 12))).isEmpty)
        #expect(AnniversaryRanges.ranges(for: day, earliest: nil).isEmpty)
    }

    /// Clocks went forward on 30 March 2025 and back on 26 October 2025 in Helsinki, but a
    /// photo's day is a day of its own clock's readings: midnight to midnight, whatever the
    /// zone did that day.
    @Test func aDaylightSavingDayIsADayOfLocalTime() {
        let floor = CaptureLocalTime(seconds: Self.local(2025, 1, 1, 12))
        let spring = AnniversaryRanges.ranges(for: CalendarDay(year: 2026, month: 3, day: 30), earliest: floor)
        let autumn = AnniversaryRanges.ranges(for: CalendarDay(year: 2026, month: 10, day: 26), earliest: floor)

        #expect(spring == [Self.local(2025, 3, 30) ..< Self.local(2025, 3, 31)])
        #expect(autumn == [Self.local(2025, 10, 26) ..< Self.local(2025, 10, 27)])
    }

    @Test func aLeapDayMatchesOnlyLeapYears() {
        let ranges = AnniversaryRanges.ranges(
            for: CalendarDay(year: 2028, month: 2, day: 29),
            earliest: CaptureLocalTime(seconds: Self.local(2019, 5, 1))
        )

        #expect(ranges.map(\.lowerBound) == [Self.local(2020, 2, 29), Self.local(2024, 2, 29)])
        #expect(CalendarDay(year: 2023, month: 2, day: 29).start(in: Self.zone("UTC")) == nil)
    }

    // MARK: - Years

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

        let years = try #require(OnThisDayYearPolicy.years(day: day, orderedIDs: ids, dayBuckets: buckets, timeZone: Self.zone("UTC")))

        #expect(years.map(\.year) == [2025, 2023, 2019])
        #expect(years.map(\.keyItem) == [ids[0], ids[1], ids[3]])
        #expect(years.map(\.count) == [1, 2, 1])
        #expect(years[1].indexes == 1 ..< 3)
        #expect(years[1].day == CalendarDay(year: 2023, month: 11, day: 9))
        #expect(OnThisDayYearPolicy.yearsAgo(years[0], today: day) == 1)
        // Buckets that do not pair with the IDs say nothing.
        #expect(OnThisDayYearPolicy.years(day: day, orderedIDs: ids, dayBuckets: [], timeZone: Self.zone("UTC")) == nil)
    }

    // MARK: - Story moves

    private static func storyFixture() -> (ids: [MediaAssetID], years: [OnThisDayYear]) {
        let ids = ["y1a", "y1b", "y3a", "y3b", "y3c"].map(id)
        let day = CalendarDay(year: 2025, month: 11, day: 9)
        let years = [
            OnThisDayYear(day: day, keyItem: ids[0], firstIndex: 0, count: 2),
            OnThisDayYear(day: day.inYear(2023), keyItem: ids[2], firstIndex: 2, count: 3),
        ]
        return (ids, years)
    }

    @Test func aStoryStartsAtTheChosenYearOrTheNewestAndMovesAcrossYears() throws {
        let (ids, years) = Self.storyFixture()

        #expect(StoryPlaybackPolicy.start(year: nil, years: years, orderedIDs: ids) == ids[0])
        #expect(StoryPlaybackPolicy.start(year: 2023, years: years, orderedIDs: ids) == ids[2])
        #expect(StoryPlaybackPolicy.start(year: 1999, years: years, orderedIDs: ids) == ids[0])
        #expect(StoryPlaybackPolicy.start(year: nil, years: [], orderedIDs: []) == nil)
        // Across the year boundary, both ways; nothing past either end.
        #expect(StoryPlaybackPolicy.next(after: ids[1], in: ids) == ids[2])
        #expect(StoryPlaybackPolicy.previous(before: ids[2], in: ids) == ids[1])
        #expect(StoryPlaybackPolicy.next(after: ids[4], in: ids) == nil)
        #expect(StoryPlaybackPolicy.previous(before: ids[0], in: ids) == nil)
        let place = try #require(StoryPlaybackPolicy.place(of: ids[3], years: years, orderedIDs: ids))
        #expect(place.year.year == 2023)
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
        // …while the scope's day, its ranges and its years stay Gregorian.
        #expect(CalendarDay(instant) == CalendarDay(year: 2023, month: 11, day: 9))
        let ranges = AnniversaryRanges.ranges(
            for: CalendarDay(year: 2026, month: 11, day: 9),
            earliest: CaptureLocalTime(startOf: CalendarDay(instant))
        )
        #expect(ranges.count == 3)
    }

    @Test func datesAreWrittenInTheUsersCalendar() {
        let year = OnThisDayYear(
            day: CalendarDay(year: 2023, month: 11, day: 9),
            keyItem: Self.id("a"),
            firstIndex: 0,
            count: 14
        )
        let british = Locale(identifier: "en_GB")
        let buddhist = Calendar(identifier: .buddhist)
        let japanese = Calendar(identifier: .japanese)

        #expect(OnThisDayPresentation.fullDate(year.day, locale: british, calendar: buddhist).contains("2566"))
        let reiwa = OnThisDayPresentation.fullDate(year.day, locale: Locale(identifier: "ja_JP"), calendar: japanese)
        #expect(reiwa.contains("5年11月9日"))
        // The distance in years is Gregorian arithmetic, the same in every calendar.
        #expect(OnThisDayPresentation.cardAccessibilityLabel(
            year,
            today: CalendarDay(year: 2026, month: 11, day: 9),
            locale: british,
            calendar: buddhist
        ).hasPrefix("3 years ago, 14 items, "))
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
        let year = OnThisDayYear(
            day: CalendarDay(year: 2023, month: 11, day: 9),
            keyItem: Self.id("a"),
            firstIndex: 0,
            count: 14
        )
        let today = CalendarDay(year: 2026, month: 11, day: 9)

        #expect(OnThisDayPresentation.yearsAgo(1) == "1 year ago")
        #expect(OnThisDayPresentation.yearsAgo(3) == "3 years ago")
        #expect(OnThisDayPresentation.dayTitle(today, locale: british, calendar: gregorian) == "9 November")
        #expect(OnThisDayPresentation.cardCaption(year, locale: british, calendar: gregorian) == "9 Nov 2023 · 14")
        #expect(OnThisDayPresentation.cardAccessibilityLabel(year, today: today, locale: british, calendar: gregorian)
            == "3 years ago, 14 items, 9 November 2023")
        #expect(OnThisDayPresentation.fullDate(year.day, locale: british, calendar: gregorian) == "9 November 2023")
        #expect(OnThisDayPresentation.barSummary(itemCount: 14, yearCount: 4) == "14 photos and videos from 4 years")
        #expect(OnThisDayPresentation.barSummary(itemCount: 1, yearCount: 1) == "1 photo or video from 1 year")
        // The bar claims emptiness only once the scope is known to be empty.
        #expect(OnThisDayPresentation.barSummary(nil, emptyState: .checkingLibraries) == "")
        #expect(OnThisDayPresentation.barSummary(nil, emptyState: .nothingOnThisDay(today))
            == "No photos or videos from earlier years")
        #expect(OnThisDayPresentation.barSummary(
            CatalogOnThisDayState(day: today, years: [year]),
            emptyState: .noMedia
        ) == "14 photos and videos from 1 year")
        #expect(OnThisDayPresentation.position(4, of: 12) == "4/12")
        #expect(OnThisDayPresentation.emptyMessage(today, locale: british, calendar: gregorian)
            == "Photos and videos taken on 9 November in earlier years appear here.")
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
