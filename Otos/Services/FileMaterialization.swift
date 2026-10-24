import Foundation
import OSLog

/// File materialization guide
///
/// Most Otos media lives in cloud-synced folders (iCloud Drive, OneDrive, Dropbox,
/// Google Drive). On current macOS every one of these is a File Provider domain, and
/// a file the provider has not downloaded is an APFS "dataless" placeholder: it
/// appears in directory enumeration and exposes all of its filesystem facts (name,
/// size, dates, type) without any download, but reading its bytes forces the
/// provider to materialize it, which can pull hundreds of megabytes per file.
///
/// This type answers one question without reading bytes: is a given file a dataless
/// placeholder right now? Cheap filesystem-fact work (the catalog scanner) never
/// needs it because it never reads bytes. Expensive byte-reading work — thumbnail
/// generation and media-metadata (EXIF and similar) extraction — must consult it
/// first so it never *accidentally* triggers a blocking download by faulting on a
/// read. Under the materialization policy (ADR 0008) such work may still
/// *deliberately* download a dataless file it has chosen to enrich, through the
/// non-blocking trigger below, but it must never block a worker on an accidental
/// fault.
///
/// Materialization is transient: a provider can evict a materialized file back to
/// dataless, or download a dataless one, at any time. The status is therefore a
/// point-in-time fact and must never be persisted in the catalog. Asset identity and
/// overlay lifecycle stay on the filesystem path (see
/// `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`); this status
/// is only a runtime gate checked immediately before a potential byte read.
///
/// Detection uses the SF_DATALESS kernel flag, the provider-agnostic signal the File
/// Provider framework sets on every unmaterialized item regardless of vendor.
/// `URLResourceValues.ubiquitousItemDownloadingStatus` reports the same state at a
/// higher level and was used to validate this against a real OneDrive library; the
/// kernel flag is preferred here because it directly answers "will reading this
/// materialize it?" and does not depend on the iCloud-flavored ubiquitous keys being
/// populated by every provider. Reading the flag via `lstat` is pure inode metadata
/// and never materializes the file.
///
/// This is wired into the current byte-reading boundary. `MediaEnricher` checks
/// `status(of:)` immediately before Quick Look thumbnail generation and metadata
/// extraction, and `EnrichmentCoordinator` is the owner that may deliberately
/// materialize dataless files before retrying that byte-reading enrichment work.
/// The catalog scanner still reads only filesystem facts and does not call this.
nonisolated enum FileMaterialization {
    /// SF_DATALESS from `<sys/stat.h>` (macOS 10.15+). When this bit is set in a
    /// file's `st_flags`, reading the file's content triggers the File Provider to
    /// download (materialize) it. Defined here rather than relying on the symbol
    /// being surfaced into the Swift Darwin overlay.
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// Reports the point-in-time materialization status of `url` without reading its
    /// bytes. Pure inode metadata, so it is safe to call from any thread and never forces a cloud download. The result is transient and must
    /// not be persisted.
    static func status(of url: URL) -> FileMaterializationStatus {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            return .unknown
        }
        return (info.st_flags & datalessFlag) != 0 ? .dataless : .materialized
    }
}

