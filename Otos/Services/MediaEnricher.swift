import CoreGraphics
import Foundation
import MediaMetadata
import OSLog
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Media enricher guide
///
/// Produces the products for one already-materialized media file: parsed metadata
/// (the `MediaMetadata` library, byte-reading, synchronous), and — for a still — one
/// `ImageRenderer` development that becomes the stored 2560 px preview and the 256 px
/// thumbnail drawn from it (ADR 0035); a video, or a still the renderer cannot read,
/// gets its thumbnail from QuickLook. It is a small `Sendable` value with one injectable closure, mirroring
/// `CatalogScanner`, so the coordinator and tests can substitute a fake.
///
/// It runs entirely off the main actor in a task-group child of the coordinator's worker
/// pass (`EnrichmentCoordinator`). The first
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
        _ access: EnrichmentByteAccess,
        _ sourceSize: Int64?,
        _ sourceMTimeSeconds: Int?,
        _ shouldHash: Bool,
        _ recipe: StoredEditRecipe?
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
        MediaEnricher { id, access, sourceSize, sourceMTimeSeconds, shouldHash, recipe in
            // A camera row has no local file, so the readiness checker — which asks the
            // filesystem — cannot speak for it. It is routed here precisely because its
            // bytes are reachable another way, and answering `.notMaterialized` would send
            // it back to be downloaded, which is the cost this path exists to avoid.
            guard case let .localFile(url) = access else {
                return await Self.enrichFromRanges(
                    id: id,
                    access: access,
                    sourceSize: sourceSize,
                    sourceMTimeSeconds: sourceMTimeSeconds,
                    thumbnailDirectory: thumbnailDirectory
                )
            }
            guard readinessChecker.status(of: url) == .materialized else {
                return .notMaterialized
            }
            // `shouldHash` is false only for `.removableVolume` sources (ADR
            // 0018): hashing them in place would force a full read of the whole card
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
                    readinessChecker: readinessChecker,
                    recipe: recipe
                )
            }
            let hashStart = ContinuousClock.now
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
                    readinessChecker: readinessChecker,
                    recipe: recipe
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

    /// Enriches a row whose bytes are ranges on an attached camera.
    ///
    /// Deliberately narrower than the local path, and each omission is a decision rather
    /// than a gap:
    ///
    /// - **No content hash.** Hashing needs every byte, which is the transfer this path
    ///   exists to avoid. A device row receives its digest after import, from the
    ///   destination's local bytes — exactly what ADR 0018 already prescribes for a
    ///   removable volume.
    /// - **No QuickLook thumbnail.** QuickLook needs a file. The camera's own provisional
    ///   thumbnail is already on disk from enumeration and is not disturbed; a full-quality
    ///   one comes from the container's embedded preview, which the package reports the
    ///   location of.
    /// - **No readiness re-check.** There is no local file whose materialization could have
    ///   regressed underneath us.
    ///
    /// A `.readFailure` returns `.transient`, never `.complete`. That is the whole reason
    /// the byte source throws rather than returning nil on a transport fault: a definitive
    /// outcome here would stamp "this file has no capture date", and ARC-057 would then name
    /// it from its filesystem mtime — a name that is also the dedupe key, so a detached
    /// camera would produce duplicate imports rather than a retry.
    private static func enrichFromRanges(
        id: MediaAssetID,
        access: EnrichmentByteAccess,
        sourceSize: Int64?,
        sourceMTimeSeconds: Int?,
        thumbnailDirectory: URL
    ) async -> EnrichmentOutcome {
        guard case let .cameraRanges(session, relativePath, size) = access else {
            return .notMaterialized
        }
        let started = ContinuousClock.now
        let parsed = await CameraMetadataReader.read(
            session: session,
            relativePath: relativePath,
            size: size
        )
        let result = parsed.result
        guard !result.outcome.shouldRetry else {
            OtosLog.metadata.noticeOperation("camera.rangedRead", phase: "transient", fields: [
                "rootPath": id.libraryRootPath.rawValue,
                "relativePath": relativePath.rawValue,
            ])
            return .transient
        }
        // What the read actually cost, per asset. The package counts it, and it is the only
        // way to see a vendor whose containers need ten times the reads, or a chunk cache
        // that has stopped working — both of which look like "import is slow" from outside.
        OtosLog.metadata.noticeOperation("camera.rangedRead", phase: "finish", fields: [
            "rootPath": id.libraryRootPath.rawValue,
            "relativePath": relativePath.rawValue,
            // What the camera was actually asked to do, after the package's internal
            // buffering and Otos's chunk cache. This is the number that costs ~40 ms each
            // over MTP, and the gap between it and `parserReads` is the only direct evidence
            // that the caching is working — a ratio near 1 means a parse is paying a round
            // trip per field, which reads from outside as "import is slow".
            "transportReads": "\(result.readCost.transportReadCount)",
            "uniqueBytes": "\(result.readCost.uniqueBytesRead)",
            "fileBytes": "\(size)",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: started))",
            // Splits "the camera is slow" from "everything around the camera is slow". A
            // parse whose elapsed time greatly exceeds its transport wait is not
            // transport-bound, and tuning chunk sizes cannot help it.
            "transportWaitMs": "\(parsed.transportWaitMilliseconds)",
            // What the container declares, so a preview that is found but rejected is
            // distinguishable from one that was never there. The thumbnail path silently
            // produced nothing on real ARW files and neither case could be told apart.
            "previews": "\(result.previews.count)",
            "previewSizes": result.previews
                .map { "\($0.pixelWidth ?? -1)x\($0.pixelHeight ?? -1)@\($0.sourcePath)" }
                .joined(separator: ","),
        ])
        // The container's own preview, when it declares one big enough to be an improvement.
        // This is the only chance to give this tile a real thumbnail: the row is about to be
        // stamped, and a stamped row is never re-claimed, so "generate it later" means never
        // for as long as the card is attached.
        let generatedThumbnail = await Self.stagedPreviewThumbnail(
            id: id,
            session: session,
            relativePath: relativePath,
            size: size,
            previews: result.previews,
            thumbnailDirectory: thumbnailDirectory
        )
        return .complete(
            EnrichmentResult(
                id: id,
                metadata: Self.map(result),
                enrichedKind: Self.normalizedKind(result.format),
                enrichedFormat: MediaFormatToken.normalize(extension: result.format.fileExtension),
                // Keeps the camera's provisional thumbnail when this pass produced no
                // better one. `EnrichmentResult` resolves `generatedThumbnail?.finalRelative-
                // Path ?? thumbnailPath`, so passing nil for both *clears* the column — and
                // the provisional JPEG written at enumeration lives at exactly this
                // deterministic name, so clearing it points the tile at nothing while its
                // image sits on disk.
                //
                // Measured on a 991-item card: 684 rows lost their thumbnail this way, with
                // all 8,606 files still present. A tile that had an image showing a
                // placeholder is precisely what APP-015 exists to prevent, and no unit test
                // caught it because the provisional write and the enrichment write are
                // owned by different types.
                thumbnailPath: Self.existingThumbnailName(for: id, in: thumbnailDirectory),
                sourceSize: sourceSize ?? -1,
                sourceMTimeSeconds: sourceMTimeSeconds ?? -1,
                contentHash: nil,
                generatedThumbnail: generatedThumbnail
            )
        )
    }

    /// The deterministic thumbnail name for `id`, when a file is actually there.
    ///
    /// Returns nil when nothing is on disk, so a row with no thumbnail at all still reports
    /// none rather than a path that resolves to a missing file.
    static func existingThumbnailName(for id: MediaAssetID, in directory: URL) -> String? {
        let name = ThumbnailStore.relativeName(for: id)
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? name : nil
    }

    /// Test seam for `existingThumbnailName`, which is otherwise only reachable through a
    /// live camera session.
    static func testExistingThumbnailName(for id: MediaAssetID, in directory: URL) -> String? {
        existingThumbnailName(for: id, in: directory)
    }

    /// Stages a grid thumbnail from a container's embedded preview, or nil when there is
    /// none worth using.
    ///
    /// Nil is a safe answer, not a failure: the camera's provisional thumbnail is already on
    /// disk under the same deterministic name and is left alone, so a tile that gets no
    /// preview keeps showing what it shows today rather than falling back to a placeholder.
    private static func stagedPreviewThumbnail(
        id: MediaAssetID,
        session: DeviceCameraSession,
        relativePath: MediaRelativePath,
        size: UInt64,
        previews: [EmbeddedPreview],
        thumbnailDirectory: URL
    ) async -> StagedDerivedImage? {
        guard !previews.isEmpty else {
            return nil
        }
        guard let image = await CameraMetadataReader.loadPreviewImage(
            session: session,
            relativePath: relativePath,
            size: size,
            previews: previews
        ) else {
            return nil
        }
        do {
            return try ThumbnailStore.stage(
                image,
                finalRelativeName: ThumbnailStore.relativeName(for: id),
                in: thumbnailDirectory
            )
        } catch {
            OtosLog.thumbnails.errorOperation("camera.previewThumbnail", phase: "stageFailed", fields: [
                "relativePath": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return nil
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
        readinessChecker: any EnrichmentReadinessChecking,
        recipe: StoredEditRecipe?
    ) async -> EnrichmentOutcome {
        await parseAndComplete(
            id: id,
            url: url,
            sourceSize: sourceSize,
            sourceMTimeSeconds: sourceMTimeSeconds,
            contentHash: nil,
            thumbnailDirectory: thumbnailDirectory,
            readinessChecker: readinessChecker,
            recipe: recipe
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
        readinessChecker: any EnrichmentReadinessChecking,
        recipe: StoredEditRecipe?
    ) async -> EnrichmentOutcome {
        let result = MediaMetadataReader.read(url: url)
        guard !result.outcome.shouldRetry else {
            return .transient
        }
        guard readinessChecker.status(of: url) == .materialized else {
            return .notMaterialized
        }
        let rendered = await Self.renderStill(
            id: id, url: url, recipe: recipe?.recipe ?? .neutral, directory: thumbnailDirectory
        )
        let generatedThumbnail: StagedDerivedImage? = if let rendered {
            rendered.thumbnail
        } else {
            await Self.generateThumbnail(id: id, url: url, directory: thumbnailDirectory)
        }
        let metadata = Self.map(result)
        return .complete(
            EnrichmentResult(
                id: id,
                metadata: metadata,
                enrichedKind: Self.normalizedKind(result.format),
                enrichedFormat: MediaFormatToken.normalize(extension: result.format.fileExtension),
                thumbnailPath: nil,
                sourceSize: sourceSize ?? -1,
                sourceMTimeSeconds: sourceMTimeSeconds ?? -1,
                contentHash: contentHash,
                generatedThumbnail: generatedThumbnail,
                generatedPreview: rendered?.preview,
                editRevision: recipe?.revision ?? 0
            )
        )
    }

    /// Renders a still's loupe preview and draws its grid thumbnail from it, both staged
    /// (ADR 0035): one development of the original serves both, so the grid and the loupe
    /// show the same rendering — RAW9 for a RAW where Apple supports the camera. Nil for
    /// a video, or when the renderer cannot read the file; the caller then falls back to
    /// Quick Look for the thumbnail and the asset has no preview.
    private static func renderStill(
        id: MediaAssetID,
        url: URL,
        recipe: EditRecipe,
        directory: URL
    ) async -> (thumbnail: StagedDerivedImage, preview: StagedDerivedImage)? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
            return nil
        }
        let rendered: ImageRenderer.Rendered
        do {
            rendered = try await ImageRenderer.background.render(
                url, longEdge: ThumbnailStore.previewMaxPixelSize, recipe: recipe
            )
        } catch {
            return nil
        }
        var preview: StagedDerivedImage?
        do {
            let stagedPreview = try ThumbnailStore.stagePreview(
                rendered.image,
                finalRelativeName: ThumbnailStore.previewRelativeName(for: id),
                in: directory
            )
            preview = stagedPreview
            let thumbnail = try ThumbnailStore.stage(
                ThumbnailStore.scaled(rendered.image, toLongEdge: ThumbnailStore.maxPixelSize),
                finalRelativeName: ThumbnailStore.relativeName(for: id),
                in: directory
            )
            return (thumbnail, stagedPreview)
        } catch {
            if let preview {
                ThumbnailStore.discard(preview, in: directory)
            }
            OtosLog.thumbnails.errorOperation("thumbnail.render", phase: "stageFailed", fields: [
                "rootPath": id.libraryRootPath.rawValue,
                "relativePath": id.relativePath.rawValue,
                "decoder": rendered.decoder.rawValue,
                "error": String(describing: error),
            ])
            return nil
        }
    }

    /// Generates a 256 px thumbnail and stages it, returning the staged/final names.
    /// Requests only real imagery (`.thumbnail` / `.lowQualityThumbnail`) — never
    /// QuickLook's generic `.icon` fallback. A generation failure returns `nil` and is
    /// a definitive "no thumbnail available" outcome; enrichment still stamps metadata
    /// so the asset is not retried until the file changes, and the grid shows a
    /// broken-media placeholder.
    static func generateThumbnail(id: MediaAssetID, url: URL, directory: URL) async -> StagedDerivedImage? {
        let generationStart = ContinuousClock.now
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
        func add(_ time: CaptureTime?, _ role: CaptureTimestampRole) {
            guard let time else { return }
            records.append(
                CaptureTimestampRecord(
                    role: role.rawValue,
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
        add(timestamps.original, .original)
        add(timestamps.digitized, .digitized)
        add(timestamps.tiffDateTime, .tiffDateTime)
        add(timestamps.gps, .gps)
        add(timestamps.quickTimeCreation, .quickTimeCreation)
        add(timestamps.quickTimeLocation, .quickTimeLocation)
        add(timestamps.quickTimeContentCreate, .quickTimeContentCreate)
        add(timestamps.containerCreation, .containerCreation)
        // MED-004: Otos is image/video only. ID3 (MP3) and WAVE/BWF are audio-only
        // containers Otos never catalogs, so their timestamp roles are not persisted.
        // RIFF is kept: it also carries AVI, which is a cataloged video format.
        add(timestamps.riffRecording, .riffRecording)
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
