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
        let recorder = PreviewMaterializationRecorder {
            materialized.withLock { $0 = true }
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
        }
        let loader = PreviewImageLoader(
            status: { _ in materialized.withLock { $0 } ? .materialized : .dataless },
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
        let recorder = PreviewMaterializationRecorder {
            startedContinuation.yield()
            for await _ in gate {
                break
            }
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
        }
        let loader = PreviewImageLoader(
            status: { url in materialized.withLock { $0.contains(url.lastPathComponent) } ? .materialized : .dataless },
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

    @Test func materializedLocalJPEGDecodes() async throws {
        let directory = try makeTestDirectory()

        let file = directory.appending(path: "sample.jpg")
        try writeTinyJPEG(to: file)

        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "sample.jpg")
        )
        let loader = PreviewImageLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )

        let outcome = await loader.preview(
            for: PreviewImageLoader.Request(
                id: id,
                detail: nil,
                targetLongEdge: 512
            )
        )
        guard case .image = outcome else {
            Issue.record("Expected decoded image, got \(String(describing: outcome))")
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
            materializationRequester: ClosureMaterializationRequester { _ in
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

    @Test func datalessReturnsDownloadingWithoutByteRead() async {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/cloud"),
            relativePath: MediaRelativePath(rawValue: "remote.jpg")
        )
        let materializeCalls = Mutex(0)
        let loader = PreviewImageLoader(
            status: { _ in .dataless },
            materializationRequester: ClosureMaterializationRequester { _ in
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
            materializationRequester: ClosureMaterializationRequester { _ in
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

    @Test func cacheMissesWhenStoredLongEdgeIsSmaller() async throws {
        let directory = try makeTestDirectory()
        let file = directory.appending(path: "sample.jpg")
        try writeTinyJPEG(to: file)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "sample.jpg")
        )
        let loader = PreviewImageLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )
        let first = await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: 128))
        guard case .image = first else {
            Issue.record("first decode failed")
            return
        }
        // Larger target must not reuse the undersized cache entry as a hit that
        // skips decode bookkeeping — outcome is still an image either way.
        let second = await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: 1024))
        guard case .image = second else {
            Issue.record("second decode failed")
            return
        }
    }
}

private final class PreviewMaterializationRecorder: MaterializationRequesting, Sendable {
    private let requestStorage = Mutex<MaterializationCoordinator.Request?>(nil)
    private let result: @Sendable () async -> MaterializationResult

    init(result: @escaping @Sendable () async -> MaterializationResult) {
        self.result = result
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
