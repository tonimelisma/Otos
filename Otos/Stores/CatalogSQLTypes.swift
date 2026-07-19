import Foundation
import GRDB

// Shared persistence value types used by `CatalogStore`, `CatalogQueryGateway`,
// and `EnrichmentLeaseGateway`. Free (not nested under `CatalogStore`) so the
// gateways depend on SQL/mapping types rather than the actor type itself.
//
// SQLite row IDs stay confined to these stored records. Product identity remains
// `LibraryRootPath` / `MediaAssetID`; a row ID is only the compact foreign key.

nonisolated struct StoredAsset {
    let libraryRootID: Int64
    let relativePath: MediaRelativePath
    let name: String?
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?
    var thumbnailPath: String?
    var bestCaptureDate: Date?
    var bestKind: MediaKind?
    var bestFormat: MediaFormatToken?
    var durationSeconds: Double?
    var enrichedSourceSize: Int64?
    var enrichedSourceMTimeSeconds: Int?
    var contentHash: XXH3Digest128?
    var contentHashSourceSize: Int64?
    var contentHashSourceMTimeSeconds: Int?
}

/// Store-owned, one-settlement snapshot of rebuildable enrichment. It is never
/// persisted as a second record and contains no source history, claims, or identity.
nonisolated struct ReusableEnrichmentOverlay: Equatable, Sendable {
    let metadata: AssetMetadata
    let originalTimestamp: Date?
    let quickTimeCreationTimestamp: Date?
    let digitizedTimestamp: Date?
    let gpsTimestamp: Date?
    let enrichedKind: MediaKind?
    let enrichedFormat: MediaFormatToken?
    let durationSeconds: Double?
    let sourceByteSize: Int64?
    let sourceMTimeSeconds: Int?
    let contentHash: XXH3Digest128?
    let contentHashSourceSize: Int64?
    let contentHashSourceMTimeSeconds: Int?
    let thumbnailPath: String?
}

nonisolated struct StoredTileDetail {
    let libraryRootID: Int64
    let relativePath: MediaRelativePath
    var thumbnailPath: String?
    var bestKind: MediaKind?
    var durationSeconds: Double?
    var enrichedSourceSize: Int64?
    var enrichedSourceMTimeSeconds: Int?
}

nonisolated struct SQLQuery {
    let sql: String
    let arguments: StatementArguments
}
