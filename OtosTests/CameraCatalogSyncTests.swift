import Foundation
@testable import OtosKit
import Testing

/// APP-018: a connected camera's catalog follows the camera. Each change the camera
/// reports runs one more pass: new items are recorded, staged and thumbnailed once,
/// and an item the camera no longer lists is removed only when the list held still.
@Suite(.testDirectory)
@MainActor
struct CameraCatalogSyncTests {
    @Test func aConnectedCameraStaysInStepWithItsCard() async throws {
        let fixture = try await Fixture(passes: [
            Fixture.snapshot(["A.JPG", "B.JPG"], isStable: true),
            Fixture.snapshot(["A.JPG", "B.JPG", "C.JPG"], isStable: true),
            // The list is still changing: what it shows is recorded, nothing is deleted.
            Fixture.snapshot(["A.JPG", "C.JPG", "D.JPG"], isStable: false),
            Fixture.snapshot(["A.JPG", "C.JPG", "D.JPG"], isStable: true),
        ])
        let run = Task { await fixture.sync.run() }
        defer { run.cancel() }
        let rootPath = try await fixture.rootPath()

        try await fixture.waitForThumbnailRequests(["A.JPG", "B.JPG"])
        #expect(try await fixture.paths(rootPath) == ["A.JPG", "B.JPG"])

        fixture.camera.reportChange()
        try await fixture.waitForThumbnailRequests(["A.JPG", "B.JPG", "C.JPG"])
        #expect(try await fixture.paths(rootPath) == ["A.JPG", "B.JPG", "C.JPG"])

        fixture.camera.reportChange()
        try await fixture.waitForThumbnailRequests(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        #expect(
            try await fixture.paths(rootPath) == ["A.JPG", "B.JPG", "C.JPG", "D.JPG"],
            "an unstable list proves no deletion"
        )

        fixture.camera.reportChange()
        try await waitUntil { try await fixture.paths(rootPath) == ["A.JPG", "C.JPG", "D.JPG"] }

        #expect(fixture.stagedBatches.values == [["A.JPG", "B.JPG"], ["C.JPG"], ["D.JPG"]], "each item is staged once")
        #expect(fixture.camera.rangedReadProbes == 1, "the ranged-read probe runs once per attach")
        #expect(fixture.rangeCapableRoots.values == [rootPath])
    }

    /// Fixture: an in-memory store, a scripted camera, and recorders for what the sync
    /// asks of enrichment.
    @MainActor
    private struct Fixture {
        let store: CatalogStore
        let camera: ScriptedCamera
        let sync: CameraCatalogSync
        let stagedBatches = TestRecorder<[String]>()
        let rangeCapableRoots = TestRecorder<LibraryRootPath>()

        init(passes: [DeviceCameraCatalogSnapshot]) async throws {
            let temp = try makeTestDirectory()
            store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
            try await store.start(scansSavedLibraries: false)
            camera = ScriptedCamera(
                stagingRootURL: temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory),
                passes: passes
            )
            let staged = stagedBatches
            let rangeCapable = rangeCapableRoots
            sync = CameraCatalogSync(
                source: camera,
                store: store,
                enrichment: CameraCatalogSync.Enrichment(
                    markRangeCapable: { rangeCapable.record($0) },
                    stage: { seeds in staged.record(seeds.map(\.id.relativePath.rawValue)) }
                ),
                thumbnailDirectory: temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
            )
        }

        static func snapshot(_ names: [String], isStable: Bool) -> DeviceCameraCatalogSnapshot {
            DeviceCameraCatalogSnapshot(
                items: names.map { name in
                    DeviceCameraCatalogItem(
                        relativePath: MediaRelativePath(rawValue: name),
                        name: name,
                        contentTypeIdentifier: "public.jpeg",
                        byteSize: 1024,
                        captureDate: Date(timeIntervalSince1970: 1000),
                        modificationDate: Date(timeIntervalSince1970: 1000)
                    )
                },
                companions: [],
                isStable: isStable
            )
        }

        func rootPath() async throws -> LibraryRootPath {
            try await waitForValue {
                try await catalogStoreTestState(store).removableSources.first { $0.root.kind == .deviceMTP }?.path
            }
        }

        func paths(_ rootPath: LibraryRootPath) async throws -> [String] {
            let ids = try await store.orderedAssetIDs(for: .library(rootPath), availableLibraryPaths: [rootPath])
            let assets = try await store.mediaAssets(for: ids)
            return ids.compactMap { assets[$0]?.relativePath.rawValue }.sorted()
        }

        /// The sync asks for thumbnails last in a pass, after recording and the deletion
        /// decision, so a request for a pass's new items marks that pass as decided.
        func waitForThumbnailRequests(_ names: [String]) async throws {
            try await waitUntil { camera.thumbnailRequests.values.sorted() == names }
        }
    }
}

/// A camera whose list is scripted pass by pass. `reportChange()` stands in for
/// ImageCaptureCore's add/remove reports.
@MainActor
private final class ScriptedCamera: CameraCatalogSource {
    let identity = DeviceIdentity.camera(id: "scripted")
    let displayName = "Camera"
    let stagingRootURL: URL
    let catalogChanges: AsyncStream<Void>
    let thumbnailRequests = TestRecorder<String>()
    private(set) var rangedReadProbes = 0
    private let bell: AsyncStream<Void>.Continuation
    private var passes: [DeviceCameraCatalogSnapshot]

    init(stagingRootURL: URL, passes: [DeviceCameraCatalogSnapshot]) {
        self.stagingRootURL = stagingRootURL
        self.passes = passes
        (catalogChanges, bell) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func reportChange() {
        bell.yield()
    }

    func catalogSnapshot() async throws -> DeviceCameraCatalogSnapshot {
        passes.count > 1 ? passes.removeFirst() : passes[0]
    }

    func thumbnailData(for relativePath: MediaRelativePath, maxPixelSize: Int) async throws -> Data? {
        thumbnailRequests.record(relativePath.rawValue)
        return nil
    }

    func answersRangedReads(relativePath: MediaRelativePath, size: UInt64) async -> Bool {
        rangedReadProbes += 1
        return true
    }
}
