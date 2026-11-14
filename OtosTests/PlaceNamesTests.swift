import Foundation
import GRDB
import MapKit
@testable import OtosKit
import Synchronization
import Testing

/// Place names and the Places filter (ADR 0051): cells of the map computed in Swift and SQL
/// alike, each named once per language from its center, a throttled Maps waited out, and the
/// filter narrowing by country and town.
@Suite(.testDirectory)
struct PlaceNamesTests {
    static let helsinki = PlaceCoordinate(latitude: 60.17, longitude: 24.94)
    static let espoo = PlaceCoordinate(latitude: 60.21, longitude: 24.66)
    static let sydney = PlaceCoordinate(latitude: -33.87, longitude: 151.21)

    /// A cell is the floor of the coordinate over 0.02°, south and west of zero too, and its
    /// center lies inside it.
    @Test func aCellHoldsItsCoordinateAndNamesFromItsCenter() {
        let cell = PlaceCell(Self.sydney)
        #expect(cell == PlaceCell(latitude: -1694, longitude: 7560))
        #expect(PlaceCell(cell.center) == cell)
        #expect(PlaceCell(PlaceCoordinate(latitude: -0.001, longitude: 0.001)) == PlaceCell(latitude: -1, longitude: 0))
        // The north pole and the 180th meridian fall in the cell below them, whose center is
        // a valid coordinate; the south pole and −180° are a cell's own edge.
        let top = PlaceCell(PlaceCoordinate(latitude: 90, longitude: 180))
        #expect(top == PlaceCell(latitude: 4499, longitude: 8999))
        #expect(top.center.latitude < 90 && top.center.longitude < 180)
        #expect(PlaceCell(PlaceCoordinate(latitude: -90, longitude: -180)) == PlaceCell(latitude: -4500, longitude: -9000))
    }

    /// The language is the Mac's language and script, never its region.
    @Test func theNamingLanguageIgnoresTheRegion() {
        #expect(PlaceNameLanguage(Locale(identifier: "en_US")) == PlaceNameLanguage(Locale(identifier: "en_FI")))
        #expect(PlaceNameLanguage(Locale(identifier: "en_US")).identifier == "en-Latn")
        #expect(PlaceNameLanguage(Locale(identifier: "zh_TW")) != PlaceNameLanguage(Locale(identifier: "zh-Hans_CN")))
        #expect(PlaceNameLanguage(Locale(identifier: "fi_FI")) != PlaceNameLanguage(Locale(identifier: "en_FI")))
    }

    /// The reader names every cell holding a located item once, from its center, in the Mac's
    /// language; a photo's own coordinate never reaches Maps. A failed naming — a throttle,
    /// or an error Maps does not explain — stores nothing: it is waited out, the next cell is
    /// asked, and another pass asks the failed cell again. A cell Maps names nothing for is
    /// stored with no names.
    @Test func everyCellIsNamedOnceAndAFailureIsAskedAgain() async throws {
        let library = try await Self.library(in: makeTestDirectory())
        let asked = Asked()
        let namer = PlaceNameReader.Namer { coordinate, locale in
            #expect(locale.identifier == "fi_FI")
            let cell = PlaceCell(coordinate)
            let times = await asked.add(coordinate, counting: cell)
            if cell == PlaceCell(Self.helsinki), times == 1 {
                throw MKError(.loadingThrottled)
            }
            if cell == PlaceCell(Self.espoo), times == 1 {
                throw MKError(.unknown)
            }
            if cell == PlaceCell(Self.sydney) {
                return .none
            }
            return PlaceNames(country: "Suomi", town: cell == PlaceCell(Self.espoo) ? "Espoo" : "Helsinki")
        }
        let waits = Asked()
        let reader = PlaceNameReader(
            store: library.store, namer: namer, locale: { Locale(identifier: "fi_FI") },
            sleep: { _ in await waits.add(PlaceCoordinate(latitude: 0, longitude: 0)) }
        )
        let finnish = PlaceNameLanguage(Locale(identifier: "fi_FI"))

        await reader.drain()

        let centers = await asked.coordinates
        #expect(centers.allSatisfy { PlaceCell($0).center == $0 })
        #expect(await asked.count(of: PlaceCell(Self.helsinki)) == 2)
        #expect(await asked.count(of: PlaceCell(Self.espoo)) == 2)
        #expect(await asked.count(of: PlaceCell(Self.sydney)) == 1)
        #expect(await waits.coordinates.count == 2)
        #expect(try await library.store.unnamedPlaceCells(language: finnish, limit: 10).isEmpty)
        let options = try await library.store.filterOptions(availableLibraryPaths: [library.rootPath])
        #expect(options.countries == [PlaceFilterCountry(name: "Suomi", towns: ["Helsinki", "Espoo"])])
        await library.store.shutdown()
    }

