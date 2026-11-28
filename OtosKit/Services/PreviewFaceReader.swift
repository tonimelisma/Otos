import CoreGraphics
import Foundation
import ImageIO

/// Preview face reader guide (ADR 0047)
///
/// The one producer of faces: every still in a library or an Immich account is read for its
/// faces from its **stored preview** in Application Support — Otos's 2560 px rendering
/// (ADR 0035), or until there is one, the source's own preview (an Immich preview, ADR 0046
/// §7). It never opens an original, so it never downloads one. Measured on a private
/// labelled set, faces read from the preview make the same identity decisions as faces read from
/// the original at full resolution
/// (`docs/research/2026-11-12-faces-from-the-preview.md`).
///
/// A preview shows the photo's saved edit, and a face is stored on the upright photo, so each
/// face read from it is carried back through the edit's geometry (`EditGeometry`). A preview
/// whose edit is no longer the one stored waits for its new rendering.
///
/// The faces are stamped with the source stamp the preview was made from, so a new version
/// of the file, with its new preview, is read again; an edit is not a new source and is not
/// read again. A write lands only while the row still has the preview that was read. Only a
/// preview that decoded and held no face is stamped with no faces. A preview that could not
/// be read or decoded, or whose analysis failed, writes nothing: the still stays owed and is
/// offered again after `retryPacing`, or at once when its preview changes
/// (`PreviewFaceRetries`). When the model cannot be loaded no still can be read, so the drain
/// stops and reading resumes after the same pacing, not at the next catalog change.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3) that a Store change of a kind its walk reads
/// (`inputs`; its own face writes do not) and the retry wake ring. The reader holds what a drain
/// owes (`PreviewFaceDebt`): the whole walk, a page at a time, at the start, after a change that
/// does not name its rows and when the model's pacing ends; else the stills a change named and
/// those whose retry came due, each read by key. A still that cannot be read now is held paced
/// with its deadline, which arms the wake, and no drain reads it before then: a ring that brings
/// neither a change nor a deadline reads nothing. The previews are decoded and analysed off this
/// actor, by `FaceAnalyzer` on its own queue. The forwarder, the loop and the wake hold this
/// actor weakly and end with it. Each ring is a request (`OwnerActivity`), covered by a drain
/// that read and wrote without failing; a drain that leaves stills paced arms the wake, which
/// the reader's quiescence names (`QuiescentOwner`).
actor PreviewFaceReader: QuiescentOwner {
    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let analyzeFaces: FaceAnalysisReader
    private let pageSize: Int
    private var retries: PreviewFaceRetries
    /// What the next drain owes; the whole walk until the first has run.
    private var owed = PreviewFaceDebt.wholeWalk
    private var doorbell: AsyncStream<Void>.Continuation?
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    /// Rings the doorbell when the earliest retry comes due; replaced when that changes.
    private var wake: (task: Task<Void, Never>, at: ContinuousClock.Instant)?
    /// Drains run, to their end or stopped: what a test waits on, and logged with each read.
    private(set) var drains = 0
    let activity = OwnerActivity(owner: "previewFaces")

    /// How long a still whose faces could not be read, or every still while the model cannot
    /// be loaded, waits before it is read again.
    static let retryPacing: Duration = .seconds(900)

    init(
        store: CatalogStore,
        thumbnailDirectory: URL?,
        analyzeFaces: @escaping FaceAnalysisReader,
        pageSize: Int = 32,
        retryPacing: Duration = PreviewFaceReader.retryPacing
    ) {
        self.store = store
        self.thumbnailDirectory = thumbnailDirectory
        self.analyzeFaces = analyzeFaces
        self.pageSize = pageSize
        retries = PreviewFaceRetries(pacing: retryPacing)
    }

    /// Starts the loop and the forwarder. Both are made and stored here with no suspension
    /// between the check and the store (ADR 0032 rule 1), so a second call finds them. The
    /// forwarder rings once it holds the change stream, so a change made before it subscribed
    /// is read by the drain that ring starts.
    func start() {
        guard loop == nil else { return }
        let (bell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        doorbell = ring
        // The first drain is owed from here, before the forwarder subscribes: a change made
        // before it did is read by that drain.
        activity.request()
        forwarder = Task { [weak self, store, deliveries = activity.deliveries] in
            let changes = await store.changeNotifications(deliveries: deliveries)
            let inputs = await Self.inputs.facts(in: store, owner: "face.preview")
            ring.yield()
            for await change in changes {
                guard let self else { break }
                await heard(change, inputs: inputs)
            }
            ring.finish()
        }
        loop = Task { [weak self] in
            for await _ in bell {
                guard let self else { return }
                await pass()
            }
        }
    }

    /// Asks for a drain (ADR 0032 rule 2).
    private func request() {
        activity.request()
        doorbell?.yield()
    }

    /// A ring that brings nothing new: the drain it asks for reads only what is already owed.
    /// What stops faces now (`PreviewFaceRetries.troubles`).
    func troubles() async -> [OwnerTrouble] {
        retries.troubles(at: ContinuousClock.now)
    }

    /// The stills not yet checked for faces: their share of `Scanning for faces`
    /// (ADR 0058).
    func progress(for _: ActivityKind) async -> WorkProgress? {
        do {
            return try await activity.progress(left: store.backgroundReads.facesLeft(), parked: retries.parked)
        } catch {
            WorkProgress.logFailure(owner: "previewFaces", error)
            return nil
        }
    }

    func ringIdle() {
        request()
    }

    private func pass() async {
        guard activity.isOwed else { return }
        let answering = activity.beginPass()
        let drained = await drain()
        activity.endPass(covering: drained ? answering : nil)
        settleQuiescence()
    }

    /// What a drain reads (`CatalogOwnerInputs`): its candidate walk's columns, less its own
    /// writes (faces), and which roots are reachable.
    static let inputs = CatalogOwnerInputs(
        statements: [PreviewFaceSQL.candidatesSQL(rootCount: 1), PreviewFaceSQL.keyedCandidateSQL], ownWrites: .faces,
        beyondSQL: .membership
    )

    /// Store changes heard, and those that rang the doorbell: what a test waits on.
    private(set) var changesHeard = 0
    private(set) var wakes = 0

    /// Rings for `change` when it is of a kind a drain reads, owing the rows it names, or the
    /// whole walk when it names none.
    private func heard(_ change: CatalogStoreChange, inputs: CatalogChangedFacts) {
        changesHeard += 1
        if change.touches(inputs) {
            wakes += 1
            owed.take(change.rows)
            request()
        }
        activity.actedOnChange()
        settleQuiescence()
    }

    /// Ends the loop now — a test's teardown; in the app, the loops end with the actor.
    func shutdown() {
        forwarder?.cancel()
        loop?.cancel()
        wake?.task.cancel()
        forwarder = nil
        loop = nil
        wake = nil
        activity.wake = nil
        doorbell = nil
    }

    /// Reads what is owed (`owed`): the whole walk, a page at a time in catalog order, each page
    /// after the last row of the one before, or the owed stills by key. A row whose read failed
    /// is left owed, paced and passed over, so it never holds back the rows after it. A model
    /// that cannot be loaded stops the drain. Returns whether the drain read and wrote without
    /// failing: a paced still is owed to the wake, not to this drain, and what a failed drain
    /// took stays owed.
    private func drain() async -> Bool {
        defer { drains += 1 }
        let now = ContinuousClock.now
        guard retries.admitsModel(at: now) else {
            armWake(after: now)
            return true
        }
        let debt = owed
        owed = .nothing
        guard debt != .nothing else { return true }
        var tally = DrainTally()
        let drained = switch debt {
        case .wholeWalk: await walk(at: now, tally: &tally)
        case let .stills(ids): await read(ids, at: now, tally: &tally)
        }
        guard drained else {
            owed.take(debt)
            return false
        }
        armWake(after: now)
        if tally.stored > 0 || tally.failed > 0 || tally.modelUnavailable {
            OtosLog.metadata.noticeOperation("face.preview", phase: "read", fields: [
                "count": "\(tally.stored)", "failed": "\(tally.failed)", "modelUnavailable": "\(tally.modelUnavailable)",
                "paced": "\(retries.stills.count)", "drain": "\(drains)",
            ])
        }
        return !Task.isCancelled
    }

    /// What one drain read and wrote.
    private struct DrainTally {
        var stored = 0
        var failed = 0
        var modelUnavailable = false
    }

    /// Every row owed faces, a page at a time. A still no longer owed has nothing to retry.
    private func walk(at now: ContinuousClock.Instant, tally: inout DrainTally) async -> Bool {
        var cursor: PreviewFaceCursor?
        var offered: Set<MediaAssetID> = []
        var reachedEnd = false
        while !Task.isCancelled, !tally.modelUnavailable {
            let page: PreviewFacePage
            do {
                page = try await store.backgroundReads.previewFaceCandidates(after: cursor, limit: pageSize)
            } catch {
                OtosLog.metadata.errorOperation("face.preview", phase: "readFailed", fields: [
                    "error": String(describing: error),
                ])
                return false
            }
            activity.read(rows: page.candidates.count)
            offered.formUnion(page.candidates.map(\.id))
            guard await readAndWrite(page.candidates, at: now, tally: &tally) else { return false }
            guard let next = page.next else {
                reachedEnd = true
                break
            }
            cursor = next
        }
        if reachedEnd, !tally.modelUnavailable {
            retries.keep(only: offered)
        }
        return true
    }

    /// The stills of `ids` still owed faces, read by key, then a page at a time. A still asked
    /// for that is no longer owed has nothing to retry.
    private func read(_ ids: Set<MediaAssetID>, at now: ContinuousClock.Instant, tally: inout DrainTally) async -> Bool {
        let owedStills: [PreviewFaceCandidate]
        do {
            owedStills = try await store.backgroundReads.previewFaceCandidates(among: ids)
        } catch {
            OtosLog.metadata.errorOperation("face.preview", phase: "readFailed", fields: [
                "error": String(describing: error),
            ])
            return false
        }
        activity.read(rows: owedStills.count)
        retries.forget(ids.subtracting(owedStills.map(\.id)))
        var at = 0
        while at < owedStills.count, !Task.isCancelled, !tally.modelUnavailable {
            let page = Array(owedStills[at ..< min(at + pageSize, owedStills.count)])
            at += page.count
            guard await readAndWrite(page, at: now, tally: &tally) else { return false }
        }
        return true
    }

    /// Reads the faces of each candidate the pacing admits and writes what was read, with no
    /// write when nothing was; false when the write failed. A model that cannot be loaded stops
    /// the reading.
    private func readAndWrite(
        _ candidates: [PreviewFaceCandidate],
        at now: ContinuousClock.Instant,
        tally: inout DrainTally
    ) async -> Bool {
        var results: [PreviewFaceResult] = []
        for candidate in candidates where !tally.modelUnavailable {
            guard retries.admits(candidate, at: now) else { continue }
            switch await read(candidate) {
            case let .faces(faces):
                retries.read(candidate)
                results.append(PreviewFaceResult(candidate: candidate, faces: faces))
            case .failed:
                retries.failed(candidate, at: now)
                tally.failed += 1
            case .modelUnavailable:
                retries.modelFailed(at: now)
                tally.modelUnavailable = true
            }
        }
        guard !results.isEmpty else { return true }
        do {
            let stored = try await store.applyPreviewFaces(results)
            tally.stored += stored
            activity.wrote(results.count)
            activity.finished(stored)
        } catch {
            OtosLog.metadata.errorOperation("face.preview", phase: "writeFailed", fields: [
                "count": "\(results.count)", "error": String(describing: error),
            ])
            return false
        }
        return true
    }

    /// Rings the doorbell when the earliest retry comes due, if one waits.
    private func armWake(after now: ContinuousClock.Instant) {
        guard let due = retries.nextWake(after: now) else {
            wake?.task.cancel()
            wake = nil
            activity.wake = nil
            return
        }
        guard wake?.at != due else { return }
        wake?.task.cancel()
        activity.wake = OwnerWake(kind: .backoff, at: due)
        wake = (Task { [weak self] in
            do {
                // time: backoff — a preview that could not be read, or a model that could not
                // be loaded, reports nothing when it would succeed.
                try await Task.sleep(until: due, clock: .continuous)
            } catch {
                return
            }
            await self?.wakeFired(at: due)
        }, due)
    }

    /// The pacing that ended by `due` owes its stills, or the whole walk once the model's ended.
    private func wakeFired(at due: ContinuousClock.Instant) {
        if wake?.at == due {
            wake = nil
            activity.wake = nil
        }
        let ended = retries.owed(at: due)
        owed.take(ended)
        request()
    }

    /// What reading one candidate came to.
    enum Reading {
        /// The faces, placed on the upright photo; none when the preview decoded and held none.
        case faces(EnrichedFaces)
        /// This preview could not be read, decoded or analysed: nothing is known of its faces.
        case failed
        /// The model could not be loaded, so no preview can be read.
        case modelUnavailable
    }

    /// The faces of one candidate's preview. A preview that cannot be read or decoded, or
    /// whose analysis failed, is `failed`: nothing is stamped, since a stamp would say the
    /// still holds no face (ADR 0032 rule 4).
    private func read(_ candidate: PreviewFaceCandidate) async -> Reading {
        guard let thumbnailDirectory else { return .failed }
        let url = thumbnailDirectory.appending(path: candidate.previewPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            OtosLog.metadata.errorOperation("face.preview", phase: "previewUnreadable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "preview": candidate.previewPath,
            ])
            return .failed
        }
        guard let image = await Self.decode(url) else {
            OtosLog.metadata.errorOperation("face.preview", phase: "previewUndecodable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "preview": candidate.previewPath,
            ])
            return .failed
        }
        do {
            let analysis = try await analyzeFaces(image)
            let edited = CGSize(width: image.width, height: image.height)
            return .faces(EnrichedFaces(
                faces: analysis.faces.map { Self.upright($0, readFrom: edited, recipe: candidate.recipe) },
                analysisRevision: FaceAnalyzer.revision
            ))
        } catch let FaceAnalysisError.modelUnavailable(description) {
            OtosLog.metadata.errorOperation("face.preview", phase: "modelUnavailable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "error": description,
            ])
            return .modelUnavailable
        } catch {
            OtosLog.metadata.errorOperation("face.preview", phase: "analysisFailed", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return .failed
        }
    }

    /// `face`, read from a preview of `edited` size showing `recipe`, as it lies on the
    /// upright photo: its five points carried back through the edit's geometry, and its box
    /// the bounds of its corners carried back, kept inside the photo. A preview with no
    /// geometry in its edit is the upright photo.
    static func upright(_ face: DetectedFace, readFrom edited: CGSize, recipe: EditRecipe) -> DetectedFace {
        guard recipe.hasGeometry else { return face }
        let geometry = EditGeometry(recipe: recipe, developedSize: EditGeometry.developedSize(ofEdited: edited, recipe: recipe))
        let corners = [
            CGPoint(x: face.box.minX, y: face.box.minY), CGPoint(x: face.box.maxX, y: face.box.minY),
            CGPoint(x: face.box.minX, y: face.box.maxY), CGPoint(x: face.box.maxX, y: face.box.maxY),
        ].map(geometry.developedFraction(atEditedFraction:))
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return DetectedFace(
            box: box,
            landmarks: FaceAlignment.Landmarks(
                leftEye: geometry.developedFraction(atEditedFraction: face.landmarks.leftEye),
                rightEye: geometry.developedFraction(atEditedFraction: face.landmarks.rightEye),
                nose: geometry.developedFraction(atEditedFraction: face.landmarks.nose),
                leftMouth: geometry.developedFraction(atEditedFraction: face.landmarks.leftMouth),
                rightMouth: geometry.developedFraction(atEditedFraction: face.landmarks.rightMouth)
            ),
            quality: face.quality,
            embedding: face.embedding
        )
    }

    /// The stored preview, decoded whole and turned upright by any orientation it carries; nil
    /// when it could not be, whatever the reason: nothing is then known of its faces.
    @concurrent
    private static func decode(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary)
    }
}

