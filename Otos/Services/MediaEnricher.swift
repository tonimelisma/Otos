import CoreGraphics
import Foundation
import MediaMetadata
import OSLog
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Media enricher guide
///
/// Produces the products its `EnrichmentScope` names for one already-materialized media
/// file, each from the one read (ADR 0009): the digest, parsed metadata (the
/// `MediaMetadata` library, byte-reading, synchronous), and a rendering — for a still, one
/// `ImageRenderer` development that becomes the stored 2560 px preview and the 256 px
/// thumbnail drawn from it (ADR 0035); for a video, or a still the renderer cannot read,
/// QuickLook's thumbnail and no preview. A card's metadata pass makes a provisional
/// QuickLook thumbnail instead of a rendering. It is a small `Sendable` value with one
/// injectable closure, mirroring `CatalogScanner`, so the coordinator, the import and tests
/// can substitute a fake.
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
        _ scope: EnrichmentScope,
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
        MediaEnricher { id, access, sourceSize, sourceMTimeSeconds, scope, recipe in
            // A camera row has no local file, so the readiness checker — which asks the
            // filesystem — cannot speak for it. It is routed here precisely because its
            // bytes are reachable another way, and answering `.notMaterialized` would send
            // it back to be downloaded, which is the cost this path exists to avoid.
            if case let .remoteRanges(reader, relativePath) = access {
                return await Self.enrichFromRemoteRanges(
                    id: id, reader: reader, relativePath: relativePath,
                    sourceSize: sourceSize, sourceMTimeSeconds: sourceMTimeSeconds
                )
            }
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
            var contentHash: XXH3Digest128?
            if scope.contains(.hash) {
                let hashStart = ContinuousClock.now
                let hashSignpost = OtosSignpost.mediaIO.beginInterval("ContentHash")
                let hashOutcome = contentHasher(url)
                OtosSignpost.mediaIO.endInterval("ContentHash", hashSignpost)
                switch hashOutcome {
                case let .complete(digest):
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
                    // Every other product is current: the digest is all this claim was
                    // for, so nothing is parsed or rendered.
                    if scope == .hash {
                        return .hashed(ContentHashResult(
                            id: id,
                            contentHash: digest,
                            sourceSize: sourceSize,
                            sourceMTimeSeconds: sourceMTimeSeconds
                        ))
                    }
                    contentHash = digest
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
            return await Self.produce(
                LocalRead(
                    id: id, url: url, sourceSize: sourceSize, sourceMTimeSeconds: sourceMTimeSeconds,
                    scope: scope, recipe: recipe
                ),
                contentHash: contentHash,
                thumbnailDirectory: thumbnailDirectory,
                readinessChecker: readinessChecker
            )
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
    /// Reads an account row's metadata from its server in ranges (ADR 0046 §5). Metadata
    /// only: the row's thumbnail and preview are the server's own (§7), and its digest and
    /// rendering wait for the original. A read the server did not answer is `.unanswered`,
    /// never a definitive "no capture date".
    private static func enrichFromRemoteRanges(
        id: MediaAssetID,
        reader: RemoteRangeReader,
        relativePath: MediaRelativePath,
        sourceSize: Int64?,
        sourceMTimeSeconds: Int?
    ) async -> EnrichmentOutcome {
        let started = ContinuousClock.now
        let result = await RemoteMetadataReader.read(reader, filenameHint: relativePath.rawValue)
        guard !result.outcome.shouldRetry else {
            OtosLog.metadata.noticeOperation("remote.rangedRead", phase: "unanswered", fields: [
                "rootPath": id.libraryRootPath.rawValue, "relativePath": relativePath.rawValue,
            ])
            return .unanswered
        }
        OtosLog.metadata.noticeOperation("remote.rangedRead", phase: "finish", fields: [
            "rootPath": id.libraryRootPath.rawValue,
            "relativePath": relativePath.rawValue,
            "transportReads": "\(result.readCost.transportReadCount)",
            "uniqueBytes": "\(result.readCost.uniqueBytesRead)",
            "fileBytes": "\(reader.size)",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: started))",
        ])
        return .complete(EnrichmentResult(
            id: id,
            metadata: EnrichedMetadata(
                metadata: Self.map(result),
                kind: Self.normalizedKind(result.format),
                format: MediaFormatToken.normalize(result.format)
            ),
            rendering: nil,
            sourceSize: sourceSize ?? -1,
            sourceMTimeSeconds: sourceMTimeSeconds ?? -1,
            contentHash: nil
        ))
    }

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
                metadata: EnrichedMetadata(
                    metadata: Self.map(result),
                    kind: Self.normalizedKind(result.format),
                    format: MediaFormatToken.normalize(result.format)
                ),
                // A camera row is never rendered in place (`claimsEveryProductTogether`):
                // its rendering is made at import, from the staged copy. The embedded
                // preview is a provisional thumbnail, and when there is none the result
                // carries no thumbnail at all, so the camera's own thumbnail written at
                // enumeration stays on the row (APP-015).
                rendering: nil,
                provisionalThumbnail: generatedThumbnail,
                sourceSize: sourceSize ?? -1,
                sourceMTimeSeconds: sourceMTimeSeconds ?? -1,
                contentHash: nil
            )
        )
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

    /// One local file's enrichment: which row, which file at which facts, the products the
    /// claim covers, and the edit its rendering shows.
    private struct LocalRead {
        let id: MediaAssetID
        let url: URL
        let sourceSize: Int64?
        let sourceMTimeSeconds: Int?
        let scope: EnrichmentScope
        let recipe: StoredEditRecipe?
    }

    /// Makes the scope's products other than the digest from a local file whose bytes are
    /// already read for it: metadata, then a rendering or a provisional thumbnail. Each is
    /// present in the result only when the scope covered it (ADR 0009).
    private static func produce(
        _ read: LocalRead,
        contentHash: XXH3Digest128?,
        thumbnailDirectory: URL,
        readinessChecker: any EnrichmentReadinessChecking
    ) async -> EnrichmentOutcome {
        let (id, url, scope, recipe) = (read.id, read.url, read.scope, read.recipe)
        var metadata: EnrichedMetadata?
        var metadataMs = 0
        if scope.contains(.metadata) {
            let metadataStart = ContinuousClock.now
            let parsed = MediaMetadataReader.read(url: url)
            metadataMs = DiagnosticsTiming.milliseconds(since: metadataStart)
            guard !parsed.outcome.shouldRetry else {
                return .transient
            }
            metadata = EnrichedMetadata(
                metadata: Self.map(parsed),
                kind: Self.normalizedKind(parsed.format),
                format: MediaFormatToken.normalize(parsed.format)
            )
        }
        guard readinessChecker.status(of: url) == .materialized else {
            return .notMaterialized
        }
        let productsStart = ContinuousClock.now
        var rendering: EnrichedRendering?
        var provisionalThumbnail: StagedDerivedImage?
        let products: String
        if scope.contains(.rendering) {
            if let rendered = await Self.renderStill(
                id: id, url: url, recipe: recipe?.recipe ?? .neutral, directory: thumbnailDirectory
            ) {
                rendering = EnrichedRendering(generatedThumbnail: rendered.thumbnail, generatedPreview: rendered.preview)
                products = "rendered"
            } else {
                rendering = await EnrichedRendering(
                    generatedThumbnail: Self.generateThumbnail(id: id, url: url, directory: thumbnailDirectory)
                )
                products = "quickLook"
            }
        } else if scope.contains(.provisionalThumbnail), recipe?.recipe.isNeutral ?? true {
            // An edited photo's thumbnail must show the edit, which only a rendering does;
            // its current thumbnail stays until that rendering lands.
            provisionalThumbnail = await Self.generateThumbnail(id: id, url: url, directory: thumbnailDirectory)
            products = "provisional"
        } else {
            products = "none"
        }
        // The item's costs apart: the metadata read is what an import's naming waits on,
        // the products (a development, or QuickLook's thumbnail) what the grid waits on.
        OtosLog.metadata.noticeOperation("enrichment.item", phase: "finish", fields: [
            "rootPath": id.libraryRootPath.rawValue,
            "relativePath": id.relativePath.rawValue,
            "scope": "\(scope)",
            "metadataMs": "\(metadataMs)",
            "products": products,
            "productsMs": "\(DiagnosticsTiming.milliseconds(since: productsStart))",
        ])
        return .complete(
            EnrichmentResult(
                id: id,
                metadata: metadata,
                rendering: rendering,
                provisionalThumbnail: provisionalThumbnail,
                sourceSize: read.sourceSize ?? -1,
                sourceMTimeSeconds: read.sourceMTimeSeconds ?? -1,
                contentHash: contentHash,
                editRevision: recipe?.revision ?? 0
            )
        )
    }

    /// Renders a still's loupe preview and draws its grid thumbnail from it, both staged
    /// (ADR 0035): one development of the original serves both, so the grid and the loupe
    /// show the same rendering. Nil for a video, or when the renderer cannot read the file;
    /// the caller then takes the thumbnail from QuickLook and the asset has no preview.
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

    /// The catalog kind for what was read, as MediaMetadata decides it (ADR 0039): the type
    /// the bytes settled, camera RAW included; else the kind the bytes showed; else the type
    /// the extension names. Audio and the unrecognisable are not catalog kinds.
    static func normalizedKind(_ format: MediaFormat) -> MediaKind? {
        func kind(_ type: MediaFileType) -> MediaKind? {
            type.isCameraRaw ? .raw : kind(type.kind)
        }
        func kind(_ kind: MediaFormat.Kind) -> MediaKind? {
            switch kind {
            case .image: .image
            case .video: .video
            case .audio, .unknown: nil
            }
        }
        if let type = format.fileType {
            return kind(type)
        }
        if format.kind != .unknown {
            return kind(format.kind)
        }
        return MediaFileType(fileExtension: format.fileExtension).flatMap(kind)
    }

    /// Maps the full library result into Otos's owned metadata record — every field, as the
    /// library reports it (ADR 0039): Otos re-derives nothing the library already says.
    static func map(_ result: MediaMetadataResult) -> AssetMetadata {
        AssetMetadata(
            family: result.format.family.rawValue,
            fileExtension: result.format.fileExtension,
            brand: result.format.brand,
            timestamps: result.timestamps.entries
                .filter { CaptureTimestamps.Role.cataloged.contains($0.role) }
                .map { CaptureTimestampRecord(role: $0.role, time: $0.time) },
            locations: result.locations.entries.map {
                GeoRecord(
                    source: $0.source.rawValue,
                    latitude: $0.location.latitude,
                    longitude: $0.location.longitude,
                    altitudeMeters: $0.location.altitudeMeters
                )
            },
            cameraMake: result.camera?.make,
            cameraModel: result.camera?.model,
            lensModel: result.camera?.lensModel,
            serialNumber: result.camera?.serialNumber,
            orientation: result.geometry?.orientation?.rawValue,
            pixelWidth: result.geometry?.pixelWidth,
            pixelHeight: result.geometry?.pixelHeight,
            durationSeconds: result.video?.durationSeconds,
            frameRate: result.video?.frameRate,
            videoCodec: result.video?.codec?.identifier,
            contentIdentifier: result.contentIdentifier,
            burstIdentifier: result.burstIdentifier,
            extractionRevision: MediaMetadataReader.extractionRevision(for: result.format.family)
        )
    }
}

/// The result of enriching one asset. The coordinator collects `.complete` results into
/// a batch for `CatalogStore.applyEnrichmentBatch` and hands `.hashed` digests to
/// `CatalogStore.applyContentHash`; `.transient`/`.notMaterialized` are re-queued (the
/// asset stays `needsEnrichment`).
nonisolated enum EnrichmentOutcome {
    case complete(EnrichmentResult)
    /// A digest-only claim's digest (`EnrichmentScope.hash`).
    case hashed(ContentHashResult)
    case transient
    case notMaterialized
    /// A server that serves the bytes in ranges did not answer this read. The row is
    /// paced rather than claimed again at once, so an outage is never a storm of claims.
    case unanswered
}
