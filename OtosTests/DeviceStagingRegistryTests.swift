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

    /// The launch backstop. Staging survives an eject, so anything on disk at launch
    /// belongs to a session that ended — a clean quit already cleared its own tree, and a
    /// crash did not. Without this the cache grows across crashes without bound.
    ///
    /// Sweeps an injected container, never the live one: the first version of this test
    /// called a no-argument overload and deleted the real staged camera data out of the
    /// user's cache when the suite ran. Every destructive entry point here takes the
    /// container for that reason.
    @Test func theLaunchSweepRemovesTreesLeftByEndedSessions() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let stale = container.appending(path: "old-instance/camera-1/2020-01-01", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let file = stale.appending(path: "STALE.ARW", directoryHint: .notDirectory)
        try Data(repeating: 1, count: 512).write(to: file)

        DeviceStagingLocation.sweepForeignInstanceStaging(inContainer: container)

        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    /// A4. The previous sweep deleted the whole container, so a second running instance
    /// lost the card it was mid-transfer on. Two instances ran on this machine on
    /// 2026-08-30 and the second would have destroyed the first's staging.
    @Test func theLaunchSweepLeavesThisInstancesOwnTreeAlone() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let mine = DeviceStagingLocation.instanceRootURL(inContainer: container)
            .appending(path: "camera-live", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let inFlight = mine.appending(path: "DSC00001.ARW", directoryHint: .notDirectory)
        try Data(repeating: 9, count: 256).write(to: inFlight)

        let foreign = container.appending(path: "some-other-instance", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

        DeviceStagingLocation.sweepForeignInstanceStaging(inContainer: container)

        #expect(
            FileManager.default.fileExists(atPath: inFlight.path(percentEncoded: false)),
            "the sweep must never delete bytes this instance is still transferring"
        )
        #expect(!FileManager.default.fileExists(atPath: foreign.path(percentEncoded: false)))
    }

    /// A2. Quit clears this instance's tree — owner decision 2026-08-30 — and only this
    /// instance's.
    @Test func quitDiscardsThisInstancesStagingAndNothingElse() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let mine = DeviceStagingLocation.instanceRootURL(inContainer: container)
            .appending(path: "camera-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 128).write(to: mine.appending(path: "A.ARW", directoryHint: .notDirectory))

        let peer = container.appending(path: "peer-instance/camera-2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
        let peerFile = peer.appending(path: "B.ARW", directoryHint: .notDirectory)
        try Data(repeating: 4, count: 128).write(to: peerFile)

        #expect(DeviceStagingLocation.hasStagedBytes(inContainer: container))
        DeviceStagingLocation.discardInstanceStaging(inContainer: container)

        #expect(!DeviceStagingLocation.hasStagedBytes(inContainer: container))
        #expect(
            FileManager.default.fileExists(atPath: peerFile.path(percentEncoded: false)),
            "quit clears our own cache, not a peer instance's"
        )
    }

    /// Quit defers termination and shows a clearing window; doing that when nothing is
    /// staged would add a flash and a delay to every quit, and most sessions never attach
    /// a camera at all.
    @Test func aSessionThatStagedNothingHasNothingToClear() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        #expect(!DeviceStagingLocation.hasStagedBytes(inContainer: container))
    }

    /// A1's guard. The release intent takes a path, and a path wrong by one component
    /// would be a delete inside the user's own media — which Otos never does. Containment
    /// is proven, not assumed.
    @Test func onlyPathsInsideThisInstancesStagingCountAsReleasable() throws {
        let container = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let inside = DeviceStagingLocation.instanceRootURL(inContainer: container)
            .appending(path: "camera-1/DSC00001.ARW", directoryHint: .notDirectory)
        #expect(DeviceStagingLocation.isInsideInstanceStaging(inside, inContainer: container))

        let userMedia = URL(fileURLWithPath: "/Users/someone/Pictures/DSC00001.ARW")
        #expect(!DeviceStagingLocation.isInsideInstanceStaging(userMedia, inContainer: container))

        let peer = container.appending(path: "peer-instance/camera-1/DSC.ARW", directoryHint: .notDirectory)
        #expect(!DeviceStagingLocation.isInsideInstanceStaging(peer, inContainer: container))

        // A sibling directory whose name merely starts with the instance id must not match.
        let neighbour = container
            .appending(path: DeviceStagingLocation.instanceID + "-other", directoryHint: .isDirectory)
            .appending(path: "DSC.ARW", directoryHint: .notDirectory)
        #expect(!DeviceStagingLocation.isInsideInstanceStaging(neighbour, inContainer: container))
    }
}
