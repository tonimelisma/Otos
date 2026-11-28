import Foundation
@testable import OtosKit
import Testing

/// The Places scopes (ADR 0040): `.places` is every located item in the fixed
/// libraries with its coordinate read alongside the order, `.mapArea` the items in one
/// latitude/longitude box, and every scoped read — order, counts, filter options —
/// agrees about both. Store answers *what the scope holds*; `CatalogWindowPolicy`
/// turns that into *what the window says*, tested at its own boundary below.
@Suite(.testScope)
struct CatalogPlacesScopeTests {
    private static let helsinki = PlaceCoordinate(latitude: 60.17, longitude: 24.94)
    private static let sydney = PlaceCoordinate(latitude: -33.87, longitude: 151.21)
    /// A box of no extent: exactly the items at Helsinki's coordinate.
    private static let helsinkiPoint = MapArea(
        south: helsinki.latitude, north: helsinki.latitude, west: helsinki.longitude, east: helsinki.longitude
    )

    // Validates: APP-057, APP-058
    @Test func placesHoldsLocatedItemsWithCoordinatesAndAnAreaHoldsWhatLiesInIt() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["helsinki-new.jpg", "helsinki-old.jpg", "sydney.mp4", "nowhere.jpg"] {
            try writeCatalogStoreFile(root.appending(path: name), contents: name)
        }

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 4 }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }
        let placed: [(String, PlaceCoordinate?, Double)] = [
            ("helsinki-new.jpg", Self.helsinki, 1_700_300_000),
            ("helsinki-old.jpg", Self.helsinki, 1_700_000_000),
            ("sydney.mp4", Self.sydney, 1_700_100_000),
            ("nowhere.jpg", nil, 1_700_200_000),
        ]
        for (name, coordinate, captured) in placed {
            let asset = try #require(try await store.windowReads.mediaAssets(for: [id(name)])[id(name)])
            var metadata = AssetMetadata.absoluteCapture(instant: Date(timeIntervalSince1970: captured))
            if let coordinate {
                metadata.locations = [
                    GeoRecord(
                        source: "exifGPS",
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        altitudeMeters: nil
                    ),
                ]
            }
            _ = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: id(name),
                    metadata: metadata,
                    thumbnailPath: "\(name)-thumb.jpg",
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                    contentHash: .empty
                ),
            ])
        }
        let available: Set<LibraryRootPath> = [rootPath]

        let places = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .places, sort: .dateNewest),
            availableLibraryPaths: available
        )
        let helsinkiOnly = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .mapArea(Self.helsinkiPoint)),
            availableLibraryPaths: available
        )
        // A stack opened from the map holds exactly its members, in the scope's order.
        let stack = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(
                scope: .mapStack(MapStack(members: [places.ids[2], places.ids[1]])), sort: .dateNewest
            ),
            availableLibraryPaths: available
        )
        // Northern Europe: Helsinki in, Sydney out.
        let europe = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .mapArea(MapArea(south: 50, north: 70, west: 0, east: 40))),
            availableLibraryPaths: available
        )
        // A box across the antimeridian, from 150° east to 170° west: Sydney in.
        let pacific = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .mapArea(MapArea(south: -40, north: -20, west: 150, east: -170))),
            availableLibraryPaths: available
        )
        let allMedia = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia),
            availableLibraryPaths: available
        )
        let placesCount = try await store.windowReads.visibleAssetCount(for: .places, availableLibraryPaths: available)
        let imagesInLibrary = try await store.windowReads.visibleAssetCount(
            for: .allMedia,
            filter: MediaFilter(kinds: [.image]),
            availableLibraryPaths: available
        )
        await store.shutdown()

        // Located items only, newest first, each with its coordinate beside it.
        #expect(places.ids.map(\.relativePath.rawValue) == ["helsinki-new.jpg", "sydney.mp4", "helsinki-old.jpg"])
        #expect(places.coordinates == [Self.helsinki, Self.sydney, Self.helsinki])
        #expect(places.dayBuckets.count == places.ids.count)
        // A box of no extent is exactly one coordinate; a box holds what lies in it.
        #expect(helsinkiOnly.ids.map(\.relativePath.rawValue) == ["helsinki-new.jpg", "helsinki-old.jpg"])
        #expect(helsinkiOnly.coordinates == [Self.helsinki, Self.helsinki])
        #expect(europe.ids.map(\.relativePath.rawValue) == ["helsinki-new.jpg", "helsinki-old.jpg"])
        #expect(pacific.ids.map(\.relativePath.rawValue) == ["sydney.mp4"])
        #expect(stack.ids.map(\.relativePath.rawValue) == ["sydney.mp4", "helsinki-old.jpg"])
        // A scope without a location requirement carries no coordinates.
        #expect(allMedia.ids.count == 4)
        #expect(allMedia.coordinates.isEmpty)
        // Counts honor the same membership as the order.
        #expect(placesCount == 3)
        #expect(imagesInLibrary == 3)
    }

    // Validates: APP-057
    @Test func placesResolvesAwayOnlyWhenNoFixedLibraryRemains() {
        let pictures = library("/Users/example/Pictures")
        let card = removable("/Volumes/CARD")

        #expect(CatalogWindowPolicy.resolvedSidebarSelection(.places, libraries: [pictures], removableSources: []) == .places)
        #expect(
            CatalogWindowPolicy.resolvedSidebarSelection(
                .mapArea(Self.helsinkiPoint),
                libraries: [pictures],
                removableSources: [card]
            ) == .mapArea(Self.helsinkiPoint)
        )
        // No fixed library: nothing to map, so the default applies (the card here).
        #expect(CatalogWindowPolicy.resolvedSidebarSelection(.places, libraries: [], removableSources: [card]) == .library(card.path))
        #expect(CatalogWindowPolicy.title(for: .places, libraries: [pictures]) == "Places")
        #expect(CatalogWindowPolicy.title(for: .mapArea(Self.helsinkiPoint), libraries: [pictures]) == "Places")
        #expect(CatalogWindowPolicy.title(for: .mapStack(MapStack(members: [])), libraries: [pictures]) == "Places")
    }

    // Validates: APP-057
    @Test func mapStatePairsScopedIDsWithCoordinatesAndCountsWhatIsLeftOff() {
        let root = LibraryRootPath(rawValue: "/Users/example/Pictures")
        let ids = ["a.jpg", "b.jpg"].map { MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: $0)) }
        let descriptor = CatalogQueryDescriptor(scope: .places)

        let map = CatalogWindowPolicy.mapState(
            for: descriptor,
            scopedAssetIDs: ids,
            scopedCoordinates: [Self.helsinki, Self.sydney]
        )
        let notPlaces = CatalogWindowPolicy.mapState(
            for: CatalogQueryDescriptor(scope: .allMedia),
            scopedAssetIDs: ids,
            scopedCoordinates: []
        )

        #expect(map?.located == [LocatedAsset(id: ids[0], coordinate: Self.helsinki), LocatedAsset(id: ids[1], coordinate: Self.sydney)])
        #expect(notPlaces == nil)
    }

    // Validates: APP-057
    /// The scope pass that drops unavailable roots keeps coordinates paired with IDs
    /// the same way it keeps day buckets paired (DES-069's rule, applied to the map).
    @Test func scopePassKeepsCoordinatesPairedWithSurvivingIDs() {
        let pictures = library("/Users/example/Pictures")
        let archive = CatalogLibraryState(
            root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive")),
            availability: .unavailable,
            activity: .idle
        )
        let kept = MediaAssetID(libraryRootPath: pictures.path, relativePath: MediaRelativePath(rawValue: "kept.jpg"))
        let dropped = MediaAssetID(libraryRootPath: archive.path, relativePath: MediaRelativePath(rawValue: "dropped.jpg"))

        let scoped = CatalogWindowPolicy.assetIDs(
            for: .places,
            orderedAssetIDs: [dropped, kept],
            dayBuckets: [],
            coordinates: [Self.sydney, Self.helsinki],
            availableLibraryPaths: [pictures.path],
            rootsByPath: CatalogWindowPolicy.rootsByPath(from: [pictures, archive])
        )

        #expect(scoped.ids == [kept])
        #expect(scoped.coordinates == [Self.helsinki])
        #expect(scoped.dayBuckets.isEmpty)
    }

    // Validates: APP-057
    @Test func anEmptyMapWithReachableLibrariesSaysNoLocatedMedia() {
        let pictures = library("/Users/example/Pictures")
        let descriptor = CatalogQueryDescriptor(scope: .places)

        let noneLocated = CatalogWindowPolicy.mediaEmptyState(
            for: descriptor,
            libraries: [pictures],
            allAssetCount: 0,
            unfilteredVisibleAssetCount: 0,
            selectedAssetCount: 0
        )
        let filteredOut = CatalogWindowPolicy.mediaEmptyState(
            for: CatalogQueryDescriptor(scope: .places, filter: MediaFilter(kinds: [.video])),
            libraries: [pictures],
            allAssetCount: 3,
            unfilteredVisibleAssetCount: 3,
            selectedAssetCount: 0
        )
        let checking = CatalogWindowPolicy.mediaEmptyState(
            for: descriptor,
            libraries: [CatalogLibraryState(root: pictures.root, availability: .unknown, activity: .idle)],
            allAssetCount: 0,
            unfilteredVisibleAssetCount: 0,
            selectedAssetCount: 0
        )

        #expect(noneLocated == .noLocatedMedia)
        #expect(filteredOut == .noFilterMatches)
        #expect(checking == .checkingLibraries)
    }

    private func library(_ path: String) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(path: LibraryRootPath(rawValue: path)),
            availability: .available,
            activity: .idle
        )
    }

    private func removable(_ path: String) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(
                path: LibraryRootPath(rawValue: path),
                kind: .removableVolume,
                deviceIdentity: .volume(uuid: path),
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                lastSeenAt: Date()
            ),
            availability: .available,
            activity: .idle,
            isEjectable: true
        )
    }
}
