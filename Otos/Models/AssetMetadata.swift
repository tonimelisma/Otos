import Foundation

/// The full parsed media metadata, preserved as JSON in the cold metadata row and
/// decoded only on demand for future per-asset detail surfaces — never held
/// resident across the catalog.
///
/// This is Otos's own `Codable` mirror of the `MediaMetadata` library's result, kept
/// independent so the catalog model does not depend on the library and so the persisted
/// shape is Otos-owned. The live enricher maps the library result into this and tests
/// prove it round-trips. "Persist everything" lives here: every timestamp role,
/// location, and camera/video field round-trips.
///
/// Metadata format is versioned by the current catalog schema, not per row. Schema
/// advances are additive migrations; a future unsupported schema refuses to open
/// rather than erasing non-rebuildable overlay such as import history.
nonisolated struct AssetMetadata: Codable, Equatable {
    var family: String?
    var fileExtension: String?
    var brand: String?
    var timestamps: [CaptureTimestampRecord]
    var locations: [GeoRecord]
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var serialNumber: String?
    var orientation: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var durationSeconds: Double?
    var frameRate: Double?
    var videoCodec: String?
    /// Apple's content identifier, shared by a Live Photo's still and motion movie (ADR 0041).
    var contentIdentifier: String?
    /// Apple's burst identifier, shared by every frame of one burst (MediaMetadata 0.9).
    var burstIdentifier: String?
    /// `MediaMetadataReader.extractionRevision` of the reader that produced this record;
    /// nil for a record read before revisions were stored. A lower revision is a record
    /// the current reader may read differently (ADR 0039).
    var extractionRevision: Int?

    init(
        family: String? = nil,
        fileExtension: String? = nil,
        brand: String? = nil,
        timestamps: [CaptureTimestampRecord] = [],
        locations: [GeoRecord] = [],
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        serialNumber: String? = nil,
        orientation: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        durationSeconds: Double? = nil,
        frameRate: Double? = nil,
        videoCodec: String? = nil,
        contentIdentifier: String? = nil,
        burstIdentifier: String? = nil,
        extractionRevision: Int? = nil
    ) {
        self.family = family
        self.fileExtension = fileExtension
        self.brand = brand
        self.timestamps = timestamps
        self.locations = locations
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.serialNumber = serialNumber
        self.orientation = orientation
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.contentIdentifier = contentIdentifier
        self.burstIdentifier = burstIdentifier
        self.extractionRevision = extractionRevision
    }
}

/// A library row whose metadata record an older MediaMetadata extraction revision produced,
/// with the file signature its enrichment is current for (ADR 0039).
nonisolated struct MetadataRefreshCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
    /// The record predates the content identifier a Live Photo pairs on and the file was
    /// made by Apple, so it may be half of a Live Photo (ADR 0041). Such a row is worth
    /// downloading when its bytes are not local; any other stale row is not (ADR 0039).
    var mayCompleteLivePhoto = false
}

/// A metadata record re-read from a row's local bytes by the current reader, to replace the
/// one an older revision produced. It carries the signature it was read at, so the store
/// writes it only if the file has not changed since.
nonisolated struct MetadataRefresh: Equatable, Sendable {
    let id: MediaAssetID
    let metadata: AssetMetadata
    let enrichedKind: MediaKind?
    let enrichedFormat: MediaFormatToken?
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
}

/// One capture-time candidate preserved in the metadata detail JSON, by role (EXIF
/// original, QuickTime creation, GPS, …). The resolved `instant` plus the raw
/// components keep the "local time, unknown offset" case representable without
/// inventing a UTC instant.
nonisolated struct CaptureTimestampRecord: Codable, Equatable {
    var role: String
    var instant: Date?
    var utcOffsetSeconds: Int?
    var precision: String?
    var year: Int?
    var month: Int?
    var day: Int?
    var hour: Int?
    var minute: Int?
    var second: Int?
    /// The fraction of `second` the file records, digits as written (MediaMetadata 0.9).
    var fractionalSecondDigits: String?
}

/// One location candidate preserved in the metadata detail JSON.
nonisolated struct GeoRecord: Codable, Equatable {
    var source: String
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
}

/// A derived image file — the 256 px grid thumbnail or the 2560 px loupe preview — that
/// has been written but not yet made catalog-visible. `MediaEnricher` writes the staged
/// file; `CatalogStore` promotes it to the final deterministic name only after SQLite
/// proves the enrichment result still matches the current asset row.
nonisolated struct StagedDerivedImage: Equatable {
    let finalRelativePath: String
    let stagedRelativePath: String
}

