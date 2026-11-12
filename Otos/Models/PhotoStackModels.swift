import Foundation

// File guide: a stack is several files Otos shows as one photo until the user expands it
// (ADR 0052). Stacks are derived, never stored: the Store reads each folder's candidate
// stills and `PhotoStackRule` decides the stacks from their names and kinds alone, so a
// rename, move, deletion or enrichment can never leave one stale. The projection collapses
// the browser's order to each stack's key member; everything here is a value.

/// What makes the files one photo.
nonisolated enum PhotoStackKind: String, Equatable, Hashable, Sendable {
    /// A RAW and the camera's processed still of the same shot: one folder, one stem key.
    case pair
}

/// A stack's identity: its kind, its root and the derived key its members share. It names
/// nothing stored; it is recomputed from the files on every read.
nonisolated struct PhotoStackID: Hashable, Sendable {
    let kind: PhotoStackKind
    let libraryRootPath: LibraryRootPath
    let key: FilesystemNameKey
}

/// One still that may belong to a stack, as the Store reads it: its path, its kind, and
/// when the user made it its stack's key (nil when never).
nonisolated struct PhotoStackCandidate: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let kind: MediaKind
    var keyChosenAtUnixMs: Int64?
}

/// One stack: its members in natural name order, and its key — the member it shows when
/// collapsed: the member the user chose (Make Key Photo), else the rule's default.
nonisolated struct PhotoStack: Equatable, Sendable {
    let id: PhotoStackID
    let members: [MediaAssetID]
    let key: MediaAssetID
    /// The collapsed tile's badge: `RAW+JPG` for a pair (DES-116).
    let badgeLabel: String
    /// Each member's badge while the stack is expanded: `RAW`, or the processed file's
    /// own extension (`JPG`, `HEIC`), so the user can tell the files apart.
    let memberLabels: [MediaAssetID: String]
}

/// Every stack the browser's order can hold, and which stack each member is in.
nonisolated struct CatalogStacks: Equatable, Sendable {
    let stacks: [PhotoStackID: PhotoStack]
    let stackOfMember: [MediaAssetID: PhotoStackID]

    static let empty = CatalogStacks(stacks: [:], stackOfMember: [:])

    init(_ stacks: [PhotoStack]) {
        var byID: [PhotoStackID: PhotoStack] = [:]
        var stackOf: [MediaAssetID: PhotoStackID] = [:]
        for stack in stacks {
            byID[stack.id] = stack
            for member in stack.members {
                stackOf[member] = stack.id
            }
        }
        self.init(stacks: byID, stackOfMember: stackOf)
    }

    init(stacks: [PhotoStackID: PhotoStack], stackOfMember: [MediaAssetID: PhotoStackID]) {
        self.stacks = stacks
        self.stackOfMember = stackOfMember
    }

    /// The stack `id` is a member of, or nil when it stands alone.
    func stack(containing id: MediaAssetID) -> PhotoStack? {
        stackOfMember[id].flatMap { stacks[$0] }
    }
}

/// The pure rule that turns one root's candidates into stacks.
nonisolated enum PhotoStackRule {
    /// A pair is exactly two stills sharing a stem key (`FilesystemNamespaceSemantics.stemKey`,
    /// the volume's own name equality): one RAW and one processed image. Any other count —
    /// a RAW alone, two JPEGs, a RAW with a JPEG and a HEIC — pairs nothing, and every file
    /// shows as before. The processed file is the default key, as Apple Photos shows it
    /// (owner, 2026-11-13).
    static func stacks(
        candidates: [PhotoStackCandidate],
        libraryRootPath: LibraryRootPath,
        capabilities: VolumeNamespaceCapabilities
    ) -> [PhotoStack] {
        // The member the user chose most recently, per stem key; a choice on a file that is
        // no longer in a stack chooses nothing.
        var chosenByStem: [FilesystemNameKey: (path: MediaRelativePath, at: Int64)] = [:]
        for candidate in candidates {
            guard let at = candidate.keyChosenAtUnixMs else { continue }
            let stem = FilesystemNamespaceSemantics.stemKey(
                relativePath: candidate.relativePath,
                capabilities: capabilities
            )
            if chosenByStem[stem].map({ at > $0.at }) ?? true {
                chosenByStem[stem] = (candidate.relativePath, at)
            }
        }
        let byStem = Dictionary(grouping: candidates.filter { $0.kind != .video }) {
            FilesystemNamespaceSemantics.stemKey(relativePath: $0.relativePath, capabilities: capabilities)
        }
        return byStem.compactMap { key, group -> PhotoStack? in
            let chosenKey = chosenByStem[key]?.path
            guard group.count == 2,
                  let raw = group.first(where: { $0.kind == .raw }),
                  let processed = group.first(where: { $0.kind == .image })
            else {
                return nil
            }
            let members = [raw, processed]
                .sorted {
                    MediaSortKey.naturalKey($0.relativePath.rawValue) < MediaSortKey.naturalKey($1.relativePath.rawValue)
                }
                .map { MediaAssetID(libraryRootPath: libraryRootPath, relativePath: $0.relativePath) }
            let processedLabel = processed.relativePath.fileExtension.uppercased()
            let rawID = MediaAssetID(libraryRootPath: libraryRootPath, relativePath: raw.relativePath)
            let processedID = MediaAssetID(libraryRootPath: libraryRootPath, relativePath: processed.relativePath)
            return PhotoStack(
                id: PhotoStackID(kind: .pair, libraryRootPath: libraryRootPath, key: key),
                members: members,
                key: chosenKey.flatMap { chosen in members.first { $0.relativePath == chosen } }
                    ?? processedID,
                badgeLabel: "RAW+\(processedLabel)",
                memberLabels: [rawID: "RAW", processedID: processedLabel]
            )
        }
    }
}

