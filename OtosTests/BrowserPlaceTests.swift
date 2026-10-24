import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Otos comes back where the user left it (APP-043): the query, the view mode, the
/// selection and the position survive a relaunch, and anything that no longer exists falls
/// back to the launch defaults instead of being trusted.
@MainActor
struct BrowserPlaceTests {
    // MARK: - Stored format

    @Test func aPlaceRoundTripsThroughPreferences() {
        let preferences = PreferencesDomain.suite(UUID().uuidString).makeDefaults()
        let ids = makeIDs(3)
        let place = BrowserPlace(
            descriptor: CatalogQueryDescriptor(
                scope: .library(pictures),
                filter: MediaFilter(kinds: [.image, .raw], formats: [MediaFormatToken(rawValue: "JPEG")], choices: [.liked]),
                sort: MediaSortOrder(field: .name, direction: .ascending)
            ),
            viewMode: .loupe,
            focus: ids[1],
            selection: [ids[0], ids[2]]
        )

        place.save(to: preferences)

        #expect(BrowserPlace.load(from: preferences) == place)
    }

    @Test func everyScopeKindRoundTrips() {
        let scopes: [SidebarSelection] = [
            .allMedia,
            .allImports,
            .library(pictures),
            .importBatch(ImportBatchID(unixMilliseconds: 1_790_000_000_000)),
        ]
        for scope in scopes {
            let preferences = PreferencesDomain.suite(UUID().uuidString).makeDefaults()
            let place = BrowserPlace(
                descriptor: CatalogQueryDescriptor(scope: scope),
                viewMode: .grid,
                focus: nil,
                selection: []
            )
            place.save(to: preferences)
            #expect(BrowserPlace.load(from: preferences) == place)
        }
    }

    /// An unreadable place costs the user their position, never their launch: every way
    /// the stored value can be wrong loads as "nothing stored".
    @Test func anUnreadablePlaceLoadsAsNothing() throws {
        let preferences = PreferencesDomain.suite(UUID().uuidString).makeDefaults()
        #expect(BrowserPlace.load(from: preferences) == nil)

        preferences.set("not json", forKey: BrowserPlace.defaultsKey)
        #expect(BrowserPlace.load(from: preferences) == nil)

        BrowserPlace(descriptor: .default, viewMode: .grid, focus: nil, selection: []).save(to: preferences)
        let stored = try #require(preferences.string(forKey: BrowserPlace.defaultsKey))
        for (valid, invalid) in [
            ("\"version\":1", "\"version\":2"),
            ("\"sortField\":\"bestDate\"", "\"sortField\":\"rating\""),
            ("\"viewMode\":\"grid\"", "\"viewMode\":\"survey\""),
            ("\"kind\":\"allMedia\"", "\"kind\":\"smartAlbum\""),
        ] {
            #expect(stored.contains(valid), "fixture drifted: \(valid)")
            preferences.set(stored.replacingOccurrences(of: valid, with: invalid), forKey: BrowserPlace.defaultsKey)
            #expect(BrowserPlace.load(from: preferences) == nil, "accepted \(invalid)")
        }
    }

    // MARK: - Relaunch

    /// The very first query asks for the restored collection, so launch never shows the
    /// default collection first.
    @Test func launchStartsFromTheRestoredQuery() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let place = makePlace(viewMode: .grid, focus: nil, selection: [])
        place.save(to: domain.makeDefaults())

        let model = makeViewModel(domain)

