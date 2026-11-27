import Foundation
import MediaMetadata

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
    /// A camera burst frame's number in its continuous-shooting sequence, 1 for the first
    /// (MediaMetadata 0.9.5); nil for a single shot.
    var continuousShootingFrame: Int?
    /// How a still was exposed, as the library reports it (MediaMetadata 0.9.4).
    var exposure: ExposureRecord?
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
        continuousShootingFrame: Int? = nil,
        exposure: ExposureRecord? = nil,
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
        self.continuousShootingFrame = continuousShootingFrame
        self.exposure = exposure
        self.extractionRevision = extractionRevision
    }
}

/// A still's exposure as MediaMetadata's `Exposure` reports it, field for field. The shutter
/// time keeps the fraction the camera wrote; the program, metering mode and white balance are
/// the Exif codes the library's enums carry as raw values, so they are put back into those
/// enums rather than mirrored here (ADR 0039).
nonisolated struct ExposureRecord: Codable, Equatable {
    var exposureTimeNumerator: Int?
    var exposureTimeDenominator: Int?
    var fNumber: Double?
    var isoSensitivity: Int?
    var exposureBiasEV: Double?
    var focalLengthMillimeters: Double?
    var focalLengthIn35mmFilmMillimeters: Int?
    var flashFired: Bool?
    var flashMode: Int?
    var flashRedEyeReduction: Bool?
    var flashHasFunction: Bool?
    var program: Int?
    var meteringMode: Int?
    var whiteBalance: Int?
}

