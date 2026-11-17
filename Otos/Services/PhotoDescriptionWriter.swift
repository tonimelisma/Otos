import CoreGraphics
import Foundation
import ImageIO

/// Photo description writer guide (ADR 0053)
///
/// The one producer of descriptions: every still whose facts are settled for its stored
/// preview (`PhotoDescriptionStorage.describableStill`) and whose description does not name
/// those facts is described again, newest capture first, from its **stored preview** — never
/// its original, so no download is made for it. The preview shows the photo's saved edit and
/// a face is stored on the upright photo, so each face is carried onto the preview through the
/// edit's geometry before the model is told where it is; a face the crop leaves out is not
/// mentioned.
///
/// The write lands only while the row's facts are still the ones described, so a person
/// renamed while the model wrote is described again. A declined photo is stored as declined.
/// A preview that cannot be read or decoded, or a request that failed, writes nothing: the
/// still is passed over for `retryPacing`, so it never holds back the stills after it. A model
/// that is not available, or busy (rate-limited while Otos is in the background), stops the
/// drain until `retryPacing` or `busyPacing` passes, since nothing reports when it would
/// answer.
///
/// Each request first waits for the background room (ADR 0057): while the person is in the
/// app, or the machine is short of memory, hot, or in Low Power Mode, the walk waits there,
/// its status naming the hold (`heldBy`), and goes on in the step that opens the room. The
/// model's service holds about 450 MB more than at rest while it answers.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3) that two sources ring: a Store change of a
/// kind its walk reads (`inputs`: a still's faces and people, place names, capture time,
/// preview, and the search embedding and text reading it waits for, which search's writes
/// announce as `.searchContent`), and the retry wake. Each ring is a request
/// (ADR 0032 rule 2). A change that names its rows owes those stills alone (`stillsOwed`): a
/// still's description is written from its own rows, and from a person's or a place's, whose
/// writes name no photo's rows, so a named change can make no other still owed. Those stills
/// are read by key ahead of the walk's next page, and the walk goes on from its cursor: text
/// reading and the search index name each still they write, and a walk restarted for each of
/// their writes visited the described stills at the top again on every page, 1.1 to 3.4 s a
/// page on the owner's library (`docs/research/2026-11-16-idle-disk-read-attribution.md`). A
/// change that names no rows, and a wake, owe a walk, which visits the owed stills newest
/// first, a page at a time (`CandidateWalk`), each once; a walk owed while one runs restarts it
/// from the newest still at its next page. A request that owes neither reads nothing: every
/// still the last walk passed over waits on its pacing's wake. Requests run one at
/// a time: the model takes one photo at a time, and a second request would only wait in it. The
/// forwarder and the loop hold this actor weakly and end with it. `changes()` rings after
/// descriptions are written, which the Info pane and On This Day's titles read again on. The
/// requests and the wake are kept in `OwnerActivity`, so the writer reports when it owes
/// nothing (`QuiescentOwner`).
actor PhotoDescriptionWriter: QuiescentOwner {
    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let describe: PhotoDescribing
    private let pageSize: Int
    private let retryPacing: Duration
    private let busyPacing: Duration
    /// Whether a request may be made now (ADR 0057): each request runs the system language
    /// model's service beside the app, so it waits while the person is in the app or the
    /// machine is short of room.
    private let room: BackgroundRoom
    /// Stills whose last request failed, and when they may be offered again.
    private var failedUntil: [MediaAssetID: ContinuousClock.Instant] = [:]
    /// When requests may be made again after the model was unavailable or busy.
    private var modelNotBefore: ContinuousClock.Instant?
    /// Walks owed, and the one the last walk that reached the end answered (ADR 0032 rule 2):
    /// owed by the first subscription, by a Store change of a kind a walk reads and by a
    /// pacing that ended, the facts that can make a still describable. Every still a finished
    /// walk passed over is held paced with its deadline (`failedUntil`, `modelNotBefore`), so a
    /// ring that owes no walk reads nothing.
    private var walksOwed: UInt64 = 0
    private var walksCovered: UInt64 = 0
    /// Stills a change named since they were last read by key: owed whatever the walk owes.
    private var stillsOwed: Set<MediaAssetID> = []
    /// Walks asked for and the one the last finished walk answered (ADR 0032 rule 2).
    let activity = OwnerActivity(owner: "descriptions")
    /// What a test waits on to deliver an event while a walk is under way.
    var requested: UInt64 {
        activity.requested
    }

    private var doorbell: AsyncStream<Void>.Continuation?
    private var subscribing = false
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var wake: (task: Task<Void, Never>, at: ContinuousClock.Instant)?
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Drains run, to their end or stopped: what a test waits on.
    private(set) var drains = 0

    static let retryPacing: Duration = .seconds(900)
    static let busyPacing: Duration = .seconds(60)

    /// What a walk reads (`CatalogOwnerInputs`): every fact a still's description names or
    /// waits for, from the walk's own SQL and the facts it reads per still, and which roots are
    /// reachable. Its own writes name no kind: a description is read by no other owner's SQL.
    static let inputs = CatalogOwnerInputs(
        statements: [
            PhotoDescriptionStorage.candidatesSQL(rootCount: 1, position: "a.best_capture_local IS NOT NULL", order: ""),
            PhotoDescriptionStorage.keyedCandidateSQL, PhotoDescriptionStorage.facesSQL, PhotoDescriptionStorage.readingsSQL,
        ],
        ownWrites: [],
        beyondSQL: .membership
    )

    init(
        store: CatalogStore,
        thumbnailDirectory: URL?,
        describe: @escaping PhotoDescribing,
        pageSize: Int = 16,
        retryPacing: Duration = PhotoDescriptionWriter.retryPacing,
        busyPacing: Duration = PhotoDescriptionWriter.busyPacing,
        room: BackgroundRoom = BackgroundRoom()
    ) {
        self.room = room
        self.store = store
        self.thumbnailDirectory = thumbnailDirectory
        self.describe = describe
        self.pageSize = pageSize
        self.retryPacing = retryPacing
        self.busyPacing = busyPacing
    }

    /// Starts the loop and the forwarder, both stored with no suspension between the check and
    /// the store (ADR 0032 rule 1). The forwarder rings once it holds the change stream, so a
    /// change made before it subscribed is read by the drain that ring starts.
    func start() {
        guard loop == nil else { return }
        let (bell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        doorbell = ring
        // Until the forwarder holds the change stream and asks for the first walk, the writer
        // is not quiescent: nothing it owes is known yet.
        subscribing = true
        forwarder = Task { [weak self, store, deliveries = activity.deliveries] in
            let changes = await store.changeNotifications(deliveries: deliveries)
            let inputs = await Self.inputs.facts(in: store, owner: "description")
            await self?.subscribed()
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

    /// Store changes heard: what a test waits on before it counts `requested`.
    private(set) var changesHeard = 0

    /// Owes a walk when `change` is of a kind a walk reads.
    private func heard(_ change: CatalogStoreChange, inputs: CatalogChangedFacts) {
        changesHeard += 1
        if change.touches(inputs) {
            switch change.rows {
            case let .named(rows):
                stillsOwed.formUnion(rows.ids)
                request()
            case .unnamed:
                oweWalk()
            case .none:
                break
            }
        }
        activity.actedOnChange()
        settleQuiescence()
    }

    /// Owes a walk from the newest still and asks for it (ADR 0032 rule 2): a walk under way
    /// starts again from the top at its next page, so a still made owed now — an import's newest
    /// photo — is described before the rest of a long backlog.
    private func oweWalk() {
        walksOwed &+= 1
        request()
    }

    private func request() {
        activity.request()
        doorbell?.yield()
    }

    /// A ring that owes no walk: the pass it asks for walks only when one is already owed.
    func ringIdle() {
        request()
    }

    /// The forwarder holds the change stream: the first walk is owed.
    private func subscribed() {
        subscribing = false
        oweWalk()
        settleQuiescence()
    }

    /// Started, with the forwarder not yet subscribed.
    var holdsWork: Bool {
        subscribing
    }

    /// Every pass is the walk over the library's owed stills, with the stills a change named
    /// read ahead of its next page: model-bound, a second or more a still, so on a large
    /// library the walk lasts hours. Once subscribed, with every change acted on, all it owes
    /// and runs is that backlog.
    var worksBacklog: Bool {
        !subscribing && activity.actedOnEveryChange
    }

    private func pass() async {
        guard activity.isOwed else { return }
        activity.beginPass()
        let answered = await drain()
        activity.endPass(covering: answered)
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
        for continuation in changeContinuations.values {
            continuation.finish()
        }
        changeContinuations = [:]
    }

    /// Yields after descriptions are written.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        changeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeContinuation(id) }
        }
        return stream
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations[id] = nil
    }

    /// Describes every owed still once, a page at a time, newest first. A still whose request
    /// failed is passed over until its pacing passes; a model that is unavailable or busy stops
    /// the drain. Returns the request the walk answered; nil when it failed, so the request
    /// stays owed.
    private func drain() async -> UInt64? {
        defer { drains += 1 }
        guard walksOwed != walksCovered || !stillsOwed.isEmpty else {
            return activity.requested
        }
        let now = ContinuousClock.now
        if let notBefore = modelNotBefore, notBefore > now {
            // The wake asks again when the model may answer.
            armWake(after: now)
            return activity.requested
        }
        modelNotBefore = nil
        failedUntil = failedUntil.filter { $0.value > now }
        var tally = DrainTally()
        // The request and the owed walk the walk answers; a newer owed walk restarts it from the
        // newest still. A walk that fails covers nothing, so the next ring walks again.
        var walking = (request: activity.requested, walk: walksOwed)
        var answered: UInt64?
        var cursor: CaptureOrderCursor?
        while !Task.isCancelled, !tally.stopped {
            if walksOwed != walking.walk {
                walking = (activity.requested, walksOwed)
                cursor = nil
            }
            // The stills a change named come first, read by their keys; the walk, when one is
            // owed, then reads its next page from where it is.
            let keyed = stillsOwed
            stillsOwed = []
            let walks = walking.walk != walksCovered
            var candidates: [PhotoDescriptionCandidate] = []
            var next: CaptureOrderCursor?
            do {
                if !keyed.isEmpty {
                    candidates = try await store.backgroundReads.photoDescriptionCandidatesByKey(of: keyed, excluding: failedUntil.keys)
                    activity.read(rows: candidates.count)
                }
                if walks {
                    let page = try await store.backgroundReads.photoDescriptionCandidates(
                        after: cursor, limit: pageSize, excluding: failedUntil.keys
                    )
                    activity.read(rows: page.candidates.count)
                    let named = Set(candidates.map(\.id))
                    candidates += page.candidates.filter { !named.contains($0.id) }
                    next = page.next
                }
            } catch {
                // What was taken stays owed for the next ring.
                stillsOwed.formUnion(keyed)
                OtosLog.metadata.errorOperation("description", phase: "readFailed", fields: [
                    "error": String(describing: error),
                ])
                break
            }
            let results = await describe(candidates, tally: &tally)
            let stopped = tally.stopped
            do {
                if !results.isEmpty, try await !store.applyPhotoDescriptions(results).isEmpty {
                    announce()
                }
                activity.wrote(results.count)
            } catch {
                OtosLog.metadata.errorOperation("description", phase: "writeFailed", fields: [
                    "count": "\(results.count)", "error": String(describing: error),
                ])
                break
            }
            // A model that stopped answering ends the walk; its wake owes the next one. A drain
            // that owed no walk ends once the named stills are read, unless more were named.
            guard walks else {
                if !stillsOwed.isEmpty, !stopped {
                    walking.request = activity.requested
                    continue
                }
                // A stopped model's wake owes a walk, which finds what was named and not read.
                answered = walking.request
                break
            }
            guard let next, !stopped else {
                answered = walking.request
                if !stopped {
                    walksCovered = walking.walk
                }
                break
            }
            cursor = next
        }
        armWake(after: ContinuousClock.now)
        if tally.written > 0 || tally.declined > 0 || tally.failed > 0 || tally.stopped {
            OtosLog.metadata.noticeOperation("description", phase: "drained", fields: [
                "written": "\(tally.written)", "declined": "\(tally.declined)", "failed": "\(tally.failed)",
                "stopped": "\(tally.stopped)", "paced": "\(failedUntil.count)", "drain": "\(drains)",
            ])
        }
        return answered
    }

    /// What one drain did, for its log line, and whether the model stopped it.
    private struct DrainTally {
        var written = 0
        var declined = 0
        var failed = 0
        var stopped = false
    }

    /// Asks the model for each candidate in turn, each request once the background room lets
    /// it start (ADR 0057), until the model stops answering; returns what to write.
    private func describe(_ candidates: [PhotoDescriptionCandidate], tally: inout DrainTally) async -> [PhotoDescriptionResult] {
        var results: [PhotoDescriptionResult] = []
        for candidate in candidates where !tally.stopped {
            // The room's fact ends the wait; the candidate is still the one read, and its
            // write lands only while its facts are those described.
            activity.heldBy = room.hold(for: .description)?.rawValue
            do {
                try await room.untilOpen(for: .description)
            } catch {
                activity.heldBy = nil
                tally.stopped = true
                break
            }
            activity.heldBy = nil
            let start = ContinuousClock.now
            switch await read(candidate) {
            case let .written(text):
                results.append(PhotoDescriptionResult(id: candidate.id, source: candidate.source, text: text))
                tally.written += 1
                OtosLog.metadata.debugOperation("description", phase: "written", fields: [
                    "relativePath": candidate.id.relativePath.rawValue,
                    "faces": "\(candidate.facts.faces.count)",
                    "ms": "\((ContinuousClock.now - start).milliseconds)",
                ])
            case .declined:
                results.append(PhotoDescriptionResult(id: candidate.id, source: candidate.source, text: nil))
                tally.declined += 1
            case .failed:
                failedUntil[candidate.id] = ContinuousClock.now.advanced(by: retryPacing)
                tally.failed += 1
            case .modelUnavailable:
                modelNotBefore = ContinuousClock.now.advanced(by: retryPacing)
                tally.stopped = true
            case .busy:
                modelNotBefore = ContinuousClock.now.advanced(by: busyPacing)
                tally.stopped = true
            }
        }
        return results
    }

    private func announce() {
        for continuation in changeContinuations.values {
            continuation.yield()
        }
    }

    /// Rings the doorbell when the model may be asked again or a failed still's pacing ends.
    private func armWake(after now: ContinuousClock.Instant) {
        guard let due = ([modelNotBefore].compactMap(\.self) + failedUntil.values).filter({ $0 > now }).min() else {
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
                // time: backoff — a failed request, an unavailable model and a busy one report
                // nothing when they would succeed.
                try await Task.sleep(until: due, clock: .continuous)
            } catch {
                return
            }
            await self?.wakeFired(at: due)
        }, due)
    }

    private func wakeFired(at due: ContinuousClock.Instant) {
        if wake?.at == due {
            wake = nil
            activity.wake = nil
        }
        // A pacing that ended makes its stills describable again.
        oweWalk()
    }

    /// What describing one candidate came to.
    enum Reading: Equatable {
        case written(String)
        case declined
        /// The preview could not be read or decoded, or the request failed.
        case failed
        /// No request can be made: Apple Intelligence is off, the Mac is not eligible, or the
        /// model is not ready.
        case modelUnavailable
        /// The model is rate-limited or answering another request.
        case busy
    }

    private func read(_ candidate: PhotoDescriptionCandidate) async -> Reading {
        guard let thumbnailDirectory else { return .failed }
        let url = thumbnailDirectory.appending(path: candidate.previewPath)
        guard let image = await Self.decode(url) else {
            OtosLog.metadata.errorOperation("description", phase: "previewUndecodable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "preview": candidate.previewPath,
            ])
            return .failed
        }
        let prompt = PhotoDescriptionPrompt(
            faces: Self.faces(candidate, on: CGSize(width: image.width, height: image.height)),
            facts: candidate.facts
        )
        do {
            switch try await describe(image, prompt) {
            case let .written(text): return .written(text)
            case .declined: return .declined
            }
        } catch let error as PhotoDescriber.ModelUnavailable {
            OtosLog.metadata.errorOperation("description", phase: "modelUnavailable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "reason": error.reason,
            ])
            return .modelUnavailable
        } catch {
            let busy = PhotoDescriber.isBusy(error)
            OtosLog.metadata.errorOperation("description", phase: busy ? "busy" : "requestFailed", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return busy ? .busy : .failed
        }
    }

    /// The candidate's faces on a preview of `edited` size showing its edit, each with its
    /// person's name and age then; a face the crop leaves out is not told.
    static func faces(_ candidate: PhotoDescriptionCandidate, on edited: CGSize) -> [PhotoDescriptionPrompt.Face] {
        let geometry = candidate.recipe.hasGeometry
            ? EditGeometry(recipe: candidate.recipe, developedSize: EditGeometry.developedSize(ofEdited: edited, recipe: candidate.recipe))
            : nil
        return candidate.facts.faces.compactMap { face in
            let box = geometry.map { $0.editedRect(ofDevelopedFraction: face.box) } ?? face.box
            guard let box else { return nil }
            return PhotoDescriptionPrompt.Face(
                box: box,
                name: face.name,
                age: face.name == nil ? nil : PhotoDescriptionPrompt.age(birthday: face.birthday, at: candidate.facts.capturedAt)
            )
        }
    }

    /// The stored preview, upright, at most `modelPixelSize` on its long edge: the model reads
    /// a picture of that size as well as a larger one, and a smaller one costs fewer tokens.
    /// Nil when it could not be read or decoded.
    @concurrent
    static func decode(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: modelPixelSize,
        ] as CFDictionary)
    }

    static let modelPixelSize = 1024
}

private nonisolated extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
