import Foundation
@testable import OtosKit
import Testing

/// The smoke seam may steer which root a developer run looks at; it may never
/// change which roots exist. These cover resolution: which requested paths select
/// something, and what an unregistered path reports instead of registering itself.
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
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "SmokeSelection-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = try CatalogPath.normalizedDirectoryPath(for: directory)

        let plain = SmokeLibrarySelection.configuredRootPath(environment: [
            SmokeLibrarySelection.environmentVariable: directory.path(percentEncoded: false),
        ])
        let trailingSlash = SmokeLibrarySelection.configuredRootPath(environment: [
            SmokeLibrarySelection.environmentVariable: directory.path(percentEncoded: false) + "/",
        ])
        let padded = SmokeLibrarySelection.configuredRootPath(environment: [
            SmokeLibrarySelection.environmentVariable: "  \(directory.path(percentEncoded: false))  ",
        ])

        #expect(plain == expected)
        #expect(trailingSlash == expected)
        #expect(padded == expected)
    }

    /// A tilde is expanded rather than treated as a relative path component.
    @Test func configuredRootPathExpandsTilde() throws {
        let path = try #require(SmokeLibrarySelection.configuredRootPath(environment: [
            SmokeLibrarySelection.environmentVariable: "~",
        ]))
        let home = try CatalogPath.normalizedDirectoryPath(
            for: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )

        #expect(path == home)
        #expect(path.rawValue.hasPrefix("/"))
    }

    @Test func configuredRootPathIgnoresMissingOrEmptyEnvironment() {
        #expect(SmokeLibrarySelection.configuredRootPath(environment: [:]) == nil)
        #expect(SmokeLibrarySelection.configuredRootPath(environment: [
            SmokeLibrarySelection.environmentVariable: "  ",
        ]) == nil)
    }

    @Test func registeredRootResolvesToTheOrdinarySidebarSelection() {
        let requested = LibraryRootPath(rawValue: "/Pictures")

        let resolution = SmokeLibrarySelection.resolve(
            requested: requested,
            among: [libraryState(path: "/Other"), libraryState(path: "/Pictures")]
        )

        #expect(resolution == .select(.library(requested)))
    }

    /// A connected card is selectable exactly like a fixed library is.
    @Test func registeredRemovableSourceIsSelectable() {
        let requested = LibraryRootPath(rawValue: "/Volumes/Card")

        let resolution = SmokeLibrarySelection.resolve(
            requested: requested,
            among: [libraryState(path: "/Volumes/Card", kind: .removableVolume)]
        )

        #expect(resolution == .select(.library(requested)))
    }

    /// An unregistered path selects nothing and reports what is registered, rather
    /// than making itself registered.
    @Test func unregisteredRootSelectsNothingAndNamesRegisteredRoots() {
        let resolution = SmokeLibrarySelection.resolve(
            requested: LibraryRootPath(rawValue: "/tmp/scratch/smoke-library"),
            among: [libraryState(path: "/Pictures"), libraryState(path: "/Archive")]
        )

        #expect(resolution == .notRegistered(
            requested: LibraryRootPath(rawValue: "/tmp/scratch/smoke-library"),
            registered: [LibraryRootPath(rawValue: "/Archive"), LibraryRootPath(rawValue: "/Pictures")]
        ))
    }

    @Test func noKnownSourcesYetStillReportsNotRegistered() {
        let resolution = SmokeLibrarySelection.resolve(
            requested: LibraryRootPath(rawValue: "/Pictures"),
            among: []
        )

        #expect(resolution == .notRegistered(
            requested: LibraryRootPath(rawValue: "/Pictures"),
            registered: []
        ))
    }

    /// A state still loading the catalog answers nothing; the first loaded one answers.
    @Test func aStateStillLoadingTheCatalogAnswersNothing() {
        let requested = LibraryRootPath(rawValue: "/Pictures")
        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: "/Pictures")]

        #expect(SmokeLibrarySelection.resolution(requested: requested, in: state) == nil)
        state.mediaEmptyState = .noMedia
        #expect(SmokeLibrarySelection.resolution(requested: requested, in: state) == .select(.library(requested)))
        state.libraries = [libraryState(path: "/Other")]
        #expect(SmokeLibrarySelection.resolution(requested: requested, in: state) == .notRegistered(
            requested: requested,
            registered: [LibraryRootPath(rawValue: "/Other")]
        ))
    }

    /// The seam waits on what the window publishes, not on a clock: the first loaded
    /// state that lists the root applies the ordinary sidebar selection.
    @MainActor
    @Test func selectsTheRootFromTheFirstLoadedStateThatListsIt() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "SmokeSelection-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = try CatalogPath.normalizedDirectoryPath(for: directory)
        let viewModel = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory, scanCadence: .milliseconds(10)),
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString)
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

        try await waitUntil { viewModel.sidebarSelection == .library(requested) }
    }
}
