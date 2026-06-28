import Foundation

// Catalog model guide
//
// These value types are the Sendable boundary between the catalog actors and
// MainActor UI state. Paths are domain identity, not display-only strings:
// library roots are identified by normalized absolute paths and media assets by
// a root plus a relative path. Runtime facts such as reachability and scanning
// stay separate from durable root identity because the filesystem can change
// independently of SQLite.
//
// `CatalogSnapshot` is raw Store truth at one instant. `CatalogWindowState` is
// the UI-ready value built by Projection. Keeping both immutable at the handoff
// boundary lets actors publish coherent state without sharing mutable storage.

/// Typed filesystem paths keep domain roles visible at call sites. A library
/// root path and a media relative path are both text under the hood, but mixing
/// them up would be a real catalog bug, so they are not plain Strings.
nonisolated struct LibraryRootPath: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    var description: String {
        rawValue
    }

    var url: URL {
        URL(fileURLWithPath: rawValue, isDirectory: true)
    }

    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? rawValue : name
    }
}

nonisolated struct MediaRelativePath: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    var description: String {
        rawValue
    }
}

/// Media identity is the natural filesystem identity inside Otos: which library
/// root the file belongs to plus its path inside that root. Keeping this as a
/// pair avoids ambiguous string concatenation and avoids generated IDs.
nonisolated struct MediaAssetID: Hashable {
    let libraryRootPath: LibraryRootPath
    let relativePath: MediaRelativePath
}

/// Durable saved library identity. This intentionally contains no scan status
/// and no SQLite rowid: the path is the product identity, while storage keys stay
/// private to persistence.
nonisolated struct LibraryRoot: Identifiable, Hashable {
    let path: LibraryRootPath

    var id: LibraryRootPath {
        path
    }

    var displayName: String {
        path.displayName
    }
}

/// Availability is the most recent reachability observation for a saved root.
/// Loaded roots begin unknown because SQLite proves only that the path was saved;
/// the pre-scan filesystem check is what proves available or unavailable. This
/// state is deliberately transient because a mounted volume can disappear
/// without any catalog mutation.
nonisolated enum LibraryAvailability: Hashable {
    case unknown
    case available
    case unavailable
}

/// Scan activity is separate from availability: an available library can be
/// idle or scanning, while an unavailable library preserves catalog rows without
/// pretending a scan is in progress.
nonisolated enum CatalogLibraryActivity: Hashable {
    case idle
    case scanning
}

/// One projected library row. The durable root remains pure identity; this row
/// adds transient runtime facts needed by the current UI surfaces.
nonisolated struct CatalogLibraryState: Identifiable, Hashable {
    let root: LibraryRoot
    let availability: LibraryAvailability
    let activity: CatalogLibraryActivity

    var id: LibraryRootPath {
        root.id
    }

    var path: LibraryRootPath {
        root.path
    }

    var displayName: String {
        root.displayName
    }

    var isScanning: Bool {
        activity == .scanning
    }

    var isAvailable: Bool {
        availability == .available
    }
}

