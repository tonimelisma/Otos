import CoreGraphics
import Foundation
import ImageIO
import MediaMetadata

/// Runs `MediaMetadata` parses that block, on threads that are allowed to block.
///
/// A camera ranged read costs ~40–90 ms and `MediaMetadataReader.read` is synchronous, so a
/// parse blocks its thread for roughly 100–300 ms per file. Where that happens matters more
/// than how long it takes:
///
/// - **Not the main actor** — two orders of magnitude past the 100 ms hang budget.
/// - **Not Swift's cooperative pool** — it is sized to the core count, and blocking its
///   threads is a forward-progress hazard rather than a slowdown: the pool assumes threads
///   yield at suspension points, and a blocked one never does. Enrichment runs there, so
///   `Task.detached` would have been exactly the wrong tool despite looking like the right
///   one.
///
/// Hence a dedicated queue. It is serial because the transport underneath is: ImageCapture-
/// Core funnels every request through one `ICDeviceCommandQueue`, so a second concurrent
/// parse would buy no parallelism and would queue somewhere Otos cannot observe. One parse
/// at a time keeps a stalled read attributable to one named file.
///
/// This is the "dedicated thread" the plan named and the repo did not have: the only other
/// `DispatchQueue`s here serve DiskArbitration and FSEvents, neither of which blocks.
/// One camera parse, plus what waiting for the camera cost it.
nonisolated struct ParsedCameraItem: Sendable {
    let result: MediaMetadataResult
    /// Time blocked on the transport. The gap between this and the parse's own elapsed time
    /// is everything that is *not* the camera — scheduling, contention, decode — and is the
    /// number that says whether tuning chunk sizes could help at all.
    let transportWaitMilliseconds: Int
}

