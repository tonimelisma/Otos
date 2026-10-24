import Foundation

/// Reorganization planner guide
///
/// Pure planning for Reorganize (ARC-050): applies the import naming policy
/// (`ImportNaming`) to a library already in place. It takes the catalog's media and the
/// destination folders already read into a `DestinationNamespace`, and returns where
/// every file goes and the order of renames that gets it there. No I/O, no actors.
///
/// Names are chosen per naming bundle exactly as import chooses them: one date, one
/// collision suffix, companions named after their primary. Every comparison between
/// paths is by the volume's name key, so a case-only difference on a case-insensitive
/// volume is the same slot. A path the catalog knows is not a foreign occupant: the
/// member there moves away (and frees it) or stays (and keeps it).
nonisolated enum ReorganizationPlanner {
    /// Every folder a plan of `snapshot` can put a file in. A suffix changes a file name,
    /// never its folder, so this set is complete before any name is chosen; the caller
    /// reads exactly these folders and passes the result to `plan`.
    static func destinationFolders(for snapshot: ReorganizationPlanningSnapshot) -> Set<String> {
        var folders: Set<String> = []
        for bundle in ImportNaming.bundles(from: snapshot.media, policy: snapshot.policy)
            where bundle.isNameable(under: snapshot.policy)
        {
            let timestamp = ImportNaming.timestamp(of: bundle, calendar: snapshot.calendar, timeZone: snapshot.timeZone)
            if let folder = ImportNaming.folder(timestamp: timestamp, policy: snapshot.policy) {
                folders.insert(folder)
            }
        }
        return folders
    }

    /// One pure pass over the library's bundles against `namespace`.
    ///
    /// Bundles that cannot move — undated, or whose folder a file occupies or could not
    /// be read — and bundles already named as the policy names them keep their names.
    /// Every other bundle takes the first suffix whose names are all free: not kept by
    /// a staying bundle, not taken by an earlier moving bundle, and not held by a file
    /// the catalog does not know. A bundle that finds no free suffix stays too; since
    /// it then keeps names an earlier bundle may have counted on, the pass restarts
    /// with it staying, which ends because each restart adds a staying bundle.
    static func plan(
        snapshot: ReorganizationPlanningSnapshot,
        namespace: DestinationNamespace
    ) -> ReorganizationPlanBuildOutcome {
        let bundles = ImportNaming.bundles(from: snapshot.media, policy: snapshot.policy)
            .map { PlannedBundle(bundle: $0, snapshot: snapshot) }
        var staying = Set<Int>()
        var blocks: [Int: ReorganizationBlockReason] = [:]
        for (index, bundle) in bundles.enumerated() {
            if let block = bundle.fixedBlock(namespace: namespace) {
                staying.insert(index)
                blocks[index] = block
            } else if bundle.isAlreadyNamed {
                staying.insert(index)
            }
        }

        let keyOf = { (path: MediaRelativePath) in
            FilesystemNamespaceSemantics.nameKey(relativePath: path, capabilities: snapshot.capabilities)
        }
        let catalogKeys = Set(bundles.flatMap(\.sourcePaths).map(keyOf))

        while true {
            var claimed: [FilesystemNameKey: Int] = [:]
            for index in staying {
                for path in bundles[index].sourcePaths {
                    claimed[keyOf(path)] = index
                }
            }
            var finals: [Int: [MediaRelativePath: MediaRelativePath]] = [:]
            var newlyStaying: Int?
            bundleLoop: for (index, bundle) in bundles.enumerated() where !staying.contains(index) {
                for suffix in 0 ..< 10000 {
                    let destinations = bundle.destinations(suffix: suffix)
                    let free = destinations.values.allSatisfy { destination in
                        let key = keyOf(destination)
                        if claimed[key] != nil {
                            return false
                        }
                        if catalogKeys.contains(key) {
                            // A catalog member is there now. Every staying member's name
                            // is already claimed, so this one moves away first.
                            return true
                        }
                        if case .absent = namespace.occupancy(of: destination) {
                            return true
                        }
                        return false
                    }
                    if free {
                        for destination in destinations.values {
                            claimed[keyOf(destination)] = index
                        }
                        finals[index] = destinations
                        continue bundleLoop
                    }
                }
                let unsuffixed = bundle.destinations(suffix: 0).values.min { $0.rawValue < $1.rawValue }
                blocks[index] = .noFreeName(destination: unsuffixed ?? bundle.sourcePaths[0])
                newlyStaying = index
                break
            }
            if let newlyStaying {
                staying.insert(newlyStaying)
                continue
            }
            return assemble(
                bundles: bundles,
                finals: finals,
                blocks: blocks,
                snapshot: snapshot,
                keyOf: keyOf
            )
        }
    }

    // MARK: - Assembly

    private static func assemble(
        bundles: [PlannedBundle],
        finals: [Int: [MediaRelativePath: MediaRelativePath]],
        blocks: [Int: ReorganizationBlockReason],
        snapshot: ReorganizationPlanningSnapshot,
        keyOf: (MediaRelativePath) -> FilesystemNameKey
    ) -> ReorganizationPlanBuildOutcome {
        var members: [ReorganizationPhysicalMember] = []
        var mediaDispositions: [MediaAssetID: ReorganizationDisposition] = [:]
        for (index, bundle) in bundles.enumerated() {
            let bundleFinals = finals[index] ?? [:]
            for member in bundle.members {
                let final = bundleFinals[member.source] ?? member.source
                members.append(ReorganizationPhysicalMember(
                    id: member.id,
                    source: member.source,
                    finalDestination: final,
                    isCompanion: member.isCompanion,
                    primarySource: member.primarySource,
                    mediaID: member.mediaID
                ))
                guard !member.isCompanion, let mediaID = member.mediaID else { continue }
                if let block = blocks[index] {
                    mediaDispositions[mediaID] = .blocked(block)
                } else if final == member.source {
                    mediaDispositions[mediaID] = .noOp
                } else {
                    mediaDispositions[mediaID] = .relocate(destination: final)
                }
            }
        }

        let relocating = members.filter { $0.source != $0.finalDestination }
        let finalKeys = relocating.map { keyOf($0.finalDestination) }
        guard Set(finalKeys).count == finalKeys.count else {
            return .inconsistent(reason: "duplicateFinalNamespaceKeys")
        }
        return .ready(ReorganizationPlan(
            generation: snapshot.generation,
            libraryRoot: snapshot.libraryRoot,
            rootRevision: snapshot.rootRevision,
            policy: snapshot.policy,
            members: members,
            components: moveComponents(relocating: relocating, keyOf: keyOf),
            mediaDispositions: mediaDispositions
        ))
    }

    /// Groups relocating members into components that must move together — a member
    /// and the member whose slot it takes, a primary and its companions — and orders
    /// each component's renames.
    private static func moveComponents(
        relocating: [ReorganizationPhysicalMember],
        keyOf: (MediaRelativePath) -> FilesystemNameKey
    ) -> [ReorganizationComponent] {
        let bySourceKey = Dictionary(uniqueKeysWithValues: relocating.map { (keyOf($0.source), $0.id) })
        var adjacency: [String: Set<String>] = Dictionary(uniqueKeysWithValues: relocating.map { ($0.id, []) })
        for member in relocating {
            if let occupant = bySourceKey[keyOf(member.finalDestination)], occupant != member.id {
                adjacency[member.id, default: []].insert(occupant)
                adjacency[occupant, default: []].insert(member.id)
            }
            if member.isCompanion, let primarySource = member.primarySource,
               let primary = relocating.first(where: { !$0.isCompanion && $0.source == primarySource })
            {
                adjacency[member.id, default: []].insert(primary.id)
                adjacency[primary.id, default: []].insert(member.id)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: relocating.map { ($0.id, $0) })
        return connectedComponents(adjacency: adjacency, orderedIDs: relocating.map(\.id))
            .enumerated()
            .map { index, ids in
                ReorganizationComponent(
                    id: "component-\(index)",
                    memberIDs: ids,
                    steps: renameOrder(ids.compactMap { byID[$0] }, keyOf: keyOf)
                )
            }
    }

    /// Orders one component's renames so no rename lands on an occupied slot. A member
    /// whose destination slot is free moves; when every remaining member's slot is held
    /// by another remaining member (a cycle, or a case-only relabel that holds its own
    /// slot), the first by name steps aside to a temporary name in its own folder and
    /// moves on from there once its slot is free.
    private static func renameOrder(
        _ members: [ReorganizationPhysicalMember],
        keyOf: (MediaRelativePath) -> FilesystemNameKey
    ) -> [ReorganizationMoveStep] {
        var current = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.source) })
        var occupant: [FilesystemNameKey: String] = Dictionary(
            uniqueKeysWithValues: members.map { (keyOf($0.source), $0.id) }
        )
        var pending = members.sorted {
            $0.source.rawValue.localizedStandardCompare($1.source.rawValue) == .orderedAscending
        }
        var steps: [ReorganizationMoveStep] = []
        while !pending.isEmpty {
            if let index = pending.firstIndex(where: { occupant[keyOf($0.finalDestination)] == nil }) {
                let member = pending.remove(at: index)
                let from = current[member.id] ?? member.source
                steps.append(.move(from: from, to: member.finalDestination))
                occupant.removeValue(forKey: keyOf(from))
                occupant[keyOf(member.finalDestination)] = member.id
                current[member.id] = member.finalDestination
                continue
            }
            let pivot = pending[0]
            let from = current[pivot.id] ?? pivot.source
            let temporary = temporaryPath(for: pivot)
            steps.append(.move(from: from, to: temporary))
            occupant.removeValue(forKey: keyOf(from))
            occupant[keyOf(temporary)] = pivot.id
            current[pivot.id] = temporary
        }
        return steps
    }

    /// A hidden name in the member's own folder, stable across processes: it is built
    /// from the member's id (its kind and catalog path), never from a hash.
    private static func temporaryPath(for member: ReorganizationPhysicalMember) -> MediaRelativePath {
        let token = member.id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return MediaRelativePath(
            folder: member.source.folder,
            fileName: ".otos-reorg-\(token)-\(member.source.fileName)"
        )
    }

    private static func connectedComponents(
        adjacency: [String: Set<String>],
        orderedIDs: [String]
    ) -> [[String]] {
        var seen = Set<String>()
        var result: [[String]] = []
        for start in orderedIDs {
            guard !seen.contains(start) else { continue }
            var stack = [start]
            var component: [String] = []
            while let current = stack.popLast() {
                guard seen.insert(current).inserted else { continue }
                component.append(current)
                for neighbor in adjacency[current, default: []].sorted() where !seen.contains(neighbor) {
                    stack.append(neighbor)
                }
            }
            component.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            result.append(component)
        }
        return result
    }
}

