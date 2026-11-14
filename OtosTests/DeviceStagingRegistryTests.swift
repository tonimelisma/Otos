import Foundation
@testable import OtosKit
import Testing

/// Serialized because the state under test is genuinely process-global: `StagingLocation`
/// keeps one `flock` table for the whole app instance, and `releaseOwnership()` releases *every*
/// claim in it — correct for the app-quit path it exists to serve, and unusable concurrently.
///
/// Run in parallel, one test's cleanup revokes another's claim, the sweep can then take that
/// tree's lock, and it is deleted. Observed 2026-09-01 as a flaky failure of
/// `theSweepLeavesATreeALiveInstanceHolds`, which had passed in the preceding runs.
@Suite(.serialized, .testDirectory)
struct DeviceStagingRegistryTests {
    /// `stagingRootURL` is a directory URL, so its path already ends in "/". Appending
    /// another produced a "…/root//" prefix that no requested path could match, so
    /// every camera file fell through to the cloud materialization path and failed
    /// there as a permission error on a path that does not exist. MTP staging was
    /// silently impossible; the misleading error is what made it look environmental.
    @Test func aDirectoryStyleStagingRootStillMatchesItsFiles() {
        let rootWithSlash = URL(fileURLWithPath: "/tmp/Staging/camera-1", isDirectory: true)
        #expect(rootWithSlash.path(percentEncoded: false).hasSuffix("/"))
        let file = rootWithSlash.appending(path: "2026-08-20/DSC08809.ARW", directoryHint: .notDirectory)

        let relative = DeviceStagingRegistry.stagingRelativePath(of: file, under: rootWithSlash)
        #expect(relative == "2026-08-20/DSC08809.ARW")
    }

    @Test func aPathOutsideTheRootDoesNotMatch() {
        let root = URL(fileURLWithPath: "/tmp/Staging/camera-1", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/Staging/camera-2/2026-08-20/DSC08809.ARW")
        #expect(DeviceStagingRegistry.stagingRelativePath(of: outside, under: root) == nil)
        // A sibling whose name merely starts the same must not match either.
        let prefixNeighbour = URL(fileURLWithPath: "/tmp/Staging/camera-10/IMG.ARW")
        #expect(DeviceStagingRegistry.stagingRelativePath(of: prefixNeighbour, under: root) == nil)
    }

    /// Staged bytes must outlive an eject and be reused on the next attach — they are
    /// already off the camera, so re-downloading them costs the whole device again.
    /// `detachRemovableSource` is the same path the camera monitor drives when the
    /// device physically leaves the bus, so this covers the real eject without one.
    @Test func stagedBytesSurviveDetachAndAreStillThereOnReattach() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/camera-reuse", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staged = stagingRoot.appending(path: "2026-08-20/DSC00001.ARW", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: 2048).write(to: staged)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        _ = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: .camera(id: "reuse"),
            displayName: "Camera"
        )

