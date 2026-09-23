import Foundation

/// How enrichment reaches an asset's bytes.
///
/// A bare `URL` would quietly assert that every asset's bytes are a local file. For a
/// camera reachable only over MTP that is false, and the cost of the assumption is the
/// whole card: to read a capture date, Otos would transfer every file so there is a URL to
/// hand to the reader — measured at 36.5 GB and ~45 minutes before the Import button could
/// appear.
///
/// Naming the two ways to reach bytes makes the device case expressible instead of
/// requiring a download to fake it. Both cases carry only `Sendable` values;
/// `DeviceCameraSession` is `@MainActor` and therefore `Sendable`, and the non-`Sendable`
/// `ICCameraFile` stays inside it.
nonisolated enum EnrichmentByteAccess: Sendable {
    /// Bytes are a local file: a library, a mounted card, or a device item already staged.
    case localFile(URL)

    /// Bytes are reachable only as ranges from an attached camera.
    ///
    /// Size comes from `ICCameraFile.fileSize` rather than the filesystem, because there is
    /// no filesystem entry to stat.
    case cameraRanges(session: DeviceCameraSession, relativePath: MediaRelativePath, size: UInt64)

    /// Where the bytes would be on disk, when that is a meaningful question.
    ///
    /// Readiness, hashing and thumbnail generation all still need a real file. A camera row
    /// answers `nil`, which is the honest answer and forces each of those to say what it
    /// does when there is no file rather than silently operating on a path that does not
    /// exist.
    var localURL: URL? {
        switch self {
        case let .localFile(url): url
        case .cameraRanges: nil
        }
    }
}
