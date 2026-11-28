import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Synchronization
import Testing
import UniformTypeIdentifiers

/// The two render lanes share one decode per photo and one memory budget (`ImageRenderer`,
/// `DecodeBudgetMachine`): the pane asking for the photo enrichment is about to render is
/// given that render, run at once as the user's, and an ask nobody waits on any more leaves
/// before its render reads a byte. Each interleaving is set up by holding a user render inside
/// its admission (its `finish` waits), so nothing of enrichment's can start meanwhile.
@Suite(.testScope)
struct RenderSharingTests {
    /// A user render of `url` whose `finish` reports that it runs and then waits for `release`:
    /// while it waits, a user decode holds its turn and no background decode starts.
    private final class HeldRender: Sendable {
        let release = DispatchSemaphore(value: 0)
        let running: AsyncStream<Void>
        let task: Task<Void, any Error>

        init(_ url: URL) {
            let (running, began) = AsyncStream.makeStream(of: Void.self)
            self.running = running
            let release = release
            task = Task {
                _ = try await ImageRenderer.interactive.render(url, longEdge: 256) { _ in
                    began.yield()
                    release.wait()
                }
            }
        }

        func waitUntilRunning() async {
            for await _ in running {
                return
            }
        }
    }

    private static func photo(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        let context = try #require(CGContext(
            data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    // Validates: ENR-016
    /// Enrichment has asked for a photo's preview and waits for its turn; the pane asks for the
    /// same photo at the same size. One render runs, at once, and both are handed its pixels.
    @Test func thePaneIsHandedTheRenderEnrichmentAskedFor() async throws {
        let directory = try makeTestDirectory()
        let held = try HeldRender(Self.photo("held.jpg", in: directory))
        let shown = try Self.photo("shown.jpg", in: directory)
        await held.waitUntilRunning()

        let enrichment = Task { try await ImageRenderer.background.render(shown, longEdge: 512) }
        try await waitUntil { ImageRenderer.rendersInFlight(of: shown) == (1, 1) }
        let pane = Task { try await ImageRenderer.interactive.render(shown, longEdge: 512) }

        // Both are answered while the held user render still runs: the joined render became
        // the user's and ran at once.
        let paneImage = try await pane.value.image
        let enrichmentImage = try await enrichment.value.image
        #expect(paneImage === enrichmentImage)
        #expect(max(paneImage.width, paneImage.height) == 512)
        #expect(ImageRenderer.rendersInFlight(of: shown) == (0, 0))

        held.release.signal()
        try await held.task.value
    }

    // Validates: ENR-016
    /// An ask cancelled while its render waits for its turn hears `CancellationError` at once,
    /// and its render, which nobody else waits on, leaves the budget without reading a byte.
    @Test func anAskNobodyWaitsOnLeavesBeforeItsRenderBegins() async throws {
        let directory = try makeTestDirectory()
        let held = try HeldRender(Self.photo("held.jpg", in: directory))
        let left = try Self.photo("left.jpg", in: directory)
        await held.waitUntilRunning()

        let enrichment = Task { try await ImageRenderer.background.render(left, longEdge: 512) }
        try await waitUntil { ImageRenderer.rendersInFlight(of: left) == (1, 1) }
        enrichment.cancel()
        await #expect(throws: CancellationError.self) { try await enrichment.value }
        #expect(ImageRenderer.rendersInFlight(of: left) == (0, 0))
        try await waitUntil {
            !ImageRenderer.decodeBudgetSnapshot.waiting.contains { $0.ask.render.path == left.path(percentEncoded: false) }
        }

        held.release.signal()
        try await held.task.value
    }
}
