import CoreGraphics
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
/// The one rule for what names an Immich server (ADR 0046 §2).
nonisolated enum ImmichServerAddress {
    /// `scheme://host[:port][/path]`, scheme and host lowercased, a default port and any
    /// trailing slash, query or fragment dropped. Nil unless the scheme is http or https
    /// and there is a host.
    static func normalized(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}

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

    /// One user on one Immich server (ADR 0046 §2): `immich:<server>#<user id>`. The
    /// server is normalized so one server typed two ways is one account: the scheme and
    /// host lowercased, a default port and a trailing slash dropped. Nil for a URL that
    /// is not http or https with a host.
    static func immichAccount(server: URL, userID: String) -> DeviceIdentity? {
        guard let normalized = ImmichServerAddress.normalized(server) else {
            return nil
        }
        return DeviceIdentity(rawValue: "immich:\(normalized.absoluteString)#\(userID)")
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
/// 2026-10-25, ADR 0013). A product rule, not a stand-in for a fact: no
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
    /// The server an Immich account reads from (ADR 0046 §2); nil for every other kind.
    let remoteBaseURL: URL?

    init(
        path: LibraryRootPath,
        kind: LibraryRootKind = .library,
        deviceIdentity: DeviceIdentity? = nil,
        displayName: String? = nil,
        lastSeenAt: Date? = nil,
        remoteBaseURL: URL? = nil
    ) {
        self.path = path
        self.kind = kind
        self.deviceIdentity = deviceIdentity
        displayNameOverride = displayName
        self.lastSeenAt = lastSeenAt
        self.remoteBaseURL = remoteBaseURL
    }

    var id: LibraryRootPath {
        path
    }

    var displayName: String {
        displayNameOverride?.isEmpty == false ? displayNameOverride ?? path.displayName : path.displayName
    }

    /// Where the root's originals live, as Settings names it: an account's server, or
    /// the folder's path.
    var locationDescription: String {
        remoteBaseURL?.absoluteString ?? path.rawValue
    }

    /// A card or camera (`LibraryRootKind.isRemovable`).
    var isRemovableSource: Bool {
        kind.isRemovable
    }

    /// `LibraryRootKind.claimsEveryProductTogether`.
    var claimsEveryProductTogether: Bool {
        kind.claimsEveryProductTogether
    }

    /// `LibraryRootKind.firstClaim`.
    var firstClaim: EnrichmentClaim {
        kind.firstClaim
    }

    /// `LibraryRootKind.producesAfterMetadata`.
    var producesAfterMetadata: Bool {
        kind.producesAfterMetadata
    }
}

/// The catalog stores every source as a root because the filesystem path remains
/// the asset identity boundary. Kind only changes ownership semantics: fixed
/// libraries participate in All Media and launch scans, while removable sources
/// are event-driven and are scoped to their own sidebar rows.
///
/// Every question a caller asks about a kind is one named capability below, each an
/// exhaustive `switch`, so a new kind does not compile until it answers every question
/// (ADR 0046). No caller compares kinds directly: a bare `kind == .library` answers a
/// different question at each call site, and a new kind would be wrong in most of them.
nonisolated enum LibraryRootKind: String, CaseIterable, Hashable, Codable {
    case library
    case removableVolume
    case deviceMTP
    /// One user's assets on an Immich server, read only (ADR 0046).
    case immichAccount

    /// A folder on this Mac the user chose as a library (ADR 0003): its stored path is
    /// normalized at load, it is scanned at launch and by integrity scans on the fixed
    /// libraries' lane, and `MetadataRefresher` re-reads its rows from local bytes.
    var isUserChosenFolder: Bool {
        switch self {
        case .library: true
        case .removableVolume, .deviceMTP, .immichAccount: false
        }
    }

    /// Listed in the sidebar's Libraries section, in the user's order, rather than in
    /// Removable while connected.
    var isInLibrariesSection: Bool {
        switch self {
        case .library, .immichAccount: true
        case .removableVolume, .deviceMTP: false
        }
    }

    /// Spanned by All Media, Places, Imports and Duplicates (ADR 0013 decision 3).
    var isMemberOfAllMedia: Bool {
        switch self {
        case .library, .immichAccount: true
        case .removableVolume, .deviceMTP: false
        }
    }

    /// Where an import may copy media to, and whose digests an import trusts as
    /// "already in a library".
    var isImportDestination: Bool {
        switch self {
        case .library: true
        case .removableVolume, .deviceMTP, .immichAccount: false
        }
    }

    /// Library reorganization may move its originals within it (ADR 0003, ARC-051): a
    /// folder the user chose, whose files Otos may move only when told to.
    var supportsReorganization: Bool {
        switch self {
        case .library: true
        case .removableVolume, .deviceMTP, .immichAccount: false
        }
    }

    /// A card or camera (ADR 0013): it attaches and detaches, starts each launch
    /// unavailable, is an import source, is enriched ahead of fixed libraries while
    /// connected, holds rows awaiting presence on attach, and is forgotten after the
    /// retention period unseen.
    var isRemovable: Bool {
        switch self {
        case .removableVolume, .deviceMTP: true
        case .library, .immichAccount: false
        }
    }

    /// Has a filesystem namespace Otos walks and watches: a library, or a mounted card.
    var hasFilesystemNamespace: Bool {
        switch self {
        case .library, .removableVolume: true
        case .deviceMTP, .immichAccount: false
        }
    }

    /// Move to Trash applies to its originals (ADR 0022). A camera's files are not on a
    /// filesystem the Trash can reach.
    var supportsMoveToTrash: Bool {
        switch self {
        case .library, .removableVolume: true
        case .deviceMTP, .immichAccount: false
        }
    }

    /// Rows come from the source's own listing under an enumeration lease, not from a
    /// filesystem walk (ADR 0013 decision 5).
    var rowsComeFromSourceListing: Bool {
        switch self {
        case .deviceMTP, .immichAccount: true
        case .library, .removableVolume: false
        }
    }

    /// The Otos staging container this kind's originals are copied into on demand, or nil
    /// when they are read in place. The staging folder and its files are Otos's to release.
    var stagingContainer: StagingContainer? {
        switch self {
        case .deviceMTP: .device
        case .immichAccount: .remote
        case .library, .removableVolume: nil
        }
    }

    /// Originals are copied into an Otos staging folder rather than read in place.
    var stagesOriginals: Bool {
        stagingContainer != nil
    }

    /// An import reads this source's own files in place, so enrichment leaves the source
    /// alone while one runs rather than competing for its bandwidth.
    var pausesEnrichmentWhileImporting: Bool {
        switch self {
        case .removableVolume: true
        case .library, .deviceMTP, .immichAccount: false
        }
    }

    /// Whether enrichment claims this kind's rows for every stale product at once —
    /// metadata, rendering and digest from one read (ADR 0009, ADR 0018). A fixed library
    /// does: its files may be cloud-only, and a download is paid once for all of them.
    ///
    /// A removable volume is claimed for metadata first, which is what an import waits on,
    /// and for its renderings and digests in a pass of its own once every row of the card
    /// has its metadata (`producesAfterMetadata`): its bytes are local, so reading it twice
    /// downloads nothing.
    ///
    /// `.deviceMTP` is claimed for metadata only: a camera row is enriched from a few
    /// kilobytes of ranged reads, and a rendering or digest would force the whole-file
    /// transfer. Those rows get both at import, from the staged copy's local bytes.
    var claimsEveryProductTogether: Bool {
        switch self {
        case .library: true
        case .removableVolume, .deviceMTP, .immichAccount: false
        }
    }

    /// The claim a row of this kind is first enriched under (ADR 0018, ADR 0047): a fixed
    /// library's every product, faces included, or metadata first. A card's renderings and
    /// digests come later, under `EnrichmentClaim.cardProducts`.
    var firstClaim: EnrichmentClaim {
        claimsEveryProductTogether ? .library : .metadata
    }

    /// The kinds that have `capability`, as a SQL list of quoted `library_root.kind`
    /// values, so a query states the same rule the Swift callers ask. Raw values are
    /// fixed identifiers with no quotes, so they need no escaping.
    static func sqlLiteralList(_ capability: KeyPath<Self, Bool>) -> String {
        allCases.filter { $0[keyPath: capability] }.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    /// Whether this kind's rows get a rendering-and-digest pass once metadata is current.
    var producesAfterMetadata: Bool {
        switch self {
        case .removableVolume: true
        case .library, .deviceMTP, .immichAccount: false
        }
    }

    var sidebarSystemImage: String {
        switch self {
        case .library:
            "folder"
        case .removableVolume:
            "sdcard"
        case .deviceMTP:
            "camera"
        case .immichAccount:
            "server.rack"
        }
    }

    /// Its rows stay in the grid while its source cannot be reached: the catalog holds the
    /// source's last listing, and its thumbnails and previews are stored (ADR 0046 §6). A
    /// folder or card that is gone shows nothing, because its filesystem is its truth.
    var showsRowsWhileUnreachable: Bool {
        switch self {
        case .immichAccount: true
        case .library, .removableVolume, .deviceMTP: false
        }
    }

    /// What a launch knows of a saved root before any source has answered. A fixed
    /// library is checked by its launch scan, and a card or camera is unavailable until a
    /// monitor attaches it. An account's stored listing is its truth until its server
    /// reports otherwise, so it is available at once; whether the server answers is a
    /// separate fact (ADR 0046 §6).
    var availabilityAtLaunch: LibraryAvailability {
        switch self {
        case .library: .unknown
        case .removableVolume, .deviceMTP: .unavailable
        case .immichAccount: .available
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
    // preserves facts. Staleness is derived, never stored, per product (ADR 0009): the
    // metadata, the rendering, the digest and the faces each record the
    // `(size, mtime-seconds)` they were made from, and each is stale when the file's
    // current pair differs.
    let thumbnailPath: String?
    let bestCaptureDate: Date?
    let bestKind: MediaKind?
    let bestFormat: MediaFormatToken?
    let durationSeconds: Double?
    let metadataSourceSize: Int64?
    let metadataSourceMTimeSeconds: Int?
    let renderedSourceSize: Int64?
    let renderedSourceMTimeSeconds: Int?
    let contentHash: XXH3Digest128?
    let contentHashSourceSize: Int64?
    let contentHashSourceMTimeSeconds: Int?
    let facesSourceSize: Int64?
    let facesSourceMTimeSeconds: Int?
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
        metadataSourceSize: Int64? = nil,
        metadataSourceMTimeSeconds: Int? = nil,
        renderedSourceSize: Int64? = nil,
        renderedSourceMTimeSeconds: Int? = nil,
        contentHash: XXH3Digest128? = nil,
        contentHashSourceSize: Int64? = nil,
        contentHashSourceMTimeSeconds: Int? = nil,
        facesSourceSize: Int64? = nil,
        facesSourceMTimeSeconds: Int? = nil,
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
        self.metadataSourceSize = metadataSourceSize
        self.metadataSourceMTimeSeconds = metadataSourceMTimeSeconds
        self.renderedSourceSize = renderedSourceSize
        self.renderedSourceMTimeSeconds = renderedSourceMTimeSeconds
        self.contentHash = contentHash
        self.contentHashSourceSize = contentHashSourceSize
        self.contentHashSourceMTimeSeconds = contentHashSourceMTimeSeconds
        self.facesSourceSize = facesSourceSize
        self.facesSourceMTimeSeconds = facesSourceMTimeSeconds
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

    /// True when the metadata stamp (parsed metadata, kind, format, capture-wall facts) is
    /// not valid for the current filesystem signature.
    var metadataStale: Bool {
        !stampIsCurrent(size: metadataSourceSize, mtimeSeconds: metadataSourceMTimeSeconds)
    }

    /// True when the rendering stamp (the thumbnail and preview made from one development,
    /// ADR 0035) is not valid for the current filesystem signature. A provisional
    /// thumbnail — QuickLook's on a card's first pass, a camera's embedded one — is not a
    /// rendering and leaves this true.
    var renderingStale: Bool {
        !stampIsCurrent(size: renderedSourceSize, mtimeSeconds: renderedSourceMTimeSeconds)
    }

    /// True when the persisted content hash is missing, malformed, or does not match
    /// the current filesystem signature. Meaningless on its own: a root that never
    /// hashes (`.removableVolume`, see ADR 0018) must not be judged stale by this
    /// alone. Callers gate it behind the claim.
    var hashStale: Bool {
        contentHash == nil
            || contentHashSourceSize == nil
            || contentHashSourceMTimeSeconds == nil
            || !stampIsCurrent(size: contentHashSourceSize, mtimeSeconds: contentHashSourceMTimeSeconds)
    }

    /// True when the faces stamp (`FaceAnalyzer`'s reading of a still, ADR 0047) is not valid
    /// for the current filesystem signature. Owed only by a row claimed under
    /// `EnrichmentClaim.library`; callers gate it behind the claim.
    var facesStale: Bool {
        !stampIsCurrent(size: facesSourceSize, mtimeSeconds: facesSourceMTimeSeconds)
    }

    /// Whether a product's stamp names the file's current `(size, mtime-seconds)`: the one
    /// staleness rule every product shares (ADR 0009).
    private func stampIsCurrent(size: Int64?, mtimeSeconds: Int?) -> Bool {
        size == (byteSize ?? -1) && mtimeSeconds == Self.mtimeSeconds(contentModifiedAt)
    }

    /// True when a product `claim` covers is stale. The claim is the one the Store chose for
    /// the row's root and pass (ADR 0018); this pure value type never derives it itself, so a
    /// caller cannot forget to supply it and silently fall back to a wrong default. The Swift
    /// twin of `EnrichmentClaimGateway.stalenessSQLPredicate(_:)`.
    func needsEnrichment(_ claim: EnrichmentClaim) -> Bool {
        switch claim {
        case .metadata: metadataStale
        case .cardProducts: metadataStale || renderingStale || hashStale
        case .library: metadataStale || renderingStale || hashStale || facesStale
        }
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
    /// The stored loupe preview, which the loupe and compare decode instead of the
    /// original (ADR 0035); nil until enrichment rendered one, and for videos.
    let previewPath: String?
    /// The original's oriented pixel size from stored metadata, so the loupe can size its
    /// 100% document without reading the original's header (which would download a
    /// cloud-only file); nil until metadata is known.
    let nativePixelWidth: Int?
    let nativePixelHeight: Int?
    /// The photo's saved edit (ADR 0036); nil when never edited.
    let editRecipe: EditRecipe?
    /// The edit revision the stored thumbnail and preview were rendered from. It changes
    /// with every rendered edit, so it keys every cached image of them.
    let renderedRevision: Int64
    let bestKind: MediaKind?
    let durationSeconds: Double?
    /// The `(size, mtime)` the stored thumbnail and preview were rendered from (ADR 0009):
    /// nil while the row has no rendering, including while a provisional thumbnail shows.
    let renderedSourceSize: Int64?
    let renderedSourceMTimeSeconds: Int?
    let mediaChoice: MediaChoice

    init(
        libraryRootPath: LibraryRootPath,
        relativePath: MediaRelativePath,
        byteSize: Int64? = nil,
        thumbnailPath: String? = nil,
        previewPath: String? = nil,
        nativePixelWidth: Int? = nil,
        nativePixelHeight: Int? = nil,
        editRecipe: EditRecipe? = nil,
        renderedRevision: Int64 = 0,
        bestKind: MediaKind? = nil,
        durationSeconds: Double? = nil,
        renderedSourceSize: Int64? = nil,
        renderedSourceMTimeSeconds: Int? = nil,
        mediaChoice: MediaChoice = .default
    ) {
        self.libraryRootPath = libraryRootPath
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.thumbnailPath = thumbnailPath
        self.previewPath = previewPath
        self.nativePixelWidth = nativePixelWidth
        self.nativePixelHeight = nativePixelHeight
        self.editRecipe = editRecipe
        self.renderedRevision = renderedRevision
        self.bestKind = bestKind
        self.durationSeconds = durationSeconds
        self.renderedSourceSize = renderedSourceSize
        self.renderedSourceMTimeSeconds = renderedSourceMTimeSeconds
        self.mediaChoice = mediaChoice
    }

    var id: MediaAssetID {
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: relativePath)
    }

    var nativePixelSize: CGSize? {
        guard let nativePixelWidth, let nativePixelHeight else {
            return nil
        }
        return CGSize(width: nativePixelWidth, height: nativePixelHeight)
    }

    /// Rendering ran and could not produce a real thumbnail (icon fallback is never
    /// stored). Distinguishes "broken/unsupported media" from "not yet rendered" (both
    /// have `thumbnailPath == nil`).
    var thumbnailUnavailable: Bool {
        renderedSourceMTimeSeconds != nil && thumbnailPath == nil
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

/// The collection the browser shows: a sidebar row, or the one place reached by
/// drilling into the Places map. Media selection is modeled separately because it
/// answers a different question.
///
/// `.places` is every located item across the fixed libraries, presented as a map
/// (ADR 0040). `.mapArea` is the leaf under it — the items in one box of the map, the
/// area the map showed or one stack's coordinate — presented in the ordinary view modes;
/// the sidebar keeps the Places row highlighted for it.
///
/// `.duplicates` is every copy in a duplicate group across the fixed libraries,
/// presented as the duplicates list (ADR 0042); `.duplicateGroup` is the leaf under it —
/// one group's copies in the ordinary Compare, Loupe or grid.
///
/// `.onThisDay` is every item in the fixed libraries captured on the day's month and day
/// in an earlier year, presented as its years and played as a story (ADR 0049). The day is
/// today, which the ViewModel owns; when today changes, the ViewModel selects the new day.
///
/// `.people` is the People list and `.peopleReview` the review (ADR 0047,
/// `docs/design/people.md`); `.person` is the leaf under the list — the photos holding a
/// confirmed face of one person, in the ordinary view modes — and `.reviewPhotos` the leaf
/// under the review: one row's photos in Loupe. The sidebar keeps People highlighted for all
/// four.
nonisolated enum SidebarSelection: Hashable {
    case allMedia
    case places
    case mapArea(MapArea)
    case onThisDay(CalendarDay)
    case duplicates
    case duplicateGroup(DuplicateGroupID)
    case people
    case peopleReview
    case person(PersonID)
    case reviewPhotos([MediaAssetID])
    case library(LibraryRootPath)
    case importBatch(ImportBatchID)
    case allImports

    /// The row the sidebar highlights for this scope: `.mapArea` has no row of its own and
    /// highlights Places, the row it was reached from.
    var sidebarRow: SidebarSelection {
        switch self {
        case .mapArea: .places
        case .duplicateGroup: .duplicates
        case .peopleReview, .person, .reviewPhotos: .people
        default: self
        }
    }

    /// The order a scope fixes for itself, whatever the sort control says: On This Day plays
    /// newest year first and newest item first within a year (ADR 0049), so its sort is not
    /// the user's to choose. Nil for every scope the user sorts.
    var fixedSort: MediaSortOrder? {
        switch self {
        case .onThisDay: .dateNewest
        default: nil
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .allMedia:
            "allMedia"
        case .places:
            "places"
        case let .mapArea(area):
            "mapArea:\(area.diagnosticDescription)"
        case let .onThisDay(day):
            "onThisDay:\(day.diagnosticDescription)"
        case .duplicates:
            "duplicates"
        case let .duplicateGroup(group):
            "duplicateGroup:\(group.kindName)"
        case .people:
            "people"
        case .peopleReview:
            "peopleReview"
        case let .person(person):
            "person:\(person.rawValue)"
        case let .reviewPhotos(ids):
            "reviewPhotos:\(ids.count)"
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
    /// The file's identifier on its volume (its inode), read with the other filesystem
    /// facts and never used as identity: it is the move witness's evidence that a file
    /// at a new path is the one an absent row described (ADR 0008). `nil` where the
    /// source has no filesystem, such as a camera.
    let fileIdentifier: UInt64?

    init(
        relativePath: MediaRelativePath,
        name: String?,
        contentTypeIdentifier: String?,
        byteSize: Int64?,
        createdAt: Date?,
        contentModifiedAt: Date?,
        kind: MediaKind? = nil,
        format: MediaFormatToken? = nil,
        fileIdentifier: UInt64? = nil
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
        self.fileIdentifier = fileIdentifier
    }
}

/// An item a source's change stream reports it holds (ADR 0046 §5).
nonisolated struct SourceListedItem: Hashable, Sendable {
    /// The item's facts. A nil size is one this report does not carry, and leaves the
    /// size the catalog already holds.
    let file: ScannedMediaFile
    /// The source's own ID for the item (an Immich asset's ID), which every later report
    /// and request about it uses.
    let sourceItemID: String
    /// The source holds the item but hides it: an Immich asset in Immich's trash.
    let isHiddenBySource: Bool
}

/// Where an item its source names by ID already lives, and whether the source hides it.
nonisolated struct SourceItemRow: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let isHiddenBySource: Bool
}

/// A row whose source's own thumbnail and preview are missing or older than its file
/// (ADR 0046 §7).
nonisolated struct SourceProductCandidate: Equatable, Sendable {
    let id: MediaAssetID
    /// The source's own ID for the item, which its images are asked for by.
    let sourceItemID: String
    let kind: MediaKind?
    let byteSize: Int64
    let contentModifiedAtSeconds: Int?
}

/// One batch of a source's change stream, applied in one transaction. Each item is named
/// by the source's own ID for it (an Immich asset's ID, ADR 0046 §2); a size or a
/// permanent deletion the source reports apart from an item's facts names only that ID.
nonisolated struct SourceListingChanges: Sendable, Equatable {
    var listed: [SourceListedItem] = []
    /// Folders listed in full: each holds exactly the items this batch lists in it, so a
    /// row there that the batch does not list — a Live Photo motion part its still no
    /// longer links — is purged.
    var completeFolders: [String] = []
    /// Sizes reported apart from the item's own facts, by the source's ID for the item.
    var sizesBySourceItem: [String: Int64] = [:]
    /// Items the source proves deleted, by its ID. Their rows and overlay are purged, and
    /// so is every row in a deleted item's own folder: a deleted still takes its motion
    /// part with it.
    var deletedSourceItems: [String] = []

    var isEmpty: Bool {
        listed.isEmpty && completeFolders.isEmpty && sizesBySourceItem.isEmpty && deletedSourceItems.isEmpty
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
    /// A durable journal or settlement write SQLite refused because the disk is full
    /// (`SQLITE_FULL`): the floor reached the hard way (ADR 0027).
    case outOfSpace
    /// An Immich server address that is not an http or https URL with a host.
    case invalidRemoteServer
    /// A stored face whose landmarks or embedding are not the size the catalog writes.
    case malformedFaceRow(MediaAssetID)

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
        case .outOfSpace:
            "The disk is full."
        case .invalidRemoteServer:
            "Enter the server’s web address, starting with http:// or https://."
        case .malformedFaceRow:
            "A face stored in the catalog could not be read."
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

/// The motion movie of a Live Photo, the member its still's item carries (ADR 0041).
nonisolated struct LivePhotoMotion: Equatable, Sendable {
    let relativePath: MediaRelativePath
    /// Cataloged size, a filesystem fact.
    let byteSize: Int64?

    func id(in root: LibraryRootPath) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: relativePath)
    }
}
