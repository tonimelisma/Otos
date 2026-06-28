import Foundation

/// The full parsed media metadata, persisted as a single binary blob and decoded only
/// on demand (a future per-asset inspector) — never held resident across the catalog.
///
/// This is Otos's own `Codable` mirror of the `MediaMetadata` library's result, kept
/// independent so the catalog model does not depend on the library and so the persisted
/// shape is Otos-owned. The enricher maps the library result into this; nothing in the
/// current increment produces it except tests. "Persist everything" lives here: every
/// timestamp role, location, and camera/video field round-trips.
///
/// Blob format is versioned DB-wide, not per row: a change to this shape is a future
/// schema migration that nulls every `metadata_blob` and the enrichment stamps so each
/// asset re-enriches into the new shape. There is therefore no per-row version and no
/// decode-time version branching — an undecodable blob cannot occur.
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
        videoCodec: String? = nil
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
    }
}

/// One capture-time candidate preserved in the metadata blob, by role (EXIF original,
/// QuickTime creation, GPS, …). The resolved `instant` plus the raw components keep the
/// "local time, unknown offset" case representable without inventing a UTC instant.
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

/// One location candidate preserved in the metadata blob.
nonisolated struct GeoRecord: Codable, Equatable {
    var source: String
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
}

/// The result of enriching one asset, applied to the catalog as part of a batch. The
/// enricher records the `(sourceSize, sourceMTimeSeconds)` it read at the start of the
/// work; the store stamps those so a file changed mid-enrichment is detected as stale.
nonisolated struct EnrichmentResult: Equatable {
    let id: MediaAssetID
    let metadata: AssetMetadata
    let captureDate: Date?
    let thumbnailPath: String?
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
}
