import Foundation
@testable import OtosKit
import Testing

/// The window's composition of camera monitoring (APP-018): the monitor the view model builds
/// stages each camera under the catalog's own containers (`CatalogStore.stagingContainers`),
/// so the root the Store loads for a remembered camera is the folder a returning camera's
/// session stages into.
@Suite(.testDirectory)
@MainActor
struct CameraStagingCompositionTests {
    @Test func theWindowsCameraMonitorStagesWhereTheStoreLoadsTheCamera() async throws {
        let temp = try makeTestDirectory()
        let database = temp.appending(path: "catalog.sqlite")
        let containers = StagingContainers(base: temp.appending(path: "Containers", directoryHint: .isDirectory))
        let camera = DeviceIdentity.camera(id: "serial")
        let first = CatalogStore(location: .databaseFile(database), stagingContainers: containers)
        try await first.start(scansSavedLibraries: false)
        _ = try await first.attachDeviceMTP(
            stagingRootURL: containers.sessionRoot(in: .device, identity: camera), identity: camera, displayName: "Camera"
        )
        try await first.detachRemovableSource(identity: camera, reason: .disconnected)
        await first.shutdown()

        let store = CatalogStore(location: .databaseFile(database), stagingContainers: containers)
        try await store.start(scansSavedLibraries: false)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )

        let monitor = model.makeCameraSourceMonitor()
        let staged = try CatalogPath.normalizedDirectoryPath(for: monitor.stagingRoot(for: camera))
        #expect(try await catalogStoreTestState(store).removableSources.map(\.path) == [staged])
        #expect(staged.rawValue.hasPrefix(containers.base.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)))
        await store.shutdown()
    }
}