/// Materialization (download) helpers.
///
/// `status(of:)` above answers "is this dataless right now?" without reading bytes.
/// These helpers answer the enrichment coordinator's next question: "make it local."
/// They are the deliberate, non-blocking counterpart to faulting bytes in.
///
/// Triggering a download has three mechanisms (see the increment notes): faulting on
/// a byte read (universal but blocks the calling thread for the whole transfer),
/// `FileManager.startDownloadingUbiquitousItem(at:)` (returns immediately, download
/// proceeds asynchronously — documented for iCloud, empirically being validated for
/// third-party File Providers such as OneDrive), and the lower-level
/// `NSFileProviderManager` (identifier-keyed, provider-specific). These helpers wrap
/// the non-blocking ubiquitous trigger plus status polling so a worker never blocks
/// on a transfer; `status(of:)` (SF_DATALESS) is the completion signal because it is
/// the most direct "are the bytes local now?" fact and matches the detector the rest
/// of the app gates on.
///
/// `EnrichmentCoordinator` calls these helpers from its materialization pool when
/// it has deliberately chosen to download a dataless file for enrichment. They are
/// not scanner helpers and must stay out of filesystem-fact catalog reads.
extension FileMaterialization {
    /// Asks the provider to download `url` and returns immediately. Non-blocking: the
    /// transfer proceeds in the background and is observed via `status(of:)`. Throws
    /// if the provider rejects the request.
    nonisolated static func requestMaterialization(of url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Serial queue the attribute watches deliver on; each delivery only rings a doorbell.
    private nonisolated static let watchQueue = DispatchQueue(
        label: "net.melisma.Otos.materialization.watch",
        qos: .utility
    )

    /// Yields each time the file's vnode reports a change. The descriptor is opened with
    /// `O_EVTONLY`, which observes the vnode without reading a byte or materializing it;
    /// the kernel clearing `SF_DATALESS` arrives as an attribute change. A file that
    /// cannot be opened for events yields nothing and finishes at once. The watch ends
    /// when the consumer stops listening.
    nonisolated static func attributeChanges(of url: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.attrib, .write, .extend, .delete, .rename, .revoke],
                queue: watchQueue
            )
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }

    /// Requests a download and waits, off the calling thread, until the file is
    /// materialized or the persistence's deadline passes, woken by the file's own
    /// attribute changes. Never reads bytes itself, so a worker awaiting this is never
    /// blocked on a transfer the way a faulting read would block a thread. Honors
    /// cancellation.
    /// Production probe: a bounded `open()+read(1)` via `FileHandle`. Returns `served`
    /// if any byte is read, `providerUnavailable` only for `ETIMEDOUT`, and
    /// `inconclusive` otherwise. Never blocks longer than ~2s (kernel caps
    /// `ETIMEDOUT` at 1s). This is the only place in the app that deliberately
    /// reads bytes to test liveness — everywhere else uses `SF_DATALESS`.
    /// Serial queue for the liveness probe. The probe performs a deliberately faulting
    /// one-byte read on a dataless file: it blocks until the provider serves or the
    /// kernel returns ETIMEDOUT (~1s). Running that on the Swift cooperative pool —
    /// whose width is the core count, against `globalConcurrency = 16` — can occupy
    /// every cooperative thread and starve unrelated async work, including MainActor
    /// continuations (ENR-008). `.utility` because no user action waits on a probe.
    private nonisolated static let probeQueue = DispatchQueue(
        label: "net.melisma.Otos.materialization.probe",
        qos: .utility,
        attributes: .concurrent
    )

    /// The kernel caps ETIMEDOUT at ~1s, but that is the provider's contract, not ours.
    /// A probe that outlives the poll interval is inconclusive by definition — the
    /// polling loop will ask again.
    private nonisolated static let probeTimeout: Duration = .seconds(3)

    nonisolated static func probeProviderLiveness(of url: URL) async -> FileMaterializationProbeResult {
        // Race the blocking probe against a timeout so a hung provider does not pin
        // a queue thread forever. The orphaned queue work completes and is discarded;
        // it holds one `.utility` thread, not a cooperative one.
        await withTaskGroup(of: FileMaterializationProbeResult.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    probeQueue.async {
                        continuation.resume(returning: blockingProbe(of: url))
                    }
                }
            }
            group.addTask {
                // time: deadline — a hung provider must not pin a probe thread
                try? await Task.sleep(for: probeTimeout)
                return FileMaterializationProbeResult.inconclusive
            }
            guard let first = await group.next() else { return .inconclusive }
            group.cancelAll()
            return first
        }
    }

    /// Timestamps arrival without reading any bytes.
    ///
    /// Hydration is **atomic** — measured 2026-09-01
    /// (`research 2026-09-01-onedrive-hydration-shape-and-latency.md`): `st_blocks` stays
    /// at 0 for the whole download and jumps to full on completion, two transitions per
    /// file, every file. So this logs exactly one line per transfer, and there is no
    /// progress here to report.
    ///
    /// That one line is still worth having: it timestamps arrival independently of the
    /// poll's own bookkeeping, and it keeps the atomicity claim falsifiable — a
    /// provider that ever hydrates progressively will show up as extra transitions rather
    /// than as a silent assumption someone has to re-derive.
    ///
    /// The consequence for the design is the important part: with no byte-level signal,
    /// Otos cannot distinguish "downloading slowly" from "stalled" through the filesystem at
    /// all, so a 3 s `ETIMEDOUT` is not definitive. That is why interactive work persists
    /// rather than deciding to give up on evidence that does not exist. Real progress would
    /// require `NSFileProviderManager`'s `NSProgress`.
    private nonisolated static func progressSample(
        _ url: URL,
        since start: ContinuousClock.Instant
    ) -> (blocks: Int64, logicalBytes: Int64, elapsedMs: Int)? {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            return nil
        }
        return (
            Int64(info.st_blocks),
            Int64(info.st_size),
            DiagnosticsTiming.milliseconds(from: start, to: ContinuousClock().now)
        )
    }

    private nonisolated static func blockingProbe(of url: URL) -> FileMaterializationProbeResult {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
            return .served
        } catch {
            return probeResult(for: error)
        }
    }

    /// Pure error classification for the probe. Domain-qualified errno only.
    /// `localizedDescription` is localized by the *system* locale, so substring
    /// matching on "timed out" silently stops working on a non-English Mac — it was
    /// never load-bearing, and keeping it only disguises a regression in this check.
    nonisolated static func probeResult(for error: any Error) -> FileMaterializationProbeResult {
        let ns = error as NSError
        // Direct POSIX domain
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ETIMEDOUT) {
            return .providerUnavailable
        }
        // Foundation often wraps POSIX in NSCocoaErrorDomain with underlying
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ETIMEDOUT)
        {
            return .providerUnavailable
        }
        return .inconclusive
    }

    /// How hard a materialization tries, and for how long — derived from the request's
    /// priority, so a background-only policy cannot reach interactive work. The two-strike
    /// probe exists to stop a background transfer squatting `rootBackgroundCap=1` for two
    /// minutes — a slot interactive work never holds.
    ///
    /// Applying that probe to interactive requests fails them early. Measured 2026-08-31:
    /// 43 interactive requests failed, every one between 2402 ms and 5539 ms against a
    /// 120 s budget, while the slowest *successful* materialization in the same window took
    /// 62,316 ms. Healthy hydration on this library
    /// reaches 8.9 s (research 2026-07-11) against a 3 s probe timeout, so the threshold
    /// sits inside the provider's own latency distribution.
    nonisolated struct Persistence: Equatable, Sendable {
        /// Abandon after two consecutive `ETIMEDOUT` probes. Background only.
        let failsFastOnProviderUnavailable: Bool
        /// `nil` polls until the caller stops waiting. The provider exposes no transfer
        /// handle (research 2026-07-14), so watching is the only way to learn of arrival,
        /// and a clock is the wrong thing to bound it by — demand is.
        let deadline: Duration?
        /// How often the provider request is re-asserted. `startDownloadingUbiquitousItem`
        /// returns no acknowledgement, so a saturated provider can discard queued work with
        /// no way for us to tell; re-asserting is the only insurance available. One XPC
        /// round trip, against an image the user is staring at — the costs are not
        /// comparable, so interactive asks more often.
        let requestRetryInterval: Duration

        static let background = Persistence(
            failsFastOnProviderUnavailable: true,
            deadline: .seconds(120),
            requestRetryInterval: .seconds(1)
        )

        /// The image in front of the user outranks everything. No deadline: bounded by the
        /// caller going away, which `MaterializationCoordinator` signals by cancelling.
        static let interactive = Persistence(
            failsFastOnProviderUnavailable: false,
            deadline: nil,
            requestRetryInterval: .milliseconds(500)
        )

        /// `command` takes the bounded background persistence: no on-screen demand will
        /// cancel it, so a clock is the only thing that can end a stuck provider wait.
        static func forPriority(_ priority: MaterializationCoordinator.Priority) -> Persistence {
            priority == .interactive ? .interactive : .background
        }
    }

    nonisolated static func materialize(
        _ url: URL,
        persistence: Persistence = .background
    ) async -> MaterializationResult {
        await materialize(
            url,
            persistence: persistence,
            providers: FileMaterializationProviders(
                status: status(of:),
                request: requestMaterialization(of:),
                probe: probeProviderLiveness(of:),
                changes: attributeChanges(of:)
            )
        )
    }

    nonisolated static func materialize(
        _ url: URL,
        persistence: Persistence = .background,
        providers: FileMaterializationProviders
    ) async -> MaterializationResult {
        let start = ContinuousClock.now
        if providers.status(url) == .materialized {
            return finishMaterialization(.alreadyMaterialized, url: url, start: start, rerequestCount: 0)
        }
        if let failed = requestDownload(url, retry: false, requestProvider: providers.request) {
            return finishMaterialization(failed, url: url, start: start, rerequestCount: 0)
        }
        let (outcome, rerequestCount) = await awaitArrival(
            url,
            persistence: persistence,
            providers: providers
        )
        return finishMaterialization(outcome, url: url, start: start, rerequestCount: rerequestCount)
    }

    /// Waits for the bytes to arrive. The kernel reports it: clearing `SF_DATALESS` is an
    /// attribute change on the file's vnode, which an event-only descriptor observes
    /// without reading a byte (`docs/research/2026-10-23-materialization-arrival.md`).
    /// One doorbell is rung by those changes and by the re-request schedule, and each
    /// ring reads the flag. The schedule stays because the provider acknowledges nothing:
    /// a request it drops is only noticed by asking again, and a background wait ends at
    /// its deadline.
    private nonisolated static func awaitArrival(
        _ url: URL,
        persistence: Persistence,
        providers: FileMaterializationProviders
    ) async -> (MaterializationOutcome, Int) {
        let clock = ContinuousClock()
        let deadline = persistence.deadline.map { clock.now.advanced(by: $0) }
        var nextRetry = clock.now.advanced(by: persistence.requestRetryInterval)
        var rerequestCount = 0
        var consecutiveProviderUnavailable = 0
        var lastBlocks: Int64 = -1
        let start = ContinuousClock().now
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = providers.changes(url)
        let watcher = Task {
            for await _ in changes {
                wake.yield()
            }
        }
        var schedule = scheduleWake(wake, at: [nextRetry, deadline].compactMap(\.self).min())
        defer {
            watcher.cancel()
            schedule.cancel()
            wake.finish()
        }
        // The flag may have cleared before the watch was in place; look once now.
        wake.yield()
        for await _ in wakes {
            if let deadline, clock.now >= deadline {
                return (.timedOut, rerequestCount)
            }
            if let sample = progressSample(url, since: start),
               sample.blocks != lastBlocks
            {
                OtosLog.mediaIO.notice(
                    """
                    op=materialization.progress path=\(url.lastPathComponent, privacy: .public) \
                    elapsedMs=\(sample.elapsedMs, privacy: .public) blocks=\(sample.blocks, privacy: .public) \
                    logicalBytes=\(sample.logicalBytes, privacy: .public) \
                    rerequests=\(rerequestCount, privacy: .public)
                    """
                )
                lastBlocks = sample.blocks
            }
            switch materializationWakeDecision(now: clock.now, nextRetry: nextRetry, status: providers.status(url)) {
            case .materialized:
                return (.materialized, rerequestCount)
            case .retryNow:
                rerequestCount += 1
                if let failed = requestDownload(url, retry: true, requestProvider: providers.request) {
                    return (failed, rerequestCount)
                }
                // Probe for a definite provider refusal after each re-request.
                // Two consecutive `providerUnavailable` probes mean the provider
                // is not serving (e.g. OneDrive signed out, `ETIMEDOUT` in 1s)
                // and continued polling would waste the full 120s holding
                // `rootBackgroundCap=1`. Fail fast to free the slot; the
                // retry ledger (15/60/300/900) will pace the next attempt.
                // A single transient ETIMEDOUT that heals on the next tick
                // yields only one probe failure and does not short-circuit.
                guard persistence.failsFastOnProviderUnavailable else {
                    // Interactive: the probe is not consulted at all. It is a one-byte
                    // faulting read whose only consumer was the short-circuit, so running
                    // it here would cost a thread and up to 3 s per re-request to produce
                    // an answer nothing acts on.
                    nextRetry = clock.now.advanced(by: persistence.requestRetryInterval)
                    schedule.cancel()
                    schedule = scheduleWake(wake, at: [nextRetry, deadline].compactMap(\.self).min())
                    continue
                }
                switch await providers.probe(url) {
                case .providerUnavailable:
                    consecutiveProviderUnavailable += 1
                    if consecutiveProviderUnavailable >= 2 {
                        return (.providerUnavailable, rerequestCount)
                    }
                case .served, .inconclusive:
                    consecutiveProviderUnavailable = 0
                }
                nextRetry = clock.now.advanced(by: persistence.requestRetryInterval)
                schedule.cancel()
                schedule = scheduleWake(wake, at: [nextRetry, deadline].compactMap(\.self).min())
            case .waitMore:
                continue
            case .statusUnavailable:
                return (.statusUnavailable, rerequestCount)
            }
        }
        // The wakes end only when this task is cancelled.
        return (.cancelled, rerequestCount)
    }

    /// Rings `wake` at `instant`: the next re-request, or the deadline. Time here is the
    /// provider's silence, not a stand-in for arrival, which the vnode reports.
    private nonisolated static func scheduleWake(
        _ wake: AsyncStream<Void>.Continuation,
        at instant: ContinuousClock.Instant?
    ) -> Task<Void, Never> {
        Task {
            guard let instant else {
                return
            }
            // time: deadline — the provider acknowledges no request and reports no refusal
            try? await ContinuousClock().sleep(until: instant)
            guard !Task.isCancelled else {
                return
            }
            wake.yield()
        }
    }

    /// Pure decision for one wake of `awaitArrival` once the deadline guard has passed:
    /// given the current status, has the file materialized, should a re-request fire
    /// now, or is it too soon since the last one? No I/O and no clock reads — the
    /// answer is a threshold comparison against already-sampled instants, the way
    /// `FilesystemReconciler.decide` sits outside its FSEvents stream — so re-request
    /// counting is tested with synthetic instants built by `Instant.advanced(by:)`.
    nonisolated static func materializationWakeDecision(
        now: ContinuousClock.Instant,
        nextRetry: ContinuousClock.Instant,
        status: FileMaterializationStatus
    ) -> MaterializationWakeDecision {
        switch status {
        case .materialized:
            .materialized
        case .dataless:
            now >= nextRetry ? .retryNow : .waitMore
        case .unknown:
            .statusUnavailable
        }
    }

    private nonisolated static func requestDownload(
        _ url: URL,
        retry: Bool,
        requestProvider: (URL) throws -> Void
    ) -> MaterializationOutcome? {
        let prefix = retry ? "re-" : ""
        do {
            OtosLog.fileAccess.debug(
                """
                File materialization \(prefix, privacy: .public)requested path=\
                \(url.path(percentEncoded: false), privacy: .public)
                """
            )
            try requestProvider(url)
            return nil
        } catch {
            OtosLog.fileAccess.error(
                """
                File materialization \(prefix, privacy: .public)request failed path=\
                \(url.path(percentEncoded: false), privacy: .public) error=\
                \(String(describing: error), privacy: .public)
                """
            )
            return .requestFailed
        }
    }

    private nonisolated static func finishMaterialization(
        _ outcome: MaterializationOutcome,
        url: URL,
        start: ContinuousClock.Instant,
        rerequestCount: Int
    ) -> MaterializationResult {
        let elapsedMs = DiagnosticsTiming.milliseconds(since: start)
        OtosLog.fileAccess.debug(
            """
            File materialization finished outcome=\(outcome.diagnosticDescription, privacy: .public) \
            rerequestCount=\(rerequestCount, privacy: .public) \
            elapsedMs=\(elapsedMs, privacy: .public) \
            path=\(url.path(percentEncoded: false), privacy: .public)
            """
        )
        return MaterializationResult(
            outcome: outcome,
            rerequestCount: rerequestCount,
            elapsedMs: elapsedMs
        )
    }
}

