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
// `LibraryRootPath`, `MediaRelativePath`, and `MediaAssetID` carry a derived
// FNV-1a `fingerprint` so Hashable / ObjC-bridged diffable hashing is O(1) after
// construction. The fingerprint is never persisted, never logged as identity,
// and never substitutes for string equality (colliding fingerprints still
// compare the full path strings).
//
// Store owns durable truth in SQLite and exposes small immutable values at query
// boundaries. `CatalogWindowState` is the UI-ready value built by Projection.

/// Stable FNV-1a 64-bit over UTF-8. Used only as derived Hashable state for path
/// identity types — never persisted, never logged as identity, never a substitute
/// for string equality (collisions fall back to full string compare).
nonisolated enum PathFingerprint {
    static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    static let prime: UInt64 = 1_099_511_628_211

    static func fnv1a64(_ bytes: some Sequence<UInt8>) -> UInt64 {
        fnv1a64(offsetBasis, bytes)
    }

    static func fnv1a64(_ seed: UInt64, _ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Root path, then a NUL separator, then the relative path — process-independent.
    static func mediaAsset(root: String, relative: String) -> UInt64 {
        var hash = fnv1a64(root.utf8)
        hash ^= 0
        hash = hash &* prime
        return fnv1a64(hash, relative.utf8)
    }
}

/// Typed filesystem paths keep domain roles visible at call sites. A library
/// root path and a media relative path are both text under the hood, but mixing
/// them up would be a real catalog bug, so they are not plain Strings.
nonisolated struct LibraryRootPath: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String
    /// Derived FNV-1a of `rawValue` UTF-8. Cheap Hashable only — not identity.
    let fingerprint: UInt64

    init(rawValue: String) {
        self.rawValue = rawValue
        fingerprint = PathFingerprint.fnv1a64(rawValue.utf8)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

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

    func hash(into hasher: inout Hasher) {
        hasher.combine(fingerprint)
    }

    static func == (lhs: LibraryRootPath, rhs: LibraryRootPath) -> Bool {
        if lhs.fingerprint != rhs.fingerprint {
            return false
        }
        return lhs.rawValue == rhs.rawValue
    }
}

nonisolated struct MediaRelativePath: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String
    /// Derived FNV-1a of `rawValue` UTF-8. Cheap Hashable only — not identity.
    let fingerprint: UInt64

    init(rawValue: String) {
        self.rawValue = rawValue
        fingerprint = PathFingerprint.fnv1a64(rawValue.utf8)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String {
        rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fingerprint)
    }

    static func == (lhs: MediaRelativePath, rhs: MediaRelativePath) -> Bool {
        if lhs.fingerprint != rhs.fingerprint {
            return false
        }
        return lhs.rawValue == rhs.rawValue
    }
}

/// The parts of a root-relative path, split on "/" as text. Never through
/// `URL(fileURLWithPath:)`: a relative path handed to it resolves against the process's
/// working directory, so its folder comes back absolute.
nonisolated extension MediaRelativePath {
    /// Joins a folder ("" at the root) and a file name.
    init(folder: String, fileName: String) {
        self.init(rawValue: folder.isEmpty ? fileName : "\(folder)/\(fileName)")
    }

    /// The folder part, "" at the root.
    var folder: String {
        guard let slash = rawValue.lastIndex(of: "/") else { return "" }
        return String(rawValue[..<slash])
    }

    var fileName: String {
        guard let slash = rawValue.lastIndex(of: "/") else { return rawValue }
        return String(rawValue[rawValue.index(after: slash)...])
    }

    /// The file name without its last extension. A leading dot does not start an
    /// extension (".hidden" has stem ".hidden").
    var stem: String {
        let name = fileName
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// The last extension without its dot, "" when there is none.
    var fileExtension: String {
        let name = fileName
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// Every folder above this path, outermost first: "a/b/c.jpg" → ["a", "a/b"].
    var ancestorFolders: [String] {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return [] }
        return (1 ..< parts.count).map { parts[0 ..< $0].joined(separator: "/") }
    }
}

/// Media identity is the natural filesystem identity inside Otos: which library
/// root the file belongs to plus its path inside that root. Keeping this as a
/// pair avoids ambiguous string concatenation and avoids generated IDs.
nonisolated struct MediaAssetID: Hashable {
    let libraryRootPath: LibraryRootPath
    let relativePath: MediaRelativePath
    /// Derived FNV-1a over both path strings' UTF-8. Cheap Hashable / ObjC
    /// `hashValue` for diffable snapshots — never persisted or logged as identity.
    let fingerprint: UInt64

    init(libraryRootPath: LibraryRootPath, relativePath: MediaRelativePath) {
        self.libraryRootPath = libraryRootPath
        self.relativePath = relativePath
        fingerprint = PathFingerprint.mediaAsset(
            root: libraryRootPath.rawValue,
            relative: relativePath.rawValue
        )
    }

    /// The absolute filesystem URL of the original file this identity names. Built
    /// from identity alone — no Store round-trip and no byte read — so the clipboard
    /// copy path and enrichment share one asset→URL construction rather than two that
    /// could disagree. `directoryHint: .notDirectory` avoids a stat: a media asset is
    /// always a file.
    var fileURL: URL {
        libraryRootPath.url.appending(path: relativePath.rawValue, directoryHint: .notDirectory)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fingerprint)
    }

    static func == (lhs: MediaAssetID, rhs: MediaAssetID) -> Bool {
        if lhs.fingerprint != rhs.fingerprint {
            return false
        }
        return lhs.libraryRootPath == rhs.libraryRootPath
            && lhs.relativePath == rhs.relativePath
    }
}

