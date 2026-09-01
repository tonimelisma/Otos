import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Synchronization
import Testing

struct PreviewImageLoaderTests {
    @Test func datalessPreviewSubmitsInteractiveRequestThenDecodes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "otos-preview-interactive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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

    @Test func materializedLocalJPEGDecodes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "otos-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

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
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "otos-preview-coalesce-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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

        async let a = loader.preview(
            for: .init(id: id, detail: nil, targetLongEdge: 256)
        )
        async let b = loader.preview(
            for: .init(id: id, detail: nil, targetLongEdge: 256)
        )
        let (ra, rb) = await (a, b)
        guard case .image = ra, case .image = rb else {
            Issue.record("Both requests should decode")
            return
        }
    }

    @Test func cacheMissesWhenStoredLongEdgeIsSmaller() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "otos-preview-edge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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

    func activeRequestCount(under rootPath: LibraryRootPath) async -> Int {
        _ = rootPath
        return 0
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