nonisolated extension ExposureRecord {
    init(_ exposure: Exposure) {
        self.init(
            exposureTimeNumerator: exposure.exposureTime?.numerator,
            exposureTimeDenominator: exposure.exposureTime?.denominator,
            fNumber: exposure.fNumber,
            isoSensitivity: exposure.isoSensitivity,
            exposureBiasEV: exposure.exposureBiasEV,
            focalLengthMillimeters: exposure.focalLengthMillimeters,
            focalLengthIn35mmFilmMillimeters: exposure.focalLengthIn35mmFilmMillimeters,
            flashFired: exposure.flash?.fired,
            flashMode: exposure.flash?.mode?.rawValue,
            flashRedEyeReduction: exposure.flash?.redEyeReduction,
            flashHasFunction: exposure.flash?.hasFlashFunction,
            program: exposure.program?.rawValue,
            meteringMode: exposure.meteringMode?.rawValue,
            whiteBalance: exposure.whiteBalance?.rawValue
        )
    }

    /// The library's value, put back from the stored record.
    var exposure: Exposure {
        let time: ExposureTime? = if let exposureTimeNumerator, let exposureTimeDenominator {
            ExposureTime(numerator: exposureTimeNumerator, denominator: exposureTimeDenominator)
        } else {
            nil
        }
        let flash: Flash? = flashFired.map { fired in
            Flash(
                fired: fired,
                mode: flashMode.flatMap(Flash.Mode.init(rawValue:)),
                redEyeReduction: flashRedEyeReduction ?? false,
                hasFlashFunction: flashHasFunction ?? true
            )
        }
        return Exposure(
            exposureTime: time,
            fNumber: fNumber,
            isoSensitivity: isoSensitivity,
            exposureBiasEV: exposureBiasEV,
            focalLengthMillimeters: focalLengthMillimeters,
            focalLengthIn35mmFilmMillimeters: focalLengthIn35mmFilmMillimeters,
            flash: flash,
            program: program.flatMap(ExposureProgram.init(rawValue:)),
            meteringMode: meteringMode.flatMap(MeteringMode.init(rawValue:)),
            whiteBalance: whiteBalance.flatMap(WhiteBalanceMode.init(rawValue:))
        )
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
/// Which of a row's products one claim covers (ADR 0009, ADR 0018, ADR 0047): the claim's
/// staleness predicate, and the pair of partial indexes the claim queries walk.
///
/// A row is owed the products its root's kind makes, and each claim names one of three sets,
/// so a product a root never makes can never hold its rows in a claim index:
/// - `metadata`: a card's or camera's first pass, and an Immich account.
/// - `products`: metadata, the rendering and the digest; a card's second pass, once its
///   metadata is current (`LibraryRootKind.producesAfterMetadata`).
/// - `library`: every product a fixed library's row owes, read for all of them at once
///   (`LibraryRootKind.claimsEveryProductTogether`): the products, and a video's faces.
/// - `account`: an Immich account's row, read in byte ranges from its server: metadata, and a
///   video's faces (`LibraryRootKind.readsVideoFaces`).
///
/// A still's faces are not an enrichment product: they are read from the stored preview the
/// rendering makes (`PreviewFaceReader`). A video has no preview, so its faces are read from
/// its frames in the same read as its other products (`VideoFaceReader`).
nonisolated enum EnrichmentClaim: Hashable, Sendable, CaseIterable {
    case metadata
    case products
    case library
    case account

    /// The claim to take while `videoFaces` says whether a video's faces may be handed out.
    /// Held, a claim that covers them covers everything else it does: a fixed library's every
    /// other product is `.products`' predicate, an account's metadata is `.metadata`'s, so a
    /// video that owes only its faces matches neither and is never claimed (ADR 0047).
    func admitting(_ videoFaces: VideoFacesAdmission) -> EnrichmentClaim {
        switch (self, videoFaces) {
        case (.library, .held): .products
        case (.account, .held): .metadata
        case (_, .admitted), (.metadata, .held), (.products, .held): self
        }
    }
}

/// What an owed row's enrichment gives the user, as the Activity surface names it (ADR 0058):
/// each row owed under a claim is filed under exactly one, the first that applies.
///
/// - `thumbnail`: a thumbnail made or remade — the rendering a library or a card owes, or, on
///   a root first read for its metadata, a tile that still shows a placeholder. Never an
///   Immich account's row: the account's sync brings its thumbnails from the server.
/// - `faces`: a video's faces (a still's are read from its preview, `PreviewFaceReader`).
/// - `info`: the details the Info pane shows — dates, camera, lens, place — read from the
///   file, or from an account's server in ranges.
/// - `copies`: the file's digest, which tells exact copies apart (duplicates).
///
/// `EnrichmentClaimGateway.purposeSQL` is the SQL twin the Activity counts read; the two file
/// every row alike.
nonisolated enum EnrichmentPurpose: CaseIterable, Sendable {
    case thumbnail
    case faces
    case info
    case copies

    /// The purpose `asset`, owed under `claim`, is filed under; `isAccount` for an Immich
    /// account's row. A row owed nothing any rule here names (an account's original made
    /// local and claimed for its rendering) is a thumbnail: that is what its work makes.
    static func of(_ asset: MediaAsset, claim: EnrichmentClaim, isAccount: Bool) -> EnrichmentPurpose {
        let owesThumbnail = claim.renders ? asset.renderingStale : asset.showsPlaceholder
        if !isAccount, owesThumbnail {
            return .thumbnail
        }
        if claim.readsVideoFaces, asset.videoFacesStale {
            return .faces
        }
        if asset.metadataStale {
            return .info
        }
        if claim.renders, asset.hashStale {
            return .copies
        }
        return .thumbnail
    }
}

nonisolated extension EnrichmentClaim {
    /// Rows claimed under it are rendered and digested (a library, a card's second pass).
    var renders: Bool {
        self == .library || self == .products
    }

    /// Rows claimed under it are read for a video's faces.
    var readsVideoFaces: Bool {
        self == .library || self == .account
    }
}

/// Whether a claim may hand out a video's faces. Held while the face model cannot be
/// loaded (`EnrichmentSchedule.holdVideoFaces`): no video can be read for them then, so
/// none is claimed for them. Process state the scheduler owns, passed to each claim as a
/// value.
nonisolated enum VideoFacesAdmission: Equatable, Sendable {
    case admitted
    case held
}

/// The products one enrichment of a claimed row makes (ADR 0009, ADR 0018): the set of
/// its stale products the claim covers. Decided by the Store at claim time from the row's
/// stamps and the claim it was claimed under, and carried to the enricher rather than
/// re-derived.
nonisolated struct EnrichmentScope: OptionSet, Hashable, Sendable {
    let rawValue: Int

    /// Parsed metadata, kind, format and capture wall: what an import's naming waits on.
    static let metadata = EnrichmentScope(rawValue: 1 << 0)
    /// The thumbnail and preview from one development of the original (ADR 0035).
    static let rendering = EnrichmentScope(rawValue: 1 << 1)
    /// The SHA-1 digest of every byte (ADR 0018).
    static let hash = EnrichmentScope(rawValue: 1 << 2)
    /// A thumbnail that is not a rendering and is not stamped: QuickLook's in a card's
    /// metadata pass, or a camera's embedded preview, shown until the rendering lands.
    static let provisionalThumbnail = EnrichmentScope(rawValue: 1 << 3)
    /// A library video's faces, read from its frames (`VideoFaceReader`, ADR 0047).
    static let videoFaces = EnrichmentScope(rawValue: 1 << 4)

    /// Whether the claim needs only what ranged reads can give: metadata, a provisional
    /// thumbnail a remote source already supplies, and a video's faces, whose frames
    /// AVFoundation reads range by range (`RemoteVideoAsset`). A rendering or a digest needs
    /// the whole original, local (ADR 0046 §5, §7; ADR 0047).
    var isReadableInRanges: Bool {
        isDisjoint(with: [.rendering, .hash])
    }

    /// The scope for `asset` claimed under `claim`. Every stale product of a row claimed for
    /// several is made from one read, so a cloud-only original is downloaded once for all of
    /// them. A row claimed for metadata alone whose rendering is owed also gets a provisional
    /// thumbnail.
    init(claim: EnrichmentClaim, asset: MediaAsset) {
        let metadataPass: EnrichmentScope = asset.renderingStale ? [.metadata, .provisionalThumbnail] : [.metadata]
        switch claim {
        case .metadata:
            self = metadataPass
            return
        case .account:
            // A row claimed for its video's faces alone reads only them.
            var scope: EnrichmentScope = asset.metadataStale ? metadataPass : []
            if asset.videoFacesStale {
                scope.insert(.videoFaces)
            }
            self = scope
            return
        case .products, .library:
            break
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
        if claim == .library, asset.videoFacesStale {
            scope.insert(.videoFaces)
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
            (.provisionalThumbnail, "provisionalThumbnail"), (.videoFaces, "videoFaces"),
        ]
        let present = names.filter { contains($0.0) }.map(\.1)
        return present.isEmpty ? "none" : present.joined(separator: "+")
    }
}

/// A digest read on its own (`EnrichmentScope.hash`), valid only for the file signature
/// it was read at (ADR 0018).
nonisolated struct ContentHashResult: Equatable, Sendable {
    let id: MediaAssetID
    let contentHash: ContentDigest
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
    enum Origin: Hashable, Sendable {
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

/// The faces one reading of a still's stored preview found (ADR 0047): every face
/// `FaceAnalyzer` admitted, in the order it read them, placed on the upright photo, and the
/// analysis revision that read them. A still with no face in it, and a preview that does not
/// decode, have none.
nonisolated struct EnrichedFaces: Equatable, Sendable {
    let faces: [DetectedFace]
    let analysisRevision: Int

    /// A reading that found no face, by the current analysis.
    static let noneFound = EnrichedFaces(faces: [], analysisRevision: FaceAnalyzer.revision)
}

/// The faces one reading of a video's frames found (ADR 0047, `VideoFaceReader`): one face
/// per person in the video, each read in the sampled frame where it was sharpest, its box a
/// fraction of that frame. `frames` holds those frames, staged as the images of one file, for
/// the face tiles to be cut from; the store promotes it with the faces. nil when no face was
/// kept.
nonisolated struct EnrichedVideoFaces: Equatable, Sendable {
    nonisolated struct Face: Equatable, Sendable {
        let face: DetectedFace
        /// The image of `frames` the face was read in.
        let frameIndex: Int
    }

    let faces: [Face]
    let analysisRevision: Int
    let frames: StagedDerivedImage?

    /// A reading that found no face, by the current analysis.
    static let noneFound = EnrichedVideoFaces(faces: [], analysisRevision: FaceAnalyzer.revision, frames: nil)
}

/// What a file's decoder said about it: a still's renderer (ENR-029), a video's frame
/// reader (ENR-031). "Cannot decode" is a fact about that decoder, never about the file, so
/// it names the decoder: a still whose rendering fell back to QuickLook's thumbnail, or a
/// video stamped with no faces, because the decoder could not read it is tried again once
/// the decoder changes.
nonisolated enum DecodeVerdict: Equatable, Sendable {
    case decoded
    case undecodable(decoder: String)

    /// The stored form: the decoder's identity, or nil once a decoder read the file.
    var undecodableBy: String? {
        switch self {
        case .decoded: nil
        case let .undecodable(decoder): decoder
        }
    }

    /// A decoder's identity: Otos's own part, named and at its revision (how Otos hands the
    /// bytes to the platform), and the running macOS build, whose frameworks do the decoding.
    static func decoder(_ name: String, revision: Int) -> String {
        "\(name)\(revision)-macos\(operatingSystemBuild)"
    }

    /// The running macOS build (`kern.osversion`, e.g. `26B118`).
    private static let operatingSystemBuild: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "unread"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else {
            return "unread"
        }
        return String(cString: bytes)
    }()
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
    let contentHash: ContentDigest?
    /// Whether the file's decoder could decode it: the renderer a still's, when the result
    /// covers its rendering, and the frame reader a video's, when it covers its faces; nil
    /// leaves the stored verdict as it is.
    let decodeVerdict: DecodeVerdict?
    /// Absent when the scope did not cover a video's faces. Present, it replaces every face
    /// the video held, and stamps them, even when it holds none (ADR 0047).
    let videoFaces: EnrichedVideoFaces?

    init(
        id: MediaAssetID,
        metadata: EnrichedMetadata?,
        rendering: EnrichedRendering?,
        provisionalThumbnail: StagedDerivedImage? = nil,
        sourceSize: Int64?,
        sourceMTimeSeconds: Int?,
        contentHash: ContentDigest?,
        editRevision: Int64 = 0,
        decodeVerdict: DecodeVerdict? = nil,
        videoFaces: EnrichedVideoFaces? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.rendering = rendering
        self.provisionalThumbnail = rendering == nil ? provisionalThumbnail : nil
        self.editRevision = editRevision
        self.sourceSize = sourceSize
        self.sourceMTimeSeconds = sourceMTimeSeconds
        self.contentHash = contentHash
        self.decodeVerdict = decodeVerdict
        self.videoFaces = videoFaces
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
        contentHash: ContentDigest?,
        generatedThumbnail: StagedDerivedImage? = nil,
        previewPath: String? = nil,
        generatedPreview: StagedDerivedImage? = nil,
        editRevision: Int64 = 0,
        videoFaces: EnrichedVideoFaces? = nil
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
            editRevision: editRevision,
            videoFaces: videoFaces
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
        [rendering?.generatedThumbnail, rendering?.generatedPreview, provisionalThumbnail, videoFaces?.frames]
            .compactMap(\.self)
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
