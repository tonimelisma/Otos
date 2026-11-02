import Foundation

// Duplicates (ADR 0042)
//
// A duplicate group is a projection over facts the catalog already holds — content
// digests (ADR 0018) and the overlay each copy carries — never a stored identity. The
// Store reads the copies; `DuplicateGroupPolicy` decides, purely, which copies each group
// keeps by default — every group has a default unless its copies hold work that cannot be
// combined; Projection publishes the result as `CatalogDuplicatesState`. The only durable fact the feature adds is the
// user's "Keep All Copies" — remembered per pair of paths, overlay with the copies'
// own lifecycle.

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
    /// Trash. `nil` when the group waits for the user: its copies hold work that cannot be
    /// combined onto one (`DuplicateGroupPolicy.workConflicts`).
    let defaultKeep: Set<MediaAssetID>?
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
        return groups.sorted { left, right in
            let leftKey = left.copies.first?.id.duplicateOrderKey ?? ""
            let rightKey = right.copies.first?.id.duplicateOrderKey ?? ""
            return leftKey < rightKey
        }
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
                id: id,
                copies: copies,
                defaultKeep: Set(ids),
                isKept: true,
                libraryPair: libraryPair
            )
        }

        let keep = defaultKeep(copies: copies, keptTogether: keptTogether, originals: originals)
        let ordered = copies.sorted { left, right in
            let leftKept = keep?.contains(left.id) ?? false
            let rightKept = keep?.contains(right.id) ?? false
            if leftKept != rightKept {
                return leftKept
            }
            if leftKept {
                return isBetterKeeper(left, than: right, originals: originals)
            }
            return left.id.duplicateOrderKey < right.id.duplicateOrderKey
        }
        return DuplicateGroup(
            id: id,
            copies: ordered,
            defaultKeep: keep,
            isKept: false,
            libraryPair: libraryPair
        )
    }

    /// Whether these copies hold work Otos cannot combine onto one copy: two edits, two sets
    /// of companion files, or two different choices.
    static func workConflicts(_ copies: [DuplicateCopy]) -> Bool {
        copies.count(where: \.isEdited) > 1
            || copies.count(where: \.hasCompanions) > 1
            || Set(copies.map(\.mediaChoice).filter { $0 != .notRated }).count > 1
    }

    /// Each library keeps its copies kept together, else its best copy; nil when a library's
    /// copies hold work that cannot be combined.
    private static func defaultKeep(
        copies: [DuplicateCopy],
        keptTogether: Set<MediaAssetID>,
        originals: Set<MediaAssetID>
    ) -> Set<MediaAssetID>? {
        var keep: Set<MediaAssetID> = []
        for members in Dictionary(grouping: copies, by: \.id.libraryRootPath).values {
            guard !workConflicts(members) else {
                return nil
            }
            let together = members.filter { keptTogether.contains($0.id) }
            if !together.isEmpty {
                keep.formUnion(together.map(\.id))
            } else if let best = members.min(by: { isBetterKeeper($0, than: $1, originals: originals) }) {
                keep.insert(best.id)
            }
        }
        return keep
    }

    /// The keeper order: companion files, then (for versions of one photo) the original,
    /// the most pixels and the largest file, then an edit, a choice, a plain name, the
    /// earliest birth time and path order.
    static func isBetterKeeper(_ left: DuplicateCopy, than right: DuplicateCopy, originals: Set<MediaAssetID>) -> Bool {
        if left.hasCompanions != right.hasCompanions {
            return left.hasCompanions
        }
        let leftOriginal = originals.contains(left.id)
        if leftOriginal != originals.contains(right.id) {
            return leftOriginal
        }
        if !originals.isEmpty {
            let leftPixels = (left.pixelWidth ?? 0) * (left.pixelHeight ?? 0)
            let rightPixels = (right.pixelWidth ?? 0) * (right.pixelHeight ?? 0)
            if leftPixels != rightPixels {
                return leftPixels > rightPixels
            }
            if left.byteSize != right.byteSize {
                return (left.byteSize ?? 0) > (right.byteSize ?? 0)
            }
        }
        if left.isEdited != right.isEdited {
            return left.isEdited
        }
        let leftChose = left.mediaChoice != .notRated
        if leftChose != (right.mediaChoice != .notRated) {
            return leftChose
        }
        let leftSuffixed = hasCopySuffix(left.name)
        if leftSuffixed != hasCopySuffix(right.name) {
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
/// the user changed and which summaries are open. Pure, so what the bar counts and what
/// the act moves are one computation. Every active group is on screen: one found while the
/// user looks joins the list at once, and one that resolves or vanishes leaves at once.
nonisolated struct DuplicatesSession: Equatable, Sendable {
    /// Copies whose Keep the user set, overriding the group's default.
    var keepOverrides: [MediaAssetID: Bool] = [:]
    var expandedPairs: Set<DuplicateLibraryPair> = []
    var showsKept = false

    /// Drops the marks of copies no group holds any more, so a copy that comes back — its
    /// move undone, its library back online — starts from its group's default.
    mutating func forgetMarks(absentFrom state: CatalogDuplicatesState) {
        guard !keepOverrides.isEmpty else {
            return
        }
        let live = Set(state.groups.flatMap(\.copies).map(\.id))
        keepOverrides = keepOverrides.filter { live.contains($0.key) }
    }

    /// Keep Only This Copy: this copy is kept and every other copy of its group marked.
    mutating func keepOnly(_ copy: MediaAssetID, in group: DuplicateGroup) {
        for other in group.copies {
            keepOverrides[other.id] = other.id == copy
        }
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
        group.defaultKeep == nil && !group.copies.contains { keepOverrides[$0.id] != nil }
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
            photosWithDuplicates: groups.count,
            itemsToMove: moving,
            carries: carried,
            bytesToMove: PartialByteCount(knownBytes: bytes, unknownCount: unknownSizes),
            needingChoice: groups.count(where: needsChoice)
        )
    }
}

nonisolated struct DuplicatesTally: Equatable, Sendable {
    let photosWithDuplicates: Int
    let itemsToMove: [MediaAssetID]
    /// The work the act carries onto kept copies as it moves `itemsToMove`.
    var carries: [DuplicateCarry] = []
    let bytesToMove: PartialByteCount
    let needingChoice: Int
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
