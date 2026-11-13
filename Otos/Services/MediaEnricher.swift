import AVFoundation
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
/// QuickLook's thumbnail and no preview. A card's metadata pass makes a provisional QuickLook
/// thumbnail instead of a rendering. A still's faces are not an enrichment product: they are
/// read from the stored preview this rendering makes (`PreviewFaceReader`, ADR 0047). A
/// library video, which has no preview, is read for its faces here, from its frames, in the
/// same read as its other products (`VideoFaceReader`). It is a small `Sendable` value with one
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
    /// only byte source that reads a whole file. `analyzeFaces` reads a video's frames for
    /// faces; the app shares its one analyzer, and a test stands in for the model.
    static func live(
        thumbnailDirectory: URL,
        readinessChecker: any EnrichmentReadinessChecking = LiveEnrichmentReadinessChecker(),
        contentHasher: @escaping @Sendable (URL) -> ContentHasher.Outcome = { url in
            ContentHasher().hashMaterializedFile(at: url)
        },
        analyzeFaces: @escaping FaceAnalysisReader = FaceAnalyzer.bundledAnalysis()
    ) -> MediaEnricher {
        MediaEnricher { id, access, sourceSize, sourceMTimeSeconds, scope, recipe in
            // A camera row has no local file, so the readiness checker — which asks the
            // filesystem — cannot speak for it. It is routed here precisely because its
            // bytes are reachable another way, and answering `.notMaterialized` would send
            // it back to be downloaded, which is the cost this path exists to avoid.
            if case let .remoteRanges(reader, relativePath) = access {
                return await Self.enrichFromRemoteRanges(
                    RemoteRead(
                        id: id, reader: reader, relativePath: relativePath,
                        sourceSize: sourceSize, sourceMTimeSeconds: sourceMTimeSeconds, scope: scope
                    ),
                    analyzeFaces: analyzeFaces,
                    thumbnailDirectory: thumbnailDirectory
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
                readinessChecker: readinessChecker,
                analyzeFaces: analyzeFaces
            )
        }
    }

    /// One account row's ranged enrichment: which row, its reader, and the products the
    /// claim covers.
    private struct RemoteRead {
        let id: MediaAssetID
        let reader: RemoteRangeReader
        let relativePath: MediaRelativePath
        let sourceSize: Int64?
        let sourceMTimeSeconds: Int?
        let scope: EnrichmentScope
    }

    /// Enriches an Immich account's row in byte ranges of its original while its server
    /// answers (ADR 0046 §5): its metadata, and a video's faces, whose frames AVFoundation
    /// reads range by range (`RemoteVideoAsset`, ADR 0047). Nothing is downloaded whole. A
    /// read the server does not answer is `.unanswered`, so the row is paced and read again,
    /// never stamped with what the server failed to send.
    private static func enrichFromRemoteRanges(
        _ read: RemoteRead,
        analyzeFaces: @escaping FaceAnalysisReader,
        thumbnailDirectory: URL
    ) async -> EnrichmentOutcome {
        let (id, reader, relativePath) = (read.id, read.reader, read.relativePath)
        var metadata: EnrichedMetadata?
        if read.scope.contains(.metadata) {
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
            metadata = EnrichedMetadata(
                metadata: Self.map(result),
                kind: Self.normalizedKind(result.format),
                format: MediaFormatToken.normalize(result.format)
            )
        }
        var videoFaces: EnrichedVideoFaces?
        if read.scope.contains(.videoFaces) {
            let started = ContinuousClock.now
            let remote = RemoteVideoAsset(reader: reader, filename: relativePath.rawValue)
            let faces: EnrichedVideoFaces
            do {
                faces = try await VideoFaceReader.read(
                    remote.asset, analyzeFaces: analyzeFaces,
                    framesRelativeName: ThumbnailStore.faceFramesRelativeName(for: id), in: thumbnailDirectory
                )
            } catch {
                OtosLog.metadata.errorOperation("videoFaces.read", phase: "failed", fields: [
                    "rootPath": id.libraryRootPath.rawValue, "relativePath": relativePath.rawValue,
                    "error": String(describing: error),
                ])
                return .transient
            }
            let cost = remote.cost
            guard !remote.failed else {
                // A frame the server did not send is not a frame without a face.
                if let frames = faces.frames {
                    ThumbnailStore.discard(frames, in: thumbnailDirectory)
                }
                OtosLog.metadata.noticeOperation("videoFaces.remote", phase: "unanswered", fields: [
                    "rootPath": id.libraryRootPath.rawValue, "relativePath": relativePath.rawValue,
                    "bytes": "\(cost.bytes)",
                ])
                return .unanswered
            }
            OtosLog.metadata.noticeOperation("videoFaces.remote", phase: "finish", fields: [
                "rootPath": id.libraryRootPath.rawValue,
                "relativePath": relativePath.rawValue,
                "faces": "\(faces.faces.count)",
                "reads": "\(cost.reads)",
                "bytes": "\(cost.bytes)",
                "fileBytes": "\(reader.size)",
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: started))",
            ])
            videoFaces = faces
        }
        return .complete(EnrichmentResult(
            id: id,
            metadata: metadata,
            rendering: nil,
            sourceSize: read.sourceSize ?? -1,
            sourceMTimeSeconds: read.sourceMTimeSeconds ?? -1,
            contentHash: nil,
            videoFaces: videoFaces
        ))
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
    /// already read for it: metadata, then a rendering or a provisional thumbnail, and a
    /// video's faces. Each is present in the result only when the scope covered it (ADR 0009).
    private static func produce(
        _ read: LocalRead,
        contentHash: XXH3Digest128?,
        thumbnailDirectory: URL,
        readinessChecker: any EnrichmentReadinessChecking,
        analyzeFaces: @escaping FaceAnalysisReader
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
        var products: [String] = []
        var videoFaces: EnrichedVideoFaces?
        // Read before anything is staged, so a failed read leaves nothing to discard.
        if scope.contains(.videoFaces) {
            do {
                let faces = try await VideoFaceReader.read(
                    AVURLAsset(url: url), analyzeFaces: analyzeFaces,
                    framesRelativeName: ThumbnailStore.faceFramesRelativeName(for: id), in: thumbnailDirectory
                )
                videoFaces = faces
                products.append("videoFaces=\(faces.faces.count)")
            } catch {
                OtosLog.metadata.errorOperation("videoFaces.read", phase: "failed", fields: [
                    "rootPath": id.libraryRootPath.rawValue,
                    "relativePath": id.relativePath.rawValue,
                    "error": String(describing: error),
                ])
                return .transient
            }
        }
        var rendering: EnrichedRendering?
        var provisionalThumbnail: StagedDerivedImage?
        var verdict: DecodeVerdict?
        if scope.contains(.rendering) {
            guard let still = await Self.renderStill(
                id: id, url: url, recipe: recipe?.recipe ?? .neutral, directory: thumbnailDirectory
            ) else {
                return .transient
            }
            verdict = still.verdict
            if case .undecodable = still.verdict {
                products.append("undecodable")
            }
            if let rendered = still.rendering {
                rendering = EnrichedRendering(generatedThumbnail: rendered.thumbnail, generatedPreview: rendered.preview)
                products.append("rendered")
            } else {
                rendering = await EnrichedRendering(
                    generatedThumbnail: Self.generateThumbnail(id: id, url: url, directory: thumbnailDirectory)
                )
                products.append("quickLook")
            }
        } else if scope.contains(.provisionalThumbnail), recipe?.recipe.isNeutral ?? true {
            // An edited photo's thumbnail must show the edit, which only a rendering does;
            // its current thumbnail stays until that rendering lands.
            provisionalThumbnail = await Self.generateThumbnail(id: id, url: url, directory: thumbnailDirectory)
            products.append("provisional")
        }
        // The item's costs apart: the metadata read is what an import's naming waits on,
        // the products (a development, QuickLook's thumbnail) what the grid waits on.
        OtosLog.metadata.noticeOperation("enrichment.item", phase: "finish", fields: [
            "rootPath": id.libraryRootPath.rawValue,
            "relativePath": id.relativePath.rawValue,
            "scope": "\(scope)",
            "metadataMs": "\(metadataMs)",
            "products": products.isEmpty ? "none" : products.joined(separator: "+"),
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
                editRevision: recipe?.revision ?? 0,
                decodeVerdict: verdict,
                videoFaces: videoFaces
            )
        )
    }

    /// What one rendering of a still made: its staged rendering, when the renderer could make
    /// one, and whether the renderer could decode it at all.
    struct StillRendering {
        let rendering: (thumbnail: StagedDerivedImage, preview: StagedDerivedImage)?
        /// nil when the file was not handed to the renderer (a video).
        let verdict: DecodeVerdict?
    }

    /// Renders a still once (ADR 0009) as its loupe preview and the grid thumbnail drawn from
    /// it, both staged (ADR 0035). A video is not rendered here. When the renderer cannot
    /// decode the file, the caller takes the thumbnail from QuickLook. Nil when the file's
    /// bytes could not be read: nothing is known about the still, so nothing is stamped and
    /// the row is retried, rather than stamped with no preview and so no faces (ADR 0047).
    private static func renderStill(
        id: MediaAssetID,
        url: URL,
        recipe: EditRecipe,
        directory: URL
    ) async -> StillRendering? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
            return StillRendering(rendering: nil, verdict: nil)
        }
        let rendered: ImageRenderer.Rendered
        do {
            rendered = try await ImageRenderer.background.render(
                url, longEdge: ThumbnailStore.previewMaxPixelSize, recipe: recipe
            )
        } catch is ImageRenderer.RenderError {
            // The decoder's verdict, not the photo's: it is stored with the decoder that
            // gave it, and a later decoder tries again (ENR-029).
            return StillRendering(rendering: nil, verdict: .undecodable(decoder: ImageRenderer.decoderIdentity))
        } catch {
            OtosLog.rendering.errorOperation("render.still", phase: "unreadable", fields: [
                "rootPath": id.libraryRootPath.rawValue,
                "relativePath": id.relativePath.rawValue,
                "error": String(describing: error),
            ])
            return nil
        }
        return StillRendering(rendering: stage(rendered, id: id, directory: directory), verdict: .decoded)
    }

    /// Stages a rendering as the loupe preview and the grid thumbnail drawn from it; nil
    /// when either cannot be written, with nothing left staged.
    private static func stage(
        _ rendered: ImageRenderer.Rendered,
        id: MediaAssetID,
        directory: URL
    ) -> (thumbnail: StagedDerivedImage, preview: StagedDerivedImage)? {
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
            exposure: result.exposure.map(ExposureRecord.init),
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
