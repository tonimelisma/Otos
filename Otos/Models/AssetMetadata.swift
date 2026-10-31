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
nonisolated struct EnrichmentResult: Equatable {
    let id: MediaAssetID
    let metadata: AssetMetadata
    let enrichedKind: MediaKind?
    let enrichedFormat: MediaFormatToken?
    let thumbnailPath: String?
    let generatedThumbnail: StagedDerivedImage?
    /// The stored loupe preview (ADR 0035); nil for videos and for stills no renderer
    /// could read, which then fall back to decoding the original.
    let previewPath: String?
    let generatedPreview: StagedDerivedImage?
    /// The edit recipe revision the products were rendered with (0: unedited). The store
    /// applies the result only while that revision is still current (ADR 0036).
    let editRevision: Int64
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
    /// Absent when the enricher skipped hashing (`EnrichWork.shouldHash == false`,
    /// a `.removableVolume` source — ADR 0018). The store then leaves the
    /// row's existing hash columns untouched rather than clearing them.
    let contentHash: XXH3Digest128?

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
        self.id = id
        self.metadata = metadata
        self.enrichedKind = enrichedKind
        self.enrichedFormat = enrichedFormat
        self.thumbnailPath = generatedThumbnail?.finalRelativePath ?? thumbnailPath
        self.generatedThumbnail = generatedThumbnail
        self.previewPath = generatedPreview?.finalRelativePath ?? previewPath
        self.generatedPreview = generatedPreview
        self.editRevision = editRevision
        self.sourceSize = sourceSize
        self.sourceMTimeSeconds = sourceMTimeSeconds
        self.contentHash = contentHash
    }
}

nonisolated extension EnrichmentResult {
    /// Every staged file this result carries, for promotion or discard as one set.
    var stagedImages: [StagedDerivedImage] {
        [generatedThumbnail, generatedPreview].compactMap(\.self)
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