/// Who a removable source is, as its monitor identified it: a volume by its UUID, or by
/// where it is mounted when it reports none; a camera by its persistent id, or by its name
/// when it reports none. The text is what the catalog and the import journal persist, so
/// it is built and read only here. An identity from a mount path or a name is transient: it
/// names one attachment, not the device, so the catalog does not keep a root for it.
nonisolated struct DeviceIdentity: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: String

    /// Reads persisted text back. Monitors build identities with the constructors below.
    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func volume(uuid: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "volume:\(uuid)")
    }

    static func volume(mountPath: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "volume:path:\(mountPath)")
    }

    static func camera(id: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "camera:\(id)")
    }

    static func camera(name: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "camera:transient:\(name)")
    }

    /// Two attached volumes that report one identity: each after the first is told apart
    /// by where it is mounted, which makes it transient.
    func disambiguated(mountPath: String) -> DeviceIdentity {
        DeviceIdentity(rawValue: "\(rawValue)#path:\(mountPath)")
    }

    var isTransient: Bool {
        rawValue.hasPrefix("volume:path:")
            || rawValue.contains("#path:")
            || rawValue.hasPrefix("camera:transient:")
    }

    var description: String {
        rawValue
    }

    static func < (lhs: DeviceIdentity, rhs: DeviceIdentity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Durable saved library identity. This intentionally contains no scan status
/// and no SQLite rowid: the path is the product identity, while storage keys stay
/// private to persistence.
/// How long a card or camera may go unseen before Otos forgets it (owner decision
/// 2026-10-25, plan 0108; ADR 0013). A product rule, not a stand-in for a fact: no
/// report can say that an absent device will never return.
nonisolated enum RemovableSourceRetention {
    static let unseenPeriod: TimeInterval = 90 * 24 * 60 * 60
}

nonisolated struct LibraryRoot: Identifiable, Hashable {
    let path: LibraryRootPath
    let kind: LibraryRootKind
    let deviceIdentity: DeviceIdentity?
    let displayNameOverride: String?
    let lastSeenAt: Date?

    init(
        path: LibraryRootPath,
        kind: LibraryRootKind = .library,
        deviceIdentity: DeviceIdentity? = nil,
        displayName: String? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.path = path
        self.kind = kind
        self.deviceIdentity = deviceIdentity
        displayNameOverride = displayName
        self.lastSeenAt = lastSeenAt
    }

    var id: LibraryRootPath {
        path
    }

    var displayName: String {
        displayNameOverride?.isEmpty == false ? displayNameOverride ?? path.displayName : path.displayName
    }

    var isRemovableSource: Bool {
        kind != .library
    }

    /// Whether enrichment on this root produces a content hash (ADR 0018).
    ///
    /// The rule is byte locality, not root kind for its own sake: a digest costs every byte
    /// of the file, so it is only free where enrichment is reading those bytes anyway. A
    /// fixed library is. A removable volume is not — hashing in place would read the whole
    /// card to checksum it.
    ///
    /// `.deviceMTP` is in the second group: a camera row is enriched from a few kilobytes
    /// of ranged reads, not from a downloaded copy, and requiring a digest would force the
    /// whole-file transfer. Those rows receive their digest after import, from the
    /// destination's local bytes, as ADR 0018 prescribes for a removable volume.
    ///
    /// Single home for the rule so a future root kind cannot diverge one caller.
    var isContentHashRequired: Bool {
        kind == .library
    }
}

/// The catalog stores every source as a root because the filesystem path remains
/// the asset identity boundary. Kind only changes ownership semantics: fixed
/// libraries participate in All Media and launch scans, while removable sources
/// are event-driven and are scoped to their own sidebar rows.
nonisolated enum LibraryRootKind: String, CaseIterable, Hashable, Codable {
    case library
    case removableVolume
    case deviceMTP

    var sidebarSystemImage: String {
        switch self {
        case .library:
            "folder"
        case .removableVolume:
            "sdcard"
        case .deviceMTP:
            "camera"
        }
    }
}

/// The one authored curation value for a cataloged image or video. It is overlay
/// state, not a filesystem fact: originals and useful companions remain untouched.
nonisolated enum MediaChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case liked
    case notRated
    case disliked

    static let `default` = MediaChoice.notRated

    var label: String {
        switch self {
        case .liked: "Liked"
        case .notRated: "Not Rated"
        case .disliked: "Disliked"
        }
    }

    var actionLabel: String {
        switch self {
        case .liked: "Like"
        case .notRated: "Mark as Not Rated"
        case .disliked: "Dislike"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .liked: "liked"
        case .notRated: "not rated"
        case .disliked: "disliked"
        }
    }

    var accessibilityActionLabel: String {
        switch self {
        case .liked: "Like item"
        case .notRated: "Mark item as not rated"
        case .disliked: "Dislike item"
        }
    }

    /// The flat glyph that names this value where all three are listed at once
    /// (the filter popover). The hover control does not use it: there the two
    /// acts are toggles with an outline/filled pair, which `MediaChoiceToggle`
    /// owns.
    var systemImage: String {
        switch self {
        case .liked: "hand.thumbsup"
        case .notRated: "minus"
        case .disliked: "hand.thumbsdown"
        }
    }

    init?(keyCharacter: String) {
        switch keyCharacter.lowercased() {
        case "p": self = .liked
        case "u": self = .notRated
        case "x": self = .disliked
        default: return nil
        }
    }
}