nonisolated enum CameraMetadataReader {
    private static let queue = DispatchQueue(
        label: "net.melisma.Otos.camera-metadata",
        qos: .utility
    )

    /// Chunk size for the read-through cache wrapped around a camera source.
    ///
    /// Still worth wrapping even though `MediaMetadata` 0.5.0 coalesces internally: its
    /// buffer is sized for a parse's working set, this one for a transport where a miss
    /// costs a ~40 ms round trip rather than a page fault. The package's `transportReadCount`
    /// is what shows whether this layer is earning its place — logged per asset in
    /// `MediaEnricher`, so a vendor whose containers defeat it is visible rather than
    /// inferred.
    ///
    /// Measured, not guessed. A parse touches one region for stills — ~44 KB for ARW, ~101 KB
    /// for HEIF — and three for MP4, while issuing up to 168 individual reads inside them.
    /// Uncached at 42.6 ms median latency that is ~5.9 s per HEIF file, which is no faster
    /// than downloading the file outright; served from one 128 KB chunk the same parse costs
    /// 91 ms. The package owns the caching mechanism, and this number is the part only a
    /// consumer that knows its transport can supply.
    static let chunkSize = 128 * 1024

    /// Parses one camera item from ranged reads, off the main actor and off the pool.
    ///
    /// `readCost` on the result is what proves the cache is working: a parse that reports
    /// 138 read operations is reaching the transport for every one of them.
    static func read(
        session: DeviceCameraSession,
        relativePath: MediaRelativePath,
        size: UInt64
    ) async -> ParsedCameraItem {
        await withCheckedContinuation { continuation in
            queue.async {
                let source = CameraByteSource(session: session, relativePath: relativePath, size: size)
                let cached = CachingByteSource(wrapping: source, chunkSize: chunkSize)
                let result = MediaMetadataReader.read(source: cached, filenameHint: relativePath.rawValue)
                continuation.resume(
                    returning: ParsedCameraItem(
                        result: result,
                        transportWaitMilliseconds: source.transportWaitMilliseconds
                    )
                )
            }
        }
    }

    /// Fetches and decodes a container's embedded preview into a grid-sized thumbnail.
    ///
    /// This is the only path that ever gives a camera tile a real thumbnail, and the reason
    /// is enrichment's stamp-once rule: `needsEnrichment` does not consider whether a
    /// thumbnail exists, so once a device row is stamped it is never re-claimed. "Generate
    /// it later, when the file is local" therefore means "never" for as long as the card is
    /// attached — the tile would keep ImageCaptureCore's 160×120 embedded EXIF thumb, which
    /// is all that body returns however large a size is asked for.
    ///
    /// The package reports *where* the preview is; the bytes are fetched here and decoded
    /// with ImageIO, which is the split that keeps the package free of graphics frameworks.
    /// ImageIO is also why this is needed at all for RAW: it refuses a truncated container
    /// outright, so a prefix of an ARW cannot be decoded even though the preview inside it
    /// is a complete JPEG.
    ///
    /// Cost is one extra ranged read of a few hundred kilobytes, and only when the container
    /// declares a preview at least as large as the grid needs. A smaller one is skipped
    /// rather than upscaled: a blurred 160×120 is not an improvement on the provisional
    /// thumbnail already on disk, it is the same picture with more steps.
    static func loadPreviewImage(
        session: DeviceCameraSession,
        relativePath: MediaRelativePath,
        size: UInt64,
        previews: [EmbeddedPreview]
    ) async -> CGImage? {
        // Largest first, by bytes, because declared dimensions are usually absent — Sony's
        // ARW omits them in exactly the directories that carry previews. Selecting on
        // `pixelWidth >= 256` therefore discarded every preview on real files: measured,
        // 991 camera tiles kept a 160x120 thumbnail while a full-size preview sat inside
        // each one. Whether a preview is actually an improvement is decided after decoding
        // it, below, where the real dimensions are known rather than declared.
        guard let preview = previews.first else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let source = CameraByteSource(session: session, relativePath: relativePath, size: size)
                // `try?` collapses a throw to nil, and the inner optional is the protocol's
                // out-of-bounds answer. Both mean the same thing here — no preview — so
                // flattening them is honest rather than lossy.
                guard let bytes = try? source.data(
                    offset: preview.byteOffset,
                    length: preview.byteLength
                ) ?? nil else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let image = decodeThumbnail(from: bytes) else {
                    continuation.resume(returning: nil)
                    return
                }
                // Only an improvement counts. ImageCaptureCore's own thumbnail is 160x120,
                // already on disk and already shown, so replacing it with something no
                // larger spends a read to change nothing.
                guard image.width > 160 || image.height > 120 else {
                    OtosLog.metadata.noticeOperation("camera.previewThumbnail", phase: "notBetter", fields: [
                        "relativePath": relativePath.rawValue,
                        "decoded": "\(image.width)x\(image.height)",
                    ])
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    /// Downsamples the embedded image to the grid's size without ever decoding it full-size.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageIfAbsent` is false on purpose: this is already
    /// an embedded preview, and asking ImageIO to synthesise one from the full image would
    /// decode a 1616×1080 JPEG to produce a 256 px tile.
    private static func decodeThumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: ThumbnailStore.maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Whether this device can serve ranged reads at all, decided once per session.
    ///
    /// `requestReadDataAtOffset` sits on MTP's `GetPartialObject`, which is **optional** —
    /// absent from the mandatory PTP command set, so a body or phone may not implement it.
    /// Devices that do can still be wrong: shipping devices are documented failing it by
    /// timeout on particular offsets, and ImageCaptureCore is documented answering with zero
    /// bytes and no error at all.
    ///
    /// So the gate is empirical rather than declared: read 12 bytes and require the magic to
    /// identify a container family consistent with the item's own extension. A short read, an
    /// error, empty data, or a family that disagrees with the name all mean the same thing —
    /// do not trust this transport — and the session stages instead, which is what the
    /// shipped build does for every device today.
    ///
    /// Costs one read against one item per attach.
    static func isRangeCapable(
        session: DeviceCameraSession,
        relativePath: MediaRelativePath,
        size: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let source = CameraByteSource(session: session, relativePath: relativePath, size: size)
                let format = MediaMetadataReader.identify(source: source, filenameHint: relativePath.rawValue)
                let capable = format.detectedByMagic && format.family != .unknown
                OtosLog.metadata.noticeOperation("camera.rangedRead", phase: "capability", fields: [
                    "identity": session.identity,
                    "capable": "\(capable)",
                    "probe": relativePath.rawValue,
                    "family": format.family.rawValue,
                    "extension": format.fileExtension,
                ])
                continuation.resume(returning: capable)
            }
        }
    }
}
