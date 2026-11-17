import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decode budget guide
///
/// How many Image I/O decodes a render lane runs at once is a question of memory, not of
/// count. A decode holds the pixels Image I/O decodes at, which are not the output's: a JPEG
/// decodes at the smallest of 1, 1/2, 1/4 or 1/8 of its size that still covers the asked
/// long edge, so a 12 MP JPEG rendered to 2,560 pixels decodes whole (4,032 is less than
/// twice 2,560) and peaked at 110 MB alone, while a 24 MP JPEG decodes at half and peaked at
/// 50 MB; HEIC decodes at the asked size (15 to 19 MB); any other format decodes whole. A new
/// library's first enrichment renders every still's preview on the background lane at once,
/// and four whole decodes in flight took a first launch to 625 MB of footprint with no other
/// view open (`docs/research/2026-11-17-first-launch-decodes.md`). The lane therefore admits
/// a decode by its cost (`DecodeBudgetMachine`, through the shared `Admission` shell): in
/// the order asked, while the decodes running cost no more than the budget together, and
/// always one when none runs, so a decode larger than the whole budget still runs, alone.
/// The lane's queue width stays the cap on how many run at once.
///
/// A render's cost is the pixels it decodes at and the rendering it makes, four bytes each,
/// from the file's header and the asked long edge (`DecodeCost.of(_:longEdge:)`): the
/// rendering is held while its preview is encoded and staged on the lane
/// (`ImageRenderer.render(_:longEdge:recipe:finish:)`), and those encodes, run beside one
/// another off the lane, took 28 stills' first enrichment from about 230 MB to 550 MB in a
/// test process. A header that cannot be read costs the whole budget, so an unknown render
/// runs alone rather than beside others.
nonisolated struct DecodeBudgetMachine: AdmissionMachine, Equatable {
    typealias Request = AdmissionRequest
    /// A decode's cost in bytes.
    typealias Ask = Int

    static func requested(_ request: Request, _ ask: Ask) -> Event {
        .request(request, cost: ask)
    }

    static func withdrawn(_ request: Request) -> Event {
        .withdraw(request)
    }

    static func released(_ request: Request) -> Event {
        .release(request)
    }

    static func resolution(of effect: Effect) -> (request: Request, granted: Bool) {
        switch effect {
        case let .grant(request): (request, true)
        case let .refuse(request): (request, false)
        }
    }

    enum Event: Equatable, Sendable {
        case request(Request, cost: Int)
        case withdraw(Request)
        case release(Request)
    }

    enum Effect: Equatable, Sendable {
        case grant(Request)
        case refuse(Request)
    }

    struct Waiting: Equatable, Sendable {
        let request: Request
        let cost: Int
    }

    let budget: Int
    private(set) var running: [Request: Int] = [:]
    /// In the order asked: the first waits for room before any behind it runs, so a large
    /// decode is never passed over by small ones forever.
    private(set) var waiting: [Waiting] = []

    /// What the running decodes cost together.
    var inUse: Int {
        running.values.reduce(0, +)
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .request(request, cost):
            waiting.append(Waiting(request: request, cost: max(0, cost)))
        case let .withdraw(request):
            guard let index = waiting.firstIndex(where: { $0.request == request }) else { return [] }
            waiting.remove(at: index)
            return [.refuse(request)]
        case let .release(request):
            guard running.removeValue(forKey: request) != nil else { return [] }
        }
        var granted: [Effect] = []
        while let next = waiting.first, running.isEmpty || inUse + next.cost <= budget {
            waiting.removeFirst()
            running[next.request] = next.cost
            granted.append(.grant(next.request))
        }
        return granted
    }
}

/// A decode's cost: the pixels Image I/O decodes a still at, four bytes each.
nonisolated enum DecodeCost {
    /// How a format's decoder meets an asked long edge.
    enum Decoding: Equatable, Sendable {
        /// At the smallest of 1, 1/2, 1/4, 1/8 of the original that covers it (JPEG).
        case scaledByHalves
        /// At the asked size (HEIC, HEIF).
        case atAskedSize
        /// Whole (every other format).
        case whole

        init(type: UTType?) {
            if type?.conforms(to: .jpeg) == true {
                self = .scaledByHalves
            } else if type?.conforms(to: .heic) == true || type?.conforms(to: .heif) == true {
                self = .atAskedSize
            } else {
                self = .whole
            }
        }
    }

    /// The bytes a still of `width` × `height` decodes to for `longEdge` (the whole original
    /// when nil).
    static func bytes(width: Int, height: Int, longEdge: Int?, decoding: Decoding) -> Int {
        let native = max(width, height)
        guard let longEdge, longEdge > 0, longEdge < native else {
            return width * height * 4
        }
        switch decoding {
        case .whole:
            return width * height * 4
        case .atAskedSize:
            let scale = Double(longEdge) / Double(native)
            return Int((Double(width) * scale).rounded(.up)) * Int((Double(height) * scale).rounded(.up)) * 4
        case .scaledByHalves:
            var divisor = 1
            while divisor < 8, native / (divisor * 2) >= longEdge {
                divisor *= 2
            }
            return (width / divisor) * (height / divisor) * 4
        }
    }

    /// What a render to `longEdge` holds at once: the pixels it decodes at, and the rendering
    /// it makes from them (an 8-bit bitmap of the asked size), which is held while what is made
    /// from it, a staged preview, is encoded.
    static func renderBytes(width: Int, height: Int, longEdge: Int?, decoding: Decoding) -> Int {
        bytes(width: width, height: height, longEdge: longEdge, decoding: decoding)
            + bytes(width: width, height: height, longEdge: longEdge, decoding: .atAskedSize)
    }

    /// Read from the file's header, which Image I/O reads without decoding, off the caller's
    /// actor: what a render to `longEdge` holds (`renderBytes`); nil when the header cannot be
    /// read.
    @concurrent
    static func of(_ url: URL, longEdge: Int?) async -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            return nil
        }
        let decoding = Decoding(type: UTType(filenameExtension: url.pathExtension))
        return renderBytes(width: width, height: height, longEdge: longEdge, decoding: decoding)
    }
}