/// How the published order shows each stack (ADR 0052). A collapsed stack is one tile, its
/// shown member; an expanded stack is every member present, in order, on one band. A stack
/// with fewer than two members present — a filter showing only RAWs, say — is not one here:
/// its file shows as any other.
nonisolated struct CatalogGridStacks: Equatable, Sendable {
    /// Each collapsed stack's shown member, mapped to its stack.
    let collapsed: [MediaAssetID: PhotoStack]
    /// Each member of an expanded stack, mapped to its stack.
    let expanded: [MediaAssetID: PhotoStack]
    /// Each hidden member of a collapsed stack, mapped to the member shown for it: where a
    /// selection or focus on a member goes when its stack collapses or changes its key.
    let shownForHiddenMember: [MediaAssetID: MediaAssetID]

    static let empty = CatalogGridStacks(collapsed: [:], expanded: [:])

    init(collapsed: [MediaAssetID: PhotoStack], expanded: [MediaAssetID: PhotoStack]) {
        self.collapsed = collapsed
        self.expanded = expanded
        var shownFor: [MediaAssetID: MediaAssetID] = [:]
        for (shown, stack) in collapsed {
            for member in stack.members where member != shown {
                shownFor[member] = shown
            }
        }
        shownForHiddenMember = shownFor
    }

    /// The stack `id` shows, collapsed or expanded, or nil when it stands alone.
    func stack(shownBy id: MediaAssetID) -> PhotoStack? {
        collapsed[id] ?? expanded[id]
    }

    /// Every file an action that changes files reaches through `id` (ADR 0052): all of a
    /// collapsed stack's members, else `id` alone. A member of an expanded stack is an
    /// ordinary photo.
    func files(reachedThrough id: MediaAssetID) -> [MediaAssetID] {
        collapsed[id]?.members ?? [id]
    }
}

/// The order a build starts from, before collapsing, with the stacks it was read with. A
/// detail-only pass reuses it, so a stack is never collapsed twice.
nonisolated struct CatalogUncollapsedOrder: Equatable, Sendable {
    let ids: [MediaAssetID]
    let dayBuckets: [Date?]
    let stacks: CatalogStacks

    static let empty = CatalogUncollapsedOrder(ids: [], dayBuckets: [], stacks: .empty)
}

/// The pure collapse pass.
nonisolated enum PhotoStackCollapse {
    /// The collapsed order, its index-paired day buckets and coordinates, and how it shows
    /// its stacks.
    struct Result: Equatable {
        let ids: [MediaAssetID]
        let dayBuckets: [Date?]
        let coordinates: [PlaceCoordinate]
        let grid: CatalogGridStacks
    }

    /// Collapses each stack in `ids` to its shown member, unless `expanded` names it: the
    /// key when present, else the first member present in `ids`' order. `dayBuckets` and
    /// `coordinates` stay index-paired with the IDs (each is empty or the IDs' length).
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
        var present: [PhotoStackID: [MediaAssetID]] = [:]
        for id in ids {
            if let stackID = stacks.stackOfMember[id] {
                present[stackID, default: []].append(id)
            }
        }
        var shown: [PhotoStackID: MediaAssetID] = [:]
        for (stackID, members) in present where members.count >= 2 {
            guard let stack = stacks.stacks[stackID] else { continue }
            shown[stackID] = members.contains(stack.key) ? stack.key : members[0]
        }
        let pairsBuckets = dayBuckets.count == ids.count
        let pairsCoordinates = coordinates.count == ids.count
        var keptIDs: [MediaAssetID] = []
        var keptBuckets: [Date?] = []
        var keptCoordinates: [PlaceCoordinate] = []
        keptIDs.reserveCapacity(ids.count)
        var collapsed: [MediaAssetID: PhotoStack] = [:]
        var expandedMembers: [MediaAssetID: PhotoStack] = [:]
        func shownStack(of id: MediaAssetID) -> (PhotoStack, MediaAssetID)? {
            guard let stackID = stacks.stackOfMember[id], let member = shown[stackID] else { return nil }
            return stacks.stacks[stackID].map { ($0, member) }
        }
        for (index, id) in ids.enumerated() {
            if let (stack, shownMember) = shownStack(of: id) {
                if expanded.contains(stack.id) {
                    expandedMembers[id] = stack
                } else if id == shownMember {
                    collapsed[id] = stack
                } else {
                    continue
                }
            }
            keptIDs.append(id)
            if pairsBuckets {
                keptBuckets.append(dayBuckets[index])
            }
            if pairsCoordinates {
                keptCoordinates.append(coordinates[index])
            }
        }
        return Result(
            ids: keptIDs,
            dayBuckets: keptBuckets,
            coordinates: keptCoordinates,
            grid: CatalogGridStacks(collapsed: collapsed, expanded: expandedMembers)
        )
    }
}
