import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

/// Both render lanes' Image I/O decodes are admitted by what they hold in memory
/// (`DecodeBudgetMachine`): enrichment's small decodes run together, a large one runs alone,
/// none is passed over forever, and a decode the user waits on runs at once with nothing of
/// enrichment's starting beside it. The machine is tested as a sequence of events.
struct DecodeBudgetMachineTests {
    static let megapixel = 4_000_000
    static let budget = 48 * megapixel

    static func ask(_ megapixels: Int, _ waiter: DecodeWaiter = .background, file: String = "photo") -> DecodeBudgetMachine.Ask {
        DecodeBudgetMachine.Ask(
            cost: megapixels * megapixel, waiter: waiter,
            render: RenderKey(URL(fileURLWithPath: "/library/\(file).jpg"), longEdge: 2560, recipe: .neutral)
        )
    }

    /// Four 12 MP decodes run at once; the fifth waits for room.
    @Test func smallDecodesRunTogetherUpToTheBudget() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        for request in 1 ... 4 as ClosedRange<AdmissionRequest> {
            #expect(machine.handle(.request(request, Self.ask(12))) == [.grant(request)])
        }
        #expect(machine.handle(.request(5, Self.ask(12))).isEmpty)
        #expect(machine.inUse == Self.budget)
        #expect(machine.handle(.release(2)) == [.grant(5)])
    }

    /// A decode larger than the whole budget still runs, alone, and nothing runs beside it.
    @Test func aLargeDecodeRunsAlone() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        #expect(machine.handle(.request(1, Self.ask(12))) == [.grant(1)])
        #expect(machine.handle(.request(2, Self.ask(192))).isEmpty)
        #expect(machine.handle(.request(3, Self.ask(12))).isEmpty)
        // The large one goes first once the lane is empty, and the small one waits behind it.
        #expect(machine.handle(.release(1)) == [.grant(2)])
        #expect(machine.handle(.release(2)) == [.grant(3)])
    }

    // Validates: ENR-016
    /// The photo on screen is decoded at once, however full the budget is, and nothing of
    /// enrichment's starts while it runs.
    @Test func aDecodeTheUserWaitsOnRunsAtOnceAndEnrichmentWaitsForIt() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        #expect(machine.handle(.request(1, Self.ask(48))) == [.grant(1)])
        #expect(machine.handle(.request(2, Self.ask(4))).isEmpty)
        #expect(machine.handle(.request(3, Self.ask(12, .user, file: "shown"))) == [.grant(3)])
        // Room frees, but a user decode runs: enrichment waits.
        #expect(machine.handle(.release(1)).isEmpty)
        #expect(machine.handle(.release(3)) == [.grant(2)])
    }

    // Validates: ENR-016
    /// The pane asking for the photo enrichment is about to render makes that waiting render
    /// the user's: it runs at once, ahead of the renders asked before it.
    @Test func aRenderTheUserComesToWaitOnIsTheUsers() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        #expect(machine.handle(.request(1, Self.ask(48, file: "a"))) == [.grant(1)])
        #expect(machine.handle(.request(2, Self.ask(12, file: "b"))).isEmpty)
        #expect(machine.handle(.request(3, Self.ask(12, file: "c"))).isEmpty)
        #expect(machine.handle(.promote(Self.ask(12, file: "c").render)) == [.grant(3)])
        #expect(machine.running[3]?.waiter == .user)
        // b waits on: a user decode runs.
        #expect(machine.handle(.release(1)).isEmpty)
        #expect(machine.handle(.release(3)) == [.grant(2)])
    }

    // Validates: ENR-016
    /// Enrichment's decodes running never cost more than the budget together, the user's
    /// decodes beside them never more than what each costs, and every decode asked for runs.
    @Test func theBudgetIsNeverExceeded() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        let asks: [DecodeBudgetMachine.Ask] = [
            Self.ask(48), Self.ask(12), Self.ask(24, .user), Self.ask(12), Self.ask(12), Self.ask(24),
            Self.ask(12, .user), Self.ask(48), Self.ask(12), Self.ask(4), Self.ask(24),
        ]
        var asked = 0
        var released = 0
        func check(_ effects: [DecodeBudgetMachine.Effect]) {
            let background = machine.running.values.filter { $0.waiter == .background }
            // Enrichment's decodes alone fit the budget, or one runs alone.
            #expect(background.count <= 1 || machine.backgroundInUse <= Self.budget)
            // Nothing of enrichment's is granted while a user decode runs.
            let grantedBackground = effects.contains { effect in
                guard case let .grant(request) = effect else { return false }
                return machine.running[request]?.waiter == .background
            }
            #expect(!grantedBackground || !machine.running.values.contains { $0.waiter == .user })
        }
        // Asked two at a time, released oldest first, as decodes end.
        while asked < asks.count || !machine.running.isEmpty {
            for _ in 0 ..< 2 where asked < asks.count {
                asked += 1
                check(machine.handle(.request(AdmissionRequest(asked), asks[asked - 1])))
            }
            if let oldest = machine.running.keys.min() {
                released += 1
                check(machine.handle(.release(oldest)))
            }
        }
        #expect(released == asks.count)
        #expect(machine.waiting.isEmpty)
    }

    /// A waiter that stops waiting is dropped and refused; a release of nothing changes nothing.
    @Test func aWithdrawnWaiterIsRefusedAndFreesItsPlace() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        _ = machine.handle(.request(1, Self.ask(48)))
        #expect(machine.handle(.request(2, Self.ask(48))).isEmpty)
        #expect(machine.handle(.withdraw(2)) == [.refuse(2)])
        #expect(machine.handle(.release(9)).isEmpty)
        #expect(machine.handle(.release(1)).isEmpty)
        #expect(machine.running.isEmpty && machine.waiting.isEmpty)
    }

    /// A decode costs the pixels its format decodes at for the asked long edge: a JPEG at the
    /// smallest half that covers it, a HEIC at the asked size, anything else whole.
    @Test func aDecodeCostsThePixelsItDecodesAt() {
        let preview = ThumbnailStore.previewMaxPixelSize
        // 4,032 is less than twice 2,560: a 12 MP JPEG decodes whole.
        #expect(DecodeCost.bytes(width: 4032, height: 3024, longEdge: preview, decoding: .scaledByHalves) == 4032 * 3024 * 4)
        #expect(DecodeCost.bytes(width: 6000, height: 4000, longEdge: preview, decoding: .scaledByHalves) == 3000 * 2000 * 4)
        #expect(DecodeCost.bytes(width: 8064, height: 6048, longEdge: preview, decoding: .scaledByHalves) == 4032 * 3024 * 4)
        // Never below an eighth.
        #expect(DecodeCost.bytes(width: 40000, height: 30000, longEdge: 256, decoding: .scaledByHalves) == 5000 * 3750 * 4)
        #expect(DecodeCost.bytes(width: 8064, height: 6048, longEdge: preview, decoding: .atAskedSize) == 2560 * 1920 * 4)
        #expect(DecodeCost.bytes(width: 4032, height: 3024, longEdge: preview, decoding: .whole) == 4032 * 3024 * 4)
        // The whole original asked for, or one smaller than the asked edge, is decoded whole.
        #expect(DecodeCost.bytes(width: 6000, height: 4000, longEdge: nil, decoding: .scaledByHalves) == 6000 * 4000 * 4)
        #expect(DecodeCost.bytes(width: 1600, height: 1200, longEdge: preview, decoding: .atAskedSize) == 1600 * 1200 * 4)
        #expect(DecodeCost.Decoding(type: .jpeg) == .scaledByHalves)
        #expect(DecodeCost.Decoding(type: .heic) == .atAskedSize)
        #expect(DecodeCost.Decoding(type: .png) == .whole)
        #expect(DecodeCost.Decoding(type: nil) == .whole)
    }

    /// A render holds its decode and the rendering it makes, which waits while its preview is
    /// encoded.
    @Test func aRenderHoldsItsDecodeAndItsRendering() {
        let preview = ThumbnailStore.previewMaxPixelSize
        #expect(DecodeCost.renderBytes(width: 4032, height: 3024, longEdge: preview, decoding: .scaledByHalves)
            == 4032 * 3024 * 4 + 2560 * 1920 * 4)
    }

    // Validates: ENR-016
    /// Both lanes together render four HEIC previews at once, three of a 24 MP JPEG, and one 12
    /// MP JPEG, which decodes whole and is charged what that route was measured to hold.
    @Test func bothLanesHoldFourHEICPreviews() {
        let machine = ImageRenderer.decodeBudgetSnapshot
        #expect(machine.budget == ImageRenderer.decodeBudget)
        let preview = ThumbnailStore.previewMaxPixelSize
        let heic = DecodeCost.renderBytes(width: 8064, height: 6048, longEdge: preview, decoding: .atAskedSize)
        let camera = DecodeCost.renderBytes(width: 6000, height: 4000, longEdge: preview, decoding: .scaledByHalves)
        let phone = DecodeCost.renderBytes(OriginalRouteTests.jpeg(4032, 3024), longEdge: preview, route: .wholeDrawn)
        #expect(4 * heic <= machine.budget)
        #expect(3 * camera <= machine.budget && 4 * camera > machine.budget)
        #expect(phone <= machine.budget && 2 * phone > machine.budget)
    }
}

