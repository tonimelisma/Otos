import Foundation
@testable import Otos
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
}
