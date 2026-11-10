import Foundation
import NaturalLanguage
@testable import OtosKit
import Testing

/// The facts a query names besides the picture (ADR 0048): when, where, who.
@Suite(.testDirectory)
struct SearchQueryFactsTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!

    private func parse(_ text: String) -> SearchQueryParse {
        SearchQueryParser.parse(text, now: Self.now, calendar: Self.calendar)
    }

    private func month(_ span: SearchDateSpan?) -> DateComponents? {
        span.map { Self.calendar.dateComponents([.year, .month], from: $0.start) }
    }

    @Test func aMonthNarrowsToItsMostRecentOccurrence() {
        let september = parse("beach in September")
        #expect(september.pictureText == "beach")
        #expect(month(september.date) == DateComponents(year: 2026, month: 9))
        // December has not begun this year, so it is last year's.
        #expect(month(parse("christmas tree in December").date) == DateComponents(year: 2025, month: 12))
        #expect(month(parse("swing July 2024").date) == DateComponents(year: 2024, month: 7))
        let possessive = parse("October's swing")
        #expect(month(possessive.date) == DateComponents(year: 2026, month: 10))
        #expect(possessive.pictureText == "swing")
    }

    @Test func yearsAndRelativeSpans() throws {
        let year = parse("pool 2025")
        #expect(year.pictureText == "pool")
        #expect(try Self.calendar.component(.year, from: #require(year.date?.start)) == 2025)
        #expect(try Self.calendar.component(.month, from: #require(year.date?.end)) == 1)
        let lastMonth = parse("pumpkins last month")
        #expect(month(lastMonth.date) == DateComponents(year: 2026, month: 10))
        #expect(lastMonth.pictureText == "pumpkins")
        #expect(parse("September").pictureText.isEmpty)
    }

    /// A query no translation reads is searched for the month in the user's own languages.
    @Test func anUntranslatedMonthIsReadInTheUsersLanguage() {
        let found = SearchQueryParser.takeNativeMonth("rand septembris", languages: ["et"], now: Self.now, calendar: Self.calendar)
        #expect(month(found?.span) == DateComponents(year: 2026, month: 9))
        #expect(found?.rest == "rand")
        #expect(SearchQueryParser.takeNativeMonth("rand septembris", languages: ["ja"], now: Self.now, calendar: Self.calendar) == nil)
    }

    /// "May" is a word as well as a month: it is the month only beside "in", "of" or a year.
    @Test func mayIsAMonthOnlyWhenItReadsAsOne() {
        #expect(parse("kids who may play").date == nil)
        #expect(month(parse("beach in May").date) == DateComponents(year: 2026, month: 5))
    }

    @Test func aNameIsTakenAsACandidatePlace() {
        let dog = parse("Dog in San Francisco")
        #expect(dog.placeName == "San Francisco")
        #expect(dog.pictureText == "Dog")
        let lake = parse("lake at Lake Tahoe")
        #expect(lake.placeName == "Lake Tahoe")
        #expect(lake.pictureText == "lake")
        #expect(SearchQueryParser.parse("Dog in San Francisco", places: .notRead).pictureText == "Dog in San Francisco")
    }

    @Test func aNameInALanguageTheTaggerDoesNotKnowIsItsCapitalisedRun() {
        let dog = SearchQueryParser.parse("koer San Franciscos", places: .capitalised)
        #expect(dog.placeName == "San Franciscos")
        #expect(dog.pictureText == "koer")
        let trampoline = SearchQueryParser.parse("batuut Walnut Creekis", places: .capitalised)
        #expect(trampoline.placeName == "Walnut Creekis")
        #expect(trampoline.pictureText == "batuut")
        #expect(SearchQueryParser.parse("rand septembris", places: .capitalised).placeName == nil)
        #expect(SearchQueryParser.parse("Dog in San Francisco", places: .capitalised).placeName == "San Francisco")
    }

    @Test func mapsNamesAPlaceWithItsCaseEnding() {
        #expect(SearchPlaces.names("San Francisco", as: "San Franciscos"))
        #expect(SearchPlaces.names("Walnut Creek", as: "Walnut Creekis"))
        #expect(SearchPlaces.names("Zürich", as: "zurich"))
        #expect(!SearchPlaces.names("San Francisco", as: "San Franciscosta ranta"))
        #expect(!SearchPlaces.names("Lake Tahoe", as: "Tahoe"))
        #expect(!SearchPlaces.names("City View Drive", as: "City view"))
        #expect(!SearchPlaces.names("Paris", as: "Parisienne"))
    }

    @Test func aRecognitionOutsideTheUsersLanguagesIsDistrustedWhenOneOfThemCannotBeRead() {
        let estonian = ["et", "en"]
        #expect(SearchQueryEncoder.trusted(.finnish, preferring: estonian, untranslatable: ["et"]) == nil)
        #expect(SearchQueryEncoder.trusted(.english, preferring: estonian, untranslatable: ["et"]) == .english)
        #expect(SearchQueryEncoder.trusted(.finnish, preferring: ["fi", "en"], untranslatable: []) == .finnish)
        #expect(SearchQueryEncoder.trusted(.german, preferring: ["fi", "en"], untranslatable: []) == .german)
    }

    @Test func namedPeopleAreTakenBeforeTranslation() {
        let abby = SearchPerson(id: PersonID(rawValue: 1), name: "Abby")
        let abbyRose = SearchPerson(id: PersonID(rawValue: 2), name: "Abby Rose")
        let found = SearchQueryEncoder.takePeople([abby, abbyRose], from: "Abby Rose rannalla")
        #expect(found.people == [abbyRose.id])
        #expect(found.rest == "rannalla")
        #expect(SearchQueryEncoder.takePeople([abby], from: "abbyn kanssa").people.isEmpty)
        #expect(SearchQueryEncoder.takePeople([abby], from: "Äino").people == [abby.id])
    }

    @Test func aPlaceHoldsWhatIsWithinItsRadius() {
        let place = SearchPlace(name: "Walnut Creek", latitude: 37.9015, longitude: -122.0618, radiusMeters: 15000)
        #expect(place.contains(latitude: 37.95, longitude: -122.05))
        #expect(!place.contains(latitude: 37.78, longitude: -122.42))
    }

    /// Facts narrow without a picture: the scope's order and day sections stay.
    @Test func factsAloneKeepTheScopesOrder() {
        let ids = (0 ..< 3).map { MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/L"), relativePath: MediaRelativePath(rawValue: "\($0).jpg")) }
        let days: [Date?] = [Self.now, Self.now, nil]
        let kept = CatalogWindowPolicy.searched(
            ids: ids, dayBuckets: days, coordinates: [], scores: nil, allowed: [ids[0], ids[2]], order: .relevance
        )
        #expect(kept.ids == [ids[0], ids[2]])
        #expect(kept.dayBuckets == [Self.now, nil])
    }

    /// The Store answers a date span from capture times.
    @Test func theStoreAllowsWhatWasCapturedInTheSpan() async throws {
        let temp = try makeTestDirectory()
        let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let file = library.appending(path: "a.jpg")
        try writeCatalogStoreFile(file, contents: "jpeg")
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: library)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let asset = try #require(scanned.testAssets.first)
        let captured = try #require(asset.bestCaptureDate ?? asset.createdAt)
        let around = SearchDateSpan(start: captured.addingTimeInterval(-60), end: captured.addingTimeInterval(60))
        let before = SearchDateSpan(start: captured.addingTimeInterval(-7200), end: captured.addingTimeInterval(-3600))
        #expect(try await store.searchFactMatches(SearchFacts(date: around)) == [asset.id])
        #expect(try await store.searchFactMatches(SearchFacts(date: before)).isEmpty)
        #expect(try await store.namedPeople().isEmpty)
        await store.shutdown()
    }
}
