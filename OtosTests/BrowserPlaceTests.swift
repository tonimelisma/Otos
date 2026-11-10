import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Otos comes back where the user left it (APP-043): the query, the view mode, the
/// selection and the position survive a relaunch, and anything that no longer exists falls
/// back to the launch defaults instead of being trusted.
@MainActor
struct BrowserPlaceTests {
    private static let today = CalendarDay(year: 2026, month: 11, day: 9)

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

        #expect(BrowserPlace.load(from: preferences, today: Self.today) == place)
    }

    @Test func everyScopeKindRoundTrips() {
        let scopes: [SidebarSelection] = [
            .allMedia,
            .places,
            .mapArea(MapArea(south: 60.1, north: 60.2, west: 24.9, east: 25)),
            .onThisDay(Self.today),
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
            #expect(BrowserPlace.load(from: preferences, today: Self.today) == place)
        }
    }

    /// On This Day is saved without its day and reopens on the day it is reopened, since
    /// it always asks about today (ADR 0049).
    @Test func onThisDayReopensOnTheDayItIsLoaded() throws {
        let preferences = PreferencesDomain.suite(UUID().uuidString).makeDefaults()
        let saved = BrowserPlace(
            descriptor: CatalogQueryDescriptor(scope: .onThisDay(Self.today), filter: MediaFilter(kinds: [.video])),
            viewMode: .grid,
            focus: nil,
            selection: []
        )
        saved.save(to: preferences)

        let tomorrow = CalendarDay(year: 2026, month: 11, day: 10)
        let loaded = try #require(BrowserPlace.load(from: preferences, today: tomorrow))

        #expect(loaded.descriptor.scope == .onThisDay(tomorrow))
        #expect(loaded.descriptor.filter == MediaFilter(kinds: [.video]))
        let json = try #require(preferences.string(forKey: BrowserPlace.defaultsKey))
        #expect(!json.contains("2026"))
    }

    /// An unreadable place costs the user their position, never their launch: every way
    /// the stored value can be wrong loads as "nothing stored".
    @Test func anUnreadablePlaceLoadsAsNothing() throws {
        let preferences = PreferencesDomain.suite(UUID().uuidString).makeDefaults()
        #expect(BrowserPlace.load(from: preferences, today: Self.today) == nil)

        preferences.set("not json", forKey: BrowserPlace.defaultsKey)
        #expect(BrowserPlace.load(from: preferences, today: Self.today) == nil)

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
            #expect(BrowserPlace.load(from: preferences, today: Self.today) == nil, "accepted \(invalid)")
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

    /// A Duplicates group is saved as the list it was reached from, and the list has one
    /// presentation: a group left in Loupe reopens as the list, never as a Loupe over it.
    @Test func aDuplicatesGroupLeftInLoupeReopensAsTheList() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let ids = makeIDs(2)
        let place = BrowserPlace(
            descriptor: CatalogQueryDescriptor(scope: .duplicates),
            viewMode: .loupe,
            focus: ids[1],
            selection: [ids[1]]
        )
        place.save(to: domain.makeDefaults())
        let model = makeViewModel(domain)

        model.applyState(loadedState(descriptor: place.descriptor, ids: ids))

        #expect(model.sidebarSelection == .duplicates)
        #expect(model.showsDuplicatesList)
        #expect(model.showsDuplicatesRow)
        #expect(model.viewMode == .grid)
        #expect(model.gridSelection.selection == [ids[1]])
        #expect(model.pendingPlaceRestore == nil)
    }

    /// Return on a picture opens its group: two copies side by side in Compare, more in
    /// Loupe, before Projection has published the group's scope.
    @Test func openingAGroupShowsTwoCopiesInCompareAndMoreInLoupe() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let ids = makeIDs(5)
        let model = makeViewModel(domain)
        let copies = ids.map { id in
            DuplicateCopy(
                id: id, libraryDisplayName: "Pictures", libraryKind: .library, kind: .image, captureDate: nil, byteSize: 1, createdAt: nil,
                pixelWidth: 4, pixelHeight: 3, mediaChoice: .notRated, isEdited: false, hasCompanions: false
            )
        }
        let pair = DuplicateGroupPolicy.group(
            id: .samePhoto(Array(ids.prefix(2))), copies: Array(copies.prefix(2)), keptPairs: [], originals: [ids[0]]
        )
        let three = DuplicateGroupPolicy.group(
            id: .samePhoto(Array(ids.suffix(3))), copies: Array(copies.suffix(3)), keptPairs: [], originals: [ids[2]]
        )
        var state = loadedState(descriptor: CatalogQueryDescriptor(scope: .duplicates), ids: ids)
        state.duplicates = CatalogDuplicatesState(groups: [pair, three])
        model.applyState(state)

        model.selectDuplicateCopy(ids[1], modifiers: [], orderedIDs: ids)
        model.openSelectedDuplicateGroup()
        #expect(model.sidebarSelection == .duplicateGroup(pair.id))
        #expect(model.viewMode == .compare)
        #expect(model.gridSelection.selection == Set(pair.copies.map(\.id)))

        model.returnToDuplicates()
        model.applyState(state)
        model.selectDuplicateCopy(ids[4], modifiers: [], orderedIDs: ids)
        model.openSelectedDuplicateGroup()
        #expect(model.viewMode == .loupe)
    }

    /// A click keeps that copy; ⌘⌫ on the list moves the selected groups' copies tagged
    /// Trash and never the kept one, so Select All then ⌘⌫ cannot empty a group (ADR 0042).
    /// Double-click opens the group of the photo clicked, whatever the selection holds.
    @Test func aClickKeepsACopyAndCommandBackspaceMovesOnlyTheOthers() throws {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let ids = makeIDs(3)
        let model = makeViewModel(domain)
        let copies = ids.enumerated().map { index, id in
            DuplicateCopy(
                id: id, libraryDisplayName: "Pictures", libraryKind: .library, kind: .image, captureDate: nil, byteSize: 1,
                createdAt: Date(timeIntervalSince1970: Double(index)), pixelWidth: 4, pixelHeight: 3,
                mediaChoice: .notRated, isEdited: false, hasCompanions: false
            )
        }
        let digest = try #require(XXH3Digest128(data: Data(repeating: 7, count: 16)))
        let group = DuplicateGroupPolicy.group(id: .identical(digest), copies: copies, keptPairs: [])
        var state = loadedState(descriptor: CatalogQueryDescriptor(scope: .duplicates), ids: ids)
        state.duplicates = CatalogDuplicatesState(groups: [group])
        model.applyState(state)

        model.selectDuplicateCopy(ids[0], modifiers: [], orderedIDs: ids)
        model.selectDuplicateCopy(ids[2], modifiers: .shift, orderedIDs: ids)
        #expect(Set(model.selectedDuplicatesToMove().ids) == Set(ids.dropFirst()))
        #expect(model.canMoveTargetedMediaToTrash)

        model.keepDuplicateCopy(ids[2])
        #expect(Set(model.selectedDuplicatesToMove().ids) == [ids[0], ids[1]])
        #expect(model.duplicatesTally?.itemsToMove.contains(ids[2]) == false)

        model.openDuplicateGroup(containing: ids[2])
        #expect(model.sidebarSelection == .duplicateGroup(group.id))
    }

    /// Before the catalog loads, the sidebar draws no row at all — not even the one the user
    /// left, whose lone presence would read as the whole sidebar (APP-044).
    @Test func beforeTheCatalogLoadsTheSidebarDrawsNoRow() {
        for scope in [SidebarSelection.allMedia, .places, .duplicates, .library(pictures)] {
            let domain = PreferencesDomain.suite(UUID().uuidString)
            BrowserPlace(descriptor: CatalogQueryDescriptor(scope: scope), viewMode: .grid, focus: nil, selection: [])
                .save(to: domain.makeDefaults())
            let model = makeViewModel(domain)

            #expect(!model.state.isCatalogLoaded)
            #expect(model.sidebarSelection == scope)
            #expect(!model.showsAllMediaRow)
            #expect(!model.showsPlacesRow)
            #expect(!model.showsDuplicatesRow)
        }
    }

    /// Until the groups are first built nothing about duplicates is known: a selected
    /// Duplicates row shows without a count, and there is nothing to move.
    @Test func duplicatesNotYetBuiltClaimNoCount() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        BrowserPlace(descriptor: CatalogQueryDescriptor(scope: .duplicates), viewMode: .grid, focus: nil, selection: [])
            .save(to: domain.makeDefaults())
        let model = makeViewModel(domain)

        model.applyState(loadedState(descriptor: CatalogQueryDescriptor(scope: .duplicates), ids: []))

        #expect(model.state.duplicates == nil)
        #expect(model.showsDuplicatesRow)
        #expect(model.duplicatesCount == nil)
        #expect(model.duplicatesTally == nil)
        #expect(!model.canMoveDuplicatesToTrash)
    }

    /// Once loaded, the rows follow the catalog: All Media with two fixed libraries.
    @Test func afterTheCatalogLoadsTheRowsFollowTheLibraries() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let model = makeViewModel(domain)
        let archive = LibraryRootPath(rawValue: "/Users/example/Archive")

        model.applyState(loadedState(
            descriptor: CatalogQueryDescriptor(scope: .allMedia),
            ids: [],
            libraries: [pictures, archive]
        ))

        #expect(model.state.isCatalogLoaded)
        #expect(model.showsAllMediaRow)
        #expect(model.showsPlacesRow)
        #expect(!model.showsDuplicatesRow)
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

        let saved = try #require(BrowserPlace.load(from: domain.makeDefaults(), today: Self.today))
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

        #expect(BrowserPlace.load(from: domain.makeDefaults(), today: Self.today) == place)
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
        volumeCapacity: ampleVolumeCapacity,
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