/// One cataloged file and the filesystem facts persisted for it. Library display
/// text is intentionally absent: it is derived from `LibraryRootPath`, so storing
/// it on every asset would create a second value that could disagree with root
/// identity.
nonisolated struct MediaAsset: Identifiable, Hashable {
    let libraryRootPath: LibraryRootPath
    let relativePath: MediaRelativePath
    let name: String?
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?
    /// Precomputed display-order key. Sorting the catalog by comparing these cheap
    /// keys replaces a localized collation call per comparison, which a 25k-asset
    /// sort measured at roughly 500 ms. The key is derived from identity, so it is
    /// constant for an asset and never disagrees with it.
    let sortKey: String

    // Enrichment overlay. These are the only enrichment data that stays resident and
    // flows through the catalog publication: a thumbnail file path, a resolved capture
    // date, and the staleness stamps. The full parsed metadata is NOT here — it is a
    // persisted, on-demand binary blob (see `AssetMetadata`), because holding ~30 mostly
    // nil fields per asset would cost ~480 B each (nil optionals reserve their space) and
    // would ride the Projection per-tick snapshot rebuild and equality check.
    //
    // Filesystem facts (scan) and enrichment overlay have disjoint writers: the scan
    // refreshes facts and preserves these fields (the in-memory merge), enrichment writes
    // these and preserves facts. Staleness is derived, never stored: an asset needs
    // enrichment when its current `(byteSize, contentModifiedAt-seconds)` no longer match
    // the `(enrichedSourceSize, enrichedSourceMTimeSeconds)` the last enrichment recorded.
    let thumbnailPath: String?
    let captureDate: Date?
    let enrichedSourceSize: Int64?
    let enrichedSourceMTimeSeconds: Int?

    init(
        libraryRootPath: LibraryRootPath,
        relativePath: MediaRelativePath,
        name: String?,
        contentTypeIdentifier: String?,
        byteSize: Int64?,
        createdAt: Date?,
        contentModifiedAt: Date?,
        thumbnailPath: String? = nil,
        captureDate: Date? = nil,
        enrichedSourceSize: Int64? = nil,
        enrichedSourceMTimeSeconds: Int? = nil
    ) {
        self.libraryRootPath = libraryRootPath
        self.relativePath = relativePath
        self.name = name
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.contentModifiedAt = contentModifiedAt
        self.thumbnailPath = thumbnailPath
        self.captureDate = captureDate
        self.enrichedSourceSize = enrichedSourceSize
        self.enrichedSourceMTimeSeconds = enrichedSourceMTimeSeconds
        sortKey = MediaSortKey.make(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    var id: MediaAssetID {
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    /// Whole-seconds form of a filesystem date for the staleness signature. Whole
    /// seconds avoid the `Double` epsilon that would otherwise make a reloaded date
    /// look different from a freshly scanned one (see FND-062/FND-064).
    static func mtimeSeconds(_ date: Date?) -> Int {
        date.map { Int($0.timeIntervalSince1970.rounded(.down)) } ?? -1
    }

    /// True when the file's current bytes have not been definitively enriched. Depends
    /// only on the `(size, mtime)` signature, never on whether products exist, so a file
    /// whose metadata is genuinely empty (unsupported, no thumbnail) is not retried.
    var needsEnrichment: Bool {
        guard let enrichedSourceSize, let enrichedSourceMTimeSeconds else {
            return true
        }
        return enrichedSourceSize != (byteSize ?? -1)
            || enrichedSourceMTimeSeconds != Self.mtimeSeconds(contentModifiedAt)
    }

    /// Truest available capture date, never fabricated (MED-002): the metadata-resolved
    /// date, then the filesystem creation date, then the modification date. `nil` only
    /// when nothing is known. Filesystem dates are real dates, surfaced like any other.
    var bestCaptureDate: Date? {
        captureDate ?? createdAt ?? contentModifiedAt
    }

    /// Returns a copy with refreshed filesystem facts and the existing enrichment
    /// overlay preserved. This is the in-memory side of disjoint ownership: a re-scan
    /// updates facts without ever clobbering metadata or the thumbnail.
    func mergingFacts(
        name: String?,
        contentTypeIdentifier: String?,
        byteSize: Int64?,
        createdAt: Date?,
        contentModifiedAt: Date?
    ) -> MediaAsset {
        MediaAsset(
            libraryRootPath: libraryRootPath,
            relativePath: relativePath,
            name: name,
            contentTypeIdentifier: contentTypeIdentifier,
            byteSize: byteSize,
            createdAt: createdAt,
            contentModifiedAt: contentModifiedAt,
            thumbnailPath: thumbnailPath,
            captureDate: captureDate,
            enrichedSourceSize: enrichedSourceSize,
            enrichedSourceMTimeSeconds: enrichedSourceMTimeSeconds
        )
    }

    /// Returns a copy with refreshed enrichment overlay and the existing filesystem
    /// facts preserved (the other half of disjoint ownership).
    func applyingEnrichment(
        thumbnailPath: String?,
        captureDate: Date?,
        sourceSize: Int64?,
        sourceMTimeSeconds: Int?
    ) -> MediaAsset {
        MediaAsset(
            libraryRootPath: libraryRootPath,
            relativePath: relativePath,
            name: name,
            contentTypeIdentifier: contentTypeIdentifier,
            byteSize: byteSize,
            createdAt: createdAt,
            contentModifiedAt: contentModifiedAt,
            thumbnailPath: thumbnailPath,
            captureDate: captureDate,
            enrichedSourceSize: sourceSize,
            enrichedSourceMTimeSeconds: sourceMTimeSeconds
        )
    }
}

/// Builds the cheap, precomputed display-order key for a media asset. Digit runs
/// are zero-padded so a plain string comparison still orders them numerically
/// ("img2" before "img10") without a locale-aware comparison on every sort step.
nonisolated enum MediaSortKey {
    static func make(libraryRootPath: LibraryRootPath, relativePath: MediaRelativePath) -> String {
        // The library segment groups a library's assets together; the relative
        // path orders within it. A null separator keeps the two segments from
        // ordering across the boundary.
        naturalKey(libraryRootPath.rawValue) + "\u{0}" + naturalKey(relativePath.rawValue)
    }

    static func naturalKey(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count + 8)
        var digitRun = ""
        for character in string.lowercased() {
            if character.isNumber {
                digitRun.append(character)
            } else {
                if !digitRun.isEmpty {
                    result += paddedDigits(digitRun)
                    digitRun = ""
                }
                result.append(character)
            }
        }
        if !digitRun.isEmpty {
            result += paddedDigits(digitRun)
        }
        return result
    }

    private static func paddedDigits(_ digits: String) -> String {
        // 19 digits covers any Int64-range counter or timestamp in a filename. A
        // longer run, not expected in real media names, falls back to plain order.
        let width = 19
        guard digits.count < width else {
            return digits
        }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

/// Raw point-in-time catalog value made by CatalogStore on demand. "Snapshot"
/// means an immutable copy of store truth at one instant; publication streams
/// are owned elsewhere.
nonisolated struct CatalogSnapshot: Equatable {
    var libraries: [CatalogLibraryState]
    var assetsByID: [MediaAssetID: MediaAsset]

    static let empty = CatalogSnapshot(
        libraries: [],
        assetsByID: [:]
    )

    var isScanning: Bool {
        libraries.contains { $0.isScanning }
    }
}

/// The collection view consumes identity order separately from current values.
/// `orderedAssetIDs` is the scoped, ordered structure; `assetsByID` is the
/// snapshot's full value map, shared by copy-on-write. The grid looks up only the
/// visible ids, so passing the full map avoids materializing a per-publication
/// scoped copy.
nonisolated struct CatalogMediaGridState: Equatable {
    var scope: SidebarSelection
    var orderedAssetIDs: [MediaAssetID]
    var assetsByID: [MediaAssetID: MediaAsset]

    static let empty = CatalogMediaGridState(
        scope: .allMedia,
        orderedAssetIDs: [],
        assetsByID: [:]
    )
}

/// Why the media browser is empty. Projection chooses the reason so the view
/// can stay declarative and avoid re-deriving catalog state in `body`.
nonisolated enum CatalogMediaEmptyState: Equatable {
    case noMedia
    case checkingLibraries
    case noAvailableMedia
    case libraryChecking
    case libraryUnavailable

    var diagnosticDescription: String {
        switch self {
        case .noMedia:
            "noMedia"
        case .checkingLibraries:
            "checkingLibraries"
        case .noAvailableMedia:
            "noAvailableMedia"
        case .libraryChecking:
            "libraryChecking"
        case .libraryUnavailable:
            "libraryUnavailable"
        }
    }
}

/// Final UI-ready catalog state. CatalogProjection builds this away from the
/// MainActor; CatalogWindowViewModel assigns it to SwiftUI.
nonisolated struct CatalogWindowState: Equatable {
    var title: String
    var libraries: [CatalogLibraryState]
    var mediaGrid: CatalogMediaGridState
    var resolvedSidebarSelection: SidebarSelection
    var mediaEmptyState: CatalogMediaEmptyState

    static let empty = CatalogWindowState(
        title: "All Media",
        libraries: [],
        mediaGrid: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia
    )
}

/// Selection of a sidebar row. Media selection will be modeled separately
/// because it answers a different question.
nonisolated enum SidebarSelection: Hashable {
    case allMedia
    case library(LibraryRootPath)

    var diagnosticDescription: String {
        switch self {
        case .allMedia:
            "allMedia"
        case let .library(path):
            "library:\(path.rawValue)"
        }
    }
}

nonisolated struct ScannedMediaFile: Hashable {
    let relativePath: MediaRelativePath
    let name: String?
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?
}

nonisolated enum CatalogPath {
    static func normalizedDirectoryPath(for url: URL) throws -> LibraryRootPath {
        let standardizedURL = url.standardizedFileURL
        var path = standardizedURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return LibraryRootPath(rawValue: path)
    }

    static func normalizedExistingDirectoryPath(for url: URL) throws -> LibraryRootPath {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw CatalogStoreError.notDirectory
        }
        return try normalizedDirectoryPath(for: url)
    }

    static func relationship(candidate: LibraryRootPath, existing: LibraryRootPath) -> LibraryRootRelationship? {
        if candidate == existing {
            return .duplicate
        }
        if candidate.rawValue.hasPrefix(existing.rawValue + "/") {
            return .descendant
        }
        if existing.rawValue.hasPrefix(candidate.rawValue + "/") {
            return .ancestor
        }
        return nil
    }

    static func relativePath(rootPath: LibraryRootPath, fileURL: URL) -> MediaRelativePath? {
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.rawValue + "/"
        guard filePath.hasPrefix(prefix) else {
            return nil
        }
        return MediaRelativePath(rawValue: String(filePath.dropFirst(prefix.count)))
    }

    /// Maps an absolute filesystem event path to the saved root that owns it.
    static func owningRoot(for eventPath: String, among roots: some Sequence<LibraryRootPath>) -> LibraryRootPath? {
        var match: LibraryRootPath?
        var matchLength = 0
        for root in roots {
            let raw = root.rawValue
            if eventPath == raw || eventPath.hasPrefix(raw + "/") {
                if raw.count > matchLength {
                    match = root
                    matchLength = raw.count
                }
            }
        }
        return match
    }
}

nonisolated enum LibraryRootRelationship: Equatable {
    case duplicate
    case ancestor
    case descendant
}

nonisolated enum CatalogStoreError: LocalizedError, Equatable {
    case notDirectory
    case overlappingRoot(existingPath: LibraryRootPath, relationship: LibraryRootRelationship)
    case catalogUnavailable

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "Choose a folder."
        case let .overlappingRoot(existingPath, relationship):
            switch relationship {
            case .duplicate:
                "That library is already saved."
            case .ancestor:
                "That folder contains an existing library at \(existingPath.rawValue)."
            case .descendant:
                "That folder is already inside an existing library at \(existingPath.rawValue)."
            }
        case .catalogUnavailable:
            "The catalog is unavailable."
        }
    }
}
