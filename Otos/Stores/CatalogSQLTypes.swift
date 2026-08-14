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
    var mediaChoice: MediaChoice = .default
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
    var mediaChoice: MediaChoice = .default
}

nonisolated struct SQLQuery {
    let sql: String
    let arguments: StatementArguments
}

/// Every row dimension a `SidebarSelection` constrains, resolved once into one
/// value that all scoped reads consume.
///
/// A scope is not "a set of roots": an Imports row narrows by root *and* by batch
/// stamp. Splitting those dimensions across call sites is what let ordered IDs
/// honor batch membership while the count and filter-option queries silently did
/// not — an import batch whose rows were all excluded by an active filter then
/// reported zero unfiltered rows and rendered as an empty library instead of an
/// empty filter match. `RootRegistry.scopePredicate` is the only producer and no
/// read takes bare root IDs, so a new query cannot honor one dimension and forget
/// the other.
nonisolated struct CatalogScopePredicate: Equatable {
    /// Catalog roots the scope admits, ascending. Already narrowed to the kinds and
    /// availability the selection allows.
    let rootIDs: [Int64]
    /// Import-batch stamp the scope requires, when the selection is an Imports row.
    let importBatchUnixMs: Int64?

    init(rootIDs: [Int64], importBatchUnixMs: Int64? = nil) {
        self.rootIDs = rootIDs
        self.importBatchUnixMs = importBatchUnixMs
    }

    /// No root can satisfy the scope, so every read over it is empty without
    /// touching SQLite.
    var selectsNothing: Bool {
        rootIDs.isEmpty
    }

    static let nothing = CatalogScopePredicate(rootIDs: [])
}
