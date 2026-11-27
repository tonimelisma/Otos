import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Render signature guide (ADR 0042)
///
/// The one producer of render signatures: a still's difference hash and 32 × 32 grayscale
/// render, read from its **stored thumbnail** in Application Support. It never opens an
/// original, so it never downloads one.
///
/// A signature is stored only while it is the current thumbnail's (`RenderSignatureSQL`).
/// When enrichment renders a new thumbnail — a changed file, an edit — the write that names
/// it clears the signature (`CatalogSchema.renderSignatureStaleTrigger`) and the row is offered
/// again; no write site needs to know signatures exist. A signature is written only where the
/// row's thumbnail identity is still the one read.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3): a Store change of a kind its walk reads
/// rings it (`inputs`; its own signature writes do not), and each wake drains every stale row
/// in pages. The page is read as values, the
/// thumbnails are decoded off this actor (`@concurrent`), and the results are written only
/// where the row's thumbnail is still the one decoded. A thumbnail that does not decode is
/// recorded as such, so it is not offered again until it changes. The forwarder and the loop
/// hold this actor weakly and end with it. Each ring is a request (`OwnerActivity`), covered
/// by a walk that read and wrote without failing, so the refresher reports when it owes
/// nothing (`QuiescentOwner`).
actor RenderSignatureRefresher: QuiescentOwner {
    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let pageSize: Int
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var doorbell: AsyncStream<Void>.Continuation?
    let activity = OwnerActivity(owner: "renderSignatures")

    init(store: CatalogStore, thumbnailDirectory: URL?, pageSize: Int = 128) {
        self.store = store
        self.thumbnailDirectory = thumbnailDirectory
        self.pageSize = pageSize
    }

    /// What a pass reads (`CatalogOwnerInputs`): its candidate walk's columns, less its own
    /// writes (a signature is a duplicates fact), and which roots are reachable.
    static let inputs = CatalogOwnerInputs(
        statements: [RenderSignatureSQL.candidatesSQL], ownWrites: .duplicateFacts, beyondSQL: .membership
    )

    /// Store changes heard, and those that rang the doorbell: what a test waits on.
    private(set) var changesHeard = 0
    private(set) var wakes = 0

    func start() async {
        guard loop == nil else { return }
        let (bell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = await store.changeNotifications(deliveries: activity.deliveries)
        let inputs = await Self.inputs.facts(in: store, owner: "renderSignature")
        // Read after the awaits: a concurrent `start()` may have won.
        guard loop == nil else { return }
        doorbell = ring
        request()
        forwarder = Task { [weak self] in
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

    /// Rings for `change` when it is of a kind a pass reads.
    private func heard(_ change: CatalogStoreChange, inputs: CatalogChangedFacts) {
        changesHeard += 1
        if change.touches(inputs) {
            wakes += 1
            request()
        }
        activity.actedOnChange()
        settleQuiescence()
    }

    /// Asks for a walk (ADR 0032 rule 2).
    private func request() {
        activity.request()
        doorbell?.yield()
    }

    func ringIdle() {
        request()
    }

    /// The stills whose thumbnail has no current render signature: the count behind `Looking
    /// for duplicates` (ADR 0058). The groups are built from these signatures, so they are its
    /// measurable part.
    func progress(for _: ActivityKind) async -> WorkProgress? {
        do {
            return try await activity.progress(left: store.backgroundReads.renderSignaturesLeft())
        } catch {
            WorkProgress.logFailure(owner: "renderSignatures", error)
            return nil
        }
    }

    private func pass() async {
        guard activity.isOwed else { return }
        let answering = activity.beginPass()
        let walked = await drain()
        activity.endPass(covering: walked ? answering : nil)
        settleQuiescence()
    }

    /// Ends the loop now — a test's teardown; in the app, the loops end with the actor.
    func shutdown() {
        forwarder?.cancel()
        loop?.cancel()
        forwarder = nil
        loop = nil
        doorbell = nil
    }

    /// Signs every stale row in one walk (`CandidateWalk`), a page at a time; a failed read or
    /// write is logged and waits for the next ring. A row whose thumbnail changed while it was
    /// read is not written, and the change that made it stale rings the next walk. Returns
    /// whether the walk read and wrote without failing.
    private func drain() async -> Bool {
        var signed = 0
        var cursor: AssetKeyCursor?
        while !Task.isCancelled {
            let page: CandidatePage<RenderSignatureCandidate, AssetKeyCursor>
            do {
                page = try await store.backgroundReads.renderSignatureCandidates(after: cursor, limit: pageSize)
            } catch {
                OtosLog.thumbnails.errorOperation("renderSignature", phase: "readFailed", fields: [
                    "error": String(describing: error),
                ])
                return false
            }
            activity.read(rows: page.candidates.count)
            let results = await Self.sign(page.candidates, thumbnailDirectory: thumbnailDirectory)
            do {
                let written = results.isEmpty ? 0 : try await store.applyRenderSignatures(results)
                signed += written
                activity.wrote(results.count)
                activity.finished(written)
            } catch {
                OtosLog.thumbnails.errorOperation("renderSignature", phase: "writeFailed", fields: [
                    "count": "\(results.count)", "error": String(describing: error),
                ])
                return false
            }
            guard let next = page.next else { break }
            cursor = next
        }
        if signed > 0 {
            OtosLog.thumbnails.noticeOperation("renderSignature", phase: "signed", fields: ["count": "\(signed)"])
        }
        return !Task.isCancelled
    }

    @concurrent
    private static func sign(_ page: [RenderSignatureCandidate], thumbnailDirectory: URL?) async -> [RenderSignatureResult] {
        page.map { candidate in
            let image: CGImage? = thumbnailDirectory.flatMap { directory in
                let url = directory.appending(path: candidate.thumbnailPath)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                else {
                    return nil
                }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            return RenderSignatureResult(
                id: candidate.id,
                source: candidate.source,
                signature: image.flatMap(RenderSignature.init(image:))
            )
        }
    }
}
