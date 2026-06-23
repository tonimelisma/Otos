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
/// first and skip or defer dataless files instead of silently triggering downloads.
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
/// NOT WIRED UP: nothing in the current app calls this. The current catalog stores
/// only filesystem facts and reads no bytes, so it has no materialization concern.
/// This is deliberately present ahead of the thumbnail and media-metadata pipelines
/// so those increments wire it in at their byte-read boundary instead of
/// rediscovering the cloud hazard. Tests keep it verified.
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
