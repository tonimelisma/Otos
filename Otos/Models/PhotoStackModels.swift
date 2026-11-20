import Foundation

// File guide: a stack is several files Otos shows as one photo until the user expands it
// (ADR 0052). Stacks are derived, never stored: the Store reads the candidate stills — the
// stills of each folder that can hold a pair and every still carrying a burst identifier —
// and `PhotoStackRule` decides the stacks from their names, kinds and identifiers alone, so a rename, move,
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
/// stored name key (ARC-056, which every path write keeps current), its burst identifier and
/// capture time, the user's choice for it (Liked, Not Rated, Disliked), and when the user
/// made it its pair's or its burst's key (nil when never).
nonisolated struct PhotoStackCandidate: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let kind: MediaKind
    let nameKey: FilesystemNameKey
    var burstIdentifier: String?
    var captureLocal: Double?
    var choice: MediaChoice = .notRated
    var keyChosenAtUnixMs: Int64?
    var burstKeyChosenAtUnixMs: Int64?

    /// The path's natural order (`MediaSortKey`), what a stack orders its files by. A stack's
    /// files share a root, so the path's own key orders them as the catalog's whole key would;
    /// it is made only for the files a stack holds, when they are ordered.
    var sortKey: String {
        MediaSortKey.naturalKey(relativePath.rawValue)
    }
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
    /// Every file of every stack: what the collapse probes each file of the order by, once.
    let stackedMembers: Set<MediaAssetID>

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
        stackedMembers = Set(pairOf.keys).union(burstOf.keys)
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
/// Whether a RAW and the camera's processed still of the same shot are one photo or two
/// (Settings ▸ General; Lightroom Classic's "Treat JPEG files next to raw files as separate
/// photos"). The Store holds the user's choice and every stack build reads it.
nonisolated enum RawPairing: String, Sendable {
    case paired
    case separate
}

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
    ///
    /// With `pairing` `.separate` (Settings) a RAW and its processed file are two photos: no
    /// pair is made, and each is its own frame of a burst.
    static func stacks(
        candidates: [PhotoStackCandidate],
        libraryRootPath: LibraryRootPath,
        pairing: RawPairing
    ) -> [PhotoStack] {
        // Built as `MappedArrayBuilder` says: a root's candidates are owner-scale.
        let stills = MappedArrayBuilder.collect(candidates) { $0.kind != .video ? $0 : nil }
        let pairs = pairing == .paired ? pairs(stills, libraryRootPath: libraryRootPath) : []
        return pairs + bursts(stills, pairs: pairs, libraryRootPath: libraryRootPath)
    }

    private static func pairs(_ stills: [PhotoStackCandidate], libraryRootPath: LibraryRootPath) -> [PhotoStack] {
        // The stem key is cut from the stored name key, never normalized again here.
        let byStem = Dictionary(exactlyGrouping: stills) { FilesystemNamespaceSemantics.stemKey(of: $0.nameKey) }
        return MappedArrayBuilder.collect(byStem) { stem, group -> PhotoStack? in
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
        let carriers = MappedArrayBuilder.collect(stills) { $0.burstIdentifier != nil ? $0 : nil }
        // Most libraries hold no burst at all; the lookups below are built only for one that does.
        guard !carriers.isEmpty else { return [] }
        var pairOfFile: [MediaRelativePath: PhotoStack] = [:]
        for pair in pairs {
            for member in pair.members {
                pairOfFile[member.relativePath] = pair
            }
        }
        let byPath = Dictionary(stills.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(exactlyGrouping: carriers) { $0.burstIdentifier ?? "" }
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
        /// The input's positions the collapse hides, ascending: an input position `p` it
        /// keeps is at `p` minus the hidden positions before it in `ids`.
        let hiddenPositions: [Int]
        /// Where each file of a stack sits in the input, whatever the collapse did with it:
        /// what a change of expansion recollapses (`changingExpansion`).
        let stackedPositions: [MediaAssetID: Int]
    }

    /// One level's pass: the positions it keeps and hides in the original order, each kept
    /// ID's stack at this level and whether it is expanded, each hidden ID's shown ID, and
    /// where each ID of a stack at this level sits.
    private struct Level {
        var kept: [Int] = []
        var hidden: [Int] = []
        var stackOf: [MediaAssetID: TileLevel] = [:]
        var shownFor: [MediaAssetID: MediaAssetID] = [:]
        var stacked: [MediaAssetID: Int] = [:]
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
            return Result(
                ids: ids, dayBuckets: dayBuckets, coordinates: coordinates, grid: .empty,
                hiddenPositions: [], stackedPositions: [:]
            )
        }
        // One probe a file finds the files in a stack, a few percent of a library; both levels
        // and the tiles then touch those files alone, and the order is copied once, without
        // the files a level hides. A file in no stack is never hidden, so a level over the
        // stacked files alone hides what it would over every file. On the owner's 164,762
        // files the two levels each walked every file twice, about 0.5 s
        // (`docs/research/2026-11-16-window-reads-owner-catalog.md`).
        var stackedPositions: [Int] = []
        for (position, id) in ids.enumerated() where stacks.stackedMembers.contains(id) {
            stackedPositions.append(position)
        }
        // A pair's files are one photo, so a pair counts once toward its burst: the burst
        // level counts frames present, never files.
        let pairs = level(
            stackedPositions.map { ids[$0] },
            positions: stackedPositions,
            membership: stacks.pairOfMember,
            framing: [:],
            stacks: stacks,
            expanded: expanded
        )
        let bursts = level(
            pairs.kept.map { ids[$0] },
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

        let hidden = Self.merged(pairs.hidden, bursts.hidden)
        var stacked = pairs.stacked
        stacked.merge(bursts.stacked) { pair, _ in pair }
        func keeping<Element>(_ elements: [Element]) -> [Element] {
            hidden.isEmpty ? elements : elements.editing(removing: hidden, inserting: [])
        }
        return Result(
            ids: keeping(ids),
            dayBuckets: dayBuckets.count != ids.count ? [] : keeping(dayBuckets),
            coordinates: coordinates.count != ids.count ? [] : keeping(coordinates),
            grid: CatalogGridStacks(tiles: tiles, shownForHiddenMember: shownFor),
            hiddenPositions: hidden,
            stackedPositions: stacked
        )
    }

    /// Two ascending runs of distinct positions as one.
    private static func merged(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var left = 0
        var right = 0
        while left < lhs.count || right < rhs.count {
            if right == rhs.count || (left < lhs.count && lhs[left] < rhs[right]) {
                result.append(lhs[left])
                left += 1
            } else {
                result.append(rhs[right])
                right += 1
            }
        }
        return result
    }

    /// `held`, the collapse of `ids` (with `dayBuckets` and `coordinates`) under
    /// `heldExpanded`, collapsed under `expanded` instead, and the edit that turns `held`'s
    /// order into the new one. Only the stacks whose expansion changed are collapsed again,
    /// with every stack that shares a file with them (a pair and the burst it is a frame
    /// of), over their files alone: a stack's collapse reads nothing but its own files, so
    /// the rest of `held` stands, and the cost is those files plus copying the order once.
    /// The result is what `collapse(ids:…expanded:)` makes.
    static func changingExpansion(
        of held: Result,
        ids: [MediaAssetID],
        dayBuckets: [Date?],
        coordinates: [PlaceCoordinate],
        stacks: CatalogStacks,
        from heldExpanded: Set<PhotoStackID>,
        to expanded: Set<PhotoStackID>
    ) -> (result: Result, edit: CatalogGridContent.Edit) {
        // The stacks whose files the change can reach, closed over shared files.
        var affected = Set<PhotoStackID>()
        var pending = Array(heldExpanded.symmetricDifference(expanded))
        while let stackID = pending.popLast() {
            guard affected.insert(stackID).inserted else {
                continue
            }
            for member in stacks.stacks[stackID]?.members ?? [] {
                for related in [stacks.pairOfMember[member], stacks.burstOfMember[member]] {
                    if let related, !affected.contains(related) {
                        pending.append(related)
                    }
                }
            }
        }
        var positionSet = Set<Int>()
        for stackID in affected {
            for member in stacks.stacks[stackID]?.members ?? [] {
                if let position = held.stackedPositions[member] {
                    positionSet.insert(position)
                }
            }
        }
        let positions = positionSet.sorted()
        let files = positions.map { ids[$0] }
        let before = collapse(ids: files, dayBuckets: [], coordinates: [], stacks: stacks, expanded: heldExpanded)
        let after = collapse(ids: files, dayBuckets: [], coordinates: [], stacks: stacks, expanded: expanded)
        let hiddenBefore = Set(before.hiddenPositions.map { positions[$0] })
        let hiddenAfter = Set(after.hiddenPositions.map { positions[$0] })
        let nowHidden = hiddenAfter.subtracting(hiddenBefore).sorted()
        let nowShown = hiddenBefore.subtracting(hiddenAfter).sorted()

        var hidden: [Int] = []
        hidden.reserveCapacity(held.hiddenPositions.count + nowHidden.count)
        for position in merged(held.hiddenPositions, nowHidden) where !hiddenBefore.contains(position) || hiddenAfter.contains(position) {
            hidden.append(position)
        }
        /// A kept input position's place in the collapsed order: itself less the hidden
        /// positions before it.
        func collapsedPosition(_ position: Int, hiding hidden: [Int]) -> Int {
            var low = 0
            var high = hidden.count
            while low < high {
                let middle = (low + high) / 2
                if hidden[middle] < position {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return position - low
        }
        let removed = nowHidden.map { collapsedPosition($0, hiding: held.hiddenPositions) }
        let inserted = nowShown.map { collapsedPosition($0, hiding: hidden) }

        var tiles = held.grid.tiles
        var shownFor = held.grid.shownForHiddenMember
        for file in files {
            tiles[file] = nil
            shownFor[file] = nil
        }
        tiles.merge(after.grid.tiles) { _, recollapsed in recollapsed }
        shownFor.merge(after.grid.shownForHiddenMember) { _, recollapsed in recollapsed }
        let result = Result(
            ids: held.ids.editing(removing: removed, inserting: zip(inserted, nowShown.map { ids[$0] }).map { (position: $0, element: $1) }),
            dayBuckets: dayBuckets.count != ids.count
                ? []
                : held.dayBuckets.editing(removing: removed, inserting: zip(inserted, nowShown.map { dayBuckets[$0] }).map { (position: $0, element: $1) }),
            coordinates: coordinates.count != ids.count
                ? []
                : held.coordinates.editing(removing: removed, inserting: zip(inserted, nowShown.map { coordinates[$0] }).map { (position: $0, element: $1) }),
            grid: CatalogGridStacks(tiles: tiles, shownForHiddenMember: shownFor),
            hiddenPositions: hidden,
            stackedPositions: held.stackedPositions
        )
        return (result, CatalogGridContent.Edit(removed: removed, inserted: inserted))
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
            guard let stackID = membership[id] else {
                level.kept.append(positions[offset])
                continue
            }
            level.stacked[id] = positions[offset]
            guard let shownMember = shown[stackID], let stack = stacks.stacks[stackID] else {
                level.kept.append(positions[offset])
                continue
            }
            let isExpanded = expanded.contains(stackID)
            if isExpanded || id == shownMember {
                level.kept.append(positions[offset])
                level.stackOf[id] = TileLevel(stack: stack, expanded: isExpanded)
            } else {
                level.hidden.append(positions[offset])
                level.shownFor[id] = shownMember
            }
        }
        return level
    }
}
