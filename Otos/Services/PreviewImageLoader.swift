import CoreGraphics
import Foundation
import ImageIO
import OSLog
import QuickLookThumbnailing
import Synchronization
import UniformTypeIdentifiers

/// Preview loading boundary used by `CatalogWindowViewModel`. Production uses
/// `PreviewImageLoader`; tests inject a controllable fake via constructor injection.
/// Explicitly nonisolated so actor-backed loaders can conform under MainActor-default
/// module isolation.
nonisolated protocol PreviewLoading: Sendable {
    func preview(for request: PreviewImageLoader.Request) async -> PreviewImageLoader.Outcome
    /// Returns once no decode under `root` is in flight, and refuses new ones there until
    /// `resume(under:)`: an eject must not find the loader holding a card file open.
    func quiesce(under root: LibraryRootPath) async
    func resume(under root: LibraryRootPath) async
    /// Lets go of every photo held for a pane to return to: the full-size view was left, so
    /// no pane can. Synchronous, so a request made after it never finds what it let go.
    func releaseHeldPhotos()
}

/// Preview image loader guide
///
/// The loupe/compare analog of `EnrichmentCoordinator`'s byte-read role, and the app's
/// only full-size decode path (ADR 0016). Callers ask for a preview at a target long edge;
/// this actor asks the shared `MaterializationCoordinator` to make the original local
/// (`ensureLocal`, interactive, because the user has opened loupe/compare), re-checks
/// `FileMaterialization.status` immediately before every byte read, and returns a
/// downsampled `DisplayImage` or `.unavailable`.
///
/// Per-id in-flight work is coalesced. Stale results are rejected by the ViewModel's
/// expected-asset identity check — this actor returns whatever it decoded. A decode whose
/// every waiter has gone (the pane moved on) is cancelled, and a cancelled decode stops
/// before it reads or allocates anything and is never held: stepping through photos faster
/// than they decode starts only the decodes still wanted.
///
/// **What a decode is.** A screen-sized request decodes the stored preview at the requested
/// long edge through `DisplayImage.decode`, the one decode of an image a layer shows: its
/// pixels drawn here, off the main actor, into an IOSurface Core Animation displays as it is,
/// so a shown photo's pixels exist once, in a region of their own that leaves the footprint
/// when the image goes, and showing it costs the window's commit nothing
/// (`docs/research/2026-11-16-full-size-view-memory.md`,
/// `docs/research/2026-11-18-display-images-drawn-before-shown.md`).
///
/// **What it holds.** A pane holds the image it shows (`PanePreview`), so the loader holds
/// only what a pane can come back to: the screen-sized decodes of the last
/// `retainedPhotos` photos asked for — the two Compare panes and the photo just left — so a
/// step back to the previous photo, or a slide back in Compare, paints at once. A
/// full-resolution decode, up to a few hundred megabytes for one photo, is held only by the
/// pane showing it; leaving that photo lets it go, and coming back asks for it again only
/// when the zoom does (APP-040). A hit requires `entry.longEdge >= request.targetLongEdge`
/// so a screen-size change re-decodes instead of upscaling. Each decoded image's pixels are
/// a region of their own (`2026-11-16-image-memory-while-used.md` §2), so what this lets go
/// leaves the footprint.
actor PreviewImageLoader: PreviewLoading {
    /// Two outcomes, because nothing downstream can act on a third.
    ///
    /// Interactive materialization persists until the bytes arrive or the request is
    /// cancelled (APP-023), so a non-image result means cancelled or genuinely absent —
    /// neither of which the caller retries. There is no "still downloading" outcome: it
    /// would only invite a re-request that restarts the attempt. The reason is still
    /// logged; it is just not a decision anyone makes.
    enum Outcome {
        /// The decode plus the source's native pixel size (oriented), when the source
        /// reports one — the loupe sizes its zoom document from it (APP-040).
        case image(DisplayImage, nativePixelSize: CGSize?)
        case unavailable
    }

    /// `Request.targetLongEdge` value asking for the full native resolution; the decode
    /// clamps it to the source's own long edge.
    static let fullResolution = Int.max

    struct Request {
        let id: MediaAssetID
        let detail: MediaTileDetail?
        let targetLongEdge: Int
    }

    /// The photos whose screen-sized decode is held: both Compare panes and the photo just
    /// left, so a return to it never waits.
    static let retainedPhotos = 3

    private nonisolated struct CacheEntry: Sendable {
        let image: DisplayImage
        let longEdge: Int
        let nativePixelSize: CGSize?
        /// The rendered edit revision the image shows (ADR 0036); a newer one misses.
        let revision: Int64
    }

    private let materializationRequester: any MaterializationRequesting
    private let status: @Sendable (URL) -> FileMaterializationStatus
    /// Where stored previews live (ADR 0035); nil for an in-memory catalog, which then
    /// always decodes the original.
    private let derivedImageDirectory: URL?
    /// The photos held for a return. Behind a lock rather than on the actor, so the window
    /// lets go of them synchronously when it leaves the full-size view (`releaseHeldPhotos`).
    private nonisolated struct HeldPhotos {
        var entries: [MediaAssetID: CacheEntry] = [:]
        /// Least recently asked for first.
        var order: [MediaAssetID] = []
        /// How many times the window left the full-size view. A decode asked for before the
        /// latest leave is not held when it lands after it.
        var visit = 0
    }

    private let held = Mutex(HeldPhotos())
    /// One decode per asset in flight, remembered with the size it was asked for. A second
    /// request shares it only when that decode is at least as large as the one it needs;
    /// otherwise it would be handed a smaller image than it asked for.
    private struct InFlightDecode {
        let longEdge: Int
        let revision: Int64
        let task: Task<Outcome, Never>
        let waiters: DecodeWaiters
    }

    /// Who still waits for one in-flight decode. The last to be cancelled cancels the decode,
    /// and a cancelled decode takes no new waiter: a request arriving after it starts its own.
    private final nonisolated class DecodeWaiters: Sendable {
        private let state = Mutex<(waiting: Int, abandoned: Bool)>((0, false))

        func join() -> Bool {
            state.withLock { state in
                guard !state.abandoned else { return false }
                state.waiting += 1
                return true
            }
        }

        /// True when the waiter leaving was the last.
        func leave() -> Bool {
            state.withLock { state in
                state.waiting -= 1
                state.abandoned = state.waiting < 1
                return state.abandoned
            }
        }

        var count: Int {
            state.withLock { $0.waiting }
        }
    }

    /// The decodes this loader started, and those it cancelled before they read a byte.
    nonisolated struct DecodeCounts: Equatable, Sendable {
        var started = 0
        var cancelledBeforeStart = 0
    }

    private(set) var decodeCounts = DecodeCounts()

    /// How many requests wait for `id`'s in-flight decode.
    func waiterCount(for id: MediaAssetID) -> Int {
        inFlight[id]?.waiters.count ?? 0
    }

    private var inFlight: [MediaAssetID: InFlightDecode] = [:]
    /// Roots an eject is releasing. A request there is answered `.unavailable` without
    /// touching the file.
    private var quiescedRoots: Set<LibraryRootPath> = []

    init(
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:),
        derivedImageDirectory: URL? = nil,
        materializationRequester: any MaterializationRequesting
    ) {
        self.status = status
        self.derivedImageDirectory = derivedImageDirectory
        self.materializationRequester = materializationRequester
    }

    /// Decodes (or materializes then decodes) a preview for `request.id`. Cached hits
    /// return immediately when the stored long edge is large enough. Concurrent requests
    /// for the same id share one in-flight task.
    func preview(for request: Request) async -> Outcome {
        guard !quiescedRoots.contains(request.id.libraryRootPath) else {
            OtosLog.mediaIO.notice(
                "op=preview.decode phase=refused reason=sourceQuiesced id=\(request.id.relativePath.rawValue, privacy: .public)"
            )
            return .unavailable
        }
        let revision = request.detail?.renderedRevision ?? 0
        let visit = held.withLock { $0.visit }
        if let cached = heldEntry(request.id, longEdge: request.targetLongEdge, revision: revision) {
            return .image(cached.image, nativePixelSize: cached.nativePixelSize)
        }
        if let existing = inFlight[request.id], existing.longEdge >= request.targetLongEdge,
           existing.revision == revision, existing.waiters.join()
        {
            return await Self.wait(for: existing.task, among: existing.waiters)
        }
        let waiters = DecodeWaiters()
        _ = waiters.join()
        let task = Task(priority: .userInitiated) {
            await self.decode(request)
        }
        // A larger request replaces a smaller decode's entry; the smaller one finishes for
        // its own caller, and each caller removes only the entry it owns.
        inFlight[request.id] = InFlightDecode(
            longEdge: request.targetLongEdge, revision: revision, task: task, waiters: waiters
        )
        let outcome = await Self.wait(for: task, among: waiters)
        if inFlight[request.id]?.task == task {
            inFlight[request.id] = nil
        }
        // A cancelled decode is never held, even one that finished: nobody waits for it.
        guard !task.isCancelled else {
            return .unavailable
        }
        if request.targetLongEdge == Self.fullResolution {
            // The pane holds the full decode; the photo's screen-sized one stays the newest
            // held, the one a return to it paints.
            held.withLock { held in
                if held.entries[request.id] != nil {
                    Self.touch(request.id, in: &held)
                }
            }
        } else if case let .image(image, nativePixelSize) = outcome {
            insert(
                image, for: request.id, longEdge: request.targetLongEdge,
                nativePixelSize: nativePixelSize, revision: revision, visit: visit
            )
        }
        return outcome
    }

    func quiesce(under root: LibraryRootPath) async {
        quiescedRoots.insert(root)
        let running = inFlight.filter { $0.key.libraryRootPath == root }.map(\.value.task)
        OtosLog.mediaIO.noticeOperation("preview.quiesce", phase: "start", fields: [
            "rootPath": root.rawValue,
            "running": "\(running.count)",
        ])
        // The decodes this root had in flight, each to its end: a decode that started is
        // never cut short, and none can start here meanwhile.
        for task in running {
            _ = await task.value
        }
        OtosLog.mediaIO.noticeOperation("preview.quiesce", phase: "finish", fields: ["rootPath": root.rawValue])
    }

    func resume(under root: LibraryRootPath) {
        quiescedRoots.remove(root)
    }

    nonisolated func releaseHeldPhotos() {
        // Taken out under the lock and let go after it: an image's last release frees its
        // pixels.
        let released = held.withLock { held in
            defer { held = HeldPhotos(visit: held.visit &+ 1) }
            return held
        }
        OtosLog.mediaIO.noticeOperation("preview.held", phase: "released", fields: [
            "photos": "\(released.entries.count)",
            "bytes": "\(Self.bytes(of: released))",
        ])
    }

    /// How many photos are held for a return, and their pixels' bytes.
    nonisolated var heldPhotos: (count: Int, bytes: Int) {
        held.withLock { held in
            (held.entries.count, Self.bytes(of: held))
        }
    }

    private nonisolated static func bytes(of held: HeldPhotos) -> Int {
        held.entries.values.reduce(0) { $0 + $1.image.byteCount }
    }

    /// Awaits a shared decode. A waiter that is cancelled leaves it, and the last to leave
    /// cancels it.
    private nonisolated static func wait(for task: Task<Outcome, Never>, among waiters: DecodeWaiters) async -> Outcome {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            if waiters.leave() {
                task.cancel()
            }
        }
    }

    /// Runs `work` off the actor, at the QoS Image I/O's own workers run at. A cancelled
    /// caller cancels it, and work cancelled before it begins does not run.
    private nonisolated static func offActor<Value: Sendable>(
        _ work: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        let task = Task.detached(priority: .medium) { () async -> Value? in
            guard !Task.isCancelled else { return nil }
            return await work()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func decode(_ request: Request) async -> Outcome {
        let url = request.id.fileURL
        let signpost = OtosSignpost.mediaIO.beginInterval("PreviewDecode")
        let start = ContinuousClock.now
        defer {
            OtosSignpost.mediaIO.endInterval("PreviewDecode", signpost)
        }

        // A still's stored preview serves every request short of full resolution, without
        // touching the original — cloud-only or not (ADR 0035). The original's size comes
        // from catalog metadata, because reading its header would download it. A preview
        // that is missing or unreadable falls through to the original below.
        guard !Task.isCancelled else {
            decodeCounts.cancelledBeforeStart += 1
            return .unavailable
        }
        if request.targetLongEdge != Self.fullResolution, request.detail?.bestKind != .video,
           let previewPath = request.detail?.previewPath, let directory = derivedImageDirectory
        {
            decodeCounts.started += 1
            let previewURL = ThumbnailStore.url(for: previewPath, in: directory)
            let target = request.targetLongEdge
            let stored = await Self.offActor {
                Self.decodeStoredPreview(at: previewURL, targetLongEdge: target)
            }
            guard !Task.isCancelled else {
                return .unavailable
            }
            if let stored {
                OtosLog.mediaIO.notice(
                    """
                    op=preview.decode phase=ok id=\(request.id.relativePath.rawValue, privacy: .public) \
                    decodeMs=\(DiagnosticsTiming.milliseconds(since: start), privacy: .public) source=storedPreview \
                    edge=\(request.targetLongEdge, privacy: .public) decoded=\(max(stored.width, stored.height), privacy: .public)
                    """
                )
                return .image(stored, nativePixelSize: request.detail?.nativePixelSize)
            }
            OtosLog.mediaIO.notice(
                "op=preview.decode phase=storedPreviewUnreadable id=\(request.id.relativePath.rawValue, privacy: .public)"
            )
        }

        let isVideo = request.detail?.bestKind == .video
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        let readiness = await materializationRequester.ensureLocal(
            MaterializationCoordinator.Request(
                id: request.id,
                sourceSize: request.detail?.byteSize,
                isVideo: isVideo,
                priority: .interactive
            )
        )
        guard readiness.isLocal else {
            OtosLog.mediaIO.notice(
                """
                op=preview.decode phase=unavailable id=\(request.id.relativePath.rawValue, privacy: .public) \
                readiness=\(String(describing: readiness), privacy: .public)
                """
            )
            return .unavailable
        }

        guard !Task.isCancelled else {
            decodeCounts.cancelledBeforeStart += 1
            return .unavailable
        }
        // Re-check immediately before the byte read (ADR 0008).
        guard status(url) == .materialized else {
            return .unavailable
        }
        decodeCounts.started += 1

        // Decoded off this actor (`offActor`) so two panes can decode concurrently and
        // bookkeeping stays responsive. Dataless/materialize gates above already ran in order.
        // ImageIO thumbnail creation waits on Default-QoS internal workers; matching
        // that QoS avoids the Thread Performance Checker priority-inversion hang risk
        // that fires when this path runs at .userInitiated.
        // A still is shown short of full resolution at the stored preview's size, whether its
        // preview is stored yet or not: the same photo at fit, from the preview or from the
        // original. Zooming past it asks for full resolution (APP-040).
        let target = isVideo || request.targetLongEdge == Self.fullResolution
            ? request.targetLongEdge
            : min(request.targetLongEdge, ThumbnailStore.previewMaxPixelSize)
        let recipe = request.detail?.editRecipe ?? .neutral
        let decoded = await Self.offActor { () async -> DecodedImage? in
            if isVideo {
                return await Self.decodeVideoPoster(url: url, targetLongEdge: target).map(DecodedImage.init)
            }
            return await Self.render(url: url, targetLongEdge: target, recipe: recipe).map(DecodedImage.init)
        }.map { ($0.image, $0.source, $0.nativePixelSize) }
        guard !Task.isCancelled else {
            return .unavailable
        }

        let decodeMs = DiagnosticsTiming.milliseconds(since: start)
        guard let (image, source, nativePixelSize) = decoded else {
            OtosLog.mediaIO.notice(
                """
                op=preview.decode phase=fail id=\(request.id.relativePath.rawValue, privacy: .public) \
                decodeMs=\(decodeMs, privacy: .public)
                """
            )
            return .unavailable
        }
        OtosLog.mediaIO.notice(
            """
            op=preview.decode phase=ok id=\(request.id.relativePath.rawValue, privacy: .public) \
            decodeMs=\(decodeMs, privacy: .public) source=\(source, privacy: .public) \
            edge=\(request.targetLongEdge, privacy: .public) \
            decoded=\(max(image.width, image.height), privacy: .public)
            """
        )
        return .image(image, nativePixelSize: nativePixelSize)
    }

    private nonisolated struct DecodedImage: Sendable {
        let image: DisplayImage
        let source: String
        let nativePixelSize: CGSize?

        init(_ decoded: (DisplayImage, String, CGSize?)) {
            (image, source, nativePixelSize) = decoded
        }
    }

    /// The stored preview at `targetLongEdge` at most, as a layer shows it (`DisplayImage.decode`).
    private nonisolated static func decodeStoredPreview(at url: URL, targetLongEdge: Int) -> DisplayImage? {
        DisplayImage.decode(url, maxPixelEdge: targetLongEdge)
    }

    /// A still's original is rendered by the interactive renderer with its saved recipe — a
    /// RAW never shown as the camera's embedded JPEG, so the loupe matches the grid (ADR 0035,
    /// ADR 0036). The renderer admits it by the memory it holds in the budget enrichment's
    /// renders share, ahead of them, and a render of the same photo at the same size that
    /// enrichment has already asked for is the one the pane is given: one decode per photo
    /// (`docs/research/2026-11-17-full-size-view-on-originals.md`).
    private nonisolated static func render(
        url: URL,
        targetLongEdge: Int,
        recipe: EditRecipe
    ) async -> (DisplayImage, String, CGSize?)? {
        let longEdge = targetLongEdge == fullResolution ? nil : targetLongEdge
        guard let rendered = try? await ImageRenderer.interactive.render(url, longEdge: longEdge, recipe: recipe) else {
            return nil
        }
        // A rendering its decode drew as a `DisplayImage` is shown as it is; any other is drawn
        // into one once, here, off the actor (`offActor`).
        guard let shown = rendered.shown ?? DisplayImage.shown(rendered.image) else {
            return nil
        }
        return (shown, "render-\(rendered.decoder.rawValue)", rendered.nativePixelSize)
    }

    private nonisolated static func decodeVideoPoster(
        url: URL,
        targetLongEdge: Int
    ) async -> (DisplayImage, String, CGSize?)? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: targetLongEdge, height: targetLongEdge),
            scale: 1,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(
                for: request
            )
            return DisplayImage.shown(representation.cgImage).map { ($0, "quicklook", nil) }
        } catch {
            return nil
        }
    }

    private func insert(
        _ image: DisplayImage,
        for id: MediaAssetID,
        longEdge: Int,
        nativePixelSize: CGSize?,
        revision: Int64,
        visit: Int
    ) {
        // A smaller decode that finishes after a larger one must not replace it — unless
        // it shows a newer edit. What is let go is let go after the lock.
        let evicted: [CacheEntry] = held.withLock { held in
            guard held.visit == visit else {
                return []
            }
            if let existing = held.entries[id], existing.longEdge >= longEdge, existing.revision >= revision {
                Self.touch(id, in: &held)
                return []
            }
            held.entries[id] = CacheEntry(image: image, longEdge: longEdge, nativePixelSize: nativePixelSize, revision: revision)
            Self.touch(id, in: &held)
            var evicted: [CacheEntry] = []
            while held.order.count > Self.retainedPhotos {
                if let entry = held.entries.removeValue(forKey: held.order.removeFirst()) {
                    evicted.append(entry)
                }
            }
            return evicted
        }
        // The evicted images are released here, outside the lock.
        _ = evicted
    }

    /// The held decode of `id` when it is at least `longEdge` and shows `revision`, made the
    /// most recently asked for.
    private func heldEntry(_ id: MediaAssetID, longEdge: Int, revision: Int64) -> CacheEntry? {
        held.withLock { held in
            guard let entry = held.entries[id], entry.longEdge >= longEdge, entry.revision == revision else {
                return nil
            }
            Self.touch(id, in: &held)
            return entry
        }
    }

    private nonisolated static func touch(_ id: MediaAssetID, in held: inout HeldPhotos) {
        held.order.removeAll { $0 == id }
        held.order.append(id)
    }
}
