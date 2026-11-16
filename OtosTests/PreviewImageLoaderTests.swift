import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testDirectory)
struct PreviewImageLoaderTests {
    @Test func datalessPreviewSubmitsInteractiveRequestThenDecodes() async throws {
        let directory = try makeTestDirectory()
        let file = directory.appending(path: "sample.jpg")
        try writeTinyJPEG(to: file)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "sample.jpg")
        )
        let materialized = Mutex(false)
        let status: @Sendable (URL) -> FileMaterializationStatus = { _ in
            materialized.withLock { $0 } ? .materialized : .dataless
        }
        let recorder = PreviewMaterializationRecorder(status: status) {
            materialized.withLock { $0 = true }
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
        }
        let loader = PreviewImageLoader(
            status: status,
            materializationRequester: recorder
        )

        let outcome = await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: 512))
        guard case .image = outcome else {
            Issue.record("Expected image after coordinated materialization")
            return
        }
        let request = try #require(recorder.lastRequest())
        #expect(request.id == id)
        #expect(request.priority == .interactive)
    }

    /// A read-only tour's panes never download: a cloud-only original asked for at full
    /// resolution is refused without a request reaching the coordinator, and the loader
    /// answers `.unavailable`, so the loupe keeps the stored preview it shows.
    @Test func aReadOnlyTourAsksNoDownloadOfACloudOnlyOriginal() async throws {
        let directory = try makeTestDirectory()
        try writeTinyJPEG(to: directory.appending(path: "cloud.jpg"))
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "cloud.jpg")
        )
        let status: @Sendable (URL) -> FileMaterializationStatus = { _ in .dataless }
        let coordinator = PreviewMaterializationRecorder(status: status) {
            Issue.record("A read-only tour must never ask for a download")
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
        }
        let readOnly = ReadOnlyOriginals(coordinator: coordinator)
        #expect(await readOnly.locality(of: id) == .fetchable)
        #expect(await readOnly.ensureLocal(.init(id: id, sourceSize: nil, isVideo: false, priority: .interactive))
            == .notMaterialized(.refusedReadOnly))

        let loader = PreviewImageLoader(status: status, materializationRequester: readOnly)
        let outcome = await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: PreviewImageLoader.fullResolution))
        guard case .unavailable = outcome else {
            Issue.record("Expected no image without a download, got \(outcome)")
            return
        }
        #expect(coordinator.lastRequest() == nil)
        #expect(PaneOriginalDownloads.configured(environment: [SmokeTour.tourVariable: "1"]) == .never)
        #expect(PaneOriginalDownloads.configured(environment: [:]) == .whenNeeded)
    }

    /// An eject quiesces the card's root: a decode already running finishes, a new one
    /// there is refused without reading the file, other roots are untouched, and resume
    /// lets decodes start again.
    @Test func quiescingARootFinishesItsDecodesAndRefusesNewOnesUntilResumed() async throws {
        let directory = try makeTestDirectory()
        try writeTinyJPEG(to: directory.appending(path: "running.jpg"))
        try writeTinyJPEG(to: directory.appending(path: "later.jpg"))
        let root = LibraryRootPath(rawValue: directory.path(percentEncoded: false))
        let running = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "running.jpg"))
        let later = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "later.jpg"))
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
        let materialized = Mutex<Set<String>>([])
        let status: @Sendable (URL) -> FileMaterializationStatus = { url in
            materialized.withLock { $0.contains(url.lastPathComponent) } ? .materialized : .dataless
        }
        let recorder = PreviewMaterializationRecorder(status: status) {
            startedContinuation.yield()
            for await _ in gate {
                break
            }
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
        }
        let loader = PreviewImageLoader(
            status: status,
            materializationRequester: recorder
        )

        let first = Task { await loader.preview(for: .init(id: running, detail: nil, targetLongEdge: 64)) }
        for await _ in started {
            break
        }
        materialized.withLock { _ = $0.insert("running.jpg") }
        let quiesce = Task { await loader.quiesce(under: root) }
        gateContinuation.yield()
        await quiesce.value
        guard case .image = await first.value else {
            Issue.record("A decode already running is finished, never cut short")
            return
        }

        materialized.withLock { _ = $0.insert("later.jpg") }
        guard case .unavailable = await loader.preview(for: .init(id: later, detail: nil, targetLongEdge: 64)) else {
            Issue.record("A decode on a quiesced root is refused")
            return
        }
        await loader.resume(under: root)
        guard case .image = await loader.preview(for: .init(id: later, detail: nil, targetLongEdge: 64)) else {
            Issue.record("Resume lets decodes start again")
            return
        }
    }

    @Test func decodeReportsNativePixelSize() async throws {
        let directory = try makeTestDirectory()
        let file = directory.appending(path: "sample.jpg")
        try writeTinyJPEG(to: file)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "sample.jpg")
        )
        let loader = PreviewImageLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )

        // The fit tier downsamples but still reports the source's native 32 × 24.
        let fit = await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: 16))
        guard case let .image(small, nativePixelSize) = fit else {
            Issue.record("Expected image, got \(String(describing: fit))")
            return
        }
        #expect(nativePixelSize == CGSize(width: 32, height: 24))
        #expect(max(small.width, small.height) <= 16)

        // The full tier decodes at native size and is not served from the smaller cache entry.
        let full = await loader.preview(for: .init(
            id: id,
            detail: nil,
            targetLongEdge: PreviewImageLoader.fullResolution
        ))
        guard case let .image(native, fullNativeSize) = full else {
            Issue.record("Expected full image, got \(String(describing: full))")
            return
        }
        #expect(fullNativeSize == CGSize(width: 32, height: 24))
        #expect(native.width == 32)
        #expect(native.height == 24)
    }

    /// ADR 0035: a cloud-only still with a stored preview opens from the preview with no
    /// download, reporting the original's size from metadata; only a full-resolution
    /// request goes to the original.
    @Test func aStoredPreviewOpensWithoutDownloadingTheOriginal() async throws {
        let directory = try makeTestDirectory()
        let previewName = "stored.heic"
        try writeTinyJPEG(to: directory.appending(path: previewName))
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/cloud"),
            relativePath: MediaRelativePath(rawValue: "remote.arw")
        )
        let detail = MediaTileDetail(
            libraryRootPath: id.libraryRootPath,
            relativePath: id.relativePath,
            previewPath: previewName,
            nativePixelWidth: 6192,
            nativePixelHeight: 4128,
            bestKind: .image
        )
        let materializeCalls = Mutex(0)
        let loader = PreviewImageLoader(
            status: { _ in .dataless },
            derivedImageDirectory: directory,
            materializationRequester: ClosureMaterializationRequester(status: { _ in .dataless }) { _ in
                materializeCalls.withLock { $0 += 1 }
                return MaterializationResult(outcome: .timedOut, rerequestCount: 0, elapsedMs: 1)
            }
        )

        let fit = await loader.preview(for: PreviewImageLoader.Request(id: id, detail: detail, targetLongEdge: 3024))
        guard case let .image(_, nativePixelSize) = fit else {
            Issue.record("Expected the stored preview, got \(String(describing: fit))")
            return
        }
        #expect(nativePixelSize == CGSize(width: 6192, height: 4128))
        let callsAfterFit = materializeCalls.withLock { $0 }
        #expect(callsAfterFit == 0)

        _ = await loader.preview(
            for: PreviewImageLoader.Request(id: id, detail: detail, targetLongEdge: PreviewImageLoader.fullResolution)
        )
        let callsAfterFullResolution = materializeCalls.withLock { $0 }
        #expect(callsAfterFullResolution == 1)
    }

    @Test func datalessReturnsDownloadingWithoutByteRead() async {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/cloud"),
            relativePath: MediaRelativePath(rawValue: "remote.jpg")
        )
        let materializeCalls = Mutex(0)
        let loader = PreviewImageLoader(
            status: { _ in .dataless },
            materializationRequester: ClosureMaterializationRequester(status: { _ in .dataless }) { _ in
                materializeCalls.withLock { $0 += 1 }
                return MaterializationResult(outcome: .timedOut, rerequestCount: 0, elapsedMs: 1)
            }
        )

        let outcome = await loader.preview(
            for: PreviewImageLoader.Request(
                id: id,
                detail: nil,
                targetLongEdge: 512
            )
        )
        guard case .unavailable = outcome else {
            Issue.record("Expected unavailable when materialization produced no bytes")
            return
        }
        #expect(materializeCalls.withLock { $0 } == 1)
    }

    @Test func coalescesConcurrentRequestsForSameID() async throws {
        let directory = try makeTestDirectory()
        let file = directory.appending(path: "sample.jpg")
        try writeTinyJPEG(to: file)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "sample.jpg")
        )

        let loader = PreviewImageLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )

        async let firstLoad = loader.preview(
            for: .init(id: id, detail: nil, targetLongEdge: 256)
        )
        async let secondLoad = loader.preview(
            for: .init(id: id, detail: nil, targetLongEdge: 256)
        )
        let (firstResult, secondResult) = await (firstLoad, secondLoad)
        guard case .image = firstResult, case .image = secondResult else {
            Issue.record("Both requests should decode")
            return
        }
    }

    /// A camera's originals are staged on demand (ADR 0013 decision 5). One never copied,
    /// opened at full resolution in the loupe, is absent from the staging folder, which
    /// the coordinator reads as fetchable rather than missing: it stages it through the
    /// device executor, and the loupe decodes the staged file.
    @Test func unstagedCameraOriginalOpenedAtFullResolutionIsStaged() async throws {
        let staging = try makeTestDirectory().appending(path: "Staging")
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: staging, identity: DeviceIdentity(rawValue: "camera:test"), displayName: "Camera"
        )
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "DCIM/IMG_0001.JPG"))
        let staged = Mutex<[MediaAssetID]>([])
        let coordinator = MaterializationCoordinator(store: store, executor: { request in
            do {
                try FileManager.default.createDirectory(
                    at: request.id.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try writeTinyJPEG(to: request.id.fileURL)
            } catch {
                Issue.record("Staging the test original failed: \(error)")
                return MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0)
            }
            staged.withLock { $0.append(request.id) }
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
        }, volumeCapacity: ampleVolumeCapacity)
        let loader = PreviewImageLoader(materializationRequester: coordinator)

        #expect(await coordinator.locality(of: id) == .fetchable)
        let outcome = await loader.preview(
            for: .init(id: id, detail: nil, targetLongEdge: PreviewImageLoader.fullResolution)
        )
        let afterwards = await coordinator.locality(of: id)
        await coordinator.shutdown()

        guard case .image = outcome else {
            Issue.record("Expected the staged original decoded, got \(outcome)")
            return
        }
        #expect(staged.withLock { $0 } == [id])
        #expect(afterwards == .local)
    }
}

private final class PreviewMaterializationRecorder: MaterializationRequesting, Sendable {
    private let requestStorage = Mutex<MaterializationCoordinator.Request?>(nil)
    private let result: @Sendable () async -> MaterializationResult
    private let status: @Sendable (URL) -> FileMaterializationStatus

    init(
        status: @escaping @Sendable (URL) -> FileMaterializationStatus,
        result: @escaping @Sendable () async -> MaterializationResult
    ) {
        self.status = status
        self.result = result
    }

    func locality(of id: MediaAssetID) async -> OriginalLocality {
        .inPlace(status(id.fileURL))
    }

    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult {
        requestStorage.withLock { $0 = request }
        return await result()
    }

    func lastRequest() -> MaterializationCoordinator.Request? {
        requestStorage.withLock { $0 }
    }
}

private func writeTinyJPEG(to url: URL) throws {
    let context = CGContext(
        data: nil,
        width: 32,
        height: 24,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "PreviewImageLoaderTests", code: 1)
    }
}
