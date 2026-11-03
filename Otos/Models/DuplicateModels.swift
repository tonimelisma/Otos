import Foundation

// Duplicates (ADR 0042)
//
// A duplicate group is a projection over facts the catalog already holds — content
// digests (ADR 0018) and the overlay each copy carries — never a stored identity. The
// Store reads the copies; `DuplicateGroupPolicy` decides, purely, which copies each group
// keeps by default and which rule decided it — every group has a default unless its
// copies hold work that cannot be combined, and then the group names what conflicts;
// Projection publishes the result as `CatalogDuplicatesState`. The only durable fact the
// feature adds is the user's "Keep All Copies" — remembered per pair of paths, overlay
// with the copies' own lifecycle.

/// What makes copies one group. Identical copies share a content digest; versions of the
/// same photo share a picture, proven by their thumbnails, and are named by their members.
nonisolated enum DuplicateGroupID: Hashable, Sendable {
    case identical(XXH3Digest128)
    /// Members in `duplicateOrderKey` order.
    case samePhoto([MediaAssetID])

    /// Versions of one photo are told apart by their pixels; identical copies, by where they
    /// live.
    var isSamePhoto: Bool {
        if case .samePhoto = self {
            return true
        }
        return false
    }

    /// No digest is logged (ADR 0018); logs name a group by its first copy's path.
    var kindName: String {
        switch self {
        case .identical: "identical"
        case .samePhoto: "samePhoto"
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
    /// The catalog's best kind, which names the group (`2 identical videos`); nil before
    /// enrichment has read it.
    let kind: MediaKind?
    /// The catalog's best capture date: what the group is dated by and listed under.
    let captureDate: Date?
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
        id.relativePath.fileName
    }

    /// The folder inside its library, empty at the library's top.
    var folder: String {
        id.relativePath.folder
    }

    /// Whether Otos or another app holds something authored for this copy.
    var carriesAuthoredWork: Bool {
        mediaChoice != .notRated || isEdited || hasCompanions
    }
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

/// The keeper rule's criteria, in the order they are tried (ADR 0042). A group's default
/// names the one that decided it, so the list can say why a copy is kept.
nonisolated enum DuplicateKeeperCriterion: Int, Comparable, Sendable {
    /// Companion files cannot move onto another copy.
    case companions
    /// For versions of one photo: the camera's own file names its capture.
    case cameraOriginal
    case mostPixels
    case largestFile
    case edited
    case rated
    /// A name without a Finder or browser copy suffix.
    case originalName
    case earliestBirth
    /// Nothing else told the copies apart.
    case pathOrder

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Work on two copies of one library that no single copy can hold (ADR 0042).
nonisolated struct DuplicateWorkConflict: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case edits
        case companions
        case choices
    }

    let kind: Kind
    /// The library whose copies conflict: named when the group spans libraries.
    let library: LibraryRootPath
}

/// What a group does unless the user changes a mark.
nonisolated enum DuplicateDefault: Equatable, Sendable {
    /// These copies are kept and the rest marked, for this reason.
    case keep(Set<MediaAssetID>, reason: Reason)
    /// Nothing is marked: the copies hold work that cannot be combined.
    case waits(DuplicateWorkConflict)
    /// The user kept every copy (Keep All Copies): listed under Kept, counted nowhere else.
    case kept

    enum Reason: Equatable, Sendable {
        /// The group spans libraries, and each keeps its own copy.
        case eachLibrary
        /// Within one library, the criterion that separated the kept copy from the others.
        case criterion(DuplicateKeeperCriterion)
    }
}

nonisolated struct DuplicateGroup: Equatable, Sendable, Identifiable {
    let id: DuplicateGroupID
    /// The copies, in display order: kept copies first, then by library and path.
    let copies: [DuplicateCopy]
    let `default`: DuplicateDefault
    /// The two libraries this group spans, when it spans exactly two.
    let libraryPair: DuplicateLibraryPair?
    /// For versions of one photo, the copies that name their capture: the camera's own
    /// files, which the keeper rule prefers and the list marks `Camera original`.
    let cameraOriginals: Set<MediaAssetID>

    /// The copies the group keeps by default; every copy for a kept group; nil while it
    /// waits for the user.
    var defaultKeep: Set<MediaAssetID>? {
        switch `default` {
        case let .keep(ids, _): ids
        case .waits: nil
        case .kept: Set(copies.map(\.id))
        }
    }

    var isKept: Bool {
        `default` == .kept
    }

    /// The group's date: the kept copy's capture date (the first in display order), so the
    /// card's date is the date of the file that stays — identical copies share it, and
    /// versions of one photo agree on it, except where a file names no capture and its
    /// birth time stands in.
    var captureDate: Date? {
        copies.first { $0.captureDate != nil }?.captureDate
    }

    /// Display order: files of one photo first — the groups that need eyes — then identical
    /// copies, each newest first by capture date, the grid's order, undated groups last,
    /// then by the first copy's path so the order is total.
    static func precedesInList(_ left: DuplicateGroup, _ right: DuplicateGroup) -> Bool {
        if left.id.isSamePhoto != right.id.isSamePhoto {
            return left.id.isSamePhoto
        }
        return switch (left.captureDate, right.captureDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            leftDate > rightDate
        case (.some, nil):
            true
        case (nil, .some):
            false
        default:
            (left.copies.first?.id.duplicateOrderKey ?? "") < (right.copies.first?.id.duplicateOrderKey ?? "")
        }
    }
}

/// Projection's answer for duplicates, published in every scope so the sidebar row
/// knows whether it exists; the list itself draws only under `.duplicates`.
nonisolated struct CatalogDuplicatesState: Equatable, Sendable {
    /// Every group, in list order (`DuplicateGroup.precedesInList`).
    let groups: [DuplicateGroup]

    static let empty = CatalogDuplicatesState(groups: [])

    init(groups: [DuplicateGroup]) {
        self.groups = groups.sorted(by: DuplicateGroup.precedesInList)
    }

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

/// The keeper rule (ADR 0042). Pure: facts in, groups out. Every group has a default:
///
/// - **Each library keeps its own copy.** Nothing across libraries is preselected, so a group
///   whose copies span libraries keeps the best copy in each; the library pair row offers
///   `Keep Only <Library>`.
/// - **Work is carried, not chosen between.** The act moves a copy's curation or edit onto
///   the kept copy when the kept copy lacks it (`DuplicatesSession.carries`), so the copy
///   kept need not be the one holding the work. A library's copies wait only when their
///   work cannot be combined: two edits, two sets of companion files, two different choices.
/// - **The best copy is kept**, in this order: one with companion files (another app's work,
///   which never moves); for versions of the same photo, the camera original, then the most
///   pixels, then the largest file; an edited copy, then one with a choice; a name without a
///   Finder or browser copy suffix; the earliest birth time; path order.
/// - **The default says why.** A group within one library records the criterion that
///   separated its kept copy from the copy it beat last, so the list names the rule that
///   was needed, not the first that happened to apply.
/// - **Copies the user kept together stay kept**, and a later copy is the one offered.
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
        return groups.sorted(by: DuplicateGroup.precedesInList)
    }

    /// One group from its copies. `originals` are the copies that name their capture — for
    /// versions of the same photo, the camera's own file is the one to keep.
    static func group(
        id: DuplicateGroupID,
        copies unordered: [DuplicateCopy],
        keptPairs: Set<DuplicateKeptPair>,
        originals: Set<MediaAssetID> = []
    ) -> DuplicateGroup {
        let copies = unordered.sorted { $0.id.duplicateOrderKey < $1.id.duplicateOrderKey }
        let ids = copies.map(\.id)
        let libraries = Set(ids.map(\.libraryRootPath)).sorted { $0.rawValue < $1.rawValue }
        let libraryPair: DuplicateLibraryPair? = libraries.count == 2
            ? DuplicateLibraryPair(libraries[0], libraries[1])
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
                id: id, copies: copies, default: .kept, libraryPair: libraryPair, cameraOriginals: originals
            )
        }

        let rule = KeeperRule(comparesPixels: id.isSamePhoto, originals: originals)
        let `default` = defaultKeep(copies: copies, keptTogether: keptTogether, rule: rule)
        let keep = `default`.keep
        let ordered = copies.sorted { left, right in
            let leftKept = keep?.contains(left.id) ?? false
            let rightKept = keep?.contains(right.id) ?? false
            if leftKept != rightKept {
                return leftKept
            }
            if leftKept {
                return isBetterKeeper(left, than: right, rule: rule)
            }
            return left.id.duplicateOrderKey < right.id.duplicateOrderKey
        }
        return DuplicateGroup(
            id: id, copies: ordered, default: `default`, libraryPair: libraryPair, cameraOriginals: originals
        )
    }

    /// The work two of these copies hold that no single copy can: edits, companion files,
    /// or different choices; nil when their work combines.
    static func workConflict(_ copies: [DuplicateCopy]) -> DuplicateWorkConflict.Kind? {
        if copies.count(where: \.isEdited) > 1 {
            return .edits
        }
        if copies.count(where: \.hasCompanions) > 1 {
            return .companions
        }
        if Set(copies.map(\.mediaChoice).filter { $0 != .notRated }).count > 1 {
            return .choices
        }
        return nil
    }

    /// Each library keeps its copies kept together, else its best copy; waits when a
    /// library's copies hold work that cannot be combined. The reason is `eachLibrary` for a
    /// group across libraries; within one library it is the criterion that separated the
    /// kept copy from the copy it beat last — the rule that was needed.
    private static func defaultKeep(
        copies: [DuplicateCopy],
        keptTogether: Set<MediaAssetID>,
        rule: KeeperRule
    ) -> DuplicateDefault {
        var keep: Set<MediaAssetID> = []
        var decidingCriterion: DuplicateKeeperCriterion = .pathOrder
        let byLibrary = Dictionary(grouping: copies, by: \.id.libraryRootPath)
        for (library, members) in byLibrary.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let kind = workConflict(members) {
                return .waits(DuplicateWorkConflict(kind: kind, library: library))
            }
            let together = members.filter { keptTogether.contains($0.id) }
            if !together.isEmpty {
                keep.formUnion(together.map(\.id))
            } else if let best = members.min(by: { isBetterKeeper($0, than: $1, rule: rule) }) {
                keep.insert(best.id)
                decidingCriterion = members
                    .filter { $0.id != best.id }
                    .map { compare(best, $0, rule: rule).criterion }
                    .max() ?? .pathOrder
            }
        }
        let reason: DuplicateDefault.Reason = byLibrary.count > 1 ? .eachLibrary : .criterion(decidingCriterion)
        return .keep(keep, reason: reason)
    }

    /// What the keeper rule compares for one group: whether the copies' pixels and sizes
    /// are different files to rank (versions of one photo; identical copies share both),
    /// and which copies name their capture.
    struct KeeperRule {
        let comparesPixels: Bool
        let originals: Set<MediaAssetID>
    }

    /// The keeper order: companion files, then (for versions of one photo) the original,
    /// the most pixels and the largest file, then an edit, a choice, a plain name, the
    /// earliest birth time and path order.
    static func isBetterKeeper(_ left: DuplicateCopy, than right: DuplicateCopy, rule: KeeperRule) -> Bool {
        compare(left, right, rule: rule).leftWins
    }

    /// The first criterion that tells two copies apart, and which copy it favours.
    static func compare(
        _ left: DuplicateCopy,
        _ right: DuplicateCopy,
        rule: KeeperRule
    ) -> (criterion: DuplicateKeeperCriterion, leftWins: Bool) {
        if left.hasCompanions != right.hasCompanions {
            return (.companions, left.hasCompanions)
        }
        let leftOriginal = rule.originals.contains(left.id)
        if leftOriginal != rule.originals.contains(right.id) {
            return (.cameraOriginal, leftOriginal)
        }
        if rule.comparesPixels {
            let leftPixels = (left.pixelWidth ?? 0) * (left.pixelHeight ?? 0)
            let rightPixels = (right.pixelWidth ?? 0) * (right.pixelHeight ?? 0)
            if leftPixels != rightPixels {
                return (.mostPixels, leftPixels > rightPixels)
            }
            // Exact bytes: the rows show sizes at whatever precision tells them apart, so
            // the rule and the rows always agree.
            if left.byteSize != right.byteSize {
                return (.largestFile, (left.byteSize ?? 0) > (right.byteSize ?? 0))
            }
        }
        if left.isEdited != right.isEdited {
            return (.edited, left.isEdited)
        }
        let leftChose = left.mediaChoice != .notRated
        if leftChose != (right.mediaChoice != .notRated) {
            return (.rated, leftChose)
        }
        let leftSuffixed = hasCopySuffix(left.name)
        if leftSuffixed != hasCopySuffix(right.name) {
            return (.originalName, !leftSuffixed)
        }
        // Whole seconds: the rows show seconds at most, so the rule never separates two
        // copies the rows show as born at the same instant.
        let leftBorn = left.createdAt?.timeIntervalSince1970.rounded(.down)
        let rightBorn = right.createdAt?.timeIntervalSince1970.rounded(.down)
        switch (leftBorn, rightBorn) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return (.earliestBirth, leftDate < rightDate)
        case (.some, nil):
            return (.earliestBirth, true)
        case (nil, .some):
            return (.earliestBirth, false)
        default:
            return (.pathOrder, left.id.duplicateOrderKey < right.id.duplicateOrderKey)
        }
    }

    /// A name Finder (` copy`, ` copy 2`), a browser download (` (1)`) or Otos's own import
    /// (`_001`, the collision suffix of ARC-050) gives a second copy of a file.
    static func hasCopySuffix(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return stem.range(of: #"( copy( \d+)?| \(\d+\)|_\d{3})$"#, options: .regularExpression) != nil
    }
}

