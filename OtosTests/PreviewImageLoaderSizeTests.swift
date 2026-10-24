import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Synchronization
import Testing

/// Two requests for one asset share a decode only when that decode is at least as large as
/// the one the second request needs; otherwise the second is handed a smaller image than it
/// asked for.
@Suite(.testDirectory)
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
        let loader = PreviewImageLoader(
            status: { _ in
                statusCalls.withLock { $0 += 1 }
                return materialized.withLock { $0 } ? .materialized : .dataless
            },
            materializationRequester: ClosureMaterializationRequester { _ in
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
