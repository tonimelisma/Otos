import Foundation

// File guide: a stack is several files Otos shows as one photo until the user expands it
// (ADR 0052). Stacks are derived, never stored: the Store reads the candidate stills — each
// RAW folder's stills and every still carrying a burst identifier — and `PhotoStackRule`
// decides the stacks from their names, kinds and identifiers alone, so a rename, move,
// deletion or enrichment can never leave one stale. A pair is one frame of a burst, so the
// projection collapses in two passes: pairs to their key file, then bursts to their key
// frame. Everything here is a value.

/// What makes the files one photo.
nonisolated enum PhotoStackKind: String, Equatable, Hashable, Sendable {
    /// A RAW and the camera's processed still of the same shot: one folder, one stem key.
    case pair
    /// The frames of one burst: an iPhone's stills carrying one burst identifier.
    case burst
}

/// A stack's identity: its kind, its root and the derived key its members share — a pair's
/// stem key, an iPhone burst's identifier. It names nothing stored; it is recomputed from the
/// files on every read.
nonisolated struct PhotoStackID: Hashable, Sendable {
    let kind: PhotoStackKind
    let libraryRootPath: LibraryRootPath
    let key: String
}

/// One still that may belong to a stack, as the Store reads it: its path and kind, its
/// stored name key and natural-order sort key (ARC-056, which every path write keeps
/// current), its burst identifier and capture time, the user's choice for it (Liked, Not
/// Rated, Disliked), and when the user made it its pair's or its burst's key (nil when never).
nonisolated struct PhotoStackCandidate: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let kind: MediaKind
    let nameKey: FilesystemNameKey
    let sortKey: String
    var burstIdentifier: String?
    var captureLocal: Double?
    var choice: MediaChoice = .notRated
    var keyChosenAtUnixMs: Int64?
    var burstKeyChosenAtUnixMs: Int64?
}

/// One stack: its member files, its key — the file it shows when collapsed — the user's
/// choice for the key, and which members are RAW files. `photos` are the shots it holds,
/// each as the file that shows it: a pair is one photo, a burst one per frame in capture
/// order. How a surface names a member follows from these facts.
nonisolated struct PhotoStack: Equatable, Sendable {
    let id: PhotoStackID
    /// A pair's two files in natural name order; a burst's files frame by frame.
    let members: [MediaAssetID]
    let key: MediaAssetID
    /// A choice on a collapsed stack is the key's (ADR 0052: curation uses the key member),
    /// so the stack is Liked or Disliked as its key is.
    let keyChoice: MediaChoice
    let rawMembers: Set<MediaAssetID>
    let photos: [MediaAssetID]

    func isRaw(_ member: MediaAssetID) -> Bool {
        rawMembers.contains(member)
    }
}

/// Every stack the browser's order can hold, and which pair and which burst each file is in.
nonisolated struct CatalogStacks: Equatable, Sendable {
    let stacks: [PhotoStackID: PhotoStack]
    let pairOfMember: [MediaAssetID: PhotoStackID]
    let burstOfMember: [MediaAssetID: PhotoStackID]

    static let empty = CatalogStacks([])

    init(_ stacks: [PhotoStack]) {
        var byID: [PhotoStackID: PhotoStack] = [:]
        var pairOf: [MediaAssetID: PhotoStackID] = [:]
        var burstOf: [MediaAssetID: PhotoStackID] = [:]
        for stack in stacks {
            byID[stack.id] = stack
            for member in stack.members {
                switch stack.id.kind {
                case .pair: pairOf[member] = stack.id
                case .burst: burstOf[member] = stack.id
                }
            }
        }
        self.stacks = byID
        pairOfMember = pairOf
        burstOfMember = burstOf
    }

    /// The outermost stack `id` is a member of — its burst, else its pair — or nil when it
    /// stands alone.
    func stack(containing id: MediaAssetID) -> PhotoStack? {
        (burstOfMember[id] ?? pairOfMember[id]).flatMap { stacks[$0] }
    }

    /// Whether a stack `id` is a file of — its pair or its burst — has a Disliked key. A
    /// choice on a collapsed stack is its key's (ADR 0052), so a surface that leaves Disliked
    /// photos out (On This Day) leaves out every file of such a stack, the key's RAW twin
    /// included, and a burst's other frames with it.
    func isInStackWithDislikedKey(_ id: MediaAssetID) -> Bool {
        [pairOfMember[id], burstOfMember[id]].contains { stackID in
            stackID.flatMap { stacks[$0] }?.keyChoice == .disliked
        }
    }

    /// The file each member shows as when its stacks are collapsed: every burst file as its
    /// burst's key, every other pair file as its pair's key. People count a stack once.
    var keyOfMember: [MediaAssetID: MediaAssetID] {
        var keys: [MediaAssetID: MediaAssetID] = [:]
        for (member, pair) in pairOfMember {
            keys[member] = stacks[pair]?.key
        }
        for (member, burst) in burstOfMember {
            keys[member] = stacks[burst]?.key
        }
        return keys
    }
}