    /// An error is not a fact (ADR 0032 rule 4): a naming that fails stores no names, so the
    /// cell stays unnamed, to be asked again, rather than stored as a place with none.
    @Test func aFailedNamingStoresNothing() async throws {
        let library = try await Self.library(in: makeTestDirectory())
        let reader = PlaceNameReader(
            store: library.store,
            namer: PlaceNameReader.Namer { _, _ in throw MKError(.decodingFailed) },
            locale: { Locale(identifier: "en_US") },
            sleep: { _ in throw CancellationError() }
        )

        await reader.drain()

        let english = PlaceNameLanguage(Locale(identifier: "en_US"))
        #expect(try await library.store.unnamedPlaceCells(language: english, limit: 10).count == 3)
        await library.store.shutdown()
    }

    /// The catalog keeps one language's names: a drain in a new language forgets the old
    /// one's before naming again, so the filter never offers one place under two names. A
    /// change of region alone keeps them and asks Maps nothing.
    @Test func aNewLanguageNamesEveryCellAgainAndANewRegionDoesNot() async throws {
        let library = try await Self.library(in: makeTestDirectory())
        let asked = Asked()
        let locale = Mutex(Locale(identifier: "en_US"))
        let reader = PlaceNameReader(
            store: library.store,
            namer: PlaceNameReader.Namer { coordinate, locale in
                await asked.add(coordinate)
                let finnish = locale.language.languageCode == .finnish
                return PlaceNames(country: finnish ? "Suomi" : "Finland", town: nil)
            },
            locale: { locale.withLock { $0 } },
            sleep: { _ in }
        )

        await reader.drain()
        #expect(await asked.coordinates.count == 3)
        locale.withLock { $0 = Locale(identifier: "en_FI") }
        await reader.drain()
        #expect(await asked.coordinates.count == 3)

        locale.withLock { $0 = Locale(identifier: "fi_FI") }
        await reader.drain()
        #expect(await asked.coordinates.count == 6)
        let options = try await library.store.filterOptions(availableLibraryPaths: [library.rootPath])
        #expect(options.countries.map(\.name) == ["Suomi"])
        await library.store.shutdown()
    }

