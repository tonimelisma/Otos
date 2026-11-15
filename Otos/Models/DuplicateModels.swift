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

/// Which copies Duplicates compares with each other (ADR 0042). By default, only copies in
/// the same library or account: a library the user keeps a second time on purpose — an
/// Immich server that indexes the same OneDrive folders — is a mirror, not waste. Settings
/// widens it to every library and account.
nonisolated enum DuplicatesReach: Equatable, Sendable {
    case withinEachLibrary
    case acrossLibraries

    /// The library a group of these copies is confined to: its copies' own while Duplicates
    /// compares within each library, none when it compares across them.
    func library(of id: MediaAssetID) -> LibraryRootPath? {
        switch self {
        case .withinEachLibrary: id.libraryRootPath
        case .acrossLibraries: nil
        }
    }
}

/// What makes copies one group. Identical copies share a content digest — in one library
/// while Duplicates compares within each library, so the same digest in two libraries is two
/// groups; versions of the same photo share a picture, proven by their thumbnails, and are
/// named by their members.
nonisolated enum DuplicateGroupID: Hashable, Sendable {
    /// `library` is nil when the group's copies may span libraries.
    case identical(ContentDigest, library: LibraryRootPath?)
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
    /// What the copy's library is, which says what Otos may do with it: an Immich account's
    /// copy is never moved to the Trash (ADR 0046 §8), and its folders are asset IDs.
    let libraryKind: LibraryRootKind
    /// The catalog's best kind, which names the group (`2 identical videos`); nil before
    /// enrichment has read it.
    let kind: MediaKind?
    /// The catalog's best capture date: what the group is dated by and listed under.
    let captureLocalTime: CaptureLocalTime?
    let byteSize: Int64?
    /// The file's birth time, a filesystem fact.
    let createdAt: Date?
    /// The upright pixel size, as the photo is seen (its orientation applied): what the
    /// list prints and lays its cells out by.
    let pixelWidth: Int?
    let pixelHeight: Int?
    let mediaChoice: MediaChoice
    let isEdited: Bool
    /// The copy has `.xmp` or `.srt` companions: another app's edits or captions.
    let hasCompanions: Bool

    var name: String {
        id.relativePath.fileName
    }

    /// The folder inside its library, empty at the library's top. A library without a
    /// folder tree of its own — an Immich account, whose folders are asset IDs — holds every
    /// copy at its top, so its copies are one folder to a rule.
    var folder: String {
        libraryKind.hasFilesystemNamespace ? id.relativePath.folder : ""
    }

    /// Otos may move this copy to the Trash: never an Immich account's (ADR 0046 §8).
    var canMoveToTrash: Bool {
        libraryKind.supportsMoveToTrash
    }

    /// Whether Otos or another app holds something authored for this copy.
    var carriesAuthoredWork: Bool {
        mediaChoice != .notRated || isEdited || hasCompanions
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
    var captureLocalTime: CaptureLocalTime? {
        copies.first { $0.captureLocalTime != nil }?.captureLocalTime
    }

    /// The copies of one library hold work no single copy can: two edits, two sets of
    /// companion files, two different choices. Read from the copies, not from the default,
    /// so a group the user kept whole or picked a copy in keeps its place in the list.
    var holdsConflictingWork: Bool {
        switch `default` {
        case .waits:
            true
        case .keep:
            false
        case .kept:
            Dictionary(grouping: copies, by: \.id.libraryRootPath).values
                .contains { DuplicateGroupPolicy.workConflict($0) != nil }
        }
    }

    /// Where the list puts the group: by how much of the user's attention it needs.
    var section: DuplicatesSection {
        if holdsConflictingWork {
            return .choose
        }
        return id.isSamePhoto ? .different : .exact
    }

    /// The largest copy's size: what an exact-copy group is ranked by, since its copies
    /// share one size and the largest are the space a visitor came for.
    var largestByteSize: Int64 {
        copies.compactMap(\.byteSize).max() ?? 0
    }
}

/// The list's three sections, in order of the attention a group needs (owner direction,
/// 2026-11-14; `docs/design/duplicates.md`).
nonisolated enum DuplicatesSection: Int, CaseIterable, Comparable, Sendable {
    /// The copies hold work that cannot be combined: only a click decides.
    case choose
    /// Files of one photo whose pixels, format or bytes differ: decided, and worth a look.
    case different
    /// The same bytes stored more than once: decided, and told apart only by name or folder.
    case exact

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Where an exact-copy group's copies sit, which is what its bucket is: one folder with
/// files saved twice, two folders that mirror each other, or three or more folders, which
/// no folder rule decides.
nonisolated enum DuplicateFolderPlace: Hashable, Sendable {
    case folders(DuplicateFolderSet)
    case scattered

    init(_ group: DuplicateGroup) {
        let set = DuplicateFolderSet(group)
        self = set.folders.count <= 2 ? .folders(set) : .scattered
    }

    /// The folder set a rule can decide: one or two folders, at least one of which Otos may
    /// move copies out of (never an Immich account's alone, ADR 0046 §8).
    var ruleFolderSet: DuplicateFolderSet? {
        guard case let .folders(set) = self, set.folders.contains(where: \.canMoveToTrash) else {
            return nil
        }
        return set
    }
}

/// The exact-copy groups of one place, under one header that carries the place's rule.
nonisolated struct DuplicateFolderBucket: Equatable, Sendable, Identifiable {
    let id: DuplicateFolderPlace
    /// Largest first, then newest, kept groups in their place among them.
    let groups: [DuplicateGroup]

    var activeGroups: [DuplicateGroup] {
        groups.filter { !$0.isKept }
    }
}

/// The groups as the list lays them out: what needs a click, what differs, then exact
/// copies by folder.
nonisolated struct DuplicatesLayout: Equatable, Sendable {
    /// Newest first.
    let choose: [DuplicateGroup]
    /// Newest first.
    let different: [DuplicateGroup]
    /// The place with the most groups first; three or more folders last.
    let buckets: [DuplicateFolderBucket]

    static let empty = DuplicatesLayout(choose: [], different: [], buckets: [])

    func groups(in section: DuplicatesSection) -> [DuplicateGroup] {
        switch section {
        case .choose: choose
        case .different: different
        case .exact: buckets.flatMap(\.groups)
        }
    }
}

/// Projection's answer for duplicates, published in every scope so the sidebar row
/// knows whether it exists; the list itself draws only under `.duplicates`.
nonisolated struct CatalogDuplicatesState: Equatable, Sendable {
    /// Every group, in the list's order: `layout`, read section by section.
    let groups: [DuplicateGroup]
    let layout: DuplicatesLayout

    static let empty = CatalogDuplicatesState(groups: [])

    init(groups: [DuplicateGroup]) {
        // One key per group and a sort of indices, so no group struct moves per comparison:
        // a comparator that re-derived the keys was a measurable share of a build.
        let dateKeys = groups.map { group in
            (group.captureLocalTime.map { -$0.seconds } ?? .greatestFiniteMagnitude, group.copies.first?.id.duplicateOrderKey ?? "")
        }
        func newestFirst(_ indices: [Int]) -> [DuplicateGroup] {
            indices.sorted { dateKeys[$0] < dateKeys[$1] }.map { groups[$0] }
        }
        var choose: [Int] = []
        var different: [Int] = []
        var byPlace: [DuplicateFolderPlace: [Int]] = [:]
        for index in groups.indices {
            switch groups[index].section {
            case .choose: choose.append(index)
            case .different: different.append(index)
            case .exact: byPlace[DuplicateFolderPlace(groups[index]), default: []].append(index)
            }
        }
        let sizes = groups.map(\.largestByteSize)
        let buckets = byPlace.map { place, indices in
            DuplicateFolderBucket(
                id: place,
                groups: indices.sorted { left, right in
                    sizes[left] != sizes[right] ? sizes[left] > sizes[right] : dateKeys[left] < dateKeys[right]
                }.map { groups[$0] }
            )
        }.sorted(by: Self.bucketPrecedes)
        layout = DuplicatesLayout(choose: newestFirst(choose), different: newestFirst(different), buckets: buckets)
        self.groups = layout.choose + layout.different + buckets.flatMap(\.groups)
    }

    /// Bucket order: three or more folders last; else the most groups first, then by the
    /// folders' own order so the order is total. Counts every group, kept ones too, so
    /// Keep All Copies moves no bucket.
    private static func bucketPrecedes(_ left: DuplicateFolderBucket, _ right: DuplicateFolderBucket) -> Bool {
        switch (left.id, right.id) {
        case (.scattered, _): return false
        case (_, .scattered): return true
        case let (.folders(leftSet), .folders(rightSet)):
            if left.groups.count != right.groups.count {
                return left.groups.count > right.groups.count
            }
            return leftSet.folders.lexicographicallyPrecedes(rightSet.folders)
        }
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
    let digest: ContentDigest
}

/// The keeper rule (ADR 0042). Pure: facts in, groups out. Every group has a default:
///
/// - **Each library keeps its own copy.** Nothing across libraries is preselected, so a group
///   whose copies span libraries — only while Duplicates compares across them
///   (`DuplicatesReach`) — keeps the best copy in each; the pair row offers
///   `Keep the copies in <folder>`.
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
        keptPairs: Set<DuplicateKeptPair>,
        reach: DuplicatesReach
    ) -> [DuplicateGroup] {
        let byGroup = Dictionary(grouping: copies) { copy in
            DuplicateGroupID.identical(copy.digest, library: reach.library(of: copy.copy.id))
        }
        var groups: [DuplicateGroup] = []
        for (id, members) in byGroup where members.count > 1 {
            groups.append(group(
                id: id,
                copies: members.map(\.copy),
                keptPairs: keptPairs
            ))
        }
        // Unordered: `CatalogDuplicatesState` orders the groups once, identical and
        // versions together.
        return groups
    }

    /// One group from its copies. `originals` are the copies that name their capture — for
    /// versions of the same photo, the camera's own file is the one to keep.
    ///
    /// A build assembles every group, so this derives each copy's ranking facts once, as
    /// scalars beside an index, and never copies a `DuplicateCopy` per comparison.
    static func group(
        id: DuplicateGroupID,
        copies unordered: [DuplicateCopy],
        keptPairs: Set<DuplicateKeptPair>,
        originals: Set<MediaAssetID> = []
    ) -> DuplicateGroup {
        let unorderedKeys = unordered.map(\.id.duplicateOrderKey)
        let order = unordered.indices.sorted { unorderedKeys[$0] < unorderedKeys[$1] }
        let copies = order.map { unordered[$0] }
        let rule = KeeperRule(comparesPixels: id.isSamePhoto, originals: originals)
        let facts = order.map { Facts(unordered[$0], orderKey: unorderedKeys[$0], rule: rule) }
        let ids = copies.map(\.id)

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
                id: id, copies: copies, default: .kept, cameraOriginals: originals
            )
        }

        let `default` = defaultKeep(copies: copies, facts: facts, keptTogether: keptTogether)
        let keep = `default`.keep
        let ordered = copies.indices.sorted { left, right in
            let leftKept = keep?.contains(copies[left].id) ?? false
            let rightKept = keep?.contains(copies[right].id) ?? false
            if leftKept != rightKept {
                return leftKept
            }
            if leftKept {
                return compare(left, right, copies: copies, facts: facts).leftWins
            }
            return left < right
        }
        return DuplicateGroup(
            id: id, copies: ordered.map { copies[$0] }, default: `default`,
            cameraOriginals: originals
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
        facts: [Facts],
        keptTogether: Set<MediaAssetID>
    ) -> DuplicateDefault {
        var keep: Set<MediaAssetID> = []
        var decidingCriterion: DuplicateKeeperCriterion?
        let byLibrary = Dictionary(grouping: copies.indices, by: { copies[$0].id.libraryRootPath })
        for (library, members) in byLibrary.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let kind = workConflict(members.map { copies[$0] }) {
                return .waits(DuplicateWorkConflict(kind: kind, library: library))
            }
            let together = members.filter { keptTogether.contains(copies[$0].id) }
            if !together.isEmpty {
                keep.formUnion(together.map { copies[$0].id })
            } else if let best = members.min(by: { compare($0, $1, copies: copies, facts: facts).leftWins }) {
                keep.insert(copies[best].id)
                for other in members where other != best {
                    let criterion = compare(best, other, copies: copies, facts: facts).criterion
                    decidingCriterion = max(decidingCriterion ?? criterion, criterion)
                }
            }
        }
        let reason: DuplicateDefault.Reason = byLibrary.count > 1
            ? .eachLibrary
            : .criterion(decidingCriterion ?? .pathOrder)
        return .keep(keep, reason: reason)
    }

    /// What the keeper rule compares for one group: whether the copies' pixels and sizes
    /// are different files to rank (versions of one photo; identical copies share both),
    /// and which copies name their capture.
    struct KeeperRule {
        let comparesPixels: Bool
        let originals: Set<MediaAssetID>
    }

    /// A copy's ranking facts, derived once per group: scalars only, beside the copies
    /// array, so a comparison copies no strings.
    struct Facts {
        let orderKey: String
        let isOriginal: Bool
        /// Pixels and bytes when the rule ranks them, else zero on every copy.
        let pixels: Int
        let bytes: Int64
        let suffixed: Bool
        /// The birth time at whole seconds: the rows show seconds at most, so the rule never
        /// separates two copies the rows show as born at the same instant.
        let bornSecond: Double?

        init(_ copy: DuplicateCopy, orderKey: String, rule: KeeperRule) {
            self.orderKey = orderKey
            isOriginal = rule.originals.contains(copy.id)
            pixels = rule.comparesPixels ? (copy.pixelWidth ?? 0) * (copy.pixelHeight ?? 0) : 0
            bytes = rule.comparesPixels ? copy.byteSize ?? 0 : 0
            suffixed = DuplicateGroupPolicy.hasCopySuffix(copy.id.relativePath.rawValue)
            bornSecond = copy.createdAt?.timeIntervalSince1970.rounded(.down)
        }
    }

    /// The keeper order: companion files, then (for versions of one photo) the original,
    /// the most pixels and the largest file in bytes, then an edit, a choice, a plain name,
    /// the earliest birth time and path order. Returns the first criterion that tells two
    /// copies apart, and which copy it favours.
    static func compare(
        _ left: Int,
        _ right: Int,
        copies: [DuplicateCopy],
        facts: [Facts]
    ) -> (criterion: DuplicateKeeperCriterion, leftWins: Bool) {
        if copies[left].hasCompanions != copies[right].hasCompanions {
            return (.companions, copies[left].hasCompanions)
        }
        if facts[left].isOriginal != facts[right].isOriginal {
            return (.cameraOriginal, facts[left].isOriginal)
        }
        if facts[left].pixels != facts[right].pixels {
            return (.mostPixels, facts[left].pixels > facts[right].pixels)
        }
        // Exact bytes: the rows show sizes at whatever precision tells them apart, so the
        // rule and the rows always agree.
        if facts[left].bytes != facts[right].bytes {
            return (.largestFile, facts[left].bytes > facts[right].bytes)
        }
        if copies[left].isEdited != copies[right].isEdited {
            return (.edited, copies[left].isEdited)
        }
        let leftChose = copies[left].mediaChoice != .notRated
        if leftChose != (copies[right].mediaChoice != .notRated) {
            return (.rated, leftChose)
        }
        if facts[left].suffixed != facts[right].suffixed {
            return (.originalName, !facts[left].suffixed)
        }
        switch (facts[left].bornSecond, facts[right].bornSecond) {
        case let (leftBorn?, rightBorn?) where leftBorn != rightBorn:
            return (.earliestBirth, leftBorn < rightBorn)
        case (.some, nil):
            return (.earliestBirth, true)
        case (nil, .some):
            return (.earliestBirth, false)
        default:
            return (.pathOrder, facts[left].orderKey < facts[right].orderKey)
        }
    }

    /// A name Finder (` copy`, ` copy 2`), a browser download (` (1)`) or Otos's own import
    /// (`_001`, the collision suffix of ARC-050) gives a second copy of a file. A byte
    /// scan over the path's last component, from its end: a build asks this for every copy
    /// of every group.
    static func hasCopySuffix(_ path: String) -> Bool {
        let utf8 = path.utf8
        guard var end = utf8.lastIndex(where: { $0 != UInt8(ascii: "/") }) else {
            return false
        }
        end = utf8.index(after: end)
        let slash = utf8[..<end].lastIndex(of: UInt8(ascii: "/"))
        let nameStart = slash.map { utf8.index(after: $0) } ?? utf8.startIndex
        // The stem: before the last dot, unless the dot leads the name.
        let name = utf8[nameStart ..< end]
        let stemEnd = name.lastIndex(of: UInt8(ascii: ".")).flatMap { $0 == name.startIndex ? nil : $0 } ?? name.endIndex
        let stem = name[name.startIndex ..< stemEnd]
        func endsWith(_ slice: some Collection<UInt8>, _ text: String) -> Bool {
            let suffix = Array(text.utf8)
            guard slice.count >= suffix.count else { return false }
            return slice.suffix(suffix.count).elementsEqual(suffix)
        }
        if endsWith(stem, " copy") {
            return true
        }
        let digitCount = stem.reversed().prefix { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }.count
        if digitCount > 0 {
            let head = stem.dropLast(digitCount)
            if endsWith(head, " copy ") {
                return true
            }
            if digitCount == 3, endsWith(head, "_") {
                return true
            }
        }
        if stem.last == UInt8(ascii: ")") {
            let inner = stem.dropLast()
            let innerDigits = inner.reversed().prefix { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }.count
            if innerDigits > 0, endsWith(inner.dropLast(innerDigits), " (") {
                return true
            }
        }
        return false
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

/// A folder that holds copies: a library and the folder inside it.
nonisolated struct DuplicateFolder: Hashable, Sendable, Comparable {
    let library: LibraryRootPath
    let libraryDisplayName: String
    /// The folder inside its library, empty at the library's top.
    let folder: String
    /// Otos may move the folder's copies to the Trash: never an Immich account's.
    let canMoveToTrash: Bool

    init(_ copy: DuplicateCopy) {
        library = copy.id.libraryRootPath
        libraryDisplayName = copy.libraryDisplayName
        folder = copy.folder
        canMoveToTrash = copy.canMoveToTrash
    }

    static func < (left: Self, right: Self) -> Bool {
        (left.library.rawValue, left.folder) < (right.library.rawValue, right.folder)
    }
}

/// The folders a group's copies sit in, sorted: one folder when a file was saved twice in
/// place, two when one folder mirrors another. A folder rule covers every group with the
/// same set.
nonisolated struct DuplicateFolderSet: Hashable, Sendable {
    let folders: [DuplicateFolder]

    init(_ group: DuplicateGroup) {
        folders = Set(group.copies.map(DuplicateFolder.init)).sorted()
    }

    init(folders: [DuplicateFolder]) {
        self.folders = folders.sorted()
    }
}

/// A rule the user sets for every group in a folder set, so a folder of duplicates is
/// decided at once. A click on one photo overrides it for that group.
nonisolated enum DuplicateFolderRule: Hashable, Sendable {
    /// The keeper rule (ADR 0042): each library's best copy.
    case automatic
    /// Keep the copy in this folder (two-folder sets).
    case folder(DuplicateFolder)
    /// Keep the copy without a ` copy` / ` (1)` / `_001` suffix (one-folder sets).
    case originalName
    /// Keep the earliest-born copy.
    case oldest
    /// Keep the largest file.
    case largest
}

/// Why a group keeps what it keeps, for its header.
nonisolated enum DuplicateKeepReason: Equatable, Sendable {
    /// The user clicked this copy.
    case picked
    /// A folder rule decided it.
    case rule(DuplicateFolderRule)
    /// The keeper rule decided it.
    case automatic(DuplicateDefault.Reason)
}

/// What one group keeps and moves, and why (ADR 0042). Pure, so what a tile shows, what
/// the bar counts and what the act moves are one computation.
nonisolated struct DuplicateResolution: Equatable, Sendable {
    /// Every copy the group keeps: the chosen ones, and every copy Otos may not move.
    let keep: Set<MediaAssetID>
    let moving: [MediaAssetID]
    /// Copies kept only because Otos may not move them (an Immich account's, ADR 0046 §8):
    /// the click, rule or default chose another, and this one stays where it is.
    let stays: [MediaAssetID]
    let carries: [DuplicateCarry]
    let bytes: PartialByteCount
    let reason: DuplicateKeepReason

    /// The group's resolution: the user's pick, else its folder set's rule, else its
    /// default. Nil for a kept group, and for a group whose copies hold work that cannot be
    /// combined until the user picks: no rule decides between two people's edits.
    static func of(_ group: DuplicateGroup, pick: MediaAssetID?, rule: DuplicateFolderRule?) -> DuplicateResolution? {
        guard !group.isKept else {
            return nil
        }
        if let pick, group.copies.contains(where: { $0.id == pick }) {
            return make(group, keep: [pick], reason: .picked)
        }
        guard case let .keep(defaultKeep, defaultReason) = group.default else {
            return nil
        }
        if let rule, rule != .automatic, let keep = keep(group, by: rule) {
            return make(group, keep: keep, reason: .rule(rule))
        }
        return make(group, keep: defaultKeep, reason: .automatic(defaultReason))
    }

    /// What a rule keeps in this group; nil when it decides nothing here (a folder the
    /// group has no copy in), so the default stands.
    private static func keep(_ group: DuplicateGroup, by rule: DuplicateFolderRule) -> Set<MediaAssetID>? {
        let copies = group.copies
        switch rule {
        case .automatic:
            return nil
        case let .folder(folder):
            let inFolder = copies.filter { DuplicateFolder($0) == folder }
            guard !inFolder.isEmpty else { return nil }
            if inFolder.count == 1 {
                return [inFolder[0].id]
            }
            return DuplicateGroupPolicy.group(
                id: group.id, copies: inFolder, keptPairs: [], originals: group.cameraOriginals
            ).defaultKeep
        case .originalName:
            return best(of: copies) { DuplicateGroupPolicy.hasCopySuffix($0.id.relativePath.rawValue) ? 1 : 0 }
        case .oldest:
            return best(of: copies) { $0.createdAt?.timeIntervalSince1970 ?? .infinity }
        case .largest:
            return best(of: copies) { -Double($0.byteSize ?? 0) }
        }
    }

    /// The copy with the lowest score; ties go to the group's own order, which puts its
    /// default keeper first.
    private static func best(of copies: [DuplicateCopy], score: (DuplicateCopy) -> Double) -> Set<MediaAssetID>? {
        guard let first = copies.min(by: { score($0) < score($1) }) else { return nil }
        return [first.id]
    }

    /// The authored work carried onto a kept copy: a moved copy's choice when the kept copy
    /// has none, and its edit when the kept copy has none. The kept copy is the first kept
    /// in the moved copy's library, else the group's first kept copy. The Store re-reads
    /// both copies when it writes, so a carry only ever fills what is missing.
    private static func make(_ group: DuplicateGroup, keep chosen: Set<MediaAssetID>, reason: DuplicateKeepReason) -> DuplicateResolution {
        let stays = group.copies.filter { !chosen.contains($0.id) && !$0.canMoveToTrash }
        let keep = chosen.union(stays.map(\.id))
        let moving = group.copies.filter { !keep.contains($0.id) }
        let kept = group.copies.filter { keep.contains($0.id) }
        var carries: [DuplicateCarry] = []
        var choiceFilled: Set<MediaAssetID> = []
        var editFilled: Set<MediaAssetID> = []
        for copy in moving {
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
        let known = moving.compactMap(\.byteSize)
        return DuplicateResolution(
            keep: keep,
            moving: moving.map(\.id),
            stays: stays.map(\.id),
            carries: carries,
            bytes: PartialByteCount(knownBytes: known.reduce(0, +), unknownCount: moving.count - known.count),
            reason: reason
        )
    }
}

/// What the window holds while the user works through Duplicates (ADR 0042): the copy the
/// user clicked in each group, the rule set for each folder set, and the receipt of the
/// last move. Window state, not catalog state: a decision in progress, forgotten once its
/// group or folder set is gone.
nonisolated struct DuplicatesSession: Equatable, Sendable {
    var picks: [DuplicateGroupID: MediaAssetID] = [:]
    var rules: [DuplicateFolderSet: DuplicateFolderRule] = [:]
    /// What the last move hid, shown as its receipt until a pick or rule changes or the
    /// user leaves the list.
    var receipt: DuplicatesReceipt?

    /// A folder's rule governs the exact copies listed under that folder's header. Files
    /// of one photo differ in their pixels, so each is decided by its own photos.
    func resolution(of group: DuplicateGroup) -> DuplicateResolution? {
        DuplicateResolution.of(
            group,
            pick: picks[group.id],
            rule: group.id.isSamePhoto ? nil : rules[DuplicateFolderSet(group)]
        )
    }

    /// Drops picks whose copy no group holds any more, so a copy that comes back starts
    /// from its group's rule or default.
    mutating func forgetPicks(absentFrom state: CatalogDuplicatesState) {
        let live = Dictionary(uniqueKeysWithValues: state.groups.map { ($0.id, Set($0.copies.map(\.id))) })
        picks = picks.filter { live[$0.key]?.contains($0.value) == true }
    }

    /// Every move the list would make: each active group's resolution.
    func moves(in state: CatalogDuplicatesState) -> [DuplicateResolution] {
        state.activeGroups.compactMap(resolution(of:))
    }

    /// What the bar states, over every active group.
    func tally(in state: CatalogDuplicatesState) -> DuplicatesTally {
        let groups = state.activeGroups
        let resolutions = groups.compactMap(resolution(of:))
        return DuplicatesTally(
            itemsWithDuplicates: groups.count,
            noun: DuplicateItemNoun.covering(groups.flatMap(\.copies).map(\.kind)),
            itemsToMove: resolutions.flatMap(\.moving),
            carries: resolutions.flatMap(\.carries),
            bytesToMove: PartialByteCount(
                knownBytes: resolutions.reduce(0) { $0 + $1.bytes.knownBytes },
                unknownCount: resolutions.reduce(0) { $0 + $1.bytes.unknownCount }
            ),
            needingChoice: groups.count { !$0.isKept && resolution(of: $0) == nil }
        )
    }
}

nonisolated struct DuplicatesTally: Equatable, Sendable {
    /// Active groups: the sidebar's count and the bar's L1.
    let itemsWithDuplicates: Int
    /// What those groups hold, so the L1 noun is honest for a library of videos.
    let noun: DuplicateItemNoun
    /// The copies the act moves: every group's resolution.
    let itemsToMove: [MediaAssetID]
    /// The work the act carries onto kept copies as it moves `itemsToMove`.
    var carries: [DuplicateCarry] = []
    let bytesToMove: PartialByteCount
    /// Groups whose copies hold work that cannot be combined, waiting for a click.
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
        // One thing is never both.
        case .photosAndVideos: count == 1 ? "photo or video" : "photos and videos"
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
///    one capture only if the camera model and the whole-second instant agree, the body
///    serial agrees where both carry one, and both carry the same sub-seconds. Sub-seconds
///    are the proof: a record without them cannot tell a version from a frame shot in the
///    same second, whether the file has none or its record predates the reader reporting
///    them, so it proves nothing and the pair is not grouped.
/// 2. The pixels must match almost exactly: a difference hash within
///    `RenderSignature.candidateHammingDistance` proposes, and a mean grayscale difference
///    below `RenderSignature.confirmedMeanDifference` confirms.
/// 3. A file without capture metadata joins only the one original clearly closer than every
///    other; two about equally close mean it could be either frame, and it joins none.
///
/// A RAW is never grouped with a processed file, and copies already in an identical group
/// are left to that group.
nonisolated enum SamePhotoPolicy {
    /// Pairs worth reading details for: same kind, same pipeline, same display aspect, a near
    /// hash, and the column half of gate 1. Blocked by aspect and instant, so a library is
    /// never compared all against all.
    ///
    /// A file without capture metadata is tested against every member of its aspect bucket —
    /// hundreds of thousands of tests on a real library — so those loops walk indices and
    /// test the hash from a flat array before they touch a candidate.
    static func candidatePairs(
        _ candidates: [SamePhotoCandidate],
        excluding excluded: Set<MediaAssetID>,
        reach: DuplicatesReach
    ) -> [SamePhotoPair] {
        let eligible = candidates.filter { !excluded.contains($0.id) && $0.aspectRatio != nil }
        // A bucket is one library's while Duplicates compares within each library, so no
        // pair, and no group joined through pairs, spans two.
        let buckets = Dictionary(grouping: eligible) { candidate in
            AspectBucket(
                library: reach.library(of: candidate.id),
                isRaw: candidate.isRaw,
                drawnBy: candidate.drawnBy,
                aspect: Int(((candidate.aspectRatio ?? 0) * 100).rounded())
            )
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
            // The installed app is a Debug build (ADR 0030): these loops run hundreds of
            // thousands of times, so they read the hashes from unsafe buffers and test the
            // distance inline before they touch a candidate.
            let capturedHashes = captured.map { hashes[$0] }
            let strippedHashes = stripped.map { hashes[$0] }
            let limit = RenderSignature.candidateHammingDistance
            capturedHashes.withUnsafeBufferPointer { capturedHash in
                strippedHashes.withUnsafeBufferPointer { strippedHash in
                    var position = 0
                    while position < strippedHash.count {
                        let hash = strippedHash[position]
                        let left = stripped[position]
                        var other = 0
                        while other < capturedHash.count {
                            if (hash ^ capturedHash[other]).nonzeroBitCount <= limit {
                                let right = captured[other]
                                if isCandidate(members[left], members[right]) {
                                    pairs.append(SamePhotoPair(left: members[left], right: members[right]))
                                }
                            }
                            other += 1
                        }
                        other = position + 1
                        while other < strippedHash.count {
                            if (hash ^ strippedHash[other]).nonzeroBitCount <= limit {
                                let right = stripped[other]
                                if isCandidate(members[left], members[right]) {
                                    pairs.append(SamePhotoPair(left: members[left], right: members[right]))
                                }
                            }
                            other += 1
                        }
                        position += 1
                    }
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
              left.drawnBy == right.drawnBy,
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

    /// The record half of gate 1: both records carry sub-seconds, and they are the same.
    /// Missing sub-seconds are unknown, not agreement: every frame of a same-second burst
    /// would otherwise pass, and 5 % of those are as pixel-close as true copies.
    static func recordsProveOneCapture(_ left: SamePhotoDetail, _ right: SamePhotoDetail) -> Bool {
        guard let leftDigits = left.fractionalSecondDigits, let rightDigits = right.fractionalSecondDigits else {
            return false
        }
        return leftDigits == rightDigits
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
            if pair.left.hasCaptureMetadata, pair.right.hasCaptureMetadata, !recordsProveOneCapture(leftDetail, rightDetail) {
                continue
            }
            let difference = leftDetail.signature.meanDifference(to: rightDetail.signature)
            if difference < RenderSignature.confirmedMeanDifference {
                confirmed.append((pair.left, pair.right, difference))
            }
        }
        // Gate 3: a file without capture metadata keeps only an edge to the one original
        // clearly closest; if two originals are about as close, it keeps none.
        // Each file's edges to originals are collected in one walk over the confirmed pairs,
        // in pair order, so a file is never tested against every pair.
        var dropped: Set<Int> = []
        var edgesToOriginals: [MediaAssetID: [(Int, Double)]] = [:]
        for (index, edge) in confirmed.enumerated() {
            if !edge.0.hasCaptureMetadata, edge.1.hasCaptureMetadata {
                edgesToOriginals[edge.0.id, default: []].append((index, edge.2))
            } else if !edge.1.hasCaptureMetadata, edge.0.hasCaptureMetadata {
                edgesToOriginals[edge.1.id, default: []].append((index, edge.2))
            }
        }
        for unsorted in edgesToOriginals.values {
            let edges = unsorted.sorted { $0.1 < $1.1 }
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
        let library: LibraryRootPath?
        let isRaw: Bool
        let drawnBy: EnrichedRendering.Origin
        let aspect: Int
    }
}

/// Two stills the column facts propose as one capture, before their details are read.
nonisolated struct SamePhotoPair: Equatable, Sendable {
    let left: SamePhotoCandidate
    let right: SamePhotoCandidate
}
