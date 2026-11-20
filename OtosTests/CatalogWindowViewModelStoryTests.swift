import AVFoundation
import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The ViewModel's half of On This Day (ADR 0049): today follows the platform's day and
/// time-zone reports and carries the scope with it, and a story plays the scope's items in
/// its own order through the loupe's focus — its one owner of the item on screen — holding
/// each still once its picture is on screen and moving on the reports the pane and the
/// player deliver for the visit they were made for. The model is not started: each test
/// starts only the lane it needs and applies states by hand. Stories run over a real
/// catalog, so the kind read and the pane's detail read are the real ones.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelStoryTests {
    private nonisolated static let today = CalendarDay(year: 2026, month: 11, day: 9)

    private final class DayBox: Sendable {
        private let value: Mutex<CalendarDay>
        init(_ day: CalendarDay) {
            value = Mutex(day)
        }

        func set(_ day: CalendarDay) {
            value.withLock { $0 = day }
        }

        func get() -> CalendarDay {
            value.withLock { $0 }
        }
    }

    private func makeModel(
        store: CatalogStore = makeTestStore(location: .inMemory),
        loader: FakePreviewLoader = FakePreviewLoader(),
        day: DayBox = DayBox(today),
        center: NotificationCenter = NotificationCenter(),
        tiles: TileContentStore = TileContentStore(),
        trash: URL? = nil
    ) -> CatalogWindowViewModel {
        CatalogWindowViewModel(
            catalogStore: store,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            previewLoader: loader,
            calendarDayReader: { day.get() },
            calendarNotificationCenter: center,
            tileContentStore: tiles,
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: trash.map { .folder($0) } ?? .refusing
        )
    }

    /// Two years over `ids`: 2025 holds the first two, 2023 the rest, newest first.
    private func years(_ ids: [MediaAssetID]) -> [OnThisDayAnniversary] {
        [
            OnThisDayAnniversary(day: Self.today.inYear(2025), keyItem: ids[0], firstIndex: 0, count: 2),
            OnThisDayAnniversary(day: Self.today.inYear(2023), keyItem: ids[2], firstIndex: 2, count: ids.count - 2),
        ]
    }

    /// A published On This Day state answering the model's own intent.
    private func onThisDayState(
        _ model: CatalogWindowViewModel,
        ids: [MediaAssetID],
        years: [OnThisDayAnniversary],
        remaps: [CatalogIdentityRemapBatch] = [],
        libraries: [CatalogLibraryState] = []
    ) -> CatalogWindowState {
        let scope = SidebarSelection.onThisDay(Self.today)
        var state = CatalogWindowState(
            title: "On This Day",
            libraries: libraries,
            removableSources: [],
            mediaGrid: CatalogMediaGridState(
                descriptor: CatalogQueryDescriptor(
                    scope: scope,
                    filter: model.queryDescriptor.filter,
                    sort: model.queryDescriptor.sort
                ),
                orderedAssetIDs: ids
            ),
            filterOptions: .empty,
            resolvedSidebarSelection: scope,
            mediaEmptyState: ids.isEmpty ? .nothingOnThisDay(Self.today) : nil,
            deviceConnectionBanner: nil,
            onThisDay: CatalogOnThisDayState(day: Self.today, anniversaries: years),
            queryGeneration: model.queryGeneration
        )
        state.pendingIdentityRemaps = remaps
        return state
    }

    private func enterOnThisDay(
        _ model: CatalogWindowViewModel,
        ids: [MediaAssetID],
        libraries: [CatalogLibraryState] = []
    ) {
        model.selectSidebar(.onThisDay(Self.today))
        model.applyState(onThisDayState(model, ids: ids, years: years(ids), libraries: libraries))
    }

    private func image(edge: Int = 8) -> DisplayImage {
        DisplayImage.fixture(width: edge)
    }

    /// A loader whose every decode is a picture.
    private func picturingLoader() async -> FakePreviewLoader {
        let loader = FakePreviewLoader()
        await loader.setDefaultOutcome(.image(image(), nativePixelSize: nil))
        return loader
    }

    // MARK: - Today

    @Test func aReportedDayChangeMovesOnThisDayToTheNewDay() async throws {
        let day = DayBox(Self.today)
        let center = NotificationCenter()
        let model = makeModel(day: day, center: center)
        model.startCalendarDayMonitoring()
        model.selectSidebar(.onThisDay(Self.today))
        #expect(model.today == Self.today)
        #expect(model.onThisDayRowDay == nil) // no library yet, so no row

        let tomorrow = CalendarDay(year: 2026, month: 11, day: 10)
        day.set(tomorrow)
        center.post(name: .NSCalendarDayChanged, object: nil)
        try await waitUntil { model.today == tomorrow }

        #expect(model.today == tomorrow)
        #expect(model.queryDescriptor.scope == .onThisDay(tomorrow))
        #expect(model.sidebarSelection == .onThisDay(tomorrow))
    }

    @Test func aDayChangeElsewhereLeavesTheScopeAlone() async throws {
        let day = DayBox(Self.today)
        let center = NotificationCenter()
        let model = makeModel(day: day, center: center)
        model.startCalendarDayMonitoring()
        model.selectSidebar(.allMedia)

        let elsewhere = CalendarDay(year: 2026, month: 11, day: 8)
        day.set(elsewhere)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await waitUntil { model.today == elsewhere }

        #expect(model.today == elsewhere)
        #expect(model.queryDescriptor.scope == .allMedia)
    }

    // MARK: - The scope

    @Test func onThisDayIsItsOwnPresentationWithItsOwnOrder() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: library.ids)

            #expect(model.showsOnThisDay)
            #expect(!model.canChangeViewMode)
            #expect(!model.canChangeSort)
            #expect(!model.canZoomIn)
            #expect(model.canPlayStory)
            model.setSortOrder(.filenameAscending)
            #expect(model.queryDescriptor.sort == .defaultOrder)
            model.setViewMode(.loupe)
            #expect(model.viewMode == .grid)
        }
    }

    // MARK: - Moving

    @Test func aStoryStartsAtTheChosenYearAndMovesAcrossYearsBothWays() async throws {
        try await withEditableLibrary(fileCount: 5) { library in
            let ids = library.ids
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: ids)

            model.playStory(anniversary: Self.today.inYear(2023))
            #expect(model.storyItem == ids[2])
            #expect(model.focusedAssetID == ids[2])
            #expect(model.viewMode == .loupe)
            #expect(!model.canPlayStory)
            // Photo commands target the item on screen, through the loupe's target.
            #expect(model.targetIDs(.current) == [ids[2]])

            model.storyPrevious()
            #expect(model.storyItem == ids[1])
            model.storyNext()
            model.storyNext()
            #expect(model.storyItem == ids[3])
            #expect(model.canStoryNext)
        }
    }

    @Test func playStoryFromTheMenuStartsAtTheNewestYear() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: library.ids)

            model.playStory()

            #expect(model.storyItem == library.ids[0])
        }
    }

    // MARK: - Timing

    @Test func aStillHoldsOnlyOnceItsPictureIsOnScreenAndThenAdvances() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let ids = library.ids
            let loader = FakePreviewLoader()
            await loader.setHold(true)
            let model = makeModel(store: library.store, loader: loader)
            enterOnThisDay(model, ids: ids)
            model.playStory(anniversary: Self.today.inYear(2025))
            let visit = try #require(model.story?.visit)
            try await loader.waitUntilPending(id: ids[0])
            try await waitUntil { model.focusedAssetKind == .image }

            // Waiting on bytes: no hold, and the hold's report moves nothing.
            #expect(model.story?.pane == .awaited)
            #expect(model.story?.hold == nil)
            model.storyHoldElapsed(visit: visit)
            #expect(model.storyItem == ids[0])

            await loader.release(id: ids[0], with: .image(image(), nativePixelSize: nil))
            try await waitUntil { model.story?.hold != nil }
            #expect(model.story?.pane == .shown)
            #expect(model.story?.hold?.countingSince != nil)

            // The hold's report, delivered at its suspension point, moves to the next item.
            model.storyHoldElapsed(visit: visit)
            #expect(model.storyItem == ids[1])
            #expect(model.story?.hold == nil)
        }
    }

    @Test func pauseFreezesTheHoldAndPlayResumesIt() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let model = await makeModel(store: library.store, loader: picturingLoader())
            enterOnThisDay(model, ids: library.ids)
            model.playStory(anniversary: Self.today.inYear(2025))
            try await waitUntil { model.story?.hold != nil }
            let visit = try #require(model.story?.visit)

            model.toggleStoryPause()
            #expect(model.story?.isPaused == true)
            #expect(model.story?.hold?.countingSince == nil)
            // A paused hold does not run out.
            model.storyHoldElapsed(visit: visit)
            #expect(model.storyItem == library.ids[0])

            model.toggleStoryPause()
            #expect(model.story?.isPaused == false)
            #expect(model.story?.hold?.countingSince != nil)
            model.storyHoldElapsed(visit: visit)
            #expect(model.storyItem == library.ids[1])
        }
    }

    /// A report made for an earlier visit of the same item — its hold, its video's end or
    /// failure — is dropped once focus has left and come back.
    @Test func aReportFromAnEarlierVisitOfTheSameItemMovesNothing() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let ids = library.ids
            let model = await makeModel(store: library.store, loader: picturingLoader())
            enterOnThisDay(model, ids: ids)
            model.playStory(anniversary: Self.today.inYear(2025))
            let firstVisit = try #require(model.story?.visit)

            model.storyNext()
            model.storyPrevious()
            #expect(model.storyItem == ids[0])
            try await waitUntil { model.story?.hold != nil }
            #expect(model.story?.visit != firstVisit)

            model.storyHoldElapsed(visit: firstVisit)
            model.storyVideoEnded(visit: firstVisit)
            model.storyVideoFailed(visit: firstVisit)
            model.storyVideoUnavailable(visit: firstVisit)
            #expect(model.storyItem == ids[0])
            #expect(model.story?.video == .notVideo)
        }
    }

    @Test func anItemWithNoPictureHoldsLikeAStill() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: library.ids)
            model.playStory(anniversary: Self.today.inYear(2025))

            // The loader answers that there is no picture.
            try await waitUntil { model.story?.hold != nil }
            #expect(model.story?.pane == StoryPane.none)
        }
    }

    @Test func theLastItemEndsPausedAndAVideoEndAdvances() async throws {
        try await withEditableLibrary(fileCount: 5) { library in
            let ids = library.ids
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: ids)
            model.playStory(anniversary: Self.today.inYear(2023))
            model.storyNext()
            #expect(model.storyItem == ids[3])

            // A video advances on its player's end report, never on a hold.
            let fourth = try #require(model.story?.visit)
            model.storyVideoEnded(visit: fourth)
            #expect(model.storyItem == ids[4])

            let last = try #require(model.story?.visit)
            model.storyVideoEnded(visit: last)
            #expect(model.storyItem == ids[4])
            #expect(model.story?.hasEnded == true)
            #expect(model.story?.isPaused == true)
            #expect(!model.canStoryNext)
            #expect(!model.canToggleStoryPause)
            model.toggleStoryPause()
            #expect(model.story?.isPaused == true)
        }
    }

    /// A player that turns up while a still's hold runs ends the hold: a video plays to its
    /// own end.
    @Test func aReadyPlayerEndsARunningHold() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let model = await makeModel(store: library.store, loader: picturingLoader())
            enterOnThisDay(model, ids: library.ids)
            model.playStory(anniversary: Self.today.inYear(2025))
            try await waitUntil { model.story?.hold != nil }
            let visit = try #require(model.story?.visit)

            model.storyVideoReady(
                LoupeVideoState(id: library.ids[0], player: AVPlayer(), isPlaying: false),
                visit: visit
            )

            #expect(model.story?.hold == nil)
            #expect(model.story?.video == .playing)
        }
    }

    /// A video the player cannot play reports its failure; the player goes and the item
    /// holds like a still on its poster.
    @Test func aVideoThatFailsToPlayHoldsLikeAStill() async throws {
        try await withEditableLibrary(
            fileCount: 3,
            fileExtension: "mp4",
            write: { url in try Data("not a movie".utf8).write(to: url) }
        ) { library in
            let model = await makeModel(store: library.store, loader: picturingLoader())
            enterOnThisDay(model, ids: library.ids)
            model.playStory(anniversary: Self.today.inYear(2025))

            try await waitUntil { model.story?.video == .unavailable && model.story?.hold != nil }
            #expect(model.focusedAssetKind == .video)
            #expect(model.loupeVideoState == nil)
            #expect(model.storyItem == library.ids[0])
        }
    }

    // MARK: - Tools

    @Test func trimAndTheLoupesOwnToolsAreOffWhileAStoryPlays() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let id = library.ids[0]
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: library.ids)
            model.playStory(anniversary: Self.today.inYear(2025))
            try await waitUntil { model.focusedAssetKind == .image }
            model.focusedAssetKind = .video
            model.loupeVideo = .ready(LoupeVideoState(id: id, player: AVPlayer(), isPlaying: false))

            #expect(!model.canTrimVideo)
            #expect(!model.canCrop)
            #expect(!model.canPlayLivePhoto)
        }
    }

    // MARK: - Covers

    /// The anniversaries' covers are pinned in the shared tile store while On This Day shows, as the
    /// grid pins its visible tiles: a story's pictures filling the store past its budget
    /// cannot drop a painted cover, so the card made again when the story closes draws the
    /// same picture, never the placeholder. Leaving the scope releases them.
    @Test func paintedCoversSurviveBudgetPressureAndAreReleasedWithTheScope() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let ids = library.ids
            let cost = TileContentStore.byteCost(of: image(edge: 64))
            let tiles = TileContentStore(imageByteBudget: cost * 3)
            let model = makeModel(store: library.store, tiles: tiles)
            enterOnThisDay(model, ids: ids)
            @MainActor func paint(_ id: MediaAssetID) -> DisplayImage {
                let picture = image(edge: 64)
                tiles.warm(
                    id: id,
                    image: picture,
                    detail: MediaTileDetail(
                        libraryRootPath: id.libraryRootPath,
                        relativePath: id.relativePath,
                        thumbnailPath: "\(id.relativePath.rawValue).thumb"
                    )
                )
                return picture
            }
            let firstCover = paint(ids[0])
            let secondCover = paint(ids[2])

            model.playStory(anniversary: Self.today.inYear(2025))
            let others = (0 ..< 5).map { index in
                MediaAssetID(
                    libraryRootPath: ids[0].libraryRootPath,
                    relativePath: MediaRelativePath(rawValue: "story-\(index).jpg")
                )
            }
            for other in others {
                _ = paint(other)
            }
            model.closeStory()

            // The store was over budget: the oldest unpinned picture went.
            #expect(tiles.currentImage(for: others[0]) == nil)
            let firstShown = OnThisDayCover.displayed(painted: nil, keyItem: ids[0], stored: tiles.currentImage(for: ids[0]))
            let secondShown = OnThisDayCover.displayed(painted: nil, keyItem: ids[2], stored: tiles.currentImage(for: ids[2]))
            #expect(firstShown === firstCover)
            #expect(secondShown === secondCover)

            model.selectSidebar(.allMedia)
            model.applyState(CatalogWindowState(
                title: "All Media",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
                filterOptions: .empty,
                resolvedSidebarSelection: .allMedia,
                mediaEmptyState: .noMedia,
                deviceConnectionBanner: nil,
                queryGeneration: model.queryGeneration
            ))
            for other in others {
                _ = paint(other)
            }
            // Released with the scope, the covers are ordinary entries again.
            #expect(tiles.currentImage(for: ids[0]) == nil)
        }
    }

    // MARK: - Move to Trash

    /// Moving the item on screen to the Trash, through the ordinary intent, leaves the story
    /// on the successor its own survivor rule names, with focus, selection and the visit
    /// all on it.
    @Test func trashingTheItemOnScreenMovesTheStoryToItsSurvivor() async throws {
        try await withCatalogedLibrary(fileCount: 5, fileNamePrefix: "story") { fixture in
            let ids = fixture.ids
            let model = try makeModel(store: fixture.store, trash: makeTestDirectory())
            enterOnThisDay(model, ids: ids, libraries: [
                CatalogLibraryState(root: LibraryRoot(path: fixture.rootPath), availability: .available, activity: .idle),
            ])
            model.playStory(anniversary: Self.today.inYear(2023))
            let before = try #require(model.story?.visit)
            let expected = StoryPlaybackPolicy.survivor(
                of: ids[2],
                previousOrderedIDs: ids,
                survivingOrderedIDs: ids.filter { $0 != ids[2] }
            )

            model.moveTargetedMediaToTrash()

            try await waitUntil { model.focusedAssetID != ids[2] }
            #expect(model.storyItem == expected)
            #expect(model.focusedAssetID == ids[3])
            #expect(model.gridSelection.selection == [ids[3]])
            let after = try #require(model.story?.visit)
            #expect(after != before)
            // The trashed item's visit is over: its report moves nothing.
            model.storyHoldElapsed(visit: before)
            #expect(model.storyItem == ids[3])
        }
    }

    // MARK: - Closing and catalog changes

    @Test func closingReturnsToTheYearsWithFocusOnTheYearItWasOn() async throws {
        try await withEditableLibrary(fileCount: 5) { library in
            let ids = library.ids
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: ids)
            model.playStory(anniversary: Self.today.inYear(2025))
            model.storyNext()
            model.storyNext()

            model.closeStory()

            #expect(model.story == nil)
            #expect(model.storyItem == nil)
            #expect(model.viewMode == .grid)
            #expect(model.onThisDayFocusRequest?.anniversary == Self.today.inYear(2023))
            #expect(model.gridSelection.selection == [ids[2]])
            #expect(model.canPlayStory)
        }
    }

    @Test func aRemovedItemMovesTheStoryToItsSurvivorAndAnEmptyScopeClosesIt() async throws {
        try await withEditableLibrary(fileCount: 5) { library in
            let ids = library.ids
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: ids)
            model.playStory(anniversary: Self.today.inYear(2023))
            #expect(model.storyItem == ids[2])

            let remaining = ids.filter { $0 != ids[2] }
            model.applyState(onThisDayState(model, ids: remaining, years: [
                years(ids)[0],
                OnThisDayAnniversary(day: Self.today.inYear(2023), keyItem: ids[3], firstIndex: 2, count: 2),
            ]))
            #expect(model.storyItem == ids[3])

            model.applyState(onThisDayState(model, ids: [], years: []))
            #expect(model.story == nil)
            #expect(model.viewMode == .grid)
        }
    }

    /// A reorganization renames the item on screen: the story is on the renamed item, and
    /// Next goes on from there instead of skipping one.
    @Test func aRenamedItemStaysTheStorysItem() async throws {
        try await withEditableLibrary(fileCount: 5) { library in
            let ids = library.ids
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: ids)
            model.playStory(anniversary: Self.today.inYear(2023))
            let renamed = MediaAssetID(
                libraryRootPath: ids[2].libraryRootPath,
                relativePath: MediaRelativePath(rawValue: "2023/renamed.jpg")
            )
            var moved = ids
            moved[2] = renamed

            model.applyState(onThisDayState(model, ids: moved, years: years(moved), remaps: [
                CatalogIdentityRemapBatch(
                    id: 1,
                    libraryRootPath: renamed.libraryRootPath,
                    remaps: [CatalogIdentityRemap(oldID: ids[2], newID: renamed)]
                ),
            ]))

            #expect(model.story != nil)
            #expect(model.storyItem == renamed)
            model.storyNext()
            #expect(model.storyItem == ids[3])
        }
    }

    @Test func leavingTheScopeClosesTheStory() async throws {
        try await withEditableLibrary(fileCount: 4) { library in
            let model = makeModel(store: library.store)
            enterOnThisDay(model, ids: library.ids)
            model.playStory(anniversary: Self.today.inYear(2025))

            model.selectSidebar(.allMedia)
            model.applyState(CatalogWindowState(
                title: "All Media",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: library.ids),
                filterOptions: .empty,
                resolvedSidebarSelection: .allMedia,
                mediaEmptyState: .noMedia,
                deviceConnectionBanner: nil,
                queryGeneration: model.queryGeneration
            ))

            #expect(model.story == nil)
            #expect(model.viewMode == .grid)
        }
    }
}