private nonisolated extension DuplicateDefault {
    var keep: Set<MediaAssetID>? {
        if case let .keep(ids, _) = self {
            return ids
        }
        return nil
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
/// the user changed and which summaries are open. Pure, so what the bar counts and what
/// the act moves are one computation. Every active group is on screen: one found while the
/// user looks joins the list at once, and one that resolves or vanishes leaves at once.
nonisolated struct DuplicatesSession: Equatable, Sendable {
    /// Copies whose Keep the user set, overriding the group's default.
    var keepOverrides: [MediaAssetID: Bool] = [:]
    var expandedPairs: Set<DuplicateLibraryPair> = []
    /// What the bar's act last moved, shown as its receipt until the marks change or the
    /// user leaves the list.
    var receipt: DuplicatesReceipt?

    /// Drops the marks of copies no group holds any more, so a copy that comes back — its
    /// move undone, its library back online — starts from its group's default.
    mutating func forgetMarks(absentFrom state: CatalogDuplicatesState) {
        guard !keepOverrides.isEmpty else {
            return
        }
        let live = Set(state.groups.flatMap(\.copies).map(\.id))
        keepOverrides = keepOverrides.filter { live.contains($0.key) }
    }

    /// The marks of these groups return to their defaults.
    mutating func forgetMarks(in groups: [DuplicateGroup]) {
        for group in groups {
            for copy in group.copies {
                keepOverrides[copy.id] = nil
            }
        }
    }

    /// Keep Only This Copy: this copy is kept and every other copy of its group marked.
    mutating func keepOnly(_ copy: MediaAssetID, in group: DuplicateGroup) {
        for other in group.copies {
            keepOverrides[other.id] = other.id == copy
        }
    }

    /// Don't Keep This Copy. In a pair, unkeeping the only kept copy keeps the other, since
    /// a group always keeps one and there is only one other: one click swaps a pair's
    /// keeper. Elsewhere the last kept copy stays kept. Returns whether a mark changed.
    @discardableResult
    mutating func unkeep(_ copy: MediaAssetID, in group: DuplicateGroup) -> Bool {
        guard keeps(copy, in: group) else {
            return false
        }
        if canMoveToTrash(copy, in: group) {
            keepOverrides[copy] = false
            return true
        }
        guard group.copies.count == 2, let other = group.copies.first(where: { $0.id != copy }) else {
            return false
        }
        keepOnly(other.id, in: group)
        return true
    }

    /// Whether unkeeping this copy changes a mark: it is kept and another copy stays kept,
    /// or the group is a pair and the other copy takes over.
    func canUnkeep(_ copy: MediaAssetID, in group: DuplicateGroup) -> Bool {
        keeps(copy, in: group) && (canMoveToTrash(copy, in: group) || group.copies.count == 2)
    }

    /// A library pair's Keep Only: every copy the pair's groups hold in the other library is
    /// marked, and each group's copies in this library keep their own marks and defaults.
    mutating func keepOnly(_ library: LibraryRootPath, in groups: [DuplicateGroup]) {
        for group in groups where group.copies.contains(where: { $0.id.libraryRootPath == library }) {
            for copy in group.copies where copy.id.libraryRootPath != library {
                keepOverrides[copy.id] = false
            }
        }
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

    /// The authored work the act carries onto a kept copy: a moved copy's choice when the
    /// kept copy has none, and its edit when the kept copy has none. The kept copy is the
    /// first kept in the moved copy's library, else the group's first kept copy. The Store
    /// re-reads both copies when it writes, so a carry only ever fills what is missing.
    func carries(in group: DuplicateGroup) -> [DuplicateCarry] {
        let moving = Set(copiesToMove(in: group))
        guard !moving.isEmpty else {
            return []
        }
        let kept = group.copies.filter { !moving.contains($0.id) }
        var carries: [DuplicateCarry] = []
        var choiceFilled: Set<MediaAssetID> = []
        var editFilled: Set<MediaAssetID> = []
        for copy in group.copies where moving.contains(copy.id) {
            guard let target = kept.first(where: { $0.id.libraryRootPath == copy.id.libraryRootPath }) ?? kept.first
            else {
                continue
            }
            if copy.mediaChoice != .notRated, target.mediaChoice == .notRated, choiceFilled.insert(target.id).inserted {
                carries.append(DuplicateCarry(from: copy.id, to: target.id, work: .choice))
            }
            if copy.isEdited, !target.isEdited, editFilled.insert(target.id).inserted {
                carries.append(DuplicateCarry(from: copy.id, to: target.id, work: .edit))
            }
        }
        return carries
    }

    /// A waiting group the user has not touched.
    func needsChoice(_ group: DuplicateGroup) -> Bool {
        group.defaultKeep == nil && !hasChosen(in: group)
    }

    /// Whether the user's marks leave this group other than its default: a mark changed and
    /// changed back is no choice.
    func hasChosen(in group: DuplicateGroup) -> Bool {
        guard let defaultKeep = group.defaultKeep else {
            return group.copies.contains { keepOverrides[$0.id] != nil }
        }
        return group.copies.contains { keeps($0.id, in: group) != defaultKeep.contains($0.id) }
    }

    /// Whether the user may unmark this copy: a group always keeps one copy.
    func canMoveToTrash(_ copy: MediaAssetID, in group: DuplicateGroup) -> Bool {
        guard keeps(copy, in: group) else {
            return false
        }
        return group.copies.count { keeps($0.id, in: group) } > 1
    }

    /// What the bar states and the act moves, over every active group.
    func tally(in state: CatalogDuplicatesState) -> DuplicatesTally {
        let groups = state.activeGroups
        var moving: [MediaAssetID] = []
        var carried: [DuplicateCarry] = []
        var bytes: Int64 = 0
        var unknownSizes = 0
        for group in groups {
            carried += carries(in: group)
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
            itemsWithDuplicates: groups.count,
            noun: DuplicateItemNoun.covering(groups.flatMap(\.copies).map(\.kind)),
            itemsToMove: moving,
            carries: carried,
            bytesToMove: PartialByteCount(knownBytes: bytes, unknownCount: unknownSizes),
            needingChoice: groups.count(where: needsChoice)
        )
    }
}

nonisolated struct DuplicatesTally: Equatable, Sendable {
    /// Active groups: the sidebar's count and the bar's L1.
    let itemsWithDuplicates: Int
    /// What those groups hold, so the L1 noun is honest for a library of videos.
    let noun: DuplicateItemNoun
    let itemsToMove: [MediaAssetID]
    /// The work the act carries onto kept copies as it moves `itemsToMove`.
    var carries: [DuplicateCarry] = []
    let bytesToMove: PartialByteCount
    let needingChoice: Int
}

/// What the last Move to Trash from the list hid, for the bar's receipt: written once the
/// Store has hidden the copies, never before; named by its batch, so undoing that batch
/// ends it and a later move replaces it.
nonisolated struct DuplicatesReceipt: Equatable, Sendable {
    let batch: MediaTrashBatchID
    let movedCount: Int
    let bytes: PartialByteCount
}

/// The noun for what the groups hold (DES-035): the user's own word for it.
nonisolated enum DuplicateItemNoun: Equatable, Sendable {
    case photos
    case videos
    /// Both kinds, every one read.
    case photosAndVideos
    /// A kind not yet read.
    case items

    /// `photos` when every copy is a still, `videos` when every copy is a video, `photos
    /// and videos` when both are present; `items` while any kind is unread, since the bar
    /// claims nothing the catalog has not read.
    static func covering(_ kinds: [MediaKind?]) -> DuplicateItemNoun {
        guard !kinds.isEmpty, !kinds.contains(where: { $0 == nil }) else {
            return .items
        }
        if kinds.allSatisfy({ $0 == .video }) {
            return .videos
        }
        if kinds.allSatisfy({ $0 == .image || $0 == .raw }) {
            return .photos
        }
        return .photosAndVideos
    }

    func string(count: Int) -> String {
        switch self {
        case .photos: count == 1 ? "photo" : "photos"
        case .videos: count == 1 ? "video" : "videos"
        case .photosAndVideos: "photos and videos"
        case .items: count == 1 ? "item" : "items"
        }
    }
}

/// What a carry wrote over on a kept copy, so the command's undo restores it.
nonisolated struct DuplicateCarryRecord: Equatable, Sendable {
    enum Previous: Equatable, Sendable {
        case choice(MediaChoice)
        /// The kept copy's edit recipe JSON before the carry; nil when it had none.
        case edit(String?)
    }

    let from: MediaAssetID
    let to: MediaAssetID
    let previous: Previous
}

/// One piece of authored work the duplicates act moves from a copy going to the Trash onto a
/// kept copy of the same picture (ADR 0042).
nonisolated struct DuplicateCarry: Hashable, Sendable {
    enum Work: Hashable, Sendable {
        /// The curation choice (`media_choice`).
        case choice
        /// The edit recipe.
        case edit
    }

    let from: MediaAssetID
    let to: MediaAssetID
    let work: Work
}

/// Versions of the same photo (ADR 0042): different files of one capture — resized,
/// re-encoded, metadata stripped — proven by their thumbnails. The camera original with the
/// most pixels is kept by default (`DuplicateGroupPolicy`).
///
/// The question is "are these the same capture?", not "do these look alike?", and three
/// gates keep separate captures — bursts, brackets — apart:
///
/// 1. Capture metadata decides first. Two files that both name a camera and an instant are
///    one capture only if the camera model, the whole-second instant and, where both carry
///    them, the sub-seconds, body serial and burst identifier agree.
/// 2. The pixels must match almost exactly: a difference hash within
///    `RenderSignature.candidateHammingDistance` proposes, and a mean grayscale difference
///    below `RenderSignature.confirmedMeanDifference` confirms.
/// 3. A file without capture metadata joins only the one original clearly closer than every
///    other; two about equally close mean it could be either frame, and it joins none.
///
/// A RAW is never grouped with a processed file, and copies already in an identical group
/// are left to that group.
nonisolated enum SamePhotoPolicy {
    /// Pairs worth reading details for: same kind, same display aspect, a near hash, and the
    /// column half of gate 1. Blocked by aspect and instant, so a library is never compared
    /// all against all.
    ///
    /// A file without capture metadata is tested against every member of its aspect bucket —
    /// hundreds of thousands of tests on a real library — so those loops walk indices and
    /// test the hash from a flat array before they touch a candidate.
    static func candidatePairs(
        _ candidates: [SamePhotoCandidate],
        excluding excluded: Set<MediaAssetID>
    ) -> [SamePhotoPair] {
        let eligible = candidates.filter { !excluded.contains($0.id) && $0.aspectRatio != nil }
        let buckets = Dictionary(grouping: eligible) { candidate in
            AspectBucket(isRaw: candidate.isRaw, aspect: Int(((candidate.aspectRatio ?? 0) * 100).rounded()))
        }
        var pairs: [SamePhotoPair] = []
        for members in buckets.values where members.count > 1 {
            let hashes = members.map(\.differenceHash)
            let captured = members.indices.filter { members[$0].hasCaptureMetadata }
            let stripped = members.indices.filter { !members[$0].hasCaptureMetadata }
            for group in Dictionary(grouping: captured, by: { members[$0].captureInstant ?? 0 }).values {
                for (position, left) in group.enumerated() {
                    for right in group[(position + 1)...] where isCandidate(members[left], members[right]) {
                        pairs.append(SamePhotoPair(left: members[left], right: members[right]))
                    }
                }
            }
            for (position, left) in stripped.enumerated() {
                let hash = hashes[left]
                for right in captured where isNear(hash, hashes[right]) && isCandidate(members[left], members[right]) {
                    pairs.append(SamePhotoPair(left: members[left], right: members[right]))
                }
                for right in stripped[(position + 1)...]
                    where isNear(hash, hashes[right]) && isCandidate(members[left], members[right])
                {
                    pairs.append(SamePhotoPair(left: members[left], right: members[right]))
                }
            }
        }
        return pairs
    }

    private static func isNear(_ left: UInt64, _ right: UInt64) -> Bool {
        (left ^ right).nonzeroBitCount <= RenderSignature.candidateHammingDistance
    }

    /// The column checks, the hash first: a file without capture metadata is tested against
    /// every member of its aspect bucket, so the cheapest rejection runs first.
    static func isCandidate(_ left: SamePhotoCandidate, _ right: SamePhotoCandidate) -> Bool {
        guard isNear(left.differenceHash, right.differenceHash),
              left.isRaw == right.isRaw,
              let leftAspect = left.aspectRatio, let rightAspect = right.aspectRatio,
              abs(log(leftAspect / rightAspect)) < 0.01
        else {
            return false
        }
        guard left.hasCaptureMetadata, right.hasCaptureMetadata else {
            return true
        }
        return left.cameraModel == right.cameraModel
            && left.captureInstant == right.captureInstant
            && agree(left.serialNumber, right.serialNumber)
    }

    /// The record half of gate 1: where both files carry them, the sub-seconds and the burst
    /// identifier agree.
    static func recordsAgree(_ left: SamePhotoDetail, _ right: SamePhotoDetail) -> Bool {
        agree(left.fractionalSecondDigits, right.fractionalSecondDigits)
            && agree(left.burstIdentifier, right.burstIdentifier)
    }

    private static func agree(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second else { return true }
        return first == second
    }

    /// Groups from proposed pairs: the record half of gate 1 and gate 2 on every pair, gate 3
    /// on every file without capture metadata, then copies joined through any confirmed pair.
    static func groups(
        pairs: [SamePhotoPair],
        details: [MediaAssetID: SamePhotoDetail],
        keptPairs: Set<DuplicateKeptPair> = []
    ) -> [DuplicateGroup] {
        var confirmed: [(SamePhotoCandidate, SamePhotoCandidate, Double)] = []
        for pair in pairs {
            guard let leftDetail = details[pair.left.id], let rightDetail = details[pair.right.id] else {
                continue
            }
            if pair.left.hasCaptureMetadata, pair.right.hasCaptureMetadata, !recordsAgree(leftDetail, rightDetail) {
                continue
            }
            let difference = leftDetail.signature.meanDifference(to: rightDetail.signature)
            if difference < RenderSignature.confirmedMeanDifference {
                confirmed.append((pair.left, pair.right, difference))
            }
        }
        // Gate 3: a file without capture metadata keeps only an edge to the one original
        // clearly closest; if two originals are about as close, it keeps none.
        var dropped: Set<Int> = []
        let strippedIDs = Set(pairs.flatMap { [$0.left, $0.right] }.filter { !$0.hasCaptureMetadata }.map(\.id))
        for strippedID in strippedIDs {
            let edges = confirmed.enumerated().compactMap { index, edge -> (Int, Double)? in
                let other = edge.0.id == strippedID ? edge.1 : (edge.1.id == strippedID ? edge.0 : nil)
                guard let other, other.hasCaptureMetadata else { return nil }
                return (index, edge.2)
            }.sorted { $0.1 < $1.1 }
            guard edges.count > 1 else { continue }
            let clearlyCloser = edges[1].1 >= edges[0].1 * 2 + 0.5
            for (position, edge) in edges.enumerated() where !clearlyCloser || position > 0 {
                dropped.insert(edge.0)
            }
        }
        var parent: [MediaAssetID: MediaAssetID] = [:]
        func root(_ id: MediaAssetID) -> MediaAssetID {
            var current = id
            while let next = parent[current], next != current {
                current = next
            }
            return current
        }
        var copies: [MediaAssetID: DuplicateCopy] = [:]
        for (index, edge) in confirmed.enumerated() where !dropped.contains(index) {
            copies[edge.0.id] = details[edge.0.id]?.copy
            copies[edge.1.id] = details[edge.1.id]?.copy
            let left = root(edge.0.id)
            let right = root(edge.1.id)
            parent[left] = parent[left] ?? left
            parent[right] = parent[right] ?? right
            if left != right {
                parent[right] = left
            }
        }
        let members = Dictionary(grouping: copies.keys, by: root)
        let originals = Set(pairs.flatMap { [$0.left, $0.right] }.filter(\.hasCaptureMetadata).map(\.id))
        return members.values.filter { $0.count > 1 }.map { ids in
            let ordered = ids.sorted { $0.duplicateOrderKey < $1.duplicateOrderKey }
            return DuplicateGroupPolicy.group(
                id: .samePhoto(ordered),
                copies: ordered.compactMap { copies[$0] },
                keptPairs: keptPairs,
                originals: originals.intersection(ordered)
            )
        }
    }

    private struct AspectBucket: Hashable {
        let isRaw: Bool
        let aspect: Int
    }
}

/// Two stills the column facts propose as one capture, before their details are read.
nonisolated struct SamePhotoPair: Equatable, Sendable {
    let left: SamePhotoCandidate
    let right: SamePhotoCandidate
}