// MARK: - Bundles

/// One naming bundle with its members' catalog paths: the media and every companion
/// that belongs to them.
private nonisolated struct PlannedBundle {
    struct Member {
        let id: String
        let source: MediaRelativePath
        let isCompanion: Bool
        let primarySource: MediaRelativePath?
        let mediaID: MediaAssetID?
        let facts: PlanningFileFacts?
        let companion: MediaCompanion?
    }

    let bundle: ImportNaming.Bundle
    let members: [Member]
    let policy: ImportPolicy
    let timestamp: CaptureWallComponents?

    init(bundle: ImportNaming.Bundle, snapshot: ReorganizationPlanningSnapshot) {
        self.bundle = bundle
        policy = snapshot.policy
        timestamp = ImportNaming.timestamp(of: bundle, calendar: snapshot.calendar, timeZone: snapshot.timeZone)
        var members: [Member] = []
        for media in bundle.members {
            members.append(Member(
                id: "media:\(media.relativePath.rawValue)",
                source: media.relativePath,
                isCompanion: false,
                primarySource: nil,
                mediaID: media.id,
                facts: media,
                companion: nil
            ))
            for companion in media.companions where companion.primaryRelativePath == media.relativePath {
                members.append(Member(
                    id: "companion:\(companion.relativePath.rawValue)",
                    source: companion.relativePath,
                    isCompanion: true,
                    primarySource: media.relativePath,
                    mediaID: media.id,
                    facts: nil,
                    companion: companion
                ))
            }
        }
        self.members = members
    }

    var sourcePaths: [MediaRelativePath] {
        members.map(\.source)
    }

    /// A reason the bundle cannot move, whatever suffix it would take.
    func fixedBlock(namespace: DestinationNamespace) -> ReorganizationBlockReason? {
        guard bundle.isNameable(under: policy),
              let folder = ImportNaming.folder(timestamp: timestamp, policy: policy)
        else {
            return .noUsableDate
        }
        if let occupant = namespace.occupiedFolders[folder] {
            return .folderOccupied(occupant: occupant)
        }
        if namespace.unreadableFolders[folder] != nil {
            return .folderUnreadable(folder: folder)
        }
        return nil
    }

    /// Every member is already named as the policy names it, spelling included.
    var isAlreadyNamed: Bool {
        destinations(suffix: 0).allSatisfy { $0.key == $0.value }
    }

    /// Each member's destination under collision suffix `suffix`, keyed by its source.
    /// Called only for a nameable bundle, where every media member has a destination.
    func destinations(suffix: Int) -> [MediaRelativePath: MediaRelativePath] {
        var result: [MediaRelativePath: MediaRelativePath] = [:]
        for member in members where !member.isCompanion {
            guard let facts = member.facts,
                  let destination = ImportNaming.destination(
                      for: facts,
                      timestamp: timestamp,
                      policy: policy,
                      suffix: suffix
                  )
            else { continue }
            result[member.source] = destination
        }
        for member in members where member.isCompanion {
            guard let primary = member.primarySource,
                  let primaryDestination = result[primary],
                  let companion = member.companion
            else { continue }
            result[member.source] = ImportNaming.companionDestination(
                companion,
                primaryDestination: primaryDestination,
                policy: policy
            )
        }
        return result
    }
}