/// The pure rule that turns one root's candidates into stacks.
nonisolated enum PhotoStackRule {
    /// Pairs and the bursts built from them.
    ///
    /// A pair is exactly two stills sharing a stem key (`FilesystemNamespaceSemantics.stemKey`,
    /// the volume's own name equality): one RAW and one processed image. Any other count —
    /// a RAW alone, two JPEGs, a RAW with a JPEG and a HEIC — pairs nothing. The processed
    /// file is the default key, as Apple Photos shows it (owner, 2026-11-13).
    ///
    /// A burst is two or more frames whose stills carry one burst identifier. A pair is one
    /// frame, shown as its pair's key. Its default key is its first Liked frame, else its
    /// first frame in capture order (ADR 0052). A camera's continuous-shooting frames never
    /// stack: the frame number a camera records says where a frame stands in its sequence
    /// but not which sequence, so after the user deletes a burst's leading frames nothing
    /// tells them from the burst before (ADR 0052).
    static func stacks(
        candidates: [PhotoStackCandidate],
        libraryRootPath: LibraryRootPath
    ) -> [PhotoStack] {
        let stills = candidates.filter { $0.kind != .video }
        let pairs = pairs(stills, libraryRootPath: libraryRootPath)
        return pairs + bursts(stills, pairs: pairs, libraryRootPath: libraryRootPath)
    }

    private static func pairs(_ stills: [PhotoStackCandidate], libraryRootPath: LibraryRootPath) -> [PhotoStack] {
        // The stem key is cut from the stored name key, never normalized again here.
        let byStem = Dictionary(grouping: stills) { FilesystemNamespaceSemantics.stemKey(of: $0.nameKey) }
        return byStem.compactMap { stem, group -> PhotoStack? in
            guard group.count == 2,
                  let raw = group.first(where: { $0.kind == .raw }),
                  let processed = group.first(where: { $0.kind == .image })
            else {
                return nil
            }
            let rawID = MediaAssetID(libraryRootPath: libraryRootPath, relativePath: raw.relativePath)
            let processedID = MediaAssetID(libraryRootPath: libraryRootPath, relativePath: processed.relativePath)
            // The member the user chose most recently, else the processed file.
            let chosen = group.filter { $0.keyChosenAtUnixMs != nil }
                .max { ($0.keyChosenAtUnixMs ?? 0) < ($1.keyChosenAtUnixMs ?? 0) }
            let keyIsRaw = chosen?.relativePath == raw.relativePath
            return PhotoStack(
                id: PhotoStackID(kind: .pair, libraryRootPath: libraryRootPath, key: stem.rawValue),
                members: raw.sortKey < processed.sortKey ? [rawID, processedID] : [processedID, rawID],
                key: keyIsRaw ? rawID : processedID,
                keyChoice: keyIsRaw ? raw.choice : processed.choice,
                rawMembers: [rawID],
                photos: [keyIsRaw ? rawID : processedID]
            )
        }
    }

    /// Bursts by their identifier.
    private static func bursts(
        _ stills: [PhotoStackCandidate],
        pairs: [PhotoStack],
        libraryRootPath: LibraryRootPath
    ) -> [PhotoStack] {
        let carriers = stills.filter { $0.burstIdentifier != nil }
        // Most libraries hold no burst at all; the lookups below are built only for one that does.
        guard !carriers.isEmpty else { return [] }
        var pairOfFile: [MediaRelativePath: PhotoStack] = [:]
        for pair in pairs {
            for member in pair.members {
                pairOfFile[member.relativePath] = pair
            }
        }
        let byPath = Dictionary(stills.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: carriers) { $0.burstIdentifier ?? "" }
            .compactMap { identifier, group in
                stack(
                    identifier: identifier,
                    frames: frames(of: group, pairOfFile: pairOfFile, byPath: byPath, libraryRootPath: libraryRootPath),
                    libraryRootPath: libraryRootPath
                )
            }
    }

    /// One frame of a burst: its files, the file that shows it, and the facts that order
    /// and choose it.
    private struct Frame {
        let files: [PhotoStackCandidate]
        let shown: MediaAssetID
        let shownChoice: MediaChoice
        let rawFiles: [MediaAssetID]

        var captureLocal: Double? {
            files.compactMap(\.captureLocal).min()
        }

        var sortKey: String {
            files.map(\.sortKey).min() ?? ""
        }

        var isLiked: Bool {
            files.contains { $0.choice == .liked }
        }

        var chosenAt: Int64? {
            files.compactMap(\.burstKeyChosenAtUnixMs).max()
        }

        /// Capture order; a frame without a capture time follows, in name order.
        func precedes(_ other: Frame) -> Bool {
            switch (captureLocal, other.captureLocal) {
            case let (mine?, theirs?) where mine != theirs: mine < theirs
            case (.some, nil): true
            case (nil, .some): false
            default: sortKey < other.sortKey
            }
        }
    }

    /// The frames `carriers` make: a pair is one frame, shown as its pair's key; any other
    /// still is a frame by itself.
    private static func frames(
        of carriers: [PhotoStackCandidate],
        pairOfFile: [MediaRelativePath: PhotoStack],
        byPath: [MediaRelativePath: PhotoStackCandidate],
        libraryRootPath: LibraryRootPath
    ) -> [Frame] {
        var frames: [Frame] = []
        var framed = Set<MediaRelativePath>()
        for carrier in carriers where !framed.contains(carrier.relativePath) {
            if let pair = pairOfFile[carrier.relativePath] {
                let files = pair.members.compactMap { byPath[$0.relativePath] }
                framed.formUnion(files.map(\.relativePath))
                frames.append(Frame(
                    files: files, shown: pair.key, shownChoice: pair.keyChoice, rawFiles: Array(pair.rawMembers)
                ))
            } else {
                framed.insert(carrier.relativePath)
                let id = MediaAssetID(libraryRootPath: libraryRootPath, relativePath: carrier.relativePath)
                frames.append(Frame(
                    files: [carrier], shown: id, shownChoice: carrier.choice, rawFiles: carrier.kind == .raw ? [id] : []
                ))
            }
        }
        return frames
    }

    /// A burst of two or more `frames`, in capture order, keyed by the frame the user chose
    /// last, else its first Liked frame, else its first frame.
    private static func stack(identifier: String, frames: [Frame], libraryRootPath: LibraryRootPath) -> PhotoStack? {
        guard frames.count >= 2 else { return nil }
        let frames = frames.sorted { $0.precedes($1) }
        let chosen = frames.filter { $0.chosenAt != nil }.max { ($0.chosenAt ?? 0) < ($1.chosenAt ?? 0) }
        let key = chosen ?? frames.first(where: \.isLiked) ?? frames[0]
        return PhotoStack(
            id: PhotoStackID(kind: .burst, libraryRootPath: libraryRootPath, key: identifier),
            members: frames.flatMap { frame in
                frame.files.sorted { $0.sortKey < $1.sortKey }.map {
                    MediaAssetID(libraryRootPath: libraryRootPath, relativePath: $0.relativePath)
                }
            },
            key: key.shown,
            keyChoice: key.shownChoice,
            rawMembers: Set(frames.flatMap(\.rawFiles)),
            photos: frames.map(\.shown)
        )
    }
}

