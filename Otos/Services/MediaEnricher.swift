import CoreGraphics
import Foundation
import MediaMetadata
import OSLog
import QuickLookThumbnailing

/// Media enricher guide
///
/// Produces both products for one already-materialized media file: parsed metadata
/// (the `MediaMetadata` library, byte-reading, synchronous) and a 256 px thumbnail
/// (QuickLook). It is a small `Sendable` value with one injectable closure, mirroring
/// `CatalogScanner`, so the coordinator and tests can substitute a fake.
///
/// It runs entirely off the main actor inside the coordinator's worker task. The first
/// thing it does is re-check materialization immediately before any byte read (ADR 0008):
/// the coordinator routed this id as materialized, but a provider can evict between the
/// routing check and this read, so the safety gate lives here, right before the read.
///
/// Outcomes drive the store's stamp-vs-retry. A definitive metadata read (`parsed` or
/// `unsupported`) yields `.complete` and is stamped, so it is not retried until the file
/// changes — even if the file embeds no metadata and QuickLook could only render an icon.
/// A transient read failure yields `.transient` (retry); a regressed-to-dataless file
/// yields `.notMaterialized` (route back to download).
nonisolated struct MediaEnricher {
    var enrich: @Sendable (
        _ id: MediaAssetID,
        _ url: URL,
        _ sourceSize: Int64?,
        _ sourceMTimeSeconds: Int?
    ) async -> EnrichmentOutcome

    /// The production enricher. `thumbnailDirectory` is captured so the per-asset
    /// signature stays small; the coordinator supplies the catalog's thumbnail directory.
    static func live(thumbnailDirectory: URL) -> MediaEnricher {
        MediaEnricher { id, url, sourceSize, sourceMTimeSeconds in
            guard FileMaterialization.status(of: url) == .materialized else {
                return .notMaterialized
            }
            let result = MediaMetadataReader.read(url: url)
            guard !result.outcome.shouldRetry else {
                return .transient
            }
            let thumbnailPath = await Self.generateThumbnail(id: id, url: url, directory: thumbnailDirectory)
            return .complete(
                EnrichmentResult(
                    id: id,
                    metadata: Self.map(result),
                    captureDate: Self.resolveCaptureDate(result.timestamps),
                    thumbnailPath: thumbnailPath,
                    sourceSize: sourceSize,
                    sourceMTimeSeconds: sourceMTimeSeconds
                )
            )
        }
    }

    /// Generates a 256 px thumbnail and writes it, returning its relative name. Accepts
    /// QuickLook's icon fallback (a generic tile beats none); a generation failure returns
    /// `nil` and is not fatal — the definitive metadata is still recorded.
    static func generateThumbnail(id: MediaAssetID, url: URL, directory: URL) async -> String? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: ThumbnailStore.maxPixelSize, height: ThumbnailStore.maxPixelSize),
            scale: 1,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return try ThumbnailStore.write(
                representation.cgImage,
                named: ThumbnailStore.relativeName(for: id),
                in: directory
            )
        } catch {
            OtosLog.thumbnails.error(
                "Thumbnail generation failed path=\(url.path(percentEncoded: false), privacy: .public)"
            )
            return nil
        }
    }

    /// Otos's best-known metadata capture date, by priority. The filesystem fallback is
    /// applied later, at display, by `MediaAsset.bestCaptureDate`.
    static func resolveCaptureDate(_ timestamps: CaptureTimestamps) -> Date? {
        timestamps.original?.instant
            ?? timestamps.quickTimeCreation?.instant
            ?? timestamps.digitized?.instant
            ?? timestamps.gps?.instant
    }

    /// Maps the full library result into Otos's persisted blob shape — every field.
    static func map(_ result: MediaMetadataResult) -> AssetMetadata {
        AssetMetadata(
            family: result.format.family.rawValue,
            fileExtension: result.format.fileExtension,
            brand: result.format.brand,
            timestamps: mapTimestamps(result.timestamps),
            locations: mapLocations(result.locations),
            cameraMake: result.camera?.make,
            cameraModel: result.camera?.model,
            lensModel: result.camera?.lensModel,
            serialNumber: result.camera?.serialNumber,
            orientation: result.camera?.orientation?.rawValue,
            pixelWidth: result.camera?.pixelWidth,
            pixelHeight: result.camera?.pixelHeight,
            durationSeconds: result.video?.durationSeconds,
            frameRate: result.video?.frameRate,
            videoCodec: result.video?.codec.map { String(describing: $0) }
        )
    }

    private static func mapTimestamps(_ timestamps: CaptureTimestamps) -> [CaptureTimestampRecord] {
        var records: [CaptureTimestampRecord] = []
        func add(_ time: CaptureTime?, _ role: String) {
            guard let time else { return }
            records.append(
                CaptureTimestampRecord(
                    role: role,
                    instant: time.instant,
                    utcOffsetSeconds: time.utcOffsetSeconds,
                    precision: time.precision.rawValue,
                    year: time.year,
                    month: time.month,
                    day: time.day,
                    hour: time.hour,
                    minute: time.minute,
                    second: time.second
                )
            )
        }
        add(timestamps.original, "original")
        add(timestamps.digitized, "digitized")
        add(timestamps.tiffDateTime, "tiffDateTime")
        add(timestamps.gps, "gps")
        add(timestamps.quickTimeCreation, "quickTimeCreation")
        add(timestamps.quickTimeLocation, "quickTimeLocation")
        add(timestamps.quickTimeContentCreate, "quickTimeContentCreate")
        add(timestamps.containerCreation, "containerCreation")
        add(timestamps.id3Recording, "id3Recording")
        add(timestamps.waveOrigination, "waveOrigination")
        add(timestamps.riffRecording, "riffRecording")
        return records
    }

    private static func mapLocations(_ locations: CaptureLocations) -> [GeoRecord] {
        var records: [GeoRecord] = []
        func add(_ location: GeoLocation?, _ source: String) {
            guard let location else { return }
            records.append(
                GeoRecord(
                    source: source,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    altitudeMeters: location.altitudeMeters
                )
            )
        }
        add(locations.exifGPS, "exifGPS")
        add(locations.quickTime, "quickTime")
        add(locations.sonyNRTM, "sonyNRTM")
        return records
    }
}

/// The result of enriching one asset. The coordinator collects `.complete` results into
/// a batch for `CatalogStore.applyEnrichmentBatch`; `.transient`/`.notMaterialized` are
/// re-queued (the asset stays `needsEnrichment`).
nonisolated enum EnrichmentOutcome {
    case complete(EnrichmentResult)
    case transient
    case notMaterialized
}
