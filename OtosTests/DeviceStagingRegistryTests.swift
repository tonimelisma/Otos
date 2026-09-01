import Foundation
@testable import OtosKit
import Testing

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
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            identity: "camera:reuse",
            displayName: "Camera"
        )

        try await store.detachRemovableSource(identity: "camera:reuse", reason: .disconnected)
        #expect(
            FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)),
            "an eject discarded bytes that were already transferred off the camera"
        )

        _ = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: "camera:reuse",
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
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let first = DeviceStagingLocation.sessionRootURL(identity: "camera:abc", inContainer: container)
        let second = DeviceStagingLocation.sessionRootURL(identity: "camera:abc", inContainer: container)

        #expect(first == second, "a camera's staging path must not depend on which process asked")
        #expect(
            first != DeviceStagingLocation.sessionRootURL(identity: "camera:xyz", inContainer: container),
            "different cameras must still get different trees"
        )
    }

    /// The launch backstop: a tree whose owner is gone is collected. Ownership is asked of
    /// the kernel rather than encoded in a name, so nothing has to be reconciled.
    @Test func theSweepRemovesTreesNoLiveInstanceHolds() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let stale = DeviceStagingLocation.sessionRootURL(identity: "camera:ended", inContainer: container)
            .appending(path: "2020-01-01", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let file = stale.appending(path: "STALE.ARW", directoryHint: .notDirectory)
        try Data(repeating: 1, count: 512).write(to: file)

        DeviceStagingLocation.sweepUnownedStaging(inContainer: container)

        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    /// And the reason ownership exists at all: a sweep must not delete what a live instance
    /// is still transferring into. Two instances ran on this machine on 2026-08-30, and a
    /// whole-container delete would have destroyed the first's card transfer.
    @Test func theSweepLeavesATreeALiveInstanceHolds() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        #expect(DeviceStagingLocation.claimOwnership(identity: "camera:live", inContainer: container))
        defer { DeviceStagingLocation.releaseOwnership() }

        let held = DeviceStagingLocation.sessionRootURL(identity: "camera:live", inContainer: container)
        let inFlight = held.appending(path: "DSC00001.ARW", directoryHint: .notDirectory)
        try Data(repeating: 9, count: 256).write(to: inFlight)

        DeviceStagingLocation.sweepUnownedStaging(inContainer: container)

        #expect(
            FileManager.default.fileExists(atPath: inFlight.path(percentEncoded: false)),
            "a claimed tree must survive a sweep — those bytes are being written right now"
        )
    }

    /// Quit is the same operation as the backstop: release the claims, then sweep. An
    /// instance that has let go of its locks is indistinguishable from one that has exited.
    @Test func quitReleasesItsClaimsAndThenClearsThem() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        DeviceStagingLocation.claimOwnership(identity: "camera:quitting", inContainer: container)
        let root = DeviceStagingLocation.sessionRootURL(identity: "camera:quitting", inContainer: container)
        let staged = root.appending(path: "A.ARW", directoryHint: .notDirectory)
        try Data(repeating: 3, count: 128).write(to: staged)
        #expect(DeviceStagingLocation.hasStagedBytes(inContainer: container))

        DeviceStagingLocation.releaseOwnership()
        DeviceStagingLocation.sweepUnownedStaging(inContainer: container)

        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
    }

    /// Attaching a camera creates its tree whether or not anything is staged into it, and
    /// since ranged reads became the normal path that is the common case. Counting directory
    /// entries made quit defer termination and show a clearing window to delete nothing.
    @Test func anEmptyClaimedTreeIsNotStagedBytes() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        DeviceStagingLocation.claimOwnership(identity: "camera:empty", inContainer: container)
        defer { DeviceStagingLocation.releaseOwnership() }

        #expect(
            !DeviceStagingLocation.hasStagedBytes(inContainer: container),
            "directories alone are not bytes; quitting must not defer to delete nothing"
        )
    }

    /// A1's guard: a release path outside staging is refused, never followed. The intent
    /// takes a path, and a path wrong by one component would be a delete inside the user's
    /// own media.
    @Test func onlyPathsInsideStagingCountAsReleasable() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let inside = DeviceStagingLocation.sessionRootURL(identity: "camera:a", inContainer: container)
            .appending(path: "DSC00001.ARW", directoryHint: .notDirectory)
        #expect(DeviceStagingLocation.isInsideStaging(inside, inContainer: container))

        #expect(!DeviceStagingLocation.isInsideStaging(
            URL(fileURLWithPath: "/Users/someone/Pictures/DSC00001.ARW"), inContainer: container
        ))
        #expect(!DeviceStagingLocation.isInsideStaging(
            container.deletingLastPathComponent().appending(path: "Elsewhere/DSC.ARW"), inContainer: container
        ))
    }
}
