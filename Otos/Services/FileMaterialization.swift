import Foundation

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
    /// bytes. Pure inode metadata, so it is safe to call off the main actor on any
    /// thread and never forces a cloud download. The result is transient and must
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
    static func requestMaterialization(of url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Requests a download and waits, off the calling thread, until the file is
    /// materialized or `timeout` elapses, polling SF_DATALESS every `pollInterval`.
    /// Never reads bytes itself, so a worker awaiting this is never blocked on a
    /// transfer the way a faulting read would block a thread. Honors cancellation
    /// between polls.
    static func materialize(
        _ url: URL,
        pollInterval: Duration = .milliseconds(250),
        timeout: Duration = .seconds(120)
    ) async -> MaterializationOutcome {
        if status(of: url) == .materialized {
            return .alreadyMaterialized
        }
        do {
            try requestMaterialization(of: url)
        } catch {
            return .requestFailed
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return .cancelled
            }
            switch status(of: url) {
            case .materialized:
                return .materialized
            case .dataless:
                continue
            case .unknown:
                return .statusUnavailable
            }
        }
        return .timedOut
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
    /// The awaiting task was cancelled before completion.
    case cancelled
    /// The file's status could not be read (for example it disappeared).
    case statusUnavailable
}

/// Point-in-time materialization status of a file. Transient and never persisted: a
/// cloud provider can change it at any time by evicting or downloading the file.
nonisolated enum FileMaterializationStatus: Equatable {
    /// Bytes are present locally; reading them does not trigger a download.
    case materialized
    /// A dataless cloud placeholder; reading its bytes forces the provider to
    /// download it. Skip or defer byte access (thumbnails, media metadata).
    case dataless
    /// Status could not be determined, for example the item is missing or its
    /// metadata could not be read. Callers should not read bytes on this result.
    case unknown
}