/// The one decode of an original takes the route that holds least for its format and size
/// (`OriginalRoute`, measured in `OriginalPaneMemoryTests`): a JPEG that Image I/O decodes
/// whole for the asked edge anyway is decoded whole, shown as it is in a pane when upright and
/// unedited, drawn once upright otherwise; everything else keeps Image I/O's thumbnail decode.
@Suite(.testScope)
struct OriginalRouteTests {
    static func jpeg(_ width: Int, _ height: Int, orientation: Int = 1) -> OriginalHeader {
        OriginalHeader(width: width, height: height, orientation: orientation, decoding: .scaledByHalves)
    }

    @Test func theRouteFollowsTheFormatAndTheSize() {
        let preview = ThumbnailStore.previewMaxPixelSize
        let phone = Self.jpeg(4032, 3024)
        #expect(OriginalRoute.of(phone, longEdge: preview, recipe: .neutral) == .wholeDrawn)
        #expect(OriginalRoute.of(phone, longEdge: nil, recipe: .neutral) == .wholeDrawn)
        // Turned, or edited, it is drawn upright the same way.
        let turned = Self.jpeg(4032, 3024, orientation: 6)
        #expect(OriginalRoute.of(turned, longEdge: preview, recipe: .neutral) == .wholeDrawn)
        var edited = EditRecipe.neutral
        edited.exposure = 1
        #expect(OriginalRoute.of(phone, longEdge: preview, recipe: edited) == .wholeDrawn)
        // A JPEG whose half covers the edge, a HEIC, an unknown header: the thumbnail decode.
        #expect(OriginalRoute.of(Self.jpeg(6000, 4000), longEdge: preview, recipe: .neutral) == .thumbnail)
        #expect(OriginalRoute.of(Self.jpeg(6000, 4000), longEdge: 256, recipe: .neutral) == .thumbnail)
        let heic = OriginalHeader(width: 4032, height: 3024, orientation: 1, decoding: .atAskedSize)
        #expect(OriginalRoute.of(heic, longEdge: preview, recipe: .neutral) == .thumbnail)
        #expect(OriginalRoute.of(nil, longEdge: preview, recipe: .neutral) == .thumbnail)
    }

