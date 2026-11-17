import Foundation
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

/// The background render lane admits Image I/O decodes by what their originals cost in
/// memory (`DecodeBudgetMachine`): small originals run together, a large one runs alone, and
/// none is passed over forever. The machine is tested as a sequence of events.
struct DecodeBudgetMachineTests {
    static let megapixel = 4_000_000
    static let budget = 48 * megapixel

    /// Four 12 MP originals run at once; the fifth waits for room.
    @Test func smallOriginalsRunTogetherUpToTheBudget() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        for request in 1 ... 4 as ClosedRange<AdmissionRequest> {
            #expect(machine.handle(.request(request, cost: 12 * Self.megapixel)) == [.grant(request)])
        }
        #expect(machine.handle(.request(5, cost: 12 * Self.megapixel)).isEmpty)
        #expect(machine.inUse == Self.budget)
        #expect(machine.handle(.release(2)) == [.grant(5)])
    }

    /// An original larger than the whole budget still runs, alone, and nothing runs beside it.
    @Test func aLargeOriginalRunsAlone() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        #expect(machine.handle(.request(1, cost: 12 * Self.megapixel)) == [.grant(1)])
        #expect(machine.handle(.request(2, cost: 192 * Self.megapixel)).isEmpty)
        #expect(machine.handle(.request(3, cost: 12 * Self.megapixel)).isEmpty)
        // The large one goes first once the lane is empty, and the small one waits behind it.
        #expect(machine.handle(.release(1)) == [.grant(2)])
        #expect(machine.handle(.release(2)) == [.grant(3)])
    }

    /// The decodes running beside one another never cost more than the budget together.
    @Test func theDecodesRunningTogetherNeverExceedTheBudget() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        let costs = [48, 12, 24, 12, 12, 24, 48, 12, 4, 24].map { $0 * Self.megapixel }
        for (index, cost) in costs.enumerated() {
            _ = machine.handle(.request(AdmissionRequest(index + 1), cost: cost))
        }
        var released = 0
        while let running = machine.running.keys.min() {
            #expect(machine.running.count == 1 || machine.inUse <= Self.budget)
            _ = machine.handle(.release(running))
            released += 1
        }
        #expect(released == costs.count)
        #expect(machine.waiting.isEmpty)
    }

    /// A waiter that stops waiting is dropped and refused; a release of nothing changes nothing.
    @Test func aWithdrawnWaiterIsRefusedAndFreesItsPlace() {
        var machine = DecodeBudgetMachine(budget: Self.budget)
        _ = machine.handle(.request(1, cost: Self.budget))
        #expect(machine.handle(.request(2, cost: Self.budget)).isEmpty)
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

    /// The background lane renders four HEIC previews at once, three of a 24 MP JPEG, and two
    /// of a 12 MP JPEG.
    @Test func theBackgroundLaneHoldsFourHEICPreviews() throws {
        let machine = try #require(ImageRenderer.background.decodeBudgetSnapshot)
        #expect(machine.budget == ImageRenderer.backgroundDecodeBudget)
        let preview = ThumbnailStore.previewMaxPixelSize
        let heic = DecodeCost.renderBytes(width: 8064, height: 6048, longEdge: preview, decoding: .atAskedSize)
        let camera = DecodeCost.renderBytes(width: 6000, height: 4000, longEdge: preview, decoding: .scaledByHalves)
        let phone = DecodeCost.renderBytes(width: 4032, height: 3024, longEdge: preview, decoding: .scaledByHalves)
        #expect(4 * heic <= machine.budget)
        #expect(3 * camera <= machine.budget && 4 * camera > machine.budget)
        #expect(2 * phone <= machine.budget && 3 * phone > machine.budget)
        #expect(ImageRenderer.interactive.decodeBudgetSnapshot == nil)
    }
}
