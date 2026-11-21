import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decode budget guide
///
/// How many Image I/O decodes run at once is a question of memory, not of count. A decode
/// holds the pixels Image I/O decodes at, which are not the output's: a JPEG decodes at the
/// smallest of 1, 1/2, 1/4 or 1/8 of its size that still covers the asked long edge, so a
/// 12 MP JPEG rendered to 2,560 pixels decodes whole (4,032 is less than twice 2,560), while
/// a 24 MP JPEG decodes at half and peaked at 50 MB; HEIC decodes at the asked size (15 to 19
/// MB); any other format decodes whole (`docs/research/2026-11-17-first-launch-decodes.md`).
/// A JPEG that decodes whole takes the route that holds least (`OriginalRoute`): 86–92 MB on
/// the lane where Image I/O's thumbnail decode peaked at 110, 36–37 MB for a pane.
///
/// **One budget for both lanes.** The background lane (enrichment) and the interactive lane
/// (the photo the user is looking at) are admitted by one machine, so viewing a new library's
/// originals while its first enrichment renders them never stacks the two lanes' peaks
/// (`docs/research/2026-11-17-full-size-view-on-originals.md`). The rule is `LoadAdmission`'s:
///
/// - a decode the user waits on (`DecodeWaiter.user`) is granted at once, whatever runs or
///   waits, and while one runs no background decode starts;
/// - a background decode is granted in the order asked, while nothing the user waits on runs
///   and the decodes running cost no more than the budget together — always one when none
///   runs, so a decode larger than the whole budget still runs, alone;
/// - a background decode the user comes to wait on (the pane asks for the photo the lane is
///   about to render, `promote`) is the user's from then on.
///
/// So the decodes running at once hold at most the budget, or the user's decodes beside what
/// was running when they asked. The lanes' queue widths stay the caps on how many run at once.
///
/// A render's cost is what its route holds: the pixels it decodes at and the rendering it
/// makes, from the file's header, the asked long edge and the route
/// (`DecodeCost.renderBytes(_:longEdge:route:)`): the
/// rendering is held while its preview is encoded and staged on the lane
/// (`ImageRenderer.render(_:longEdge:recipe:finish:)`). A header that cannot be read costs
/// the whole budget, so an unknown render runs alone rather than beside others.
nonisolated struct DecodeBudgetMachine: AdmissionMachine, Equatable {
    typealias Request = AdmissionRequest

    /// One decode's ask: what it costs in bytes, who waits on it, and the render it is, so the
    /// user can come to wait on one already asked for.
    struct Ask: Equatable, Sendable {
        let cost: Int
        let waiter: DecodeWaiter
        let render: RenderKey
    }

    static func requested(_ request: Request, _ ask: Ask) -> Event {
        .request(request, ask)
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
        case request(Request, Ask)
        case withdraw(Request)
        case release(Request)
        /// The user now waits on `render`: a waiting ask for it is the user's from now on.
        case promote(RenderKey)
    }

    enum Effect: Equatable, Sendable {
        case grant(Request)
        case refuse(Request)
    }

    struct Waiting: Equatable, Sendable {
        let request: Request
        var ask: Ask
    }

    let budget: Int
    private(set) var running: [Request: Ask] = [:]
    /// In the order asked: the first background decode waits for room before any behind it
    /// runs, so a large decode is never passed over by small ones forever.
    private(set) var waiting: [Waiting] = []

    /// What the running decodes cost together.
    var inUse: Int {
        running.values.reduce(0) { $0 + $1.cost }
    }

    /// What the running background decodes cost together.
    var backgroundInUse: Int {
        running.values.filter { $0.waiter == .background }.reduce(0) { $0 + $1.cost }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .request(request, ask):
            waiting.append(Waiting(request: request, ask: Ask(cost: max(0, ask.cost), waiter: ask.waiter, render: ask.render)))
        case let .withdraw(request):
            guard let index = waiting.firstIndex(where: { $0.request == request }) else { return [] }
            waiting.remove(at: index)
            return [.refuse(request)]
        case let .release(request):
            guard running.removeValue(forKey: request) != nil else { return [] }
        case let .promote(render):
            for index in waiting.indices where waiting[index].ask.render == render {
                waiting[index].ask = Ask(cost: waiting[index].ask.cost, waiter: .user, render: render)
            }
        }
        var granted: [Effect] = []
        // The user's decodes first, each at once.
        while let index = waiting.firstIndex(where: { $0.ask.waiter == .user }) {
            let next = waiting.remove(at: index)
            running[next.request] = next.ask
            granted.append(.grant(next.request))
        }
        // Then enrichment's, in order, while nothing the user waits on runs and they fit.
        while let next = waiting.first, !running.values.contains(where: { $0.waiter == .user }),
              running.isEmpty || inUse + next.ask.cost <= budget
        {
            waiting.removeFirst()
            running[next.request] = next.ask
            granted.append(.grant(next.request))
        }
        return granted
    }
}

/// Who waits on a decode: the photo on screen, or enrichment.
nonisolated enum DecodeWaiter: Sendable, Equatable {
    case user
    case background
}

/// One render as asked of either lane: the file, the long edge (nil for the whole original),
/// the recipe and the route that decodes it. Two asks for the same render share one decode
/// (`ImageRenderer`), a pane's ask and the lane's alike.
nonisolated struct RenderKey: Hashable, Sendable {
    let path: String
    let longEdge: Int?
    let recipe: EditRecipe
    let route: OriginalRoute

    init(_ url: URL, longEdge: Int?, recipe: EditRecipe, route: OriginalRoute = .thumbnail) {
        path = url.path(percentEncoded: false)
        self.longEdge = longEdge
        self.recipe = recipe
        self.route = route
    }
}

/// A decode's cost: the pixels Image I/O decodes a still at, four bytes each.
nonisolated enum DecodeCost {
    /// How a format's decoder meets an asked long edge.
    enum Decoding: Hashable, Sendable {
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

    /// What a render of an original with `header` to `longEdge` holds by `route`, as measured
    /// (`OriginalRoute`):
    ///
    /// - `thumbnail`: its decode and its rendering (`renderBytes`);
    /// - `wholeDrawn`: the whole decode, four bytes a pixel, the YCbCr image Image I/O decodes
    ///   it from, a byte and a half, and the rendering drawn from it: 87 MB for a 12 MP JPEG
    ///   at 2,560 pixels, which peaked at 86–92 MB.
    static func renderBytes(_ header: OriginalHeader, longEdge: Int?, route: OriginalRoute) -> Int {
        let (width, height) = (header.width, header.height)
        switch route {
        case .thumbnail:
            return renderBytes(width: width, height: height, longEdge: longEdge, decoding: header.decoding)
        case .wholeDrawn:
            return width * height * 4 + width * height * 3 / 2
                + bytes(width: width, height: height, longEdge: longEdge, decoding: .atAskedSize)
        }
    }
}