nonisolated enum FileMaterializationProbeResult: Equatable {
    /// A tiny byte read succeeded — provider is serving.
    case served
    /// The read failed with `ETIMEDOUT` (errno 60/110 or "timed out" text) — provider definitively refused.
    case providerUnavailable
    /// The read failed for another reason or the file is missing — inconclusive.
    case inconclusive
}

nonisolated struct FileMaterializationProviders {
    let status: @Sendable (URL) -> FileMaterializationStatus
    let request: @Sendable (URL) throws -> Void
    /// Best-effort probe for a definite provider refusal via a tiny byte read.
    /// Injected for testability; production uses `FileHandle` on a dedicated
    /// `.utility` queue with a 3s timeout. Returns `served` if the read succeeds,
    /// `providerUnavailable` only for domain-qualified `ETIMEDOUT`, and
    /// `inconclusive` for any other error. Never throws.
    let probe: @Sendable (URL) async -> FileMaterializationProbeResult
    /// Yields whenever the file's attributes change. Production watches the vnode through
    /// an event-only descriptor, which reads no bytes; a stream that finishes at once
    /// (the file could not be opened for events) leaves the re-request schedule to wake
    /// the wait.
    let changes: @Sendable (URL) -> AsyncStream<Void>
}

/// Outcome of `materializationWakeDecision`: what one wake of the arrival wait does.
nonisolated enum MaterializationWakeDecision: Equatable {
    /// The provider reports the file materialized; the wait ends.
    case materialized
    /// Still dataless, and `requestRetryInterval` has elapsed since the last request.
    case retryNow
    /// Still dataless, but too soon to re-request.
    case waitMore
    /// The provider's status could not be read; the wait ends.
    case statusUnavailable
}

