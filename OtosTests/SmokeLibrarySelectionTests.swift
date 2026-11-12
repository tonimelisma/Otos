import Foundation
@testable import OtosKit
import Testing

/// The smoke seam may steer which root a developer run looks at; it may never
/// change which roots exist. These cover resolution: which requested paths select
/// something, and what an unregistered path reports instead of registering itself.
@Suite(.testDirectory)
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
            catalogStore: CatalogStore(location: .inMemory, scanCadence: .milliseconds(10)),
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
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
