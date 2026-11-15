import AppKit
import Foundation
@testable import OtosKit
import Testing

/// How the window takes in a publication (ADR 0004, ADR 0005): Projection hands unchanged
/// parts on as the last publication's own, the window tells what changed by identity, every
/// scope is titled by one owner, and nothing on a pane the user has left acts.
@MainActor
struct WindowStateApplyTests {
    // MARK: - Publication shares what did not change

    /// A pass that rebuilt the grid's content equal to the last one publishes the last one's,
    /// so the window sees it unchanged without comparing; a different order is new content.
    @Test func anEqualRebuiltContentIsPublishedAsTheLastOne() {
        let ids = makeIDs(4)
        let first = windowState(ids: ids).sharingUnchanged(with: nil)
        let rebuilt = windowState(ids: ids.map { makeID($0.relativePath.rawValue) }, detailRefresh: 2)
        #expect(!rebuilt.mediaGrid.sharesContent(with: first.mediaGrid))

        let republished = rebuilt.sharingUnchanged(with: first)
        #expect(republished.mediaGrid.sharesContent(with: first.mediaGrid))
        #expect(republished.mediaGrid.detailRefreshGeneration == 2)

        let reordered = windowState(ids: ids.reversed()).sharingUnchanged(with: first)
        #expect(!reordered.mediaGrid.sharesContent(with: first.mediaGrid))
        #expect(reordered.mediaGrid.orderedAssetIDs == ids.reversed())
    }

    /// The same order over other days, or with other stacks, is other content.
    @Test func otherDaysOrStacksAreOtherContent() {
        let ids = makeIDs(2)
        let day = Date(timeIntervalSince1970: 86400)
        let first = windowState(ids: ids, dayBuckets: [day, day]).sharingUnchanged(with: nil)
        let movedDay = windowState(ids: ids, dayBuckets: [day, nil]).sharingUnchanged(with: first)
        #expect(!movedDay.mediaGrid.sharesContent(with: first.mediaGrid))

        var stacked = windowState(ids: ids, dayBuckets: [day, day])
        stacked.mediaGrid.stacks = CatalogGridStacks(tiles: [:], shownForHiddenMember: [makeID("hidden.CR3"): ids[0]])
        #expect(!stacked.sharingUnchanged(with: first).mediaGrid.sharesContent(with: first.mediaGrid))
    }

