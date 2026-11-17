import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Synchronization
import Testing

/// Two requests for one asset share a decode only when that decode is at least as large as
/// the one the second request needs; otherwise the second is handed a smaller image than it
/// asked for.
@Suite(.testScope)
struct PreviewImageLoaderSizeTests {
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen {
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    @Test func aLargerRequestIsNeverHandedASmallerDecodeThatWasAlreadyInFlight() async throws {
        let directory = try makeTestDirectory()
        try writeJPEG(width: 2000, height: 1500, to: directory.appending(path: "big.jpg"))
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "big.jpg")
        )
        let gate = Gate()
        let materialized = Mutex(false)
        let statusCalls = Mutex(0)
        let status: @Sendable (URL) -> FileMaterializationStatus = { _ in
            statusCalls.withLock { $0 += 1 }
            return materialized.withLock { $0 } ? .materialized : .dataless
        }
        let loader = PreviewImageLoader(
            status: status,
            materializationRequester: ClosureMaterializationRequester(status: status) { _ in
                await gate.wait()
                materialized.withLock { $0 = true }
                return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
            }
        )

        let small = Task { await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: 256)) }
        try await waitUntil { statusCalls.withLock { $0 } >= 1 }
        let large = Task { await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: 1024)) }
        // The larger request starts its own decode, which probes the file's status itself.
        // If it were folded into the smaller one it would never get here.
        try await waitUntil { statusCalls.withLock { $0 } >= 2 }
        await gate.open()

        guard case let .image(smallImage, _) = await small.value,
              case let .image(largeImage, _) = await large.value
        else {
            Issue.record("expected both decodes to produce images")
            return
        }
        #expect(max(smallImage.width, smallImage.height) <= 256)
        #expect(max(largeImage.width, largeImage.height) > 256)
    }

    /// A still with no stored preview yet is shown at the stored preview's size, whatever the
    /// screen asks: its original is decoded scaled to that edge, not whole, and only a
    /// full-resolution request decodes it whole.
    @Test func anOriginalIsDecodedAtTheStoredPreviewsSizeShortOfFullResolution() async throws {
        let directory = try makeTestDirectory()
        try writeJPEG(width: 3600, height: 2400, to: directory.appending(path: "camera.jpg"))
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "camera.jpg")
        )
        let loader = PreviewImageLoader(
            status: { _ in .materialized },
            materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in .testMaterialized }
        )
        guard case let .image(fit, native) = await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: 3024)),
              case let .image(full, _) = await loader.preview(for: .init(id: id, detail: nil, targetLongEdge: PreviewImageLoader.fullResolution))
        else {
            Issue.record("expected both decodes to produce images")
            return
        }
        #expect(native == CGSize(width: 3600, height: 2400))
        // A JPEG this size decodes whole for the preview's size anyway, so the pane shows it
        // whole, as Image I/O returns it (`OriginalRoute.wholeShown`).
        #expect(fit.width == 3600)
        #expect(full.width == 3600)

        // One whose half covers the preview's size is decoded at it.
        try writeJPEG(width: 6000, height: 4000, to: directory.appending(path: "large.jpg"))
        let large = MediaAssetID(libraryRootPath: id.libraryRootPath, relativePath: MediaRelativePath(rawValue: "large.jpg"))
        guard case let .image(largeFit, _) = await loader.preview(for: .init(id: large, detail: nil, targetLongEdge: 3024)) else {
            Issue.record("expected the decode to produce an image")
            return
        }
        #expect(largeFit.width == ThumbnailStore.previewMaxPixelSize)
    }

    private func writeJPEG(width: Int, height: Int, to url: URL) throws {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PreviewImageLoaderSizeTests", code: 1)
        }
    }
}