    /// The whole route is charged what it was measured to hold: 87 MB for a 12 MP JPEG at
    /// 2,560 pixels (peaks 86–92 MB).
    @Test func aWholeRouteIsChargedWhatItHolds() {
        let preview = ThumbnailStore.previewMaxPixelSize
        let phone = Self.jpeg(4032, 3024)
        #expect(DecodeCost.renderBytes(phone, longEdge: preview, route: .wholeDrawn)
            == 4032 * 3024 * 4 + 4032 * 3024 * 3 / 2 + 2560 * 1920 * 4)
        #expect(DecodeCost.renderBytes(Self.jpeg(6000, 4000), longEdge: preview, route: .thumbnail)
            == DecodeCost.renderBytes(width: 6000, height: 4000, longEdge: preview, decoding: .scaledByHalves))
    }

    /// A turned JPEG drawn whole comes out upright at the asked size, its pixels where Image
    /// I/O's own upright thumbnail decode puts them, already a `DisplayImage`.
    @Test func aTurnedJPEGDrawnWholeIsUpright() throws {
        let directory = try makeTestDirectory()
        let url = directory.appending(path: "turned.jpg")
        // Stored 400 × 300, its top-left quarter red, tagged to be turned a quarter clockwise.
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 150, width: 200, height: 150))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let stored = try #require(context.makeImage())
        CGImageDestinationAddImage(destination, stored, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let header = try #require(OriginalHeader.read(source, type: .jpeg))
        #expect(header.orientation == 6)
        #expect(OriginalRoute.of(header, longEdge: 256, recipe: .neutral) == .wholeDrawn)
        let drawn = try #require(DisplayImage.original(source, header: header, decodeLongEdge: 256, route: .wholeDrawn))
        let thumbnail = try #require(DisplayImage.original(source, header: header, decodeLongEdge: 256, route: .thumbnail))
        #expect(drawn.drawn?.cgImage === drawn.image)
        #expect(drawn.image.width == thumbnail.image.width && drawn.image.height == thumbnail.image.height)
        #expect(drawn.image.width == 192 && drawn.image.height == 256)
        // Probed away from the quarters' edges: each quarter is the same colour in both.
        for (x, y) in [(40, 40), (150, 40), (40, 210), (150, 210)] {
            let (a, b) = (Self.red(drawn.image, x, y), Self.red(thumbnail.image, x, y))
            #expect(abs(a - b) < 40, "pixel \(x),\(y): drawn red \(a), thumbnail red \(b)")
        }
    }

    /// The red of the pixel at `x`, `y` from the top-left, drawn into an sRGB bitmap.
    private static func red(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            context?.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        }
        return Int(pixel[0])
    }
}