/// Timestamp role facts promoted from the metadata JSON into hot generated-column
/// inputs. These are facts, not the current ranking winner; SQLite derives the
/// displayed/sorted best date from them plus filesystem dates.
/// The result of enriching one asset, applied to the catalog as part of a batch. The
/// enricher records the `(sourceSize, sourceMTimeSeconds)` it read at the start of the
/// work; the store stamps those so a file changed mid-enrichment is detected as stale.
/// A generated thumbnail or preview may be staged, in which case `thumbnailPath` /
/// `previewPath` is the final path to stamp only after Store promotes the staged file.
/// The products one enrichment of a claimed row makes (ADR 0009, ADR 0018): the set of
/// its stale products the claim covers. Decided by the Store at claim time from the row's
/// stamps and the claim predicate it was claimed under, and carried to the enricher
/// rather than re-derived.
nonisolated struct EnrichmentScope: OptionSet, Hashable, Sendable {
    let rawValue: Int

    /// Parsed metadata, kind, format and capture wall: what an import's naming waits on.
    static let metadata = EnrichmentScope(rawValue: 1 << 0)
    /// The thumbnail and preview from one development of the original (ADR 0035).
    static let rendering = EnrichmentScope(rawValue: 1 << 1)
    /// The XXH3 digest of every byte.
    static let hash = EnrichmentScope(rawValue: 1 << 2)
    /// A thumbnail that is not a rendering and is not stamped: QuickLook's in a card's
    /// metadata pass, or a camera's embedded preview, shown until the rendering lands.
    static let provisionalThumbnail = EnrichmentScope(rawValue: 1 << 3)

    /// The scope for `asset` claimed under the every-product predicate (`everyProduct`)
    /// or the metadata-only one. Every stale product of a row claimed for all of them is
    /// made from one read, so a cloud-only original is downloaded once for all of them. A
    /// row claimed for metadata alone whose rendering is owed also gets a provisional
    /// thumbnail.
    init(everyProduct: Bool, asset: MediaAsset) {
        guard everyProduct else {
            self = asset.renderingStale ? [.metadata, .provisionalThumbnail] : [.metadata]
            return
        }
        var scope: EnrichmentScope = []
        if asset.metadataStale {
            scope.insert(.metadata)
        }
        if asset.renderingStale {
            scope.insert(.rendering)
        }
        if asset.hashStale {
            scope.insert(.hash)
        }
        self = scope
    }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

nonisolated extension EnrichmentScope: CustomStringConvertible {
    /// A stable, greppable name for logs: the products joined by `+`.
    var description: String {
        let names: [(EnrichmentScope, String)] = [
            (.metadata, "metadata"), (.rendering, "rendering"), (.hash, "hash"),
            (.provisionalThumbnail, "provisionalThumbnail"),
        ]
        let present = names.filter { contains($0.0) }.map(\.1)
        return present.isEmpty ? "none" : present.joined(separator: "+")
    }
}

/// A digest read on its own (`EnrichmentScope.hash`), valid only for the file signature
/// it was read at (ADR 0018).
nonisolated struct ContentHashResult: Equatable, Sendable {
    let id: MediaAssetID
    let contentHash: XXH3Digest128
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
}

/// Parsed metadata and what the catalog projects from it.
nonisolated struct EnrichedMetadata: Equatable {
    let metadata: AssetMetadata
    let kind: MediaKind?
    let format: MediaFormatToken?
}

/// One rendering's products (ADR 0035): the 256 px thumbnail and, for a still the
/// renderer read, the 2560 px preview. A video's QuickLook thumbnail is its rendering, and
/// a still no renderer could read falls back to QuickLook's with no preview; either can be
/// nil when nothing could be drawn, which is still a definitive outcome and is stamped.
nonisolated struct EnrichedRendering: Equatable {
    /// Who drew the images (ADR 0035). Otos's rendering is stamped as the row's
    /// rendering; a source's own images (an Immich account's thumbnail and preview,
    /// ADR 0046 §7) are stamped as source products, and leave the rendering owed.
    enum Origin: Equatable {
        case otos
        case source
    }

    let thumbnailPath: String?
    let generatedThumbnail: StagedDerivedImage?
    /// nil for videos and for stills no renderer could read, which then fall back to
    /// decoding the original.
    let previewPath: String?
    let generatedPreview: StagedDerivedImage?
    let origin: Origin

    init(
        thumbnailPath: String? = nil,
        generatedThumbnail: StagedDerivedImage? = nil,
        previewPath: String? = nil,
        generatedPreview: StagedDerivedImage? = nil,
        origin: Origin = .otos
    ) {
        self.thumbnailPath = generatedThumbnail?.finalRelativePath ?? thumbnailPath
        self.generatedThumbnail = generatedThumbnail
        self.previewPath = generatedPreview?.finalRelativePath ?? previewPath
        self.generatedPreview = generatedPreview
        self.origin = origin
    }
}

/// What one enrichment made for one row, each product present only when the scope
/// covered it (ADR 0009). The store writes each present product with its own stamp, the
/// `(sourceSize, sourceMTimeSeconds)` the bytes were read at, and leaves the others as
/// they are.
nonisolated struct EnrichmentResult: Equatable {
    let id: MediaAssetID
    let metadata: EnrichedMetadata?
    let rendering: EnrichedRendering?
    /// A thumbnail shown until the rendering lands; written without a stamp, and only
    /// when the result carries no rendering.
    let provisionalThumbnail: StagedDerivedImage?
    /// The edit recipe revision the rendering was made with (0: unedited). The store
    /// applies a rendering only while that revision is still current (ADR 0036).
    let editRevision: Int64
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
    /// Absent when the scope did not cover the digest. The store then leaves the row's
    /// existing hash columns untouched rather than clearing them.
    let contentHash: XXH3Digest128?

    init(
        id: MediaAssetID,
        metadata: EnrichedMetadata?,
        rendering: EnrichedRendering?,
        provisionalThumbnail: StagedDerivedImage? = nil,
        sourceSize: Int64?,
        sourceMTimeSeconds: Int?,
        contentHash: XXH3Digest128?,
        editRevision: Int64 = 0
    ) {
        self.id = id
        self.metadata = metadata
        self.rendering = rendering
        self.provisionalThumbnail = rendering == nil ? provisionalThumbnail : nil
        self.editRevision = editRevision
        self.sourceSize = sourceSize
        self.sourceMTimeSeconds = sourceMTimeSeconds
        self.contentHash = contentHash
    }

    /// A result carrying metadata and a rendering together, as a fixed library's
    /// enrichment of a row whose every product was stale makes.
    init(
        id: MediaAssetID,
        metadata: AssetMetadata,
        enrichedKind: MediaKind? = nil,
        enrichedFormat: MediaFormatToken? = nil,
        thumbnailPath: String?,
        sourceSize: Int64?,
        sourceMTimeSeconds: Int?,
        contentHash: XXH3Digest128?,
        generatedThumbnail: StagedDerivedImage? = nil,
        previewPath: String? = nil,
        generatedPreview: StagedDerivedImage? = nil,
        editRevision: Int64 = 0
    ) {
        self.init(
            id: id,
            metadata: EnrichedMetadata(metadata: metadata, kind: enrichedKind, format: enrichedFormat),
            rendering: EnrichedRendering(
                thumbnailPath: thumbnailPath,
                generatedThumbnail: generatedThumbnail,
                previewPath: previewPath,
                generatedPreview: generatedPreview
            ),
            sourceSize: sourceSize,
            sourceMTimeSeconds: sourceMTimeSeconds,
            contentHash: contentHash,
            editRevision: editRevision
        )
    }

    /// The thumbnail the row shows once this result is written: the rendering's, else the
    /// provisional one; nil when this result leaves the row's thumbnail as it is.
    var shownThumbnailPath: String? {
        rendering?.thumbnailPath ?? provisionalThumbnail?.finalRelativePath
    }
}

nonisolated extension EnrichmentResult {
    /// Every staged file this result carries, for promotion or discard as one set.
    var stagedImages: [StagedDerivedImage] {
        [rendering?.generatedThumbnail, rendering?.generatedPreview, provisionalThumbnail].compactMap(\.self)
    }
}

/// The result of applying an enrichment batch, so the coordinator reacts correctly:
/// re-wake to retry validated stale/deleted drops, but never re-wake on a write failure
/// (which would tight-loop the read/generate/fail cycle instead of backing off).
nonisolated enum EnrichmentApplyOutcome: Equatable {
    /// Persisted successfully; `count` is how many results applied. `count` below the
    /// submitted total means the rest were proven-deleted or stale (a scan saw newer
    /// bytes) — the coordinator re-wakes to retry those against fresh truth.
    case applied(count: Int)
    /// The SQLite write failed; the error is recorded. The coordinator must not re-wake.
    case writeFailed
}
