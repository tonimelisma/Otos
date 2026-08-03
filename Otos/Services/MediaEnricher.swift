import CoreGraphics
import Foundation
import MediaMetadata
import OSLog
import QuickLookThumbnailing
import UniformTypeIdentifiers

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
/// changes — even when QuickLook cannot produce a real thumbnail (icon fallback is
/// rejected; the grid shows a broken-media placeholder instead). Thumbnail bytes are
/// staged, not published to their final deterministic filename, so Store remains the
/// owner that decides whether a derived product matches current catalog truth. A
/// transient read failure yields `.transient` (retry); a regressed-to-dataless file
/// yields `.notMaterialized` (route back to download).
nonisolated struct MediaEnricher {
    var enrich: @Sendable (
        _ id: MediaAssetID,
        _ url: URL,
        _ sourceSize: Int64?,
        _ sourceMTimeSeconds: Int?,
        _ shouldHash: Bool
    ) async -> EnrichmentOutcome

    /// The production enricher. `thumbnailDirectory` is captured so the per-asset
    /// signature stays small; the coordinator supplies the catalog's thumbnail
    /// directory. `contentHasher` is injectable so tests can prove a
    /// `.removableVolume` source performs no full-file read — the digest read is the
    /// only byte source that reads a whole file.
    static func live(
        thumbnailDirectory: URL,
        readinessChecker: any EnrichmentReadinessChecking = LiveEnrichmentReadinessChecker(),
        contentHasher: @escaping @Sendable (URL) -> ContentHasher.Outcome = { url in
            ContentHasher().hashMaterializedFile(at: url)
        }
    ) -> MediaEnricher {
        MediaEnricher { id, url, sourceSize, sourceMTimeSeconds, shouldHash in
            guard readinessChecker.status(of: url) == .materialized else {
                return .notMaterialized
            }
            // `shouldHash` is false only for `.removableVolume` sources (ADR 0018/plan
            // 0062): hashing them in place would force a full read of the whole card
            // merely to checksum it. Skip the read entirely rather than hash and
            // discard — `contentHash` stays nil and the store leaves any existing
            // digest untouched.
            guard shouldHash else {
                return await Self.enrichWithoutHash(
                    id: id,
                    url: url,
                    sourceSize: sourceSize,
                    sourceMTimeSeconds: sourceMTimeSeconds,
                    thumbnailDirectory: thumbnailDirectory,
                    readinessChecker: readinessChecker
                )
            }
            let hashStart = Date()
            let hashSignpost = OtosSignpost.mediaIO.beginInterval("ContentHash")
            let hashOutcome = contentHasher(url)
            OtosSignpost.mediaIO.endInterval("ContentHash", hashSignpost)
            switch hashOutcome {
            case let .complete(contentHash):
                let hashMs = DiagnosticsTiming.milliseconds(since: hashStart)
                OtosLog.mediaIO.noticeOperation(
                    "contentHash",
                    phase: "finish",
                    fields: [
                        "owner": "enrichment",
                        "rootPath": id.libraryRootPath.rawValue,
                        "relativePath": id.relativePath.rawValue,
                        "bytes": "\(max(sourceSize ?? 0, 0))",
                        "elapsedMs": "\(hashMs)",
                        "mbps": throughputMBps(bytes: max(sourceSize ?? 0, 0), elapsedMs: hashMs),
                    ]
                )
                guard readinessChecker.status(of: url) == .materialized else {
                    return .notMaterialized
                }
                return await Self.parseAndComplete(
                    id: id,
                    url: url,
                    sourceSize: sourceSize,
                    sourceMTimeSeconds: sourceMTimeSeconds,
                    contentHash: contentHash,
                    thumbnailDirectory: thumbnailDirectory,
                    readinessChecker: readinessChecker
                )
            case .cancelled:
                OtosLog.mediaIO.noticeOperation(
                    "contentHash",
                    phase: "cancelled",
                    fields: [
                        "owner": "enrichment",
                        "rootPath": id.libraryRootPath.rawValue,
                        "relativePath": id.relativePath.rawValue,
                    ]
                )
                return .transient
            case let .failed(category):
                OtosLog.mediaIO.errorOperation(
                    "contentHash",
                    phase: "failed",
                    fields: [
                        "owner": "enrichment",
                        "rootPath": id.libraryRootPath.rawValue,
                        "relativePath": id.relativePath.rawValue,
                        "category": category.rawValue,
                    ]
                )
                return .transient
            }
        }
    }

    /// The un-hashed path: identical to the post-hash continuation above except no
    /// digest was produced, so `EnrichmentResult.contentHash` stays nil.
    private static func enrichWithoutHash(
        id: MediaAssetID,
        url: URL,
        sourceSize: Int64?,
        sourceMTimeSeconds: Int?,
        thumbnailDirectory: URL,
        readinessChecker: any EnrichmentReadinessChecking
    ) async -> EnrichmentOutcome {
        await parseAndComplete(
            id: id,
            url: url,
            sourceSize: sourceSize,
            sourceMTimeSeconds: sourceMTimeSeconds,
            contentHash: nil,
            thumbnailDirectory: thumbnailDirectory,
            readinessChecker: readinessChecker
        )
    }

    /// Metadata parse, readiness re-check, and thumbnail generation — shared by the
    /// hashed and un-hashed paths once each has (or has decided not to produce) a
    /// digest.
    private static func parseAndComplete(
        id: MediaAssetID,
        url: URL,
        sourceSize: Int64?,
        sourceMTimeSeconds: Int?,
        contentHash: XXH3Digest128?,
        thumbnailDirectory: URL,
        readinessChecker: any EnrichmentReadinessChecking
    ) async -> EnrichmentOutcome {
        let result = MediaMetadataReader.read(url: url)
        guard !result.outcome.shouldRetry else {
            return .transient
        }
        guard readinessChecker.status(of: url) == .materialized else {
            return .notMaterialized
        }
        let generatedThumbnail = await Self.generateThumbnail(
            id: id,
            url: url,
            directory: thumbnailDirectory
        )
        let metadata = Self.map(result)
        return .complete(
            EnrichmentResult(
                id: id,
                metadata: metadata,
                timestampFacts: Self.timestampFacts(result.timestamps),
                enrichedKind: Self.normalizedKind(result.format),
                enrichedFormat: MediaFormatToken.normalize(extension: result.format.fileExtension),
                thumbnailPath: nil,
                sourceSize: sourceSize ?? -1,
                sourceMTimeSeconds: sourceMTimeSeconds ?? -1,
                contentHash: contentHash,
                generatedThumbnail: generatedThumbnail
            )
        )
    }

    /// Generates a 256 px thumbnail and stages it, returning the staged/final names.
    /// Requests only real imagery (`.thumbnail` / `.lowQualityThumbnail`) — never
    /// QuickLook's generic `.icon` fallback. A generation failure returns `nil` and is
    /// a definitive "no thumbnail available" outcome; enrichment still stamps metadata
    /// so the asset is not retried until the file changes, and the grid shows a
    /// broken-media placeholder.
    static func generateThumbnail(id: MediaAssetID, url: URL, directory: URL) async -> GeneratedThumbnail? {
        let generationStart = Date()
        let signpost = OtosSignpost.thumbnails.beginInterval("ThumbnailGenerate")
        defer {
            OtosSignpost.thumbnails.endInterval("ThumbnailGenerate", signpost)
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: ThumbnailStore.maxPixelSize, height: ThumbnailStore.maxPixelSize),
            scale: 1,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let thumbnail = try ThumbnailStore.stage(
                representation.cgImage,
                finalRelativeName: ThumbnailStore.relativeName(for: id),
                in: directory
            )
            let generationMs = DiagnosticsTiming.milliseconds(since: generationStart)
            OtosLog.thumbnails.info(
                """
                Thumbnail generation finished path=\(url.path(percentEncoded: false), privacy: .public) \
                thumbnailPath=\(thumbnail.finalRelativePath, privacy: .public) \
                representation=\(String(describing: representation.type), privacy: .public) \
                generationMs=\(generationMs, privacy: .public)
                """
            )
            return thumbnail
        } catch {
            OtosLog.thumbnails.errorOperation(
                "catalog.thumbnails.generate",
                phase: "unavailable",
                fields: [
                    "path": url.path(percentEncoded: false),
                    "error": String(describing: error),
                ]
            )
            return nil
        }
    }

    /// Promotes the timestamp roles that participate in the current best-date
    /// generated column. Roles without a usable UTC instant remain nil here while
    /// their raw components stay preserved in metadata JSON.
    static func timestampFacts(_ timestamps: CaptureTimestamps) -> EnrichmentTimestampFacts {
        EnrichmentTimestampFacts(
            original: timestamps.original?.instant,
            quickTimeCreation: timestamps.quickTimeCreation?.instant,
            digitized: timestamps.digitized?.instant,
            gps: timestamps.gps?.instant
        )
    }

    static func normalizedKind(_ format: MediaFormat) -> MediaKind? {
        let kind = UTType(filenameExtension: format.fileExtension)
            .flatMap(MediaKind.classify)
        if let kind {
            return kind
        }
        switch format.family {
        case .jpeg, .heif, .tiff:
            return .image
        case .isoBMFF, .riffAVI:
            return .video
        case .id3, .riffWAV, .unknown:
            return nil
        }
    }

    /// Maps the full library result into Otos's owned metadata record — every field.
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
        // MED-004: Otos is image/video only. ID3 (MP3) and WAVE/BWF are audio-only
        // containers Otos never catalogs, so their timestamp roles are not persisted.
        // RIFF is kept: it also carries AVI, which is a cataloged video format.
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