        #expect(model.queryDescriptor == place.descriptor)
        #expect(model.sidebarSelection == place.descriptor.scope)
    }

    /// Grid: surviving selection comes back and the grid is told to center on the saved
    /// middle item, which puts the viewport back where it was. A selected item that is gone
    /// is dropped, not guessed at.
    @Test func gridRestoresSelectionAndPosition() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let ids = makeIDs(6)
        let gone = makeID("gone.jpg")
        let place = makePlace(viewMode: .grid, focus: ids[4], selection: [ids[1], gone, ids[2]])
        place.save(to: domain.makeDefaults())
        let model = makeViewModel(domain)

        model.applyState(loadedState(descriptor: place.descriptor, ids: ids))

        #expect(model.viewMode == .grid)
        #expect(model.gridSelection.selection == [ids[1], ids[2]])
        #expect(model.focusedAssetID == ids[4])
        #expect(model.pendingPlaceRestore == nil)
    }

    @Test func loupeReopensOnTheFocusedItem() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let ids = makeIDs(4)
        let place = makePlace(viewMode: .loupe, focus: ids[2], selection: [ids[2]])
        place.save(to: domain.makeDefaults())
        let model = makeViewModel(domain)

        model.applyState(loadedState(descriptor: place.descriptor, ids: ids))

        #expect(model.viewMode == .loupe)
        #expect(model.focusedAssetID == ids[2])
    }

    @Test func compareReopensOnTheSavedPair() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let ids = makeIDs(5)
        let place = makePlace(viewMode: .compare, focus: nil, selection: [ids[1], ids[3]])
        place.save(to: domain.makeDefaults())
        let model = makeViewModel(domain)

        model.applyState(loadedState(descriptor: place.descriptor, ids: ids))

        #expect(model.viewMode == .compare)
        #expect(Set(model.comparePair.members) == [ids[1], ids[3]])
    }

    /// A restored library that was removed is a different collection: the launch default
    /// applies, the filter and sort carry over, and nothing from the old place is applied.
    @Test func aRemovedScopeFallsBackToTheDefaultKeepingFilterAndSort() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let ids = makeIDs(3)
        let place = makePlace(viewMode: .loupe, focus: ids[0], selection: [ids[0]])
        place.save(to: domain.makeDefaults())
        let model = makeViewModel(domain)
        let archive = LibraryRootPath(rawValue: "/Users/example/Archive")

        model.applyState(loadedState(descriptor: place.descriptor, ids: [], libraries: [archive]))

        #expect(model.sidebarSelection == .library(archive))
        #expect(model.queryDescriptor.filter == place.descriptor.filter)
        #expect(model.queryDescriptor.sort == place.descriptor.sort)
        #expect(model.pendingPlaceRestore == nil)

        let archiveQuery = model.queryDescriptor
        model.applyState(loadedState(descriptor: archiveQuery, ids: ids, libraries: [archive], generation: 1))
        #expect(model.viewMode == .grid)
        #expect(model.gridSelection == .empty)
    }

    /// All Media is only a row with two or more fixed libraries; a remembered All Media
    /// in a one-library set is gone too, so the launch default applies.
    @Test func aRememberedAllMediaWithOneLibraryFallsBackToTheDefault() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let place = BrowserPlace(
            descriptor: CatalogQueryDescriptor(scope: .allMedia),
            viewMode: .grid,
            focus: nil,
            selection: []
        )
        place.save(to: domain.makeDefaults())
        let model = makeViewModel(domain)

        model.applyState(loadedState(descriptor: place.descriptor, ids: []))

        #expect(model.sidebarSelection == .library(pictures))
        #expect(model.pendingPlaceRestore == nil)
    }

    /// Once the user goes somewhere else before the catalog has loaded, the old place
    /// would be a surprise jump — it is dropped.
    @Test func aUserChoiceBeforeLoadDropsThePendingPlace() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let place = makePlace(viewMode: .loupe, focus: nil, selection: [])
        place.save(to: domain.makeDefaults())
        let model = makeViewModel(domain)

        model.setSortOrder(MediaSortOrder(field: .size, direction: .descending))

        #expect(model.pendingPlaceRestore == nil)
    }

    // MARK: - Quit

    @Test func quitSavesWhereTheUserIs() throws {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let model = makeViewModel(domain)
        let ids = makeIDs(9)
        let descriptor = CatalogQueryDescriptor(scope: .library(pictures))
        model.applyState(loadedState(descriptor: descriptor, ids: ids))
        _ = model.applyGridClick(hit: ids[5], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[2], modifiers: [.command], orderedIDs: ids)
        model.viewportChanged(Array(ids[3 ... 7]))

        model.persistBrowserPlace()

        let saved = try #require(BrowserPlace.load(from: domain.makeDefaults()))
        #expect(saved.descriptor == model.queryDescriptor)
        #expect(saved.viewMode == .grid)
        #expect(saved.selection == [ids[2], ids[5]], "selection is saved in display order")
        #expect(saved.focus == ids[5], "the grid saves its middle visible item")
    }

    /// Quitting before the catalog loaded must not overwrite the user's real place with
    /// the launch defaults.
    @Test func quitBeforeRestoreKeepsTheStoredPlace() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let place = makePlace(viewMode: .loupe, focus: makeID("kept.jpg"), selection: [])
        place.save(to: domain.makeDefaults())
        let model = makeViewModel(domain)

        model.persistBrowserPlace()

        #expect(BrowserPlace.load(from: domain.makeDefaults()) == place)
    }
}

private let pictures = LibraryRootPath(rawValue: "/Users/example/Pictures")

private func makeID(_ path: String) -> MediaAssetID {
    MediaAssetID(libraryRootPath: pictures, relativePath: MediaRelativePath(rawValue: path))
}

private func makeIDs(_ count: Int) -> [MediaAssetID] {
    (0 ..< count).map { makeID("asset-\($0).jpg") }
}

private func makePlace(
    viewMode: BrowserViewMode,
    focus: MediaAssetID?,
    selection: [MediaAssetID]
) -> BrowserPlace {
    BrowserPlace(
        descriptor: CatalogQueryDescriptor(
            scope: .library(pictures),
            filter: MediaFilter(kinds: [.image]),
            sort: MediaSortOrder(field: .bestDate, direction: .ascending)
        ),
        viewMode: viewMode,
        focus: focus,
        selection: selection
    )
}

@MainActor
private func makeViewModel(_ domain: PreferencesDomain) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory, scanCadence: .milliseconds(10)),
        catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: domain,
        trashFiles: .refusing
    )
}

/// A loaded catalog state: its libraries exist, so the launch latch decides, and its grid
/// is the result of `descriptor`.
private func loadedState(
    descriptor: CatalogQueryDescriptor,
    ids: [MediaAssetID],
    libraries: [LibraryRootPath] = [pictures],
    generation: UInt64 = 0
) -> CatalogWindowState {
    CatalogWindowState(
        title: "Pictures",
        libraries: libraries.map {
            CatalogLibraryState(root: LibraryRoot(path: $0), availability: .available, activity: .idle)
        },
        removableSources: [],
        mediaGrid: CatalogMediaGridState(descriptor: descriptor, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: descriptor.scope,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil,
        queryGeneration: generation
    )
}