/// How one tile shows the stacks it is in: its pair and its burst, each with whether the
/// user expanded it. A tile can be in both — a pair is one frame of a burst.
nonisolated struct TileStacks: Equatable, Sendable {
    var pair: PhotoStack?
    var pairExpanded = false
    var burst: PhotoStack?
    var burstExpanded = false

    /// The collapsed stack the tile stands for, outermost first: its burst, else its pair.
    var collapsed: PhotoStack? {
        if let burst, !burstExpanded {
            return burst
        }
        if let pair, !pairExpanded {
            return pair
        }
        return nil
    }

    /// The innermost expanded stack the tile is a member of: its pair, else its burst.
    var expanded: PhotoStack? {
        if let pair, pairExpanded {
            return pair
        }
        if let burst, burstExpanded {
            return burst
        }
        return nil
    }
}

/// How the published order shows each stack (ADR 0052). A collapsed stack is one tile, its
/// shown file; an expanded stack is every member present, in order, on one band. A stack
/// with fewer than two members present — a filter showing only RAWs, say, or a burst with
/// one frame present, whose pair counts once — is not one here: its files show as any other.
nonisolated struct CatalogGridStacks: Equatable, Sendable {
    /// Each tile in a stack, with its pair and its burst.
    let tiles: [MediaAssetID: TileStacks]
    /// Each hidden file, mapped to the tile shown for it: where a selection or focus on a
    /// file goes when its stack collapses or changes its key.
    let shownForHiddenMember: [MediaAssetID: MediaAssetID]

    static let empty = CatalogGridStacks(tiles: [:], shownForHiddenMember: [:])

    /// The stack `id` stands for or is a member of, the collapsed one first, or nil when it
    /// stands alone.
    func stack(shownBy id: MediaAssetID) -> PhotoStack? {
        tiles[id].flatMap { $0.collapsed ?? $0.expanded }
    }

    /// The collapsed stack the tile showing `id` stands for.
    func collapsed(shownBy id: MediaAssetID) -> PhotoStack? {
        tiles[id]?.collapsed
    }

    /// The innermost expanded stack the tile showing `id` is a member of.
    func expanded(shownBy id: MediaAssetID) -> PhotoStack? {
        tiles[id]?.expanded
    }

    /// The RAW+JPEG pair the tile showing `id` is a file of, collapsed or expanded.
    func pair(shownBy id: MediaAssetID) -> PhotoStack? {
        tiles[id]?.pair
    }

    /// Every file an action that changes files reaches through `id` (ADR 0052): all of a
    /// collapsed stack's members, else `id` alone. A member of an expanded stack is an
    /// ordinary photo.
    func files(reachedThrough id: MediaAssetID) -> [MediaAssetID] {
        tiles[id]?.collapsed?.members ?? [id]
    }

    /// These stacks without the tiles of `hidden` and without the hidden files they mapped;
    /// a stack still shown by another tile keeps its members until the next read of the
    /// collapse (`CatalogWindowState.hidingItems`). The same value when none is here.
    func removing(_ hidden: Set<MediaAssetID>) -> CatalogGridStacks {
        guard hidden.contains(where: { tiles[$0] != nil || shownForHiddenMember[$0] != nil }) else {
            return self
        }
        var tiles = tiles
        var shownFor = shownForHiddenMember
        for id in hidden {
            tiles[id] = nil
            shownFor[id] = nil
        }
        if shownFor.values.contains(where: hidden.contains) {
            shownFor = shownFor.filter { !hidden.contains($0.value) }
        }
        return CatalogGridStacks(tiles: tiles, shownForHiddenMember: shownFor)
    }
}