    /// The content answers positions and membership as the plain order does, keeping an
    /// identity's first position.
    @Test func theContentIndexAnswersAsTheOrderDoes() {
        let ids = makeIDs(5)
        let order = ids + [ids[1]]
        let content = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: order).content
        for id in ids {
            #expect(content.position(of: id) == order.position(of: id))
            #expect(content.contains(id))
        }
        #expect(!content.contains(makeID("absent.jpg")))
        let selected: Set = [ids[4], ids[0], ids[2], makeID("absent.jpg")]
        #expect(content.inDisplayOrder(selected) == order.inDisplayOrder(selected))
        #expect(content.inDisplayOrder(selected) == [ids[0], ids[2], ids[4]])
    }

    // MARK: - Applying keeps the user's place

    /// A republication that moved nothing the user sees keeps the selection and the loupe's
    /// focus; one that dropped the focused item moves focus to its nearest survivor and
    /// prunes the selection (APP-042).
    @Test func aRepublicationKeepsSelectionAndFocusAndAnOrderChangePrunesThem() {
        let model = makeViewModel()
        let ids = makeIDs(6)
        let first = windowState(ids: ids).sharingUnchanged(with: nil)
        model.applyState(first)
        _ = model.applyGridClick(hit: ids[2], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[4], modifiers: [.command], orderedIDs: ids)
        model.openLoupe(id: ids[2])
        #expect(model.focusedAssetID == ids[2])

        let republished = windowState(ids: ids, detailRefresh: 2).sharingUnchanged(with: first)
        model.applyState(republished)
        #expect(model.focusedAssetID == ids[2])
        #expect(model.gridSelection.selection == [ids[2], ids[4]])

        let lost = ids.filter { $0 != ids[2] }
        model.applyState(windowState(ids: lost, detailRefresh: 3).sharingUnchanged(with: republished))
        #expect(model.focusedAssetID == ids[3])
        #expect(model.gridSelection.selection == [ids[3]])
    }

    /// A scope change starts the new scope with nothing selected, even when the new scope
    /// holds the same items (APP-042).
    @Test func aScopeChangeClearsTheSelectionWhateverTheOrder() {
        let model = makeViewModel()
        let ids = makeIDs(3)
        let first = windowState(ids: ids).sharingUnchanged(with: nil)
        model.applyState(first)
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)

        var library = windowState(ids: ids, scope: .library(pictures)).sharingUnchanged(with: first)
        library.queryGeneration = 0
        #expect(library.mediaGrid.sharesContent(with: first.mediaGrid))
        model.applyState(library)
        #expect(model.gridSelection.selection.isEmpty)
    }

    /// A selected file its stack now hides moves to the file shown for it.
    @Test func aSelectionOnAFileAStackNowHidesMovesToTheShownFile() {
        let model = makeViewModel()
        let raw = makeID("IMG_1.CR3")
        let jpeg = makeID("IMG_1.JPG")
        let first = windowState(ids: [raw, jpeg]).sharingUnchanged(with: nil)
        model.applyState(first)
        _ = model.applyGridClick(hit: raw, modifiers: [], orderedIDs: [raw, jpeg])

        var collapsed = windowState(ids: [jpeg], detailRefresh: 2)
        collapsed.mediaGrid.stacks = CatalogGridStacks(tiles: [:], shownForHiddenMember: [raw: jpeg])
        model.applyState(collapsed.sharingUnchanged(with: first))
        #expect(model.gridSelection.selection == [jpeg])
    }

    // MARK: - Titles

    /// Every scope the sidebar can show is titled by its name, from one owner: never the
    /// app's name, never blank once the catalog has loaded.
    @Test func everyScopeHasItsTitle() {
        let card = LibraryRoot(path: LibraryRootPath(rawValue: "/Volumes/EOS_DIGITAL"), kind: .removableVolume, displayName: "EOS_DIGITAL")
        let camera = LibraryRoot(path: LibraryRootPath(rawValue: "mtp://camera"), kind: .deviceMTP, displayName: "X-T5")
        let account = LibraryRoot(path: LibraryRootPath(rawValue: "immich://family"), kind: .immichAccount, displayName: "Family")
        let roots = [LibraryRoot(path: pictures), card, camera, account].map {
            CatalogLibraryState(root: $0, availability: .available, activity: .idle)
        }
        let batch = ImportBatchID(unixMilliseconds: 1_700_000_000_000)
        let digest = ContentDigest(data: Data(repeating: 7, count: ContentDigest.byteCount))
        for scope in Self.scopeSamples(batch: batch, digest: digest) {
            let expected: String = switch scope {
            case .allMedia: "All Media"
            case .places, .mapArea, .mapStack: "Places"
            case .onThisDay: "On This Day"
            case .duplicates, .duplicateGroup: "Duplicates"
            case .people, .person: "People"
            case let .library(path): roots.first { $0.path == path }?.displayName ?? ""
            case .importBatch: ImportBatchFormatting.sidebarTitle(for: batch)
            case .allImports: "All Imports"
            }
            let model = makeViewModel()
            var state = windowState(ids: [], scope: scope)
            state.libraries = roots
            state.title = CatalogWindowPolicy.title(for: scope, libraries: roots)
            model.selectSidebar(scope)
            state.queryGeneration = model.queryGeneration
            model.applyState(state)
            #expect(model.windowTitle == expected, "scope=\(scope.diagnosticDescription)")
            #expect(!model.windowTitle.isEmpty && model.windowTitle != "Otos", "scope=\(scope.diagnosticDescription)")
        }
    }

    /// One sample of every scope; the switch fails to build when a scope is added.
    private static func scopeSamples(batch: ImportBatchID, digest: ContentDigest?) -> [SidebarSelection] {
        let samples: [SidebarSelection] = [
            .allMedia, .places, .mapArea(MapArea(south: 0, north: 1, west: 0, east: 1)),
            .mapStack(MapStack(members: [makeID("a.jpg")])), .onThisDay(CalendarDay(year: 2026, month: 11, day: 14)),
            .duplicates, .duplicateGroup(digest.map { DuplicateGroupID.identical($0, library: nil) } ?? .samePhoto([makeID("a.jpg")])),
            .people, .person(PersonID(rawValue: 1)),
            .library(pictures), .library(LibraryRootPath(rawValue: "/Volumes/EOS_DIGITAL")),
            .library(LibraryRootPath(rawValue: "mtp://camera")), .library(LibraryRootPath(rawValue: "immich://family")),
            .importBatch(batch), .allImports,
        ]
        for sample in samples {
            switch sample {
            case .allMedia, .places, .mapArea, .mapStack, .onThisDay, .duplicates, .duplicateGroup, .people, .person,
                 .library, .importBatch, .allImports:
                break
            }
        }
        return samples
    }

    // MARK: - A scope the user has left does not act

    /// Clicking another row while the duplicates list shows leaves the list on screen until
    /// the new scope publishes; from the click on, neither its Move Copies to Trash nor the
    /// targets of ⌘⌫ act, and once the new scope shows, its own targets do.
    @Test func theDuplicatesListLeftForAnotherRowNoLongerActs() throws {
        let model = makeViewModel()
        let ids = makeIDs(2)
        let copies = ids.enumerated().map { index, id in
            DuplicateCopy(
                id: id, libraryDisplayName: "Pictures", libraryKind: .library, kind: .image, captureLocalTime: nil, byteSize: 1,
                createdAt: Date(timeIntervalSince1970: Double(index)), pixelWidth: 4, pixelHeight: 3,
                mediaChoice: .notRated, isEdited: false, hasCompanions: false
            )
        }
        let digest = try #require(ContentDigest(data: Data(repeating: 7, count: ContentDigest.byteCount)))
        let group = DuplicateGroupPolicy.group(id: .identical(digest, library: nil), copies: copies, keptPairs: [])

        model.selectSidebar(.duplicates)
        var duplicates = windowState(ids: ids, scope: .duplicates)
        duplicates.duplicates = CatalogDuplicatesState(groups: [group])
        duplicates.queryGeneration = model.queryGeneration
        model.applyState(duplicates)
        model.selectDuplicateCopy(ids[0], modifiers: [], orderedIDs: ids)
        #expect(model.showsSelectedScope)
        #expect(model.canMoveDuplicatesToTrash)
        #expect(model.canMoveTargetedMediaToTrash)
        #expect(model.canKeepSelectedDuplicateCopy)

        model.selectSidebar(.allMedia)
        #expect(model.showsDuplicatesList, "the list stays on screen until All Media publishes")
        #expect(!model.showsSelectedScope)
        #expect(!model.canMoveDuplicatesToTrash)
        #expect(!model.canMoveTargetedMediaToTrash)
        #expect(!model.canKeepSelectedDuplicateCopy)
        #expect(model.targetIDs(.current).isEmpty)
        let picks = model.duplicatesSession.picks
        model.duplicatesActions.keep(ids[1])
        #expect(model.duplicatesSession.picks == picks)
        model.duplicatesActions.moveAll()
        #expect(model.mediaTrashTask == nil)

        var allMedia = windowState(ids: ids)
        allMedia.duplicates = duplicates.duplicates
        allMedia.queryGeneration = model.queryGeneration
        model.applyState(allMedia)
        #expect(model.showsSelectedScope)
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)
        #expect(model.targetIDs(.current) == [ids[1]])
        #expect(!model.canMoveDuplicatesToTrash, "the list's act is the list's alone")
    }

    /// A loupe left for People keeps its photo on screen until People publishes, and nothing
    /// in it is a target meanwhile.
    @Test func aLoupeLeftForPeopleHasNoTargets() {
        let model = makeViewModel()
        let ids = makeIDs(3)
        model.applyState(windowState(ids: ids).sharingUnchanged(with: nil))
        model.openLoupe(id: ids[1])
        #expect(model.targetIDs(.current) == [ids[1]])

        model.selectSidebar(.people)
        #expect(model.viewMode == .loupe)
        #expect(model.targetIDs(.current).isEmpty)
        #expect(model.targetIDs(.item(ids[0])).isEmpty)
    }

    /// The grid of the scope left stays on screen, but nothing on it opens, drags out or
    /// edits until the selected scope publishes (APP-080).
    @Test func aGridLeftForAnotherRowOpensDragsAndEditsNothing() {
        let model = makeViewModel()
        let ids = makeIDs(3)
        model.applyState(windowState(ids: ids).sharingUnchanged(with: nil))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        #expect(model.dragWriter(for: ids[0]) != nil)

        model.selectSidebar(.people)
        #expect(!model.showsSelectedScope)
        #expect(model.dragWriter(for: ids[0]) == nil)
        #expect(!model.canEdit)
        model.openLoupe(id: ids[1])
        #expect(model.viewMode == .grid)
        model.enterCompare()
        #expect(model.viewMode == .grid)
        #expect(model.galleryActingPerson == nil)
    }
}

private let pictures = LibraryRootPath(rawValue: "/Users/example/Pictures")

private func makeID(_ path: String) -> MediaAssetID {
    MediaAssetID(libraryRootPath: pictures, relativePath: MediaRelativePath(rawValue: path))
}

private func makeIDs(_ count: Int) -> [MediaAssetID] {
    (0 ..< count).map { makeID("asset-\($0).jpg") }
}

@MainActor
private func makeViewModel() -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        enrichmentCoordinator: nil,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
}

private func windowState(
    ids: [MediaAssetID],
    scope: SidebarSelection = .allMedia,
    dayBuckets: [Date?] = [],
    detailRefresh: UInt64 = 1
) -> CatalogWindowState {
    CatalogWindowState(
        title: "Test",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(
            descriptor: CatalogQueryDescriptor(scope: scope),
            orderedAssetIDs: ids,
            dayBuckets: dayBuckets,
            detailRefreshGeneration: detailRefresh
        ),
        filterOptions: .empty,
        resolvedSidebarSelection: scope,
        mediaEmptyState: ids.isEmpty ? .noMedia : nil,
        deviceConnectionBanner: nil,
        queryGeneration: 0
    )
}
