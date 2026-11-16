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
/// A signature records the thumbnail it was read from (`render_signature_source`). When
/// enrichment renders a new thumbnail — a changed file, an edit — the source no longer
/// matches and the row is offered again; no write site needs to know signatures exist.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3): the Store's change notifications ring it,
/// and each wake drains every stale row in pages. The page is read as values, the
/// thumbnails are decoded off this actor (`@concurrent`), and the results are written only
/// where the row's thumbnail is still the one decoded. A thumbnail that does not decode is
/// recorded as such, so it is not offered again until it changes. The forwarder and the loop
/// hold this actor weakly and end with it.
actor RenderSignatureRefresher {
    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let pageSize: Int
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?

    init(store: CatalogStore, thumbnailDirectory: URL?, pageSize: Int = 128) {
        self.store = store
        self.thumbnailDirectory = thumbnailDirectory
        self.pageSize = pageSize
    }

    func start() async {
        guard loop == nil else { return }
        let (doorbell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = await store.changeNotifications()
        ring.yield()
        forwarder = Task { [weak self] in
            for await change in changes {
                guard self != nil else { break }
                if case .changed = change {
                    ring.yield()
                }
            }
            ring.finish()
        }
        loop = Task { [weak self] in
            for await _ in doorbell {
                guard let self else { return }
                await drain()
            }
        }
    }

    /// Ends the loop now — a test's teardown; in the app, the loops end with the actor.
    func shutdown() {
        forwarder?.cancel()
        loop?.cancel()
        forwarder = nil
        loop = nil
    }

    /// Signs every stale row in one walk (`CandidateWalk`), a page at a time; a failed read or
    /// write is logged and waits for the next ring. A row whose thumbnail changed while it was
    /// read is not written, and the change that made it stale rings the next walk.
    private func drain() async {
        var signed = 0
        var cursor: AssetKeyCursor?
        while !Task.isCancelled {
            let page: CandidatePage<RenderSignatureCandidate, AssetKeyCursor>
            do {
                page = try await store.renderSignatureCandidates(after: cursor, limit: pageSize)
            } catch {
                OtosLog.thumbnails.errorOperation("renderSignature", phase: "readFailed", fields: [
                    "error": String(describing: error),
                ])
                return
            }
            let results = await Self.sign(page.candidates, thumbnailDirectory: thumbnailDirectory)
            do {
                signed += results.isEmpty ? 0 : try await store.applyRenderSignatures(results)
            } catch {
                OtosLog.thumbnails.errorOperation("renderSignature", phase: "writeFailed", fields: [
                    "count": "\(results.count)", "error": String(describing: error),
                ])
                return
            }
            guard let next = page.next else { break }
            cursor = next
        }
        if signed > 0 {
            OtosLog.thumbnails.noticeOperation("renderSignature", phase: "signed", fields: ["count": "\(signed)"])
        }
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