/// The pure collapse pass.
nonisolated enum PhotoStackCollapse {
    /// The collapsed order, its index-paired day buckets and coordinates, and how it shows
    /// its stacks.
    struct Result: Equatable, Sendable {
        let ids: [MediaAssetID]
        let dayBuckets: [Date?]
        let coordinates: [PlaceCoordinate]
        let grid: CatalogGridStacks
    }

    /// One level's pass: the positions it keeps in the original order, each kept ID's stack
    /// at this level and whether it is expanded, and each hidden ID's shown ID.
    private struct Level {
        var kept: [Int] = []
        var stackOf: [MediaAssetID: TileLevel] = [:]
        var shownFor: [MediaAssetID: MediaAssetID] = [:]
    }

    private struct TileLevel {
        let stack: PhotoStack
        let expanded: Bool
    }

    /// Collapses each pair to its shown file, then each burst to its shown frame, unless
    /// `expanded` names it: the key when present, else the first member present in `ids`'
    /// order. `dayBuckets` and `coordinates` stay index-paired with the IDs (each is empty or
    /// the IDs' length).
    static func collapse(
        ids: [MediaAssetID],
        dayBuckets: [Date?],
        coordinates: [PlaceCoordinate],
        stacks: CatalogStacks,
        expanded: Set<PhotoStackID>
    ) -> Result {
        guard !stacks.stacks.isEmpty else {
            return Result(ids: ids, dayBuckets: dayBuckets, coordinates: coordinates, grid: .empty)
        }
        // Each pass touches every ID once; a pass with no stacks of its kind is skipped, and
        // the tiles are built from the stacked IDs alone, a few percent of a library.
        // A pair's files are one photo, so a pair counts once toward its burst: the burst
        // level counts frames present, never files.
        let pairs = level(
            ids,
            positions: Array(ids.indices),
            membership: stacks.pairOfMember,
            framing: [:],
            stacks: stacks,
            expanded: expanded
        )
        let bursts = level(
            pairs.kept.count == ids.count ? ids : pairs.kept.map { ids[$0] },
            positions: pairs.kept,
            membership: stacks.burstOfMember,
            framing: stacks.pairOfMember,
            stacks: stacks,
            expanded: expanded
        )

        var tiles: [MediaAssetID: TileStacks] = [:]
        for (id, pair) in pairs.stackOf where bursts.shownFor[id] == nil {
            tiles[id] = TileStacks(pair: pair.stack, pairExpanded: pair.expanded)
        }
        for (id, burst) in bursts.stackOf {
            tiles[id, default: TileStacks()].burst = burst.stack
            tiles[id, default: TileStacks()].burstExpanded = burst.expanded
        }
        // A file a pair hides goes to its pair's shown file, and on to the burst's shown
        // frame when the burst hides that one too.
        var shownFor = bursts.shownFor
        for (hidden, shown) in pairs.shownFor {
            shownFor[hidden] = bursts.shownFor[shown] ?? shown
        }

        let kept = bursts.kept
        let keepsAll = kept.count == ids.count
        return Result(
            ids: keepsAll ? ids : kept.map { ids[$0] },
            dayBuckets: dayBuckets.count != ids.count ? [] : keepsAll ? dayBuckets : kept.map { dayBuckets[$0] },
            coordinates: coordinates.count != ids.count ? [] : keepsAll ? coordinates : kept.map { coordinates[$0] },
            grid: CatalogGridStacks(tiles: tiles, shownForHiddenMember: shownFor)
        )
    }

    /// How many units `members` are: each file is one, except that the files `framing` maps
    /// to one pair are one together. Counted only where it can differ from the file count — a
    /// burst level's stack of two or more files — so a pair level, every file of a library
    /// of pairs, hashes nothing for it.
    private static func unitCount(_ members: [MediaAssetID], framing: [MediaAssetID: PhotoStackID]) -> Int {
        guard members.count >= 2, !framing.isEmpty else {
            return members.count
        }
        var pairs = Set<PhotoStackID>()
        var count = 0
        for member in members {
            if let pair = framing[member] {
                count += pairs.insert(pair).inserted ? 1 : 0
            } else {
                count += 1
            }
        }
        return count
    }

    /// One level over `ids`, whose positions in the original order are `positions`. A stack
    /// is one here when two or more of its units are present: its files, except that the
    /// files `framing` maps to one pair are one unit (an expanded pair's two files are one
    /// frame of its burst).
    private static func level(
        _ ids: [MediaAssetID],
        positions: [Int],
        membership: [MediaAssetID: PhotoStackID],
        framing: [MediaAssetID: PhotoStackID],
        stacks: CatalogStacks,
        expanded: Set<PhotoStackID>
    ) -> Level {
        guard !membership.isEmpty else {
            var level = Level()
            level.kept = positions
            return level
        }
        var present: [PhotoStackID: [MediaAssetID]] = [:]
        for id in ids {
            if let stackID = membership[id] {
                present[stackID, default: []].append(id)
            }
        }
        var shown: [PhotoStackID: MediaAssetID] = [:]
        for (stackID, members) in present where unitCount(members, framing: framing) >= 2 {
            guard let stack = stacks.stacks[stackID] else { continue }
            shown[stackID] = members.contains(stack.key) ? stack.key : members[0]
        }
        var level = Level()
        level.kept.reserveCapacity(ids.count)
        for (offset, id) in ids.enumerated() {
            guard let stackID = membership[id], let shownMember = shown[stackID],
                  let stack = stacks.stacks[stackID]
            else {
                level.kept.append(positions[offset])
                continue
            }
            let isExpanded = expanded.contains(stackID)
            if isExpanded || id == shownMember {
                level.kept.append(positions[offset])
                level.stackOf[id] = TileLevel(stack: stack, expanded: isExpanded)
            } else {
                level.shownFor[id] = shownMember
            }
        }
        return level
    }
}