/// The two acts the hover control offers. Neutral is deliberately not a button:
/// pressing the act an item already carries returns it to `.notRated`, so the
/// control is two toggles rather than three mutually exclusive states (DES-066).
/// `MediaChoice` keeps all three values — the neutral one is still reachable by
/// keyboard (`u`), by menu, and as a VoiceOver action; it just has no button.
nonisolated enum MediaChoiceToggle: String, CaseIterable, Hashable, Sendable {
    case like
    case dislike

    var choice: MediaChoice {
        switch self {
        case .like: .liked
        case .dislike: .disliked
        }
    }

    /// Outline at rest, filled when the item carries this act's choice. Shape,
    /// not tint, is what carries the selected state, so it survives grayscale
    /// and Increase Contrast (DES-068).
    func symbol(isOn: Bool) -> String {
        switch self {
        case .like: isOn ? "hand.thumbsup.fill" : "hand.thumbsup"
        case .dislike: isOn ? "hand.thumbsdown.fill" : "hand.thumbsdown"
        }
    }

    /// The one resolution every surface shares. The grid tile (AppKit) and the
    /// Loupe/Compare control (SwiftUI) are two renderers of one user intent, so
    /// neither re-derives "pressing the active act clears it" for itself.
    func resolved(from current: MediaChoice) -> MediaChoice {
        current == choice ? .notRated : choice
    }

    var actionLabel: String {
        choice.actionLabel
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
    case enumerating
}

/// One projected library row. The durable root remains pure identity; this row
/// adds transient runtime facts needed by the current UI surfaces.
nonisolated struct CatalogLibraryState: Identifiable, Hashable {
    let root: LibraryRoot
    /// User-controlled order, durable on the root row.
    /// Authoritative for library-kind roots: the first available one, in this
    /// order, is the deterministic import destination, and Settings → Libraries
    /// shows and reorders exactly this order. Removable sources carry a value
    /// too but are sorted by display name at query time regardless
    /// (`CatalogWindowPolicy.sortLibraries`).
    let sortIndex: Int64
    let availability: LibraryAvailability
    let activity: CatalogLibraryActivity
    let isEjectable: Bool
    /// Store-owned process-local identity of the current removable attachment.
    /// It is never persisted and is zero for roots constructed outside the live
    /// attachment owner.
    let attachmentGeneration: UInt64

    var id: LibraryRootPath {
        root.id
    }

    var path: LibraryRootPath {
        root.path
    }

    var displayName: String {
        root.displayName
    }

    var kind: LibraryRootKind {
        root.kind
    }

    var deviceIdentity: DeviceIdentity? {
        root.deviceIdentity
    }

    var lastSeenAt: Date? {
        root.lastSeenAt
    }

    var isScanning: Bool {
        activity == .scanning
    }

    var isEnumerating: Bool {
        activity == .enumerating
    }

    var isAvailable: Bool {
        availability == .available
    }

    init(
        root: LibraryRoot,
        sortIndex: Int64 = 0,
        availability: LibraryAvailability,
        activity: CatalogLibraryActivity,
        isEjectable: Bool = false,
        attachmentGeneration: UInt64 = 0
    ) {
        self.root = root
        self.sortIndex = sortIndex
        self.availability = availability
        self.activity = activity
        self.isEjectable = isEjectable
        self.attachmentGeneration = attachmentGeneration
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
    // fields are generated in SQLite from scan and enrichment facts, so query,
    // sort, filter, and the video badge use the same policy without a Swift
    // fallback chain. Capture dates remain catalog facts, not tile labels.
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
    let durationSeconds: Double?
    let enrichedSourceSize: Int64?
    let enrichedSourceMTimeSeconds: Int?
    let contentHash: XXH3Digest128?
    let contentHashSourceSize: Int64?
    let contentHashSourceMTimeSeconds: Int?
    let mediaChoice: MediaChoice

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
        durationSeconds: Double? = nil,
        enrichedSourceSize: Int64? = nil,
        enrichedSourceMTimeSeconds: Int? = nil,
        contentHash: XXH3Digest128? = nil,
        contentHashSourceSize: Int64? = nil,
        contentHashSourceMTimeSeconds: Int? = nil,
        mediaChoice: MediaChoice = .default
    ) {
        self.libraryRootPath = libraryRootPath
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.name = name
        self.contentTypeIdentifier = contentTypeIdentifier
        self.createdAt = createdAt
        self.contentModifiedAt = contentModifiedAt
        self.thumbnailPath = thumbnailPath
        self.bestCaptureDate = bestCaptureDate
        self.bestKind = bestKind
        self.bestFormat = bestFormat
        self.durationSeconds = durationSeconds
        self.enrichedSourceSize = enrichedSourceSize
        self.enrichedSourceMTimeSeconds = enrichedSourceMTimeSeconds
        self.contentHash = contentHash
        self.contentHashSourceSize = contentHashSourceSize
        self.contentHashSourceMTimeSeconds = contentHashSourceMTimeSeconds
        self.mediaChoice = mediaChoice
        sortKey = MediaSortKey.make(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    var id: MediaAssetID {
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    /// Whole-seconds form of a filesystem date for the staleness signature. Whole
    /// seconds avoid the `Double` epsilon that would otherwise make a reloaded date
    /// look different from a freshly scanned one (see ARC-038/ARC-039).
    static func mtimeSeconds(_ date: Date?) -> Int {
        date.map { Int($0.timeIntervalSince1970.rounded(.down)) } ?? -1
    }

    /// True when the enrichment stamp (thumbnail, parsed metadata, capture-wall
    /// facts) is not valid for the current filesystem signature. Independent of
    /// whether a hash is required at all.
    var metadataStale: Bool {
        let currentSize = byteSize ?? -1
        let currentMTime = Self.mtimeSeconds(contentModifiedAt)
        return enrichedSourceSize != currentSize || enrichedSourceMTimeSeconds != currentMTime
    }

    /// True when the persisted content hash is missing, malformed, or does not match
    /// the current filesystem signature. Meaningless on its own: a root that never
    /// hashes (`.removableVolume`, see ADR 0018) must not be judged stale by this
    /// alone. Callers gate it behind `hashRequired`.
    var hashStale: Bool {
        let currentSize = byteSize ?? -1
        let currentMTime = Self.mtimeSeconds(contentModifiedAt)
        return contentHash == nil
            || contentHashSourceSize == nil
            || contentHashSourceMTimeSeconds == nil
            || contentHashSourceSize != currentSize
            || contentHashSourceMTimeSeconds != currentMTime
    }

    /// True when metadata is stale, or — only when a hash is required for this
    /// asset's root kind — the hash is stale. `hashRequired` is a Store-owned
    /// root-kind fact (ADR 0018); this pure value type never derives it itself, so a
    /// caller cannot forget to supply it and silently fall back to a wrong default.
    func needsEnrichment(hashRequired: Bool) -> Bool {
        metadataStale || (hashRequired && hashStale)
    }
}

/// The narrow detail value a visible grid tile needs after structure publishes
/// only identities. It intentionally omits filename and capture-date facts so the
/// thumbnail boundary cannot accidentally keep rendering removed labels.
nonisolated struct MediaTileDetail: Identifiable, Hashable {
    let libraryRootPath: LibraryRootPath
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let thumbnailPath: String?
    let bestKind: MediaKind?
    let durationSeconds: Double?
    let enrichedSourceSize: Int64?
    let enrichedSourceMTimeSeconds: Int?
    let mediaChoice: MediaChoice

    init(
        libraryRootPath: LibraryRootPath,
        relativePath: MediaRelativePath,
        byteSize: Int64? = nil,
        thumbnailPath: String? = nil,
        bestKind: MediaKind? = nil,
        durationSeconds: Double? = nil,
        enrichedSourceSize: Int64? = nil,
        enrichedSourceMTimeSeconds: Int? = nil,
        mediaChoice: MediaChoice = .default
    ) {
        self.libraryRootPath = libraryRootPath
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.thumbnailPath = thumbnailPath
        self.bestKind = bestKind
        self.durationSeconds = durationSeconds
        self.enrichedSourceSize = enrichedSourceSize
        self.enrichedSourceMTimeSeconds = enrichedSourceMTimeSeconds
        self.mediaChoice = mediaChoice
    }

    var id: MediaAssetID {
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    /// Enrichment ran and could not produce a real thumbnail (icon fallback is
    /// never stored). Distinguishes "broken/unsupported media" from "not yet
    /// enriched" (both have `thumbnailPath == nil`).
    var thumbnailUnavailable: Bool {
        enrichedSourceMTimeSeconds != nil && thumbnailPath == nil
    }
}

/// Builds the cheap, precomputed display-order key for a media asset. Digit runs
/// are zero-padded so a plain string comparison still orders them numerically
/// ("img2" before "img10") without a locale-aware comparison on every sort step.
nonisolated enum MediaSortKey {
    static func make(libraryRootPath: LibraryRootPath, relativePath: MediaRelativePath) -> String {
        // The library segment groups a library's assets together; the relative
        // path orders within it. U+0001 keeps the two segments from
        // ordering across the boundary.
        naturalKey(libraryRootPath.rawValue) + "\u{1}" + naturalKey(relativePath.rawValue)
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
/// copies every asset's detail (thumbnail, kind, size, …).
///
/// `dayBuckets` is the one deliberate exception, and it is not detail: it is a
/// single lightweight grouping key per asset (DES-069's day headers), computed
/// once per catalog change at the same cadence `orderedAssetIDs` already is —
/// not per scroll, not per visible window. Empty under any sort but `.bestDate`
/// (day-contiguity only holds under that sort; `.name`/`.size` render one
/// ungrouped section, same as before this field existed). When populated it is
/// always the same length as `orderedAssetIDs`, index-for-index; an individual
/// entry is `nil` when that asset has no known capture date (still grouped —
/// into a single "no date" section, per `MediaGridBridge`'s section grouping).
nonisolated struct CatalogMediaGridState: Equatable {
    var descriptor: CatalogQueryDescriptor
    var orderedAssetIDs: [MediaAssetID]
    var dayBuckets: [Date?] = []
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
        dayBuckets: [Date?] = [],
        detailRefreshGeneration: UInt64 = 0
    ) {
        self.init(
            descriptor: CatalogQueryDescriptor(scope: scope),
            orderedAssetIDs: orderedAssetIDs,
            dayBuckets: dayBuckets,
            detailRefreshGeneration: detailRefreshGeneration
        )
    }

    init(
        descriptor: CatalogQueryDescriptor,
        orderedAssetIDs: [MediaAssetID],
        dayBuckets: [Date?] = [],
        detailRefreshGeneration: UInt64 = 0
    ) {
        self.descriptor = descriptor
        self.orderedAssetIDs = orderedAssetIDs
        self.dayBuckets = dayBuckets
        self.detailRefreshGeneration = detailRefreshGeneration
    }
}

/// Selection of a sidebar row. Media selection will be modeled separately
/// because it answers a different question.
nonisolated enum SidebarSelection: Hashable {
    case allMedia
    case library(LibraryRootPath)
    case importBatch(ImportBatchID)
    case allImports

    var diagnosticDescription: String {
        switch self {
        case .allMedia:
            "allMedia"
        case let .library(path):
            "library:\(path.rawValue)"
        case let .importBatch(batchID):
            "importBatch:\(batchID.unixMilliseconds)"
        case .allImports:
            "allImports"
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

nonisolated enum RemovableSourceDetachReason: String {
    case unmounted
    case ejected
    case disconnected
    case forgotten
    case transientIdentityEnded
}

nonisolated enum CatalogStoreError: LocalizedError, Equatable {
    case notDirectory
    case overlappingRoot(existingPath: LibraryRootPath, relationship: LibraryRootRelationship)
    case catalogUnavailable
    case unsupportedCatalogSchema(CatalogSchemaCompatibility)
    case importOperationMissing(ActiveFileOperationKey)

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
        case let .unsupportedCatalogSchema(problem):
            problem.errorDescription
        case let .importOperationMissing(key):
            "The import journal operation \(key.rawValue) is no longer present."
        }
    }
}

/// What asking to remove a library did.
nonisolated enum LibraryRemovalOutcome: Equatable, Sendable {
    /// The library and its catalog rows are gone.
    case removed
    /// No library is cataloged at that path; nothing changed.
    case notInCatalog
    /// Another owner is changing the library's files. It is removed as soon as that owner
    /// releases it — or, when the owner is a removal already, by that removal.
    case waiting(for: RootNamespaceMutationOwner)
}

/// A removal the user asked for that waits for the library to be free: which library,
/// and the work it waits for. The alert wording is `LibraryRemovalNoticePresentation`'s.
nonisolated struct LibraryRemovalNotice: Equatable, Sendable {
    let displayName: String
    let waitingFor: RootNamespaceMutationOwner
}

/// Result of the pre-migration catalog schema compatibility check.
nonisolated enum CatalogSchemaCompatibility: Equatable, Sendable {
    /// Empty database or a known partial/current schema that additive migrations can advance.
    case readyToMigrate
    /// Applied migration identifiers include ones this build does not know: a newer Otos
    /// wrote it, or one from before the schema baseline. Which is not recorded, so not said.
    case writtenByOtherOtos
    /// User tables exist but no known migration identifiers are present.
    case unrecognized

    var errorDescription: String {
        switch self {
        case .readyToMigrate:
            "The catalog schema is compatible."
        case .writtenByOtherOtos:
            "This catalog was written by a different version of Otos."
        case .unrecognized:
            "This catalog is not compatible with this version of Otos."
        }
    }

    var isSupported: Bool {
        if case .readyToMigrate = self {
            return true
        }
        return false
    }
}

/// Typed UTC epoch milliseconds shared by every asset newly published in one import.
/// Rendered in the user's locale/time zone only in the sidebar.
nonisolated struct ImportBatchID: Hashable, Sendable, Comparable {
    let unixMilliseconds: Int64

    init(unixMilliseconds: Int64) {
        self.unixMilliseconds = unixMilliseconds
    }

    init(date: Date = Date()) {
        unixMilliseconds = Int64((date.timeIntervalSince1970 * 1000.0).rounded(.down))
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1000.0)
    }

    static func < (lhs: ImportBatchID, rhs: ImportBatchID) -> Bool {
        lhs.unixMilliseconds < rhs.unixMilliseconds
    }
}

/// One nonempty import batch for Store history queries and the Imports sidebar.
nonisolated struct ImportBatchSummary: Equatable, Sendable {
    let batchID: ImportBatchID
    let assetCount: Int
}