        try await store.detachRemovableSource(identity: .camera(id: "reuse"), reason: .disconnected)
        #expect(
            FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)),
            "an eject discarded bytes that were already transferred off the camera"
        )

        _ = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: .camera(id: "reuse"),
            displayName: "Camera"
        )
        #expect(
            FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)),
            "re-attaching must reuse staged bytes rather than start from empty"
        )
    }

    /// The invariant the per-instance path broke. Asset identity *is* the filesystem path,
    /// so a staging root that changed per launch made every camera item a new asset each
    /// run and recreated all overlay keyed to it — catalog rows, and thumbnails whose names
    /// hash the root. Measured on a 991-item card: 9,997 thumbnail files against 9,304 rows.
    @Test func acameraGetsTheSamePathOnEveryLaunch() throws {
        let container = try makeTestDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let first = StagingLocation.sessionRootURL(identity: .camera(id: "abc"), inContainer: container)
        let second = StagingLocation.sessionRootURL(identity: .camera(id: "abc"), inContainer: container)

        #expect(first == second, "a camera's staging path must not depend on which process asked")
        #expect(
            first != StagingLocation.sessionRootURL(identity: .camera(id: "xyz"), inContainer: container),
            "different cameras must still get different trees"
        )
    }

    /// The launch backstop: a tree whose owner is gone is collected. Ownership is asked of
    /// the kernel rather than encoded in a name, so nothing has to be reconciled.
    @Test func theSweepRemovesTreesNoLiveInstanceHolds() throws {
        let container = try makeTestDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let stale = StagingLocation.sessionRootURL(identity: .camera(id: "ended"), inContainer: container)
            .appending(path: "2020-01-01", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let file = stale.appending(path: "STALE.ARW", directoryHint: .notDirectory)
        try Data(repeating: 1, count: 512).write(to: file)

        StagingLocation.sweepUnownedStaging(inContainers: [container])

        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    /// And the reason ownership exists at all: a sweep must not delete what a live instance
    /// is still transferring into. Two instances ran on this machine on 2026-08-30, and a
    /// whole-container delete would have destroyed the first's card transfer.
    @Test func theSweepLeavesATreeALiveInstanceHolds() throws {
        let container = try makeTestDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        #expect(StagingLocation.claimOwnership(identity: .camera(id: "live"), inContainer: container))
        defer { StagingLocation.releaseOwnership() }

        let held = StagingLocation.sessionRootURL(identity: .camera(id: "live"), inContainer: container)
        let inFlight = held.appending(path: "DSC00001.ARW", directoryHint: .notDirectory)
        try Data(repeating: 9, count: 256).write(to: inFlight)

        StagingLocation.sweepUnownedStaging(inContainers: [container])

        #expect(
            FileManager.default.fileExists(atPath: inFlight.path(percentEncoded: false)),
            "a claimed tree must survive a sweep — those bytes are being written right now"
        )
    }

    /// Quit is the same operation as the backstop: release the claims, then sweep. An
    /// instance that has let go of its locks is indistinguishable from one that has exited.
    @Test func quitReleasesItsClaimsAndThenClearsThem() throws {
        let container = try makeTestDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        StagingLocation.claimOwnership(identity: .camera(id: "quitting"), inContainer: container)
        let root = StagingLocation.sessionRootURL(identity: .camera(id: "quitting"), inContainer: container)
        let staged = root.appending(path: "A.ARW", directoryHint: .notDirectory)
        try Data(repeating: 3, count: 128).write(to: staged)
        #expect(StagingLocation.hasStagedBytes(inContainers: [container]))

        StagingLocation.releaseOwnership()
        StagingLocation.sweepUnownedStaging(inContainers: [container])

        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
    }

    /// An Immich account's tree is claimed while this process holds the account, signed in
    /// or not, so another instance's sweep never deletes the originals it staged; forgetting
    /// the account releases the claim, and the sweep then collects the tree.
    @Test func anImmichAccountHoldsItsTreeUntilItIsForgotten() async throws {
        struct NoSessions: ImmichSessionStoring {
            func saveToken(_: String, for _: DeviceIdentity) throws {}
            func token(for _: DeviceIdentity) throws -> String? {
                nil
            }

            func deleteToken(for _: DeviceIdentity) throws {}
        }
        let containers = try StagingContainers(base: makeTestDirectory())
        let container = containers.url(.remote)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: containers)
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "user-1", displayName: "Family"
        )
        let staged = rootPath.url.appending(path: "a1/IMG_1.JPG", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 5, count: 64).write(to: staged)
        let accounts = ImmichAccounts(
            store: store, sessions: NoSessions(), volumeCapacity: ampleVolumeCapacity
        )

        await accounts.start()
        StagingLocation.sweepUnownedStaging(inContainers: [container])
        #expect(FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))

        let root = try #require(await store.currentLibraries().first { $0.path == rootPath }?.root)
        await accounts.forget(root)
        StagingLocation.sweepUnownedStaging(inContainers: [container])
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        await accounts.shutdown()
        await store.shutdown()
    }

    /// Attaching a camera creates its tree whether or not anything is staged into it, and
    /// since ranged reads became the normal path that is the common case. Counting directory
    /// entries made quit defer termination and show a clearing window to delete nothing.
    @Test func anEmptyClaimedTreeIsNotStagedBytes() throws {
        let container = try makeTestDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        StagingLocation.claimOwnership(identity: .camera(id: "empty"), inContainer: container)
        defer { StagingLocation.releaseOwnership() }

        #expect(
            !StagingLocation.hasStagedBytes(inContainers: [container]),
            "directories alone are not bytes; quitting must not defer to delete nothing"
        )
    }

    /// A1's guard: a release path outside staging is refused, never followed. The intent
    /// takes a path, and a path wrong by one component would be a delete inside the user's
    /// own media.
    @Test func onlyPathsInsideStagingCountAsReleasable() throws {
        let container = try makeTestDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let inside = StagingLocation.sessionRootURL(identity: .camera(id: "a"), inContainer: container)
            .appending(path: "DSC00001.ARW", directoryHint: .notDirectory)
        #expect(StagingLocation.isInsideStaging(inside, inContainers: [container]))

        #expect(!StagingLocation.isInsideStaging(
            URL(fileURLWithPath: "/Users/someone/Pictures/DSC00001.ARW"), inContainers: [container]
        ))
        #expect(!StagingLocation.isInsideStaging(
            container.deletingLastPathComponent().appending(path: "Elsewhere/DSC.ARW"), inContainers: [container]
        ))
    }

    /// A downloaded original that cannot be placed leaves no file behind: not when the
    /// destination is outside its staging root, and not when a step of the place fails.
    @Test func aPlaceThatFailsDeletesTheDownload() async throws {
        let container = try makeTestDirectory()
        let stagingRoot = container.appending(path: "account", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        func downloaded() throws -> URL {
            let file = container.appending(path: "download-\(UUID().uuidString).tmp")
            try Data("bytes".utf8).write(to: file)
            return file
        }

        let outside = try downloaded()
        await #expect(throws: (any Error).self) {
            try await StagingLocation.placeDownloaded(
                outside, at: container.appending(path: "Elsewhere/IMG.JPG"), inside: stagingRoot
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))

        // The asset's folder is a file, so the folder cannot be made.
        let blocker = stagingRoot.appending(path: "asset")
        try Data().write(to: blocker)
        let blocked = try downloaded()
        await #expect(throws: (any Error).self) {
            try await StagingLocation.placeDownloaded(
                blocked, at: blocker.appending(path: "IMG.JPG"), inside: stagingRoot
            )
        }
        #expect(!FileManager.default.fileExists(atPath: blocked.path(percentEncoded: false)))
        let left = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path(percentEncoded: false))
        #expect(left == ["asset"])
    }
}
