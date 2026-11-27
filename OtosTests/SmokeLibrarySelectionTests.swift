import Foundation
@testable import OtosKit
import Testing

/// The smoke seam may steer which root a developer run looks at; it may never
/// change which roots exist. These cover resolution: which requested paths select
/// something, and what an unregistered path reports instead of registering itself.
@Suite(.testScope)
struct SmokeLibrarySelectionTests {
    private func libraryState(
        path: String,
        kind: LibraryRootKind = .library
    ) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(
                path: LibraryRootPath(rawValue: path),
                kind: kind,
                deviceIdentity: nil,
                displayName: (path as NSString).lastPathComponent
            ),
            availability: .available,
            activity: .idle,
            isEjectable: false
        )
    }

    /// The requested path has to be spelled the way `CatalogStore` spells stored
    /// roots — symlinks resolved, trailing slash trimmed — or a registered root can
    /// report as unregistered. Asserted against a real directory rather than a
    /// literal, because the answer depends on how the running machine's filesystem
    /// resolves.
    @Test func configuredRootPathMatchesTheNormalizationStoreUsesForRoots() throws {
        let directory = try makeTestDirectory()
        let expected = try CatalogPath.normalizedDirectoryPath(for: directory)

        let plain = SmokeLibrarySelection.configuredRequest(environment: [
            SmokeLibrarySelection.environmentVariable: directory.path(percentEncoded: false),
        ])
        let trailingSlash = SmokeLibrarySelection.configuredRequest(environment: [
            SmokeLibrarySelection.environmentVariable: directory.path(percentEncoded: false) + "/",
        ])
        let padded = SmokeLibrarySelection.configuredRequest(environment: [
            SmokeLibrarySelection.environmentVariable: "  \(directory.path(percentEncoded: false))  ",
        ])

        #expect(plain == .root(expected))
        #expect(trailingSlash == .root(expected))
        #expect(padded == .root(expected))
    }

    /// `places` is the one non-path request: the Places map, which exists with a fixed
    /// library and nothing else (ADR 0040).
    @Test func placesRequestSelectsTheMapOnlyWithAFixedLibrary() {
        #expect(SmokeLibrarySelection.configuredRequest(environment: [
            SmokeLibrarySelection.environmentVariable: " places ",
        ]) == .places)
        #expect(SmokeLibrarySelection.resolve(
            requested: .places,
            among: [libraryState(path: "/Pictures")]
        ) == .select(.places))
        #expect(SmokeLibrarySelection.resolve(
            requested: .places,
            among: [libraryState(path: "/Volumes/CARD", kind: .removableVolume)]
        ) == .noFixedLibrary(registered: [LibraryRootPath(rawValue: "/Volumes/CARD")]))
        #expect(SmokeLibrarySelection.resolve(requested: .places, among: []) == .noFixedLibrary(registered: []))
    }

    /// `duplicates` selects the Duplicates list once a group is active (ADR 0042); until
    /// then the seam keeps following, since groups arrive as digests do.
    @Test func duplicatesRequestSelectsTheListOnceAGroupIsActive() {
        #expect(SmokeLibrarySelection.configuredRequest(environment: [
            SmokeLibrarySelection.environmentVariable: "duplicates",
        ]) == .duplicates)
        #expect(SmokeLibrarySelection.resolve(requested: .duplicates, among: []) == .noDuplicatesYet)
        #expect(SmokeLibrarySelection.resolve(
            requested: .duplicates, among: [], activeDuplicateGroups: 2
        ) == .select(.duplicates))
    }

    /// The capture seam waits on a published fact: stacks for the map, groups for the
    /// duplicates list, items for a grid.
    @Test func captureIsReadyOnTheFirstStacksOrTheFirstItems() {
        #expect(!SmokeWindowCapture.isReady(showsPlacesMap: true, clusterCount: 0, gridCount: 10))
        #expect(SmokeWindowCapture.isReady(showsPlacesMap: true, clusterCount: 1, gridCount: 0))
        #expect(!SmokeWindowCapture.isReady(showsPlacesMap: false, clusterCount: 0, gridCount: 0))
        #expect(SmokeWindowCapture.isReady(showsPlacesMap: false, clusterCount: 0, gridCount: 3))
        #expect(!SmokeWindowCapture.isReady(
            showsPlacesMap: false, clusterCount: 0, showsDuplicates: true, duplicateGroupCount: 0, gridCount: 3
        ))
        #expect(SmokeWindowCapture.isReady(
            showsPlacesMap: false, clusterCount: 0, showsDuplicates: true, duplicateGroupCount: 1, gridCount: 0
        ))
    }

    /// Alone, the capture path is one PNG of the window as it is; with views it is a folder
    /// the walk fills, view by view, light then dark unless the appearances are named.
    @Test func captureWalksEachViewInEachAppearance() {
        let single = SmokeWindowCapture.plan(environment: [
            SmokeWindowCapture.pathVariable: "/tmp/window.png",
            SmokeWindowCapture.appearanceVariable: "dark",
        ])
        #expect(single == .steps([.init(view: nil, appearance: .dark, path: "/tmp/window.png")]))

        let walk = SmokeWindowCapture.plan(environment: [
            SmokeWindowCapture.pathVariable: "/tmp/captures",
            SmokeWindowCapture.viewsVariable: "library, edit",
        ])
        #expect(walk == .steps([
            .init(view: .library, appearance: .light, path: "/tmp/captures/library-light-rendering.png"),
            .init(view: .library, appearance: .dark, path: "/tmp/captures/library-dark-rendering.png"),
            .init(view: .edit, appearance: .light, path: "/tmp/captures/edit-light-rendering.png"),
            .init(view: .edit, appearance: .dark, path: "/tmp/captures/edit-dark-rendering.png"),
        ]))

        #expect(SmokeWindowCapture.plan(environment: [:]) == SmokeWindowCapture.Plan.none)
        #expect(SmokeWindowCapture.plan(environment: [
            SmokeWindowCapture.pathVariable: "/tmp/captures",
            SmokeWindowCapture.viewsVariable: "people",
        ]) == .invalid("unknownView=people"))
        #expect(SmokeWindowCapture.plan(environment: [
            SmokeWindowCapture.pathVariable: "/tmp/window.png",
            SmokeWindowCapture.appearanceVariable: "light,dark",
        ]) == .invalid("oneAppearanceForOnePath"))
    }

    /// A walk selects a view only once the window's state can show it: nothing while the
    /// catalog loads or before a library is registered (a choice then would stand in for the
    /// launch's default), Duplicates once a group is active.
    @Test func captureSelectsAViewOnceTheStateCanShowIt() {
        let today = CalendarDay(year: 2026, month: 11, day: 27)
        let pictures = LibraryRootPath(rawValue: "/Pictures")
        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: pictures.rawValue)]
        #expect(SmokeWindowCapture.selection(for: .library, in: state, today: today) == nil)

        state.mediaEmptyState = .noMedia
        state.libraries = []
        #expect(SmokeWindowCapture.selection(for: .library, in: state, today: today) == nil)

        state.libraries = [libraryState(path: pictures.rawValue)]
        #expect(SmokeWindowCapture.selection(for: .library, in: state, today: today) == .library(pictures))
        #expect(SmokeWindowCapture.selection(for: .edit, in: state, today: today) == .library(pictures))
        #expect(SmokeWindowCapture.selection(for: .places, in: state, today: today) == .places)
        #expect(SmokeWindowCapture.selection(for: .onThisDay, in: state, today: today) == .onThisDay(today))
        #expect(SmokeWindowCapture.selection(for: .duplicates, in: state, today: today) == nil)
    }

    /// An unregistered path selects nothing and reports what is registered, rather
    /// than making itself registered.
    @Test func unregisteredRootSelectsNothingAndNamesRegisteredRoots() {
        let resolution = SmokeLibrarySelection.resolve(
            requested: .root(LibraryRootPath(rawValue: "/tmp/scratch/smoke-library")),
            among: [libraryState(path: "/Pictures"), libraryState(path: "/Archive")]
        )

        #expect(resolution == .notRegistered(
            requested: LibraryRootPath(rawValue: "/tmp/scratch/smoke-library"),
            registered: [LibraryRootPath(rawValue: "/Archive"), LibraryRootPath(rawValue: "/Pictures")]
        ))
    }

    /// A state still loading the catalog answers nothing; the first loaded one answers.
    @Test func aStateStillLoadingTheCatalogAnswersNothing() {
        let requested = LibraryRootPath(rawValue: "/Pictures")
        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: "/Pictures")]

        #expect(SmokeLibrarySelection.resolution(requested: .root(requested), in: state) == nil)
        state.mediaEmptyState = .noMedia
        #expect(SmokeLibrarySelection.resolution(requested: .root(requested), in: state) == .select(.library(requested)))
        state.libraries = [libraryState(path: "/Other")]
        #expect(SmokeLibrarySelection.resolution(requested: .root(requested), in: state) == .notRegistered(
            requested: requested,
            registered: [LibraryRootPath(rawValue: "/Other")]
        ))
    }

    /// The seam waits on what the window publishes, not on a clock: the first loaded
    /// state that lists the root applies the ordinary sidebar selection.
    @MainActor
    @Test func selectsTheRootFromTheFirstLoadedStateThatListsIt() async throws {
        let directory = try makeTestDirectory()
        let requested = try CatalogPath.normalizedDirectoryPath(for: directory)
        let viewModel = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory, scanCadence: .milliseconds(10)),
            catalogProjection: CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )

        SmokeLibrarySelection.applyIfPresent(to: viewModel, environment: [
            SmokeLibrarySelection.environmentVariable: requested.rawValue,
        ])
        // Two libraries, so the window's own launch default is not the requested root.
        var loading = CatalogWindowState.empty
        loading.libraries = [libraryState(path: "/Other"), libraryState(path: requested.rawValue)]
        viewModel.applyState(loading)

        var loaded = loading
        loaded.mediaEmptyState = .noMedia
        viewModel.applyState(loaded)

        // The seam acts through the ordinary sidebar intent, which records a source
        // choice; once it has, the selection it made is final.
        try await waitUntil { viewModel.userHasChosenSource }
        #expect(viewModel.sidebarSelection == .library(requested))
    }
}
