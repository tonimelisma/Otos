import CoreGraphics
import Foundation
import ImageIO
@testable import Otos
import Synchronization
import Testing

struct PreviewImageLoaderTests {
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
            materialize: { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )

        let result = await loader.preview(
            for: PreviewImageLoader.Request(
                id: id,
                detail: nil,
                targetLongEdge: 512,
                generation: 1
            )
        )
        guard case .image = result.outcome else {
            Issue.record("Expected decoded image, got \(String(describing: result.outcome))")
            return
        }
        #expect(result.generation == 1)
    }

    @Test func datalessReturnsDownloadingWithoutByteRead() async {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/cloud"),
            relativePath: MediaRelativePath(rawValue: "remote.jpg")
        )
        let materializeCalls = Mutex(0)
        let loader = PreviewImageLoader(
            status: { _ in .dataless },
            materialize: { _ in
                materializeCalls.withLock { $0 += 1 }
                return MaterializationResult(outcome: .timedOut, rerequestCount: 0, elapsedMs: 1)
            }
        )

        let result = await loader.preview(
            for: PreviewImageLoader.Request(
                id: id,
                detail: nil,
                targetLongEdge: 512,
                generation: 7
            )
        )
        guard case .downloading = result.outcome else {
            Issue.record("Expected downloading")
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
            materialize: { _ in
                MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
            }
        )

        async let a = loader.preview(
            for: .init(id: id, detail: nil, targetLongEdge: 256, generation: 1)
        )
        async let b = loader.preview(
            for: .init(id: id, detail: nil, targetLongEdge: 256, generation: 2)
        )
        let (ra, rb) = await (a, b)
        guard case .image = ra.outcome, case .image = rb.outcome else {
            Issue.record("Both requests should decode")
            return
        }
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
