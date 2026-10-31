import Foundation

// Duplicates (ADR 0042)
//
// A duplicate group is a projection over facts the catalog already holds — content
// digests (ADR 0018) and the overlay each copy carries — never a stored identity. The
// Store reads the copies; `DuplicateGroupPolicy` decides, purely, which copy each group
// would keep by default and which groups wait for the user; Projection publishes the
// result as `CatalogDuplicatesState`. The only durable fact the feature adds is the
// user's "Keep All Copies" — remembered per pair of paths, overlay with the copies'
// own lifecycle.

/// What makes copies one group. Identical copies share a content digest.
nonisolated enum DuplicateGroupID: Hashable, Sendable {
    case identical(XXH3Digest128)

    /// No digest is logged (ADR 0018); logs name a group by its first copy's path.
    var kindName: String {
        switch self {
        case .identical: "identical"
        }
    }
}

extension MediaAssetID {
    /// Total order for duplicate display and the keeper rule's last tiebreak: library
    /// path, then path inside it.
    nonisolated var duplicateOrderKey: String {
        "\(libraryRootPath.rawValue)\u{0}\(relativePath.rawValue)"
    }
}

/// One file in a duplicate group, with the facts the keeper rule and the list need.
nonisolated struct DuplicateCopy: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let libraryDisplayName: String
    let byteSize: Int64?
    /// The file's birth time, a filesystem fact.
    let createdAt: Date?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let mediaChoice: MediaChoice
    let isEdited: Bool
    /// The copy has `.xmp` or `.srt` companions: another app's edits or captions.
    let hasCompanions: Bool

    var name: String {
        (id.relativePath.rawValue as NSString).lastPathComponent
    }

    /// The folder inside its library, empty at the library's top.
    var folder: String {
        let components = id.relativePath.rawValue.split(separator: "/")
        return components.dropLast().joined(separator: "/")
    }

    /// Whether Otos or another app holds something authored for this copy.
    var carriesAuthoredWork: Bool {
        mediaChoice != .notRated || isEdited || hasCompanions
    }
}

/// Why a group waits for the user instead of offering a default.
nonisolated enum DuplicateGroupWait: Equatable, Sendable {
    /// Its copies live in more than one library; nothing across libraries is preselected.
    case spansLibraries
    /// More than one copy carries authored work — edits, companions, or different choices.
    case differingAuthoredWork
}

/// Two libraries that share identical items, summarized as one row before their groups.
nonisolated struct DuplicateLibraryPair: Hashable, Sendable {
    let first: LibraryRootPath
    let second: LibraryRootPath

    init(_ left: LibraryRootPath, _ right: LibraryRootPath) {
        if left.rawValue <= right.rawValue {
            first = left
            second = right
        } else {
            first = right
            second = left
        }
    }
}

nonisolated struct DuplicateGroup: Equatable, Sendable, Identifiable {
    let id: DuplicateGroupID
    /// The copies, in display order: kept copies first, then by library and path.
    let copies: [DuplicateCopy]
    /// The copies the group keeps by default; every other copy is marked to move to the
    /// Trash. `nil` when the group waits for the user.
    let defaultKeep: Set<MediaAssetID>?
    let wait: DuplicateGroupWait?
    /// The user kept every copy (Keep All Copies): listed under Kept, counted nowhere else.
    let isKept: Bool
    /// The two libraries this group spans, when it spans exactly two.
    let libraryPair: DuplicateLibraryPair?
}

/// Projection's answer for duplicates, published in every scope so the sidebar row
/// knows whether it exists; the list itself draws only under `.duplicates`.
nonisolated struct CatalogDuplicatesState: Equatable, Sendable {
    let groups: [DuplicateGroup]

    static let empty = CatalogDuplicatesState(groups: [])

    /// Groups that still need something: not kept.
    var activeGroups: [DuplicateGroup] {
        groups.filter { !$0.isKept }
    }

    var keptGroups: [DuplicateGroup] {
        groups.filter(\.isKept)
    }
}

/// Facts the Store reads for one copy, plus the library's display name and kind.
nonisolated struct DuplicateCopyFacts: Equatable, Sendable {
    let copy: DuplicateCopy
    let digest: XXH3Digest128
}

