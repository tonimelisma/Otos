import Foundation
import MapKit
@testable import OtosKit
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
    }

    /// The reader names every cell holding a located item once, from its center, in the Mac's
    /// language; a photo's own coordinate never reaches Maps. A throttled answer is waited out
    /// and asked again; a cell Maps names nothing for is stored with no names.
    @Test func everyCellIsNamedOnceAndAThrottleIsWaitedOut() async throws {
        let library = try await Self.library(in: makeTestDirectory())
        let asked = Asked()
        let namer = PlaceNameReader.Namer { coordinate, locale in
            #expect(locale.identifier == "fi_FI")
            if await asked.add(coordinate) == 1 {
                throw MKError(.loadingThrottled)
            }
            if PlaceCell(coordinate) == PlaceCell(Self.sydney) {
                return PlaceNames(country: "Australia", town: "Sydney NSW")
            }
            return coordinate.latitude > 0 ? PlaceNames(country: "Suomi", town: "Helsinki") : .none
        }
        let waits = Asked()
        let reader = PlaceNameReader(
            store: library.store, namer: namer, locale: { Locale(identifier: "fi_FI") },
            sleep: { _ in await waits.add(PlaceCoordinate(latitude: 0, longitude: 0)) }
        )

        await reader.drain()

        let centers = await asked.coordinates
        #expect(Set(centers.map(PlaceCell.init)) == [PlaceCell(Self.helsinki), PlaceCell(Self.espoo), PlaceCell(Self.sydney)])
        #expect(centers.allSatisfy { PlaceCell($0).center == $0 })
        #expect(await waits.coordinates.count == 1)
        #expect(try await library.store.unnamedPlaceCells(locale: "fi_FI", limit: 10).isEmpty)
        #expect(try await library.store.unnamedPlaceCells(locale: "en_US", limit: 10).count == 3)
        await library.store.shutdown()
    }

    /// The filter offers the countries and towns named, most items first, and narrows by them:
    /// a country takes all its towns, a town only its own photos.
    @Test func theFilterNarrowsByCountryAndTown() async throws {
        let library = try await Self.library(in: makeTestDirectory())
        try await library.store.applyPlaceNames([
            PlaceCell(Self.helsinki): PlaceNames(country: "Finland", town: "Helsinki"),
            PlaceCell(Self.espoo): PlaceNames(country: "Finland", town: "Espoo"),
            PlaceCell(Self.sydney): PlaceNames(country: "Australia", town: "Sydney NSW"),
        ], locale: "en_US")
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
    }
}
