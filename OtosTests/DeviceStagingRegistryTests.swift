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

    /// The launch backstop. Staging now survives an eject, so anything on disk at
    /// launch belongs to a session that ended — a clean quit already cleared it, and a
    /// crash did not. Without this the cache grows across crashes without bound.
    ///
    /// Sweeps an injected temporary root, never the live one: the first version of
    /// this test called the no-argument overload and deleted the real staged camera
    /// data out of the user's cache when the suite ran.
    @Test func discardAllStagingRemovesEverythingAPreviousSessionLeft() throws {
        let root = try makeCatalogStoreTemporaryDirectory().appending(
            path: "DeviceStaging",
            directoryHint: .isDirectory
        )
        let stale = root.appending(path: "camera-old-session/2020-01-01", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let file = stale.appending(path: "STALE.ARW", directoryHint: .notDirectory)
        try Data(repeating: 1, count: 512).write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

        DeviceStagingRegistry.discardAllStaging(at: root)

        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }
}