    /// v45: names stored before v43 under a full locale (`en_US`) are keyed by the language the
    /// reader computes for it, so an upgraded catalog asks an English Mac's Maps for nothing.
    @Test func namesStoredUnderAFullLocaleSurviveTheUpgrade() async throws {
        let databaseURL = try makeTestDirectory().appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.continuousFrameMigrationIdentifier)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            for (name, coordinate) in [("helsinki.jpg", Self.helsinki), ("sydney.jpg", Self.sydney)] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key)
                    VALUES (1, ?, ?, ?, ?)
                    """,
                    arguments: [name, name, name, name]
                )
                try db.execute(
                    sql: "INSERT INTO asset_metadata (library_root_id, relative_path, primary_latitude, primary_longitude) VALUES (1, ?, ?, ?)",
                    arguments: [name, coordinate.latitude, coordinate.longitude]
                )
                let cell = PlaceCell(coordinate)
                try db.execute(
                    sql: "INSERT INTO place_cell (cell_latitude, cell_longitude, country, town, locale) VALUES (?, ?, 'Somewhere', NULL, 'en_US')",
                    arguments: [cell.latitude, cell.longitude]
                )
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        #expect(try await store.unnamedPlaceCells(language: PlaceNameLanguage(Locale(identifier: "en_GB")), limit: 10).isEmpty)
        #expect(try await store.unnamedPlaceCells(language: PlaceNameLanguage(Locale(identifier: "fi_FI")), limit: 10).count == 2)
        await store.shutdown()
    }

    /// Every place the filter holds has a row: a held town under its country even while the
    /// country is offered for other towns, every held town of a country nothing names, and
    /// a held country nothing names (#649: a filter never holds a value the user cannot see).
    @Test func everyHeldPlaceHasARow() {
        let options = CatalogFilterOptions(countries: [
            PlaceFilterCountry(name: "Finland", towns: ["Helsinki", "Espoo"]),
        ])
        let filter = MediaFilter(places: [
            PlaceFilterKey(country: "Finland", town: "Turku"),
            PlaceFilterKey(country: "Finland", town: "Helsinki"),
            PlaceFilterKey(country: "Suomi", town: "Tampere"),
            PlaceFilterKey(country: "Suomi", town: "Oulu"),
            PlaceFilterKey(country: "Australia", town: nil),
        ])
        #expect(options.countries(holding: filter) == [
            PlaceFilterCountry(name: "Finland", towns: ["Helsinki", "Espoo", "Turku"]),
            PlaceFilterCountry(name: "Australia", towns: []),
            PlaceFilterCountry(name: "Suomi", towns: ["Oulu", "Tampere"]),
        ])
        #expect(options.countries(holding: .all) == options.countries)
    }

    /// The filter offers the countries and towns named, most items first, and narrows by them:
    /// a country takes all its towns, a town only its own photos.
    @Test func theFilterNarrowsByCountryAndTown() async throws {
        let library = try await Self.library(in: makeTestDirectory())
        try await library.store.applyPlaceNames([
            PlaceCell(Self.helsinki): PlaceNames(country: "Finland", town: "Helsinki"),
            PlaceCell(Self.espoo): PlaceNames(country: "Finland", town: "Espoo"),
            PlaceCell(Self.sydney): PlaceNames(country: "Australia", town: "Sydney NSW"),
        ], language: PlaceNameLanguage(Locale(identifier: "en_US")))
        let options = try await library.store.filterOptions(availableLibraryPaths: [library.rootPath])
        #expect(options.countries == [
            PlaceFilterCountry(name: "Finland", towns: ["Helsinki", "Espoo"]),
            PlaceFilterCountry(name: "Australia", towns: ["Sydney NSW"]),
        ])
        func photos(_ places: Set<PlaceFilterKey>) async throws -> [String] {
            try await library.store.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .library(library.rootPath), filter: MediaFilter(places: places), sort: .filenameAscending),
                availableLibraryPaths: [library.rootPath]
            ).ids.map(\.relativePath.rawValue)
        }
        #expect(try await photos([PlaceFilterKey(country: "Finland", town: nil)]) == ["espoo.jpg", "harbour.jpg", "helsinki.jpg"])
        #expect(try await photos([PlaceFilterKey(country: "Finland", town: "Espoo")]) == ["espoo.jpg"])
        #expect(try await photos([
            PlaceFilterKey(country: "Finland", town: "Espoo"), PlaceFilterKey(country: "Australia", town: nil),
        ]) == ["espoo.jpg", "sydney.jpg"])
        await library.store.shutdown()
    }

    /// Checking a country takes all of it; unchecking one town of it keeps the rest.
    @Test func aCountryIsAllItsTownsUntilOneIsUnchecked() {
        let finland = PlaceFilterKey(country: "Finland", town: nil)
        let towns = ["Espoo", "Helsinki", "Turku"]
        var filter = MediaFilter.all.settingPlace(PlaceFilterKey(country: "Finland", town: "Espoo"), included: true, towns: towns)
        filter = filter.settingPlace(finland, included: true, towns: towns)
        #expect(filter.places == [finland])
        filter = filter.settingPlace(PlaceFilterKey(country: "Finland", town: "Turku"), included: false, towns: towns)
        #expect(filter.places == [PlaceFilterKey(country: "Finland", town: "Espoo"), PlaceFilterKey(country: "Finland", town: "Helsinki")])
        filter = filter.settingPlace(finland, included: false, towns: towns)
        #expect(filter.places.isEmpty && !filter.isActive)
    }

    // MARK: - Fixtures

    /// helsinki.jpg and harbour.jpg in one Helsinki cell, espoo.jpg and sydney.jpg, each
    /// located; nowhere.jpg not.
    static func library(in directory: URL) async throws -> FaceEnrichmentTests.ScannedLibrary {
        let files: [(String, PlaceCoordinate?)] = [
            ("helsinki.jpg", helsinki), ("harbour.jpg", helsinki), ("espoo.jpg", espoo), ("sydney.jpg", sydney), ("nowhere.jpg", nil),
        ]
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: files.map(\.0))
        for (name, coordinate) in files {
            let asset = try #require(try await library.store.mediaAssets(for: [library.id(name)])[library.id(name)])
            var metadata = AssetMetadata()
            if let coordinate {
                metadata.locations = [
                    GeoRecord(source: "exifGPS", latitude: coordinate.latitude, longitude: coordinate.longitude, altitudeMeters: nil),
                ]
            }
            _ = await library.store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: library.id(name), metadata: metadata, thumbnailPath: nil, sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), contentHash: .empty
                ),
            ])
        }
        return library
    }

    /// What a test's namer or sleeper was asked, in order.
    actor Asked {
        private(set) var coordinates: [PlaceCoordinate] = []

        @discardableResult
        func add(_ coordinate: PlaceCoordinate) -> Int {
            coordinates.append(coordinate)
            return coordinates.count
        }

        /// Adds `coordinate` and returns how many times `cell` has been asked, this one included.
        func add(_ coordinate: PlaceCoordinate, counting cell: PlaceCell) -> Int {
            coordinates.append(coordinate)
            return count(of: cell)
        }

        func count(of cell: PlaceCell) -> Int {
            coordinates.count { PlaceCell($0) == cell }
        }
    }
}
