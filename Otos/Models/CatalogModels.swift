import Foundation
import UniformTypeIdentifiers

// Catalog model guide
//
// These value types are the Sendable boundary between the catalog actors and
// MainActor UI state. Paths are domain identity, not display-only strings:
// library roots are identified by normalized absolute paths and media assets by
// a root plus a relative path. Runtime facts such as reachability and scanning
// stay separate from durable root identity because the filesystem can change
// independently of SQLite.
//
// Store owns durable truth in SQLite and exposes small immutable values at query
// boundaries. `CatalogWindowState` is the UI-ready value built by Projection.

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

    /// The absolute filesystem URL of the original file this identity names. Built
    /// from identity alone — no Store round-trip and no byte read — so the clipboard
    /// copy path and enrichment share one asset→URL construction rather than two that
    /// could disagree. `directoryHint: .notDirectory` avoids a stat: a media asset is
    /// always a file.
    var fileURL: URL {
        libraryRootPath.url.appending(path: relativePath.rawValue, directoryHint: .notDirectory)
    }
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

/// One cataloged file and the hot facts the grid can read by identity. Library
/// display text is intentionally absent: it is derived from `LibraryRootPath`, so
/// storing it on every asset would create a second value that could disagree with
/// root identity.
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

    // Enrichment overlay and SQLite-derived best values. The best date/kind/format
    // fields are generated in SQLite from scan and enrichment facts, so display,
    // sort, and filter use the same policy without a Swift fallback chain.
    // Full parsed metadata lives in the `asset_metadata` companion table as queryable
    // scalar columns plus JSON for long-tail fields, and is not loaded by the grid.
    //
    // Filesystem facts (scan) and enrichment overlay have disjoint writers: the scan
    // refreshes facts and preserves these fields, while enrichment writes these and
    // preserves facts. Staleness is derived, never stored: an asset needs
    // enrichment when its current `(byteSize, contentModifiedAt-seconds)` no longer match
    // the `(enrichedSourceSize, enrichedSourceMTimeSeconds)` the last enrichment recorded.
    let thumbnailPath: String?
    let bestCaptureDate: Date?
    let bestKind: MediaKind?
    let bestFormat: MediaFormatToken?
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
        bestCaptureDate: Date? = nil,
        bestKind: MediaKind? = nil,
        bestFormat: MediaFormatToken? = nil,
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
        self.bestCaptureDate = bestCaptureDate
        self.bestKind = bestKind
        self.bestFormat = bestFormat
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

/// The collection view consumes identity order plus a scalar detail-refresh
/// generation. Visible cell details are faulted through the Store-backed detail
/// reader owned by the AppKit grid boundary, so publishing a window state never
/// copies every asset value.
nonisolated struct CatalogMediaGridState: Equatable {
    var descriptor: CatalogQueryDescriptor
    var orderedAssetIDs: [MediaAssetID]
    var detailRefreshGeneration: UInt64 = 0

    var scope: SidebarSelection {
        descriptor.scope
    }

    static let empty = CatalogMediaGridState(
        descriptor: .default,
        orderedAssetIDs: []
    )

    init(
        scope: SidebarSelection,
        orderedAssetIDs: [MediaAssetID],
        detailRefreshGeneration: UInt64 = 0
    ) {
        self.init(
            descriptor: CatalogQueryDescriptor(scope: scope),
            orderedAssetIDs: orderedAssetIDs,
            detailRefreshGeneration: detailRefreshGeneration
        )
    }

    init(
        descriptor: CatalogQueryDescriptor,
        orderedAssetIDs: [MediaAssetID],
        detailRefreshGeneration: UInt64 = 0
    ) {
        self.descriptor = descriptor
        self.orderedAssetIDs = orderedAssetIDs
        self.detailRefreshGeneration = detailRefreshGeneration
    }
}

/// Why the media browser is empty. Projection chooses the reason so the view
/// can stay declarative and avoid re-deriving catalog state in `body`.
nonisolated enum CatalogMediaEmptyState: Equatable {
    case noMedia
    case noFilterMatches
    case checkingLibraries
    case noAvailableMedia
    case libraryChecking
    case libraryUnavailable

    var diagnosticDescription: String {
        switch self {
        case .noMedia:
            "noMedia"
        case .noFilterMatches:
            "noFilterMatches"
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
    var filterOptions: CatalogFilterOptions
    var resolvedSidebarSelection: SidebarSelection
    var mediaEmptyState: CatalogMediaEmptyState

    var queryDescriptor: CatalogQueryDescriptor {
        mediaGrid.descriptor
    }

    static let empty = CatalogWindowState(
        title: "All Media",
        libraries: [],
        mediaGrid: .empty,
        filterOptions: .empty,
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
    let kind: MediaKind?
    let format: MediaFormatToken?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?

    init(
        relativePath: MediaRelativePath,
        name: String?,
        contentTypeIdentifier: String?,
        byteSize: Int64?,
        createdAt: Date?,
        contentModifiedAt: Date?,
        kind: MediaKind? = nil,
        format: MediaFormatToken? = nil
    ) {
        let contentType = contentTypeIdentifier.flatMap(UTType.init)
        self.relativePath = relativePath
        self.name = name
        self.contentTypeIdentifier = contentTypeIdentifier
        self.kind = kind ?? MediaKind.classify(contentType)
        self.format = format ?? MediaFormatToken.normalize(contentType: contentType)
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.contentModifiedAt = contentModifiedAt
    }
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