/// When a still whose faces could not be read is offered again, and when reading resumes after
/// the model could not be loaded (ADR 0047). A value with synchronous transitions (ADR 0032
/// rule 1): every instant comes in as an argument, so each wait is tested by passing the
/// instant it covers rather than by waiting for it.
nonisolated struct PreviewFaceRetries: Sendable {
    /// A still whose read failed, and the preview it failed on: a new preview is read at once.
    struct Entry: Sendable, Equatable {
        let candidate: PreviewFaceCandidate
        let notBefore: ContinuousClock.Instant
    }

    let pacing: Duration
    private(set) var stills: [MediaAssetID: Entry] = [:]
    private(set) var modelNotBefore: ContinuousClock.Instant?

    init(pacing: Duration) {
        self.pacing = pacing
    }

    /// Whether any still may be read at `now`: not while the model waits out its pacing.
    func admitsModel(at now: ContinuousClock.Instant) -> Bool {
        modelNotBefore.map { $0 <= now } ?? true
    }

    /// Whether `candidate` may be read at `now`: unless its read failed on this same preview
    /// and its pacing has not passed.
    func admits(_ candidate: PreviewFaceCandidate, at now: ContinuousClock.Instant) -> Bool {
        guard let entry = stills[candidate.id], entry.candidate == candidate else { return true }
        return entry.notBefore <= now
    }

    mutating func failed(_ candidate: PreviewFaceCandidate, at now: ContinuousClock.Instant) {
        stills[candidate.id] = Entry(candidate: candidate, notBefore: now.advanced(by: pacing))
    }

    /// A read that came to faces: neither the still nor the model waits any longer.
    mutating func read(_ candidate: PreviewFaceCandidate) {
        stills[candidate.id] = nil
        modelNotBefore = nil
    }

    mutating func modelFailed(at now: ContinuousClock.Instant) {
        modelNotBefore = now.advanced(by: pacing)
    }

    /// What stops faces at `now`: the model, while it waits out its pacing, and the stills
    /// whose reads failed, until theirs passes.
    func troubles(at now: ContinuousClock.Instant) -> [OwnerTrouble] {
        var troubles: [OwnerTrouble] = []
        if let modelNotBefore, modelNotBefore > now {
            troubles.append(OwnerTrouble(.faceModelUnavailable))
        }
        let failed = stills.values.count { $0.notBefore > now }
        if failed > 0 {
            troubles.append(OwnerTrouble(.facesUnread, count: failed))
        }
        return troubles
    }

    /// The stills whose read failed and that wait to be read again, or are being read again:
    /// every one is still unchecked, until its read lands (`read`). While the model waits, no
    /// still can be read, which the board reads as every one parked (`Int.max`, bounded by
    /// what is left).
    var parked: Int {
        modelNotBefore == nil ? stills.count : Int.max
    }

    /// Keeps only the stills still owed faces.
    mutating func keep(only owed: Set<MediaAssetID>) {
        stills = stills.filter { owed.contains($0.key) }
    }

    /// Forgets stills no longer owed faces.
    mutating func forget(_ ids: Set<MediaAssetID>) {
        for id in ids {
            stills[id] = nil
        }
    }

    /// What a drain owes once the pacing has run to `now`: the whole walk when the model's has
    /// ended, which this takes up, else the stills whose own has.
    mutating func owed(at now: ContinuousClock.Instant) -> PreviewFaceDebt {
        if let modelNotBefore, modelNotBefore <= now {
            self.modelNotBefore = nil
            return .wholeWalk
        }
        let due = Set(stills.filter { $0.value.notBefore <= now }.keys)
        return due.isEmpty ? .nothing : .stills(due)
    }

    /// The earliest retry still ahead of `now`, or nil when nothing waits.
    func nextWake(after now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        ([modelNotBefore].compactMap(\.self) + stills.values.map(\.notBefore)).filter { $0 > now }.min()
    }
}

/// What the preview face reader's next drain owes (ADR 0032 rule 2 for its walk): every still
/// owed faces, read by the walk; or the stills a change named, or whose retry came due, read by
/// key; or nothing, when no change and no deadline reached the reader since its last drain.
nonisolated enum PreviewFaceDebt: Equatable, Sendable {
    case wholeWalk
    case stills(Set<MediaAssetID>)

    static let nothing = PreviewFaceDebt.stills([])

    /// Adds what a change owes: the rows it names, or the whole walk when it names none.
    mutating func take(_ rows: CatalogChangedRows) {
        switch rows {
        case .unnamed: self = .wholeWalk
        case let .named(named): take(.stills(named.ids))
        case .none: break
        }
    }

    mutating func take(_ other: PreviewFaceDebt) {
        switch (self, other) {
        case (.wholeWalk, _): break
        case (_, .wholeWalk): self = .wholeWalk
        case let (.stills(held), .stills(more)): self = .stills(held.union(more))
        }
    }
}