/// The keeper rule (ADR 0042). Pure: facts in, groups out.
///
/// A default is offered only where it cannot lose anything: identical bytes, every copy
/// in one library, and at most one copy carrying authored work — that copy is kept.
/// Otherwise the kept copy is the one whose name has no Finder or browser copy suffix,
/// then the earliest birth time, then path order. Every other group waits.
nonisolated enum DuplicateGroupPolicy {
    static func groups(
        copies: [DuplicateCopyFacts],
        keptPairs: Set<DuplicateKeptPair>
    ) -> [DuplicateGroup] {
        let byDigest = Dictionary(grouping: copies, by: \.digest)
        var groups: [DuplicateGroup] = []
        for (digest, members) in byDigest where members.count > 1 {
            groups.append(group(
                id: .identical(digest),
                copies: members.map(\.copy),
                keptPairs: keptPairs
            ))
        }
        return groups.sorted { left, right in
            let leftKey = left.copies.first?.id.duplicateOrderKey ?? ""
            let rightKey = right.copies.first?.id.duplicateOrderKey ?? ""
            return leftKey < rightKey
        }
    }

    static func group(
        id: DuplicateGroupID,
        copies unordered: [DuplicateCopy],
        keptPairs: Set<DuplicateKeptPair>
    ) -> DuplicateGroup {
        let copies = unordered.sorted { $0.id.duplicateOrderKey < $1.id.duplicateOrderKey }
        let ids = copies.map(\.id)
        let libraries = Set(ids.map(\.libraryRootPath))
        let libraryPair: DuplicateLibraryPair? = libraries.count == 2
            ? DuplicateLibraryPair(libraries.sorted { $0.rawValue < $1.rawValue }[0],
                                   libraries.sorted { $0.rawValue < $1.rawValue }[1])
            : nil

        var keptTogether: Set<MediaAssetID> = []
        var everyPairKept = true
        for (index, left) in ids.enumerated() {
            for right in ids[(index + 1)...] {
                if keptPairs.contains(DuplicateKeptPair(left, right)) {
                    keptTogether.insert(left)
                    keptTogether.insert(right)
                } else {
                    everyPairKept = false
                }
            }
        }
        if everyPairKept {
            return DuplicateGroup(
                id: id,
                copies: copies,
                defaultKeep: Set(ids),
                wait: nil,
                isKept: true,
                libraryPair: libraryPair
            )
        }

        let decision = defaultKeep(copies: copies, keptTogether: keptTogether, libraries: libraries)
        let ordered = copies.sorted { left, right in
            let leftKept = decision.keep?.contains(left.id) ?? false
            let rightKept = decision.keep?.contains(right.id) ?? false
            if leftKept != rightKept {
                return leftKept
            }
            return left.id.duplicateOrderKey < right.id.duplicateOrderKey
        }
        return DuplicateGroup(
            id: id,
            copies: ordered,
            defaultKeep: decision.keep,
            wait: decision.wait,
            isKept: false,
            libraryPair: libraryPair
        )
    }

    private static func defaultKeep(
        copies: [DuplicateCopy],
        keptTogether: Set<MediaAssetID>,
        libraries: Set<LibraryRootPath>
    ) -> (keep: Set<MediaAssetID>?, wait: DuplicateGroupWait?) {
        guard libraries.count == 1 else {
            return (nil, .spansLibraries)
        }
        let authored = copies.filter(\.carriesAuthoredWork)
        // A later copy of copies the user kept together: keep those, offer only the new one
        // — unless the new one carries work of its own.
        if !keptTogether.isEmpty {
            let newcomers = copies.filter { !keptTogether.contains($0.id) }
            guard newcomers.allSatisfy({ !$0.carriesAuthoredWork }) else {
                return (nil, .differingAuthoredWork)
            }
            return (keptTogether, nil)
        }
        if authored.count > 1 {
            return (nil, .differingAuthoredWork)
        }
        if let only = authored.first {
            return ([only.id], nil)
        }
        let keeper = copies.min { left, right in
            let leftSuffixed = hasCopySuffix(left.name)
            let rightSuffixed = hasCopySuffix(right.name)
            if leftSuffixed != rightSuffixed {
                return !leftSuffixed
            }
            switch (left.createdAt, right.createdAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate < rightDate
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return left.id.duplicateOrderKey < right.id.duplicateOrderKey
            }
        }
        return (keeper.map { [$0.id] }, nil)
    }

    /// A name Finder (` copy`, ` copy 2`) or a browser download (` (1)`) gives a second
    /// copy of a file.
    static func hasCopySuffix(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return stem.range(of: #"( copy( \d+)?| \(\d+\))$"#, options: .regularExpression) != nil
    }
}

/// "Keep All Copies", remembered for one pair of paths (ADR 0042). Unordered.
nonisolated struct DuplicateKeptPair: Hashable, Sendable {
    let first: MediaAssetID
    let second: MediaAssetID

    init(_ left: MediaAssetID, _ right: MediaAssetID) {
        if left.duplicateOrderKey <= right.duplicateOrderKey {
            first = left
            second = right
        } else {
            first = right
            second = left
        }
    }
}

/// What the window holds while the user works through Duplicates (ADR 0042): the marks
/// the user changed, which groups are on screen, and which summaries are open. Pure, so
/// what the bar counts and what the act moves are one computation.
///
/// Groups found while the user is looking are held back (`heldCount`) until Show — so
/// neither the count on the button nor the rows under the pointer move — and are taken
/// in at once after the user's own act. Groups that resolve or vanish leave at once.
nonisolated struct DuplicatesSession: Equatable, Sendable {
    /// Copies whose Keep the user set, overriding the group's default.
    var keepOverrides: [MediaAssetID: Bool] = [:]
    /// The active groups on screen; nil until the list is first shown.
    var shownGroupIDs: Set<DuplicateGroupID>?
    var expandedPairs: Set<DuplicateLibraryPair> = []
    var showsKept = false

    /// The active groups to draw, in the published order, without held newcomers.
    func shownActiveGroups(in state: CatalogDuplicatesState) -> [DuplicateGroup] {
        guard let shown = shownGroupIDs else {
            return state.activeGroups
        }
        return state.activeGroups.filter { shown.contains($0.id) }
    }

    func heldCount(in state: CatalogDuplicatesState) -> Int {
        guard let shown = shownGroupIDs else {
            return 0
        }
        return state.activeGroups.count { !shown.contains($0.id) }
    }

    /// Takes in every published group (first show, Show, or after the user's own act).
    mutating func adoptAll(_ state: CatalogDuplicatesState) {
        shownGroupIDs = Set(state.activeGroups.map(\.id))
        let live = Set(state.groups.flatMap(\.copies).map(\.id))
        keepOverrides = keepOverrides.filter { live.contains($0.key) }
    }

    /// Whether this copy is kept: the user's mark, else the group's default, else kept
    /// (a waiting group marks nothing).
    func keeps(_ copy: MediaAssetID, in group: DuplicateGroup) -> Bool {
        if let override = keepOverrides[copy] {
            return override
        }
        return group.defaultKeep?.contains(copy) ?? true
    }

    /// The copies this group would move to the Trash: none unless the group has a default
    /// or the user marked it, and never every copy.
    func copiesToMove(in group: DuplicateGroup) -> [MediaAssetID] {
        let moving = group.copies.map(\.id).filter { !keeps($0, in: group) }
        return moving.count < group.copies.count ? moving : []
    }

    /// A waiting group the user has not touched.
    func needsChoice(_ group: DuplicateGroup) -> Bool {
        group.defaultKeep == nil && !group.copies.contains { keepOverrides[$0.id] != nil }
    }

    /// Whether the user may unmark this copy: a group always keeps one copy.
    func canMoveToTrash(_ copy: MediaAssetID, in group: DuplicateGroup) -> Bool {
        guard keeps(copy, in: group) else {
            return false
        }
        return group.copies.count { keeps($0.id, in: group) } > 1
    }

    /// What the bar states and the act moves, over the groups on screen.
    func tally(in state: CatalogDuplicatesState) -> DuplicatesTally {
        let groups = shownActiveGroups(in: state)
        var moving: [MediaAssetID] = []
        var bytes: Int64 = 0
        var unknownSizes = 0
        for group in groups {
            for id in copiesToMove(in: group) {
                moving.append(id)
                if let size = group.copies.first(where: { $0.id == id })?.byteSize {
                    bytes += size
                } else {
                    unknownSizes += 1
                }
            }
        }
        return DuplicatesTally(
            photosWithDuplicates: groups.count,
            itemsToMove: moving,
            bytesToMove: PartialByteCount(knownBytes: bytes, unknownCount: unknownSizes),
            needingChoice: groups.count(where: needsChoice),
            held: heldCount(in: state)
        )
    }
}

nonisolated struct DuplicatesTally: Equatable, Sendable {
    let photosWithDuplicates: Int
    let itemsToMove: [MediaAssetID]
    let bytesToMove: PartialByteCount
    let needingChoice: Int
    let held: Int
}
