import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OSLog
import Synchronization
import UniformTypeIdentifiers

/// Image renderer guide
///
/// The one place a still photo's pixels are made from its original (ADR 0035). A RAW
/// file is developed by `CIRAWFilter` with the newest decoder the file supports — RAW9
/// where Apple offers it, otherwise RAW8 — so the grid, the loupe and every product
/// derived from them show the same rendering; any other still is decoded by Image I/O
/// with its orientation applied. The result is an 8-bit Display P3 bitmap.
///
/// Rendering is blocking CPU and GPU work, so it leaves every actor on named queues
/// (ADR 0032 rule 6). There are two lanes: `background` for enrichment and `interactive`
/// for what the user is looking at, so a backlog of enrichment renders never queues in
/// front of the photo on screen. Each lane develops one RAW at a time — a RAW9
/// development takes about a second, gains nothing from running beside another, and
/// holds 160–340 MB — so at most two are in memory at once. Image I/O decodes have their
/// own queue per lane: up to four at once on `background`, where four measured 2.5× the
/// throughput of one and eight no more than four (research 2026-10-31-raw9-speed), and
/// one at a time on `interactive`. On `background` they are also admitted by the pixels
/// they decode at (`DecodeBudget`): four HEIC or three 24 MP JPEG previews at once, but one
/// of a 12 MP JPEG, which decodes whole, so a new library's first enrichment does not peak at
/// four whole decodes in flight (research 2026-11-17-first-launch-decodes). Each still's
/// original is decoded by the route its format and size call for (`OriginalRoute`,
/// `DisplayImage.original`; research 2026-11-17-jpeg-decode-routes).
///
/// The caller has already checked that the original's bytes are local; reading a
/// dataless file here would block on its download.
final nonisolated class ImageRenderer: Sendable {
    /// Which decoder produced a rendering — recorded so a product can say how it was made.
    enum Decoder: String, Sendable {
        case raw9
        case raw8
        /// A RAW file whose camera only an older decoder supports.
        case rawOther
        case imageIO
    }

    struct Rendered: Sendable {
        /// An immutable 8-bit Display P3 bitmap, or an original's decode (`DisplayImage.original`).
        let image: CGImage
        let decoder: Decoder
        /// The original's oriented full-resolution size, for the loupe's 100% document.
        let nativePixelSize: CGSize
        /// `image` as a layer shows it, when its decode already drew it as one (a JPEG's
        /// `wholeDrawn` route); a pane draws any other rendering once (`DisplayImage.shown`).
        let shown: DisplayImage?
    }

    enum RenderError: Error {
        case unreadable
        case renderFailed
    }

    /// Apple's support for a RAW's camera at the decoder chosen for it could not be fetched
    /// (`CIRAWFilter.downloadResources`): the download failed or did not finish by its
    /// deadline. It is no verdict on the file — the same file develops once the support is
    /// on the Mac — so it is not a `RenderError`, and enrichment paces the row rather than
    /// stamping it undecodable or its source unreadable.
    struct RAWResourcesUnavailable: Error, Equatable, CustomStringConvertible {
        let domain: String
        let code: Int

        var description: String {
            "rawResourcesUnavailable(\(domain) \(code))"
        }
    }

    /// Otos's own part of the decoder: 2 since a still's bytes are decoded as the type its
    /// extension names (`docs/research/2026-11-11-arw-bytes-read-as-tiff.md`). A change to
    /// how Otos hands a still to its decoders that can make an unreadable still readable is
    /// a new revision.
    static let decodeRevision = 2

    /// The decoder a verdict of "cannot decode" is about: Otos's revision and the macOS
    /// build, whose Image I/O and `CIRAWFilter` do the decoding. A still neither could
    /// decode is tried again once either changes (ENR-029).
    static let decoderIdentity = DecodeVerdict.decoder("otos", revision: decodeRevision)

    /// Up to four Image I/O renders at once for enrichment, while the budget holds them.
    static let background = ImageRenderer(lane: "background", qos: .utility, imageDecodes: 4, waiter: .background)
    /// The photos on screen: both Compare panes at once.
    static let interactive = ImageRenderer(lane: "interactive", qos: .userInitiated, imageDecodes: 2, waiter: .user)

    /// No more Image I/O decodes at once, on both lanes together, than four HEIC previews hold
    /// (`DecodeBudget`): three 24 MP JPEG previews, one of a 12 MP JPEG, which decodes whole.
    static let decodeBudget = 4 * 2 * 2560 * 1920 * 4
    /// The one admission both lanes' Image I/O decodes pass (`DecodeBudgetMachine`).
    private static let admission = Admission(DecodeBudgetMachine(budget: decodeBudget))
    /// The renders asked for and not yet rendered, on both lanes: a second ask for one joins it.
    private static let inFlight = Mutex<[RenderKey: InFlightRender]>([:])

    private let lane: String
    private let waiter: DecodeWaiter
    private let rawQueue: OperationQueue
    private let imageQueue: OperationQueue

    private init(lane: String, qos: QualityOfService, imageDecodes: Int, waiter: DecodeWaiter) {
        self.lane = lane
        self.waiter = waiter
        rawQueue = Self.queue("net.melisma.Otos.render.\(lane).raw", qos: qos, width: 1)
        imageQueue = Self.queue("net.melisma.Otos.render.\(lane).image", qos: qos, width: imageDecodes)
    }

    /// The shared decode budget as it is now: what a test reads to see what runs and waits.
    static var decodeBudgetSnapshot: DecodeBudgetMachine {
        admission.machine
    }

    /// How many renders of `url` are asked for and not yet rendered, and how many asks wait on
    /// them: what a test reads to see one decode per photo.
    static func rendersInFlight(of url: URL) -> (renders: Int, asks: Int) {
        let path = url.path(percentEncoded: false)
        return inFlight.withLock { map in
            let renders = map.filter { $0.key.path == path }.map(\.value)
            return (renders.count, renders.reduce(0) { $0 + $1.waiters.count })
        }
    }

    private static func queue(_ name: String, qos: QualityOfService, width: Int) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = qos
        queue.maxConcurrentOperationCount = width
        return queue
    }

    /// Renders `url` with `recipe` applied so the edited photo's long edge is at most
    /// `longEdge`, or at full size when nil. A cropped photo is developed from a frame
    /// large enough for its crop to reach that size.
    func render(_ url: URL, longEdge: Int?, recipe: EditRecipe = .neutral) async throws -> Rendered {
        try await render(url, longEdge: longEdge, recipe: recipe) { $0 }
    }

    /// Renders `url` as `render(_:longEdge:recipe:)` does and hands the rendering to `finish`
    /// on the lane, inside the render's admission, returning what `finish` makes. What is
    /// made from the pixels — a preview encoded and staged — is made on the lane's queue while
    /// they are held, so the lane bounds it with the decode (`DecodeBudget`) and no actor runs
    /// the encode (ADR 0032 rule 6).
    ///
    /// **One decode per render.** An ask for a render already asked for on either lane — the
    /// pane opening the photo enrichment is rendering, or enrichment reaching the photo on
    /// screen — joins it: the render runs once, and each ask's `finish` runs on the lane, in
    /// the render's admission, with the same pixels. The user joining a background render that
    /// still waits for its turn makes it the user's (`DecodeBudgetMachine.promote`).
    ///
    /// **An ask nobody waits on any more costs nothing.** A cancelled ask leaves its render at
    /// once and hears `CancellationError`; a render whose every ask left before it began is
    /// withdrawn from the budget, or skipped on the queue, before it reads a byte. A render
    /// that began runs to its end, and its pixels go to whoever still waits.
    ///
    /// **The route is the file's.** Its header, read first, names the route that decodes it
    /// (`OriginalRoute`), which is part of the render asked for, so a pane and the lane asking
    /// for the same photo at the same size share one render.
    func render<Product: Sendable>(
        _ url: URL,
        longEdge: Int?,
        recipe: EditRecipe = .neutral,
        finish: @escaping @Sendable (Rendered) -> Product
    ) async throws -> Product {
        let header = Self.isRAW(url) ? nil : await OriginalHeader.read(url)
        let route = OriginalRoute.of(header, longEdge: longEdge, recipe: recipe)
        let key = RenderKey(url, longEdge: longEdge, recipe: recipe, route: route)
        let ask = Self.nextAsk.withLock { value in
            value &+= 1
            return value
        }
        let user = waiter == .user
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Product, any Error>) in
                let waiter = InFlightRender.Waiter(user: user) { result in
                    continuation.resume(with: result.map(finish))
                }
                // Decided under the lock `onCancel` takes: a cancellation before this point is
                // seen here, one after it finds the ask waiting and resumes it.
                let joined: Bool? = Self.inFlight.withLock { map in
                    guard !Task.isCancelled else { return nil }
                    if map[key] != nil {
                        map[key]?.waiters[ask] = waiter
                        return true
                    }
                    map[key] = InFlightRender(
                        id: ask,
                        waiters: [ask: waiter],
                        runner: Task.detached(priority: user ? .userInitiated : .utility) {
                            await self.run(key, url: url, header: header, render: ask)
                        }
                    )
                    return false
                }
                switch joined {
                case nil:
                    continuation.resume(throwing: CancellationError())
                case true?:
                    if user {
                        Self.admission.perform(.promote(key))
                    }
                    OtosLog.rendering.debugOperation("render.still", phase: "joined", fields: [
                        "lane": lane, "path": key.path,
                    ])
                case false?:
                    break
                }
            }
        } onCancel: {
            Self.leave(ask, from: key)
        }
    }

    private static let nextAsk = Mutex<UInt64>(0)

    /// A cancelled ask leaves its render and hears `CancellationError`; the last ask to leave a
    /// render that has not begun withdraws it.
    private static func leave(_ ask: UInt64, from key: RenderKey) {
        let left: (waiter: InFlightRender.Waiter, abandoned: Task<Void, Never>?)? = inFlight.withLock { map in
            guard let waiter = map[key]?.waiters.removeValue(forKey: ask) else { return nil }
            guard let render = map[key], render.waiters.isEmpty, !render.began else { return (waiter, nil) }
            map[key] = nil
            return (waiter, render.runner)
        }
        guard let left else { return }
        left.abandoned?.cancel()
        left.waiter.deliver(.failure(CancellationError()))
    }

    /// Whether `render` is still the one asked for `key`, and whether the user waits on it.
    private static func pending(_ key: RenderKey, render: UInt64) -> (pending: Bool, user: Bool) {
        inFlight.withLock { map in
            guard let current = map[key], current.id == render else { return (false, false) }
            return (true, current.wantedByUser)
        }
    }

    /// The render of `key`, once: admitted by the shared budget (an Image I/O decode; a RAW
    /// lane runs one at a time already), then on this lane's queue, or the interactive lane's
    /// when the user waits on it.
    private func run(_ key: RenderKey, url: URL, header: OriginalHeader?, render: UInt64) async {
        let enqueued = ContinuousClock.now
        let isRAW = Self.isRAW(url)
        var admitted: AdmissionRequest?
        if !isRAW {
            let cost = header.map { DecodeCost.renderBytes($0, longEdge: key.longEdge, route: key.route) } ?? Self.decodeBudget
            let state = Self.pending(key, render: render)
            guard state.pending else { return }
            do {
                admitted = try await Self.admission.admit(
                    DecodeBudgetMachine.Ask(cost: cost, waiter: state.user ? .user : waiter, render: key)
                )
            } catch {
                // Withdrawn: every ask left before its turn came.
                return
            }
        }
        defer {
            if let admitted {
                Self.admission.release(admitted)
            }
        }
        let state = Self.pending(key, render: render)
        guard state.pending else { return }
        let lane = state.user ? Self.interactive : self
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            (isRAW ? lane.rawQueue : lane.imageQueue).addOperation {
                defer { done.resume() }
                // Begins only for asks still waiting; with none left, nothing is read.
                let begun: Bool = Self.inFlight.withLock { map in
                    guard map[key]?.id == render, map[key]?.waiters.isEmpty == false else { return false }
                    map[key]?.began = true
                    return true
                }
                guard begun else { return }
                let result = Self.renderOnQueue(url, key: key, lane: lane.lane, enqueued: enqueued)
                // Taken out under the lock: an ask arriving after this starts its own render.
                let waiters = Self.inFlight.withLock { map -> [InFlightRender.Waiter] in
                    let waiters = map[key]?.waiters ?? [:]
                    map[key] = nil
                    return waiters.sorted { $0.key < $1.key }.map(\.value)
                }
                for waiter in waiters {
                    waiter.deliver(result)
                }
            }
        }
    }

    private static func renderOnQueue(
        _ url: URL,
        key: RenderKey,
        lane: String,
        enqueued: ContinuousClock.Instant
    ) -> Result<Rendered, any Error> {
        let start = ContinuousClock.now
        let signpost = OtosSignpost.rendering.beginInterval("ImageRender")
        defer { OtosSignpost.rendering.endInterval("ImageRender", signpost) }
        do {
            let source = try StillSource.read(url)
            let developStart = ContinuousClock.now
            let rendered = try renderNow(source, longEdge: key.longEdge, recipe: key.recipe, route: key.route)
            // The lane's time splits into reading the original and developing it, so a slow
            // render says whether its source or its decoder set the pace; `queueWaitMs` is the
            // wait for its turn in the budget and its place on the lane.
            OtosLog.rendering.noticeOperation("render.still", phase: "finish", fields: [
                "lane": lane,
                "decoder": rendered.decoder.rawValue,
                "route": "\(key.route)",
                "width": "\(rendered.image.width)",
                "height": "\(rendered.image.height)",
                "bytes": "\(source.data.count)",
                "queueWaitMs": "\(DiagnosticsTiming.milliseconds(from: enqueued, to: start))",
                "readMs": "\(DiagnosticsTiming.milliseconds(source.readDuration))",
                "developMs": "\(DiagnosticsTiming.milliseconds(since: developStart))",
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
                "path": url.path(percentEncoded: false),
            ])
            return .success(rendered)
        } catch {
            OtosLog.rendering.errorOperation("render.still", phase: "failed", fields: [
                "lane": lane,
                "decoder": decoderIdentity,
                "path": url.path(percentEncoded: false),
                "error": String(describing: error),
            ])
            return .failure(error)
        }
    }

    /// One render asked for and not yet rendered, and the asks waiting on it, as
    /// `ImageRenderer.inFlight` holds it.
    private nonisolated struct InFlightRender: Sendable {
        struct Waiter: Sendable {
            let user: Bool
            /// Runs the ask's `finish` with the result, on the lane, and resumes the ask.
            let deliver: @Sendable (Result<Rendered, any Error>) -> Void
        }

        /// The first ask's number: which render of this key it is.
        let id: UInt64
        var waiters: [UInt64: Waiter]
        /// The task that admits and queues it, cancelled when every ask left before it began.
        let runner: Task<Void, Never>
        var began = false

        var wantedByUser: Bool {
            waiters.values.contains(where: \.user)
        }
    }

    /// A still's original, read whole in one timed read before anything decodes it. The
    /// decoders are handed the bytes rather than the file, so every byte a render needs is
    /// read here and the time a render spends waiting on its source is measured apart from
    /// the time it spends developing (`render.still` `readMs` / `developMs`). The bytes are in
    /// a mapped region (`FileBytes.whole`), unmapped when the render lets them go, so a 30 MB
    /// RAW read leaves nothing in the footprint after its render.
    ///
    /// A source carries its file's type, named by its extension, because the bytes alone do
    /// not always name it: a Sony ARW begins as a TIFF, and Image I/O handed only its bytes
    /// reads it as a TIFF with no image in it (`docs/research/2026-11-11-arw-bytes-read-as-tiff.md`).
    /// Every decoder is told the type through this source.
    struct StillSource {
        let url: URL
        let data: Data
        let type: UTType?
        let readDuration: Duration

        static func read(_ url: URL) throws -> StillSource {
            let start = ContinuousClock.now
            let data = try FileBytes.whole(url)
            return StillSource(
                url: url,
                data: data,
                type: UTType(filenameExtension: url.pathExtension),
                readDuration: ContinuousClock.now - start
            )
        }

        /// An Image I/O source over the bytes, told the file's type, that caches nothing.
        func imageSource() -> CGImageSource? {
            var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            if let type {
                options[kCGImageSourceTypeIdentifierHint] = type.identifier
            }
            return CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
        }
    }

    static func isRAW(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
    }

    private static func renderNow(_ source: StillSource, longEdge: Int?, recipe: EditRecipe, route: OriginalRoute) throws -> Rendered {
        if isRAW(source.url) {
            return try developRAW(source, longEdge: longEdge, recipe: recipe)
        }
        let decoded = try decodeImage(source, outputLongEdge: longEdge, recipe: recipe, route: route)
        guard !recipe.isNeutral else {
            return decoded
        }
        let developed = applying(recipe, toDevelopedRAW: false, CIImage(cgImage: decoded.image))
        let adjusted = applyingEffects(recipe, applyingGeometry(recipe, developed))
        return try Rendered(
            image: bitmap(adjusted), decoder: decoded.decoder, nativePixelSize: decoded.nativePixelSize, shown: nil
        )
    }

    /// A RAW opened for development, with its oriented full-resolution size: its sensor
    /// size, turned when its orientation (5–8) rotates it a quarter.
    ///
    /// The size is read once, when the filter is made, and never from the filter again:
    /// under RAW9 `CIRAWFilter.nativeSize` changes once a scale factor is set — a
    /// 6192 × 4128 ARW then reads 3302 × 1844, and 3096 × 2064 after a render (research
    /// 2026-10-26). A scale factor computed from those developed the photo at up to twice
    /// the size asked for, and every change of scale between two renders is a fresh
    /// development of seconds.
    struct OpenedRAW {
        let filter: CIRAWFilter
        let decoder: Decoder
        let nativeSize: CGSize
    }

    /// The scale factor that develops a RAW of `nativeSize` so the edited photo's long edge
    /// is at most `outputLongEdge`: a crop keeps a fraction of the frame, so the frame is
    /// developed that much larger, never beyond full resolution.
    static func rawScaleFactor(nativeSize native: CGSize, outputLongEdge: Int?, recipe: EditRecipe) -> Float {
        let nativeLongEdge = max(native.width, native.height)
        guard let outputLongEdge, nativeLongEdge > 0 else {
            return 1
        }
        let fraction = recipe.cropLongEdgeFraction(ofOriginal: native)
        return Float(min(1, Double(outputLongEdge) / (Double(nativeLongEdge) * fraction)))
    }

    /// Opens a RAW for development with the newest decoder the file supports, scaled for
    /// an edited long edge of at most `outputLongEdge`, once Apple's support for its camera
    /// at that decoder is on the Mac (`fetchResources`).
    ///
    /// Blocks its thread while the support downloads: it runs on a render lane's queue or
    /// the live edit renderer's own, never on a shared executor (ADR 0032 rule 6).
    static func openRAW(
        _ source: StillSource,
        outputLongEdge: Int?,
        recipe: EditRecipe
    ) throws -> OpenedRAW {
        guard let filter = CIRAWFilter(imageData: source.data, identifierHint: source.type?.identifier) else {
            throw RenderError.unreadable
        }
        let sensor = filter.nativeSize
        let nativeSize = filter.orientation.rawValue >= 5 ? CGSize(width: sensor.height, height: sensor.width) : sensor
        let decoder: Decoder
        if filter.supportedDecoderVersions.contains(.version9) {
            filter.decoderVersion = .version9
            decoder = .raw9
        } else if filter.supportedDecoderVersions.contains(.version8) {
            filter.decoderVersion = .version8
            decoder = .raw8
        } else {
            decoder = .rawOther
        }
        let fetchStart = ContinuousClock.now
        do {
            // time: deadline — Apple's asset server may never answer; at the deadline Core
            // Image reports a timeout error, and the render waits for that report.
            try fetchResources { reported in
                _ = filter.downloadResources(timeout: rawResourcesDeadline, completionHandler: reported)
            }
        } catch {
            OtosLog.rendering.errorOperation("render.rawResources", phase: "failed", fields: [
                "decoder": decoder.rawValue,
                "error": String(describing: error),
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: fetchStart))",
                "path": source.url.path(percentEncoded: false),
            ])
            throw error
        }
        OtosLog.rendering.debugOperation("render.rawResources", phase: "ready", fields: [
            "decoder": decoder.rawValue,
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: fetchStart))",
            "path": source.url.path(percentEncoded: false),
        ])
        filter.scaleFactor = rawScaleFactor(nativeSize: nativeSize, outputLongEdge: outputLongEdge, recipe: recipe)
        return OpenedRAW(filter: filter, decoder: decoder, nativeSize: nativeSize)
    }

    /// How long a RAW's development waits for Apple's support for its camera to download. A
    /// camera's support is one asset of about 1.6 MB (`com_apple_MobileAsset_RawCamera_Camera`,
    /// research 2026-11-22), so a minute is a download that is not coming; the row is paced
    /// and its development tried again.
    static let rawResourcesDeadline: TimeInterval = 60

    /// Waits for Apple's report that what a RAW's decoder needs for its camera is on the Mac.
    /// macOS does not install a camera's RAW support with the OS: it is an on-demand asset,
    /// one per camera, fetched by `CIRAWFilter.downloadResources` for the filter's decoder
    /// version, which reports success at once when it is already present (under 0.5 ms
    /// measured; research 2026-11-22). `download` starts that fetch with the reporter it is
    /// handed; Core Image calls the reporter once, on a queue of its own, so this thread's
    /// wait cannot hold up the report. An error throws `RAWResourcesUnavailable`, classified
    /// by its domain and code.
    static func fetchResources(_ download: (@escaping @Sendable ((any Error)?) -> Void) -> Void) throws {
        let outcome = Mutex<(any Error)??>(nil)
        let reported = DispatchSemaphore(value: 0)
        download { error in
            outcome.withLock { $0 = .some(error) }
            reported.signal()
        }
        reported.wait()
        if case let error?? = outcome.withLock({ $0 }) {
            let failure = error as NSError
            throw RAWResourcesUnavailable(domain: failure.domain, code: failure.code)
        }
    }

    /// The developed image for `recipe`. Exposure is set on the filter, where it acts on
    /// the RAW data; everything after is applied to the developed image. Setting a
    /// property before each read matters: under RAW9 below a 0.5 scale factor a second
    /// read of an unchanged filter returns an image at half the requested size, and any
    /// property change restores it (research 2026-10-24).
    static func developed(_ filter: CIRAWFilter, recipe: EditRecipe) throws -> CIImage {
        filter.scaleFactor = filter.scaleFactor
        filter.exposure = Float(recipe.exposure)
        if let temperature = recipe.temperature {
            filter.neutralTemperature = Float(temperature)
        }
        if let tint = recipe.tint {
            filter.neutralTint = Float(tint)
        }
        // Detail and Optics act in the RAW pipeline when the decoder supports them; nil
        // leaves the decoder's own amount.
        if let sharpening = recipe.sharpening, filter.isSharpnessSupported {
            filter.sharpnessAmount = Float(sharpening / 100)
        }
        if let noise = recipe.noiseReduction, filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = Float(noise / 100)
        }
        if let color = recipe.colorNoiseReduction, filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = Float(color / 100)
        }
        if let detail = recipe.detail, filter.isDetailSupported {
            filter.detailAmount = Float(detail / 100 * 3)
        }
        if let moire = recipe.moireReduction, filter.isMoireReductionSupported {
            filter.moireReductionAmount = Float(moire / 100)
        }
        if let lens = recipe.lensCorrection, filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = lens
        }
        guard let image = filter.outputImage else {
            throw RenderError.renderFailed
        }
        return applying(recipe, toDevelopedRAW: true, image)
    }

    /// Applies the recipe with the Core Image filters macOS provides (ADR 0036): white
    /// balance and exposure first, for a still that is not a RAW (a RAW's are applied in
    /// its pipeline), then contrast, highlights and shadows, vibrance, and saturation.
    /// A neutral value applies no filter.
    static func applying(_ recipe: EditRecipe, toDevelopedRAW isRAW: Bool, _ image: CIImage) -> CIImage {
        var output = image
        if !isRAW, recipe.temperature != nil || recipe.tint != nil {
            output = relativeWhiteBalance(temperature: recipe.temperature ?? 0, tint: recipe.tint ?? 0, output)
        }
        if !isRAW, recipe.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = output
            exposure.ev = Float(recipe.exposure)
            output = exposure.outputImage ?? output
        }
        if !isRAW, let noise = recipe.noiseReduction, noise > 0 {
            // Noise reduction alone: its own sharpening is left to the Sharpening control.
            let reduction = CIFilter.noiseReduction()
            reduction.inputImage = output
            reduction.noiseLevel = Float(noise / 100 * 0.1)
            reduction.sharpness = 0
            output = reduction.outputImage ?? output
        }
        if !isRAW, let sharpening = recipe.sharpening, sharpening > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = output
            sharpen.sharpness = Float(sharpening / 100)
            output = sharpen.outputImage ?? output
        }
        if recipe.contrast != 0 || recipe.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.contrast = Float(1 + recipe.contrast / 200)
            controls.saturation = Float(1 + recipe.saturation / 100)
            output = controls.outputImage ?? output
        }
        // Highlights down and Shadows use Core Image's local tone filter. It cannot raise
        // highlights (an amount above 1 changes nothing, measured), so Highlights up lifts
        // the upper tones with a curve that keeps white at white, as Lightroom's does.
        if recipe.highlights < 0 || recipe.shadows != 0 {
            let tones = CIFilter.highlightShadowAdjust()
            tones.inputImage = output
            tones.highlightAmount = Float(1 + min(recipe.highlights, 0) / 100)
            tones.shadowAmount = Float(recipe.shadows / 100)
            output = tones.outputImage ?? output
        }
        if recipe.highlights > 0 {
            let lift = recipe.highlights / 100
            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: 0.25)
            curve.point2 = CGPoint(x: 0.5, y: 0.5 + 0.04 * lift)
            curve.point3 = CGPoint(x: 0.75, y: 0.75 + 0.14 * lift)
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage ?? output
        }
        if recipe.vibrance != 0 {
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = output
            vibrance.amount = Float(recipe.vibrance / 100)
            output = vibrance.outputImage ?? output
        }
        return output
    }

    /// A still's relative white balance: the image is treated as lit by a neutral one
    /// mired cooler per step of `temperature` (warmer output for a positive value) and
    /// one `CITemperatureAndTint` tint unit per step of `tint` (magenta for positive),
    /// mapped to D65. Measured on a mid gray: ±100 moves it from r/b 0.41/0.67 to 0.56/0.38
    /// (research 2026-10-25, white balance and geometry probes).
    static func relativeWhiteBalance(temperature: Double, tint: Double, _ image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 1_000_000 / (d65Mired - temperature), y: tint)
        filter.targetNeutral = CIVector(x: 1_000_000 / d65Mired, y: 0)
        return filter.outputImage ?? image
    }

    private static let d65Mired = 1_000_000 / 6500.0

    /// Applies the recipe's geometry (`EditGeometry`) to a developed, oriented image.
    static func applyingGeometry(_ recipe: EditRecipe, _ image: CIImage) -> CIImage {
        guard recipe.hasGeometry else {
            return image
        }
        let developed = atOrigin(image)
        let geometry = EditGeometry(recipe: recipe, developedSize: developed.extent.size)
        let frame = CGRect(origin: .zero, size: geometry.frameSize)
        // The edge is clamped before the transform so straightening samples the photo's
        // own edge pixels at the frame's border instead of transparency.
        let placed = developed.clampedToExtent().transformed(by: geometry.transform)
        return atOrigin(placed.cropped(to: geometry.cropRect.integral.intersection(frame)))
    }

    /// Applies the recipe's Effects to the edited, cropped photo: a vignette that follows
    /// the photo's shape. The photo is scaled to a square, `CIVignetteEffect` (a circle) is
    /// applied about its center, and it is scaled back, so the vignette is an ellipse fitted
    /// to the frame, as Lightroom's post-crop vignette is.
    static func applyingEffects(_ recipe: EditRecipe, _ image: CIImage) -> CIImage {
        guard recipe.vignette != 0, image.extent.width > 0, image.extent.height > 0 else {
            return image
        }
        let photo = atOrigin(image)
        let size = photo.extent.size
        let squeeze = size.height / size.width
        let square = photo.transformed(by: CGAffineTransform(scaleX: squeeze, y: 1))
        let side = size.height
        let vignette = CIFilter.vignetteEffect()
        vignette.inputImage = square
        vignette.center = CGPoint(x: side / 2, y: side / 2)
        // Midpoint 0…100 moves the start from a quarter to the whole of the half-diagonal.
        vignette.radius = Float(side / 2 * 2.0.squareRoot() * (0.25 + 0.75 * recipe.vignetteMidpoint / 100))
        vignette.falloff = Float(0.05 + 0.95 * recipe.vignetteFeather / 100)
        // Negative darkens the corners in Lightroom; positive intensity darkens in Core Image.
        vignette.intensity = Float(-recipe.vignette / 100)
        let applied = vignette.outputImage ?? square
        return applied
            .transformed(by: CGAffineTransform(scaleX: 1 / squeeze, y: 1))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static func developRAW(_ source: StillSource, longEdge: Int?, recipe: EditRecipe) throws -> Rendered {
        let opened = try openRAW(source, outputLongEdge: longEdge, recipe: recipe)
        let image = try applyingEffects(recipe, applyingGeometry(recipe, developed(opened.filter, recipe: recipe)))
        return try Rendered(image: bitmap(image), decoder: opened.decoder, nativePixelSize: opened.nativeSize, shown: nil)
    }

    /// Decodes a still that is not a RAW, upright, large enough for the recipe's edited
    /// long edge to reach `outputLongEdge` (the whole original when nil), by `route`, through
    /// the one decode of an original (`DisplayImage.original`).
    static func decodeImage(_ still: StillSource, outputLongEdge: Int?, recipe: EditRecipe, route: OriginalRoute? = nil) throws -> Rendered {
        guard let source = still.imageSource(), let header = OriginalHeader.read(source, type: still.type) else {
            throw RenderError.unreadable
        }
        // A caller with no route of its own (the edit session's decode) takes the one its
        // header names.
        let route = route ?? OriginalRoute.of(header, longEdge: outputLongEdge, recipe: recipe)
        let decodeLongEdge = header.decodeLongEdge(output: outputLongEdge, recipe: recipe)
        guard let decoded = DisplayImage.original(source, header: header, decodeLongEdge: decodeLongEdge, route: route) else {
            throw RenderError.renderFailed
        }
        return Rendered(image: decoded.image, decoder: .imageIO, nativePixelSize: header.orientedSize, shown: decoded.drawn)
    }

    /// Renders every pixel into an 8-bit Display P3 bitmap. `createCGImage` may return an
    /// image that renders lazily on first draw; the bitmap makes the work happen here, on
    /// the lane, rather than wherever the image is first drawn.
    static func bitmap(
        _ image: CIImage,
        context: CIContext = CIContext(options: [.cacheIntermediates: false])
    ) throws -> CGImage {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw RenderError.renderFailed
        }
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { buffer in
            context.render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: rowBytes,
                bounds: extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: rowBytes,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            throw RenderError.renderFailed
        }
        return cgImage
    }
}