/// Result of an awaited materialization request. The outcome remains the product
/// state; the counters are transient diagnostics for attributing provider stalls.
nonisolated struct MaterializationResult: Equatable {
    let outcome: MaterializationOutcome
    let rerequestCount: Int
    let elapsedMs: Int

    var isMaterialized: Bool {
        outcome.isMaterialized
    }
}

/// Result of an awaited `materialize(_:)`. Transient like the status it reports.
nonisolated enum MaterializationOutcome: Equatable {
    /// The file was already local; no download was requested.
    case alreadyMaterialized
    /// A download was requested and the file became local within the timeout.
    case materialized
    /// The provider rejected the download request.
    case requestFailed
    /// The file did not become local before the timeout elapsed.
    case timedOut
    /// The provider definitively refused a byte read with `ETIMEDOUT` (errno 60/110)
    /// twice consecutively, so continued polling would waste the 120s timeout
    /// holding `rootBackgroundCap=1` while the provider is not serving. Treated
    /// identically to `timedOut` by retry pacing, but attributed separately so a
    /// future short-circuit can be measured.
    case providerUnavailable
    /// A device staging download was deferred because local free space is below the safety floor.
    case insufficientLocalSpace
    /// The awaiting task was cancelled before completion.
    case cancelled
    /// The file's status could not be read (for example it disappeared).
    case statusUnavailable
    /// The asset belongs to a device root with no live camera session, so its bytes
    /// are not obtainable until the device is reconnected. A real, expected state —
    /// not a provider failure, and never a reason to ask a *cloud* provider for a
    /// camera file (APP-018).
    case deviceUnavailable

    var isMaterialized: Bool {
        switch self {
        case .alreadyMaterialized, .materialized:
            true
        case .requestFailed, .timedOut, .providerUnavailable, .insufficientLocalSpace, .cancelled,
             .statusUnavailable, .deviceUnavailable:
            false
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .alreadyMaterialized:
            "alreadyMaterialized"
        case .materialized:
            "materialized"
        case .requestFailed:
            "requestFailed"
        case .timedOut:
            "timedOut"
        case .providerUnavailable:
            "providerUnavailable"
        case .insufficientLocalSpace:
            "insufficientLocalSpace"
        case .cancelled:
            "cancelled"
        case .statusUnavailable:
            "statusUnavailable"
        case .deviceUnavailable:
            "deviceUnavailable"
        }
    }
}

/// Point-in-time materialization status of a file. Transient and never persisted: a
/// cloud provider can change it at any time by evicting or downloading the file.
nonisolated enum FileMaterializationStatus: Equatable, Sendable {
    /// Bytes are present locally; reading them does not trigger a download.
    case materialized
    /// A dataless cloud placeholder; reading its bytes forces the provider to
    /// download it. Skip or defer byte access (thumbnails, media metadata).
    case dataless
    /// Status could not be determined, for example the item is missing or its
    /// metadata could not be read. Callers should not read bytes on this result.
    case unknown
}
