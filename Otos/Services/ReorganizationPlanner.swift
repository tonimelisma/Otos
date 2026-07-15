import Foundation

// Reorganization reservation + graph construction is intentionally cohesive.
// swiftlint:disable cyclomatic_complexity function_body_length type_body_length

/// Pure reorganization planner (plan 0055 Stage G1 / §9).
///
/// Accepts only immutable Sendable values. Emits occupancy probe requests for
/// targets/ancestors the catalog cannot prove free. Never writes the filesystem.
nonisolated enum ReorganizationPlanner {
    static func plan(
        snapshot: ReorganizationPlanningSnapshot,
        occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:]
    ) -> ReorganizationPlanBuildOutcome {
        if snapshot.media.contains(where: { !$0.hasUsableDate }) {
            // Undatable media block individually; still build the rest.
        }

        var pendingOccupancy: [NamespaceOccupancyRequest] = []
        let capabilities = snapshot.capabilities
        let volumeID = snapshot.volumeIdentifier

        // 1. Build physical members from media + companions with ideal destinations.
        var members: [ReorganizationPhysicalMember] = []
        var mediaDispositions: [MediaAssetID: ReorganizationDisposition] = [:]
        let sortedMedia = snapshot.media.sorted {
            $0.relativePath.rawValue.localizedStandardCompare($1.relativePath.rawValue) == .orderedAscending
        }

        for media in sortedMedia {
            guard media.hasUsableDate else {
                mediaDispositions[media.id] = .blocked(.noUsableDate)
                continue
            }
            let ideal = idealRelativePath(for: media, policy: snapshot.policy)
            let primaryID = "media:\(media.relativePath.rawValue)"
            members.append(
                ReorganizationPhysicalMember(
                    id: primaryID,
                    source: media.relativePath,
                    idealDestination: ideal,
                    finalDestination: ideal,
                    isCompanion: false,
                    primarySource: nil,
                    mediaID: media.id
                )
            )
            for companion in media.companions.sorted(by: {
                $0.relativePath.rawValue.localizedStandardCompare($1.relativePath.rawValue) == .orderedAscending
            }) {
                let companionIdeal = companionDestination(
                    companion: companion,
                    primaryIdeal: ideal
                )
                members.append(
                    ReorganizationPhysicalMember(
                        id: "companion:\(companion.relativePath.rawValue)",
                        source: companion.relativePath,
                        idealDestination: companionIdeal,
                        finalDestination: companionIdeal,
                        isCompanion: true,
                        primarySource: media.relativePath,
                        mediaID: media.id
                    )
                )
            }
        }

        // 2. Exact spelling no-ops.
        for index in members.indices where members[index].source == members[index].finalDestination {
            if let mediaID = members[index].mediaID, !members[index].isCompanion {
                mediaDispositions[mediaID] = .noOp
            }
        }

        // 3. Reserve final lookup keys; suffix colliding bundles deterministically.
        var reservedKeys: [FilesystemNameKey: String] = [:]
        for index in members.indices where members[index].source != members[index].finalDestination {
            var destination = members[index].finalDestination
            var key = FilesystemNamespaceSemantics.nameKey(
                relativePath: destination,
                capabilities: capabilities
            )
            var suffix = 0
            while let owner = reservedKeys[key], owner != members[index].id {
                suffix += 1
                destination = suffixed(destination, suffix: suffix)
                key = FilesystemNamespaceSemantics.nameKey(
                    relativePath: destination,
                    capabilities: capabilities
                )
            }
            // Stationary occupant (exact no-op member or known foreign) forces suffix.
            let stationaryConflict = members.contains {
                $0.source == destination && $0.source == $0.finalDestination && $0.id != members[index].id
            } || snapshot.knownForeignOccupants.contains(destination)
            if stationaryConflict {
                suffix += 1
                destination = suffixed(members[index].idealDestination, suffix: suffix)
                key = FilesystemNamespaceSemantics.nameKey(
                    relativePath: destination,
                    capabilities: capabilities
                )
                while reservedKeys[key] != nil {
                    suffix += 1
                    destination = suffixed(members[index].idealDestination, suffix: suffix)
                    key = FilesystemNamespaceSemantics.nameKey(
                        relativePath: destination,
                        capabilities: capabilities
                    )
                }
            }
            members[index].finalDestination = destination
            reservedKeys[key] = members[index].id
        }

        // Keep companion finals aligned with primary when primary was suffixed.
        for index in members.indices where members[index].isCompanion {
            guard let primarySource = members[index].primarySource,
                  let primary = members.first(where: { $0.source == primarySource && !$0.isCompanion })
            else {
                continue
            }
            let aligned = companionDestination(
                companionRelative: members[index].source,
                primaryIdeal: primary.finalDestination
            )
            members[index].finalDestination = aligned
        }

        // 4. Emit occupancy probes for finals/ancestors not answered by catalog.
        let currentSources = Set(members.map(\.source))
        for member in members where member.source != member.finalDestination {
            let request = NamespaceOccupancyRequest(
                rootPath: snapshot.libraryRoot,
                relativePath: member.finalDestination
            )
            if occupancy[request] == nil,
               !currentSources.contains(member.finalDestination),
               !snapshot.knownForeignOccupants.contains(member.finalDestination)
            {
                pendingOccupancy.append(request)
            }
            for ancestor in directoryAncestors(of: member.finalDestination) {
                let ancestorRequest = NamespaceOccupancyRequest(
                    rootPath: snapshot.libraryRoot,
                    relativePath: ancestor
                )
                if occupancy[ancestorRequest] == nil {
                    pendingOccupancy.append(ancestorRequest)
                }
            }
        }
        if !pendingOccupancy.isEmpty {
            return .needsProbes(occupancy: uniqueOccupancy(pendingOccupancy))
        }

        // 5. Apply probe results.
        // Ancestors: only non-directory occupants block (existing date folders are valid).
        for member in members where member.source != member.finalDestination {
            for ancestor in directoryAncestors(of: member.finalDestination) {
                let ancestorRequest = NamespaceOccupancyRequest(
                    rootPath: snapshot.libraryRoot,
                    relativePath: ancestor
                )
                if isBlockingAncestorOccupancy(occupancy[ancestorRequest]),
                   let mediaID = member.mediaID
                {
                    mediaDispositions[mediaID] = .blocked(.ancestorConflict(ancestor))
                }
            }
        }

        // Finals: occupied non-catalog paths force suffixing like knownForeignOccupants.
        var pendingAfterResuffix: [NamespaceOccupancyRequest] = []
        for index in members.indices where members[index].source != members[index].finalDestination {
            if let mediaID = members[index].mediaID,
               case .blocked = mediaDispositions[mediaID]
            {
                continue
            }
            let destination = members[index].finalDestination
            let finalRequest = NamespaceOccupancyRequest(
                rootPath: snapshot.libraryRoot,
                relativePath: destination
            )
            guard isOccupiedFinalOccupancy(occupancy[finalRequest]) else {
                continue
            }
            // Release prior reservation for this member, then suffix away from the occupant.
            let priorKey = FilesystemNamespaceSemantics.nameKey(
                relativePath: destination,
                capabilities: capabilities
            )
            if reservedKeys[priorKey] == members[index].id {
                reservedKeys.removeValue(forKey: priorKey)
            }
            var suffix = 1
            var candidate = suffixed(members[index].idealDestination, suffix: suffix)
            var key = FilesystemNamespaceSemantics.nameKey(
                relativePath: candidate,
                capabilities: capabilities
            )
            while reservedKeys[key] != nil
                || snapshot.knownForeignOccupants.contains(candidate)
                || isOccupiedFinalOccupancy(
                    occupancy[
                        NamespaceOccupancyRequest(
                            rootPath: snapshot.libraryRoot,
                            relativePath: candidate
                        )
                    ]
                )
            {
                suffix += 1
                candidate = suffixed(members[index].idealDestination, suffix: suffix)
                key = FilesystemNamespaceSemantics.nameKey(
                    relativePath: candidate,
                    capabilities: capabilities
                )
            }
            members[index].finalDestination = candidate
            reservedKeys[key] = members[index].id
            let newRequest = NamespaceOccupancyRequest(
                rootPath: snapshot.libraryRoot,
                relativePath: candidate
            )
            if occupancy[newRequest] == nil {
                pendingAfterResuffix.append(newRequest)
            }
            for ancestor in directoryAncestors(of: candidate) {
                let ancestorRequest = NamespaceOccupancyRequest(
                    rootPath: snapshot.libraryRoot,
                    relativePath: ancestor
                )
                if occupancy[ancestorRequest] == nil {
                    pendingAfterResuffix.append(ancestorRequest)
                }
            }
        }
        // Keep companion finals aligned after any primary resuffix.
        for index in members.indices where members[index].isCompanion {
            guard let primarySource = members[index].primarySource,
                  let primary = members.first(where: { $0.source == primarySource && !$0.isCompanion })
            else {
                continue
            }
            members[index].finalDestination = companionDestination(
                companionRelative: members[index].source,
                primaryIdeal: primary.finalDestination
            )
        }
        if !pendingAfterResuffix.isEmpty {
            return .needsProbes(occupancy: uniqueOccupancy(pendingAfterResuffix))
        }

        // 6. Build move graph among relocating members.
        let relocating = members.filter { $0.source != $0.finalDestination }
        var adjacency: [String: Set<String>] = [:]
        for member in relocating {
            adjacency[member.id, default: []] = []
        }
        // Edge: member depends on occupant that must vacate finalDestination.
        for member in relocating {
            if let vacator = relocating.first(where: { $0.source == member.finalDestination }) {
                adjacency[member.id, default: []].insert(vacator.id)
                adjacency[vacator.id, default: []].insert(member.id)
            }
        }
        // Group primary + companions into the same undirected component.
        for member in relocating where member.isCompanion {
            if let primary = relocating.first(where: {
                $0.source == member.primarySource && !$0.isCompanion
            }) {
                adjacency[member.id, default: []].insert(primary.id)
                adjacency[primary.id, default: []].insert(member.id)
            }
        }

        let componentIDLists = connectedComponents(adjacency: adjacency, orderedIDs: relocating.map(\.id))
        var components: [ReorganizationComponent] = []
        for (index, ids) in componentIDLists.enumerated() {
            let componentMembers = ids.compactMap { id in relocating.first { $0.id == id } }
            let steps = recipe(for: componentMembers, capabilities: capabilities, volumeID: volumeID)
            components.append(
                ReorganizationComponent(
                    id: "component-\(index)",
                    memberIDs: ids,
                    steps: steps
                )
            )
        }

        // 7. Fill relocate dispositions for non-blocked media.
        for member in members where !member.isCompanion {
            guard let mediaID = member.mediaID else { continue }
            if case .blocked = mediaDispositions[mediaID] {
                continue
            }
            if member.source == member.finalDestination {
                mediaDispositions[mediaID] = .noOp
            } else {
                mediaDispositions[mediaID] = .relocate(destination: member.finalDestination)
            }
        }

        // Invariants
        let finalKeys = relocating.map {
            FilesystemNamespaceSemantics.nameKey(
                relativePath: $0.finalDestination,
                capabilities: capabilities
            )
        }
        if Set(finalKeys).count != finalKeys.count {
            return .blocked(reason: "duplicateFinalNamespaceKeys")
        }

        return .ready(
            ReorganizationPlan(
                generation: snapshot.generation,
                libraryRoot: snapshot.libraryRoot,
                rootRevision: snapshot.rootRevision,
                policy: snapshot.policy,
                members: members,
                components: components,
                mediaDispositions: mediaDispositions
            )
        )
    }

    // MARK: - Helpers

    private static func idealRelativePath(
        for media: PlanningFileFacts,
        policy: ImportPolicy
    ) -> MediaRelativePath {
        let components = media.captureWallCompact.flatMap(CaptureWallClock.components(fromCompact:))
        let folder: String
        switch policy.destinationFolderPolicy {
        case .yearMonth:
            if let components {
                folder = String(format: "%04d/%02d", components.year, components.month)
            } else if let modified = media.contentModifiedAt {
                let parts = Calendar.current.dateComponents([.year, .month], from: modified)
                folder = String(format: "%04d/%02d", parts.year ?? 0, parts.month ?? 0)
            } else {
                folder = "undated"
            }
        case .none:
            folder = ""
        }
        let stem: String
        switch policy.destinationNamePolicy {
        case .original:
            stem = URL(fileURLWithPath: media.relativePath.rawValue)
                .deletingPathExtension()
                .lastPathComponent
        case .captureDateTime:
            if let components {
                stem = String(
                    format: "%04d%02d%02d_%02d%02d%02d",
                    components.year,
                    components.month,
                    components.day,
                    components.hour,
                    components.minute,
                    components.second
                )
            } else if let modified = media.contentModifiedAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                stem = formatter.string(from: modified)
            } else {
                stem = URL(fileURLWithPath: media.relativePath.rawValue)
                    .deletingPathExtension()
                    .lastPathComponent
            }
        }
        let destinationExtension = switch policy.destinationNamePolicy {
        case .original:
            media.fileExtension
        case .captureDateTime:
            CanonicalMediaExtension.forDateTimeName(
                contentTypeIdentifier: media.contentTypeIdentifier,
                sourceExtension: media.fileExtension
            )
        }
        let ext = destinationExtension.isEmpty ? "" : ".\(destinationExtension)"
        let name = stem + ext
        let relative = folder.isEmpty ? name : "\(folder)/\(name)"
        return MediaRelativePath(rawValue: relative)
    }

    private static func companionDestination(
        companion: MediaCompanion,
        primaryIdeal: MediaRelativePath
    ) -> MediaRelativePath {
        companionDestination(companionRelative: companion.relativePath, primaryIdeal: primaryIdeal)
    }

    private static func companionDestination(
        companionRelative: MediaRelativePath,
        primaryIdeal: MediaRelativePath
    ) -> MediaRelativePath {
        let primaryURL = URL(fileURLWithPath: primaryIdeal.rawValue)
        let dir = primaryURL.deletingLastPathComponent().path
        let primaryStem = primaryURL.deletingPathExtension().lastPathComponent
        let companionExt = URL(fileURLWithPath: companionRelative.rawValue).pathExtension
        let name = companionExt.isEmpty ? primaryStem : "\(primaryStem).\(companionExt)"
        if dir == "." || dir.isEmpty {
            return MediaRelativePath(rawValue: name)
        }
        return MediaRelativePath(rawValue: "\(dir)/\(name)")
    }

    private static func suffixed(_ path: MediaRelativePath, suffix: Int) -> MediaRelativePath {
        let url = URL(fileURLWithPath: path.rawValue)
        let dir = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
        if dir == "." || dir.isEmpty {
            return MediaRelativePath(rawValue: name)
        }
        return MediaRelativePath(rawValue: "\(dir)/\(name)")
    }

    private static func directoryAncestors(of path: MediaRelativePath) -> [MediaRelativePath] {
        let parts = path.rawValue.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        var ancestors: [MediaRelativePath] = []
        for end in 1 ..< parts.count {
            ancestors.append(MediaRelativePath(rawValue: parts[0 ..< end].joined(separator: "/")))
        }
        return ancestors
    }

    private static func uniqueOccupancy(_ requests: [NamespaceOccupancyRequest]) -> [NamespaceOccupancyRequest] {
        var seen = Set<NamespaceOccupancyRequest>()
        var unique: [NamespaceOccupancyRequest] = []
        for request in requests where seen.insert(request).inserted {
            unique.append(request)
        }
        return unique
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

    /// Deterministic chain/cycle recipe (plan §9.5).
    private static func recipe(
        for members: [ReorganizationPhysicalMember],
        capabilities: VolumeNamespaceCapabilities,
        volumeID: String
    ) -> [ReorganizationMoveStep] {
        _ = volumeID
        let bySource = Dictionary(uniqueKeysWithValues: members.map { ($0.source.rawValue, $0) })
        // Namespace-equivalent self-rename: same lookup key, different spelling.
        if members.count == 1 {
            let member = members[0]
            let sourceKey = FilesystemNamespaceSemantics.nameKey(
                relativePath: member.source,
                capabilities: capabilities
            )
            let destKey = FilesystemNamespaceSemantics.nameKey(
                relativePath: member.finalDestination,
                capabilities: capabilities
            )
            if sourceKey == destKey, member.source != member.finalDestination {
                let temporary = temporaryPath(for: member)
                return [
                    .moveViaTemporary(
                        from: member.source,
                        temporary: temporary,
                        to: member.finalDestination
                    ),
                ]
            }
            return [.move(from: member.source, to: member.finalDestination)]
        }

        // Build directed edges source → final when final is another source.
        var next: [String: String] = [:]
        for member in members where bySource[member.finalDestination.rawValue] != nil {
            next[member.source.rawValue] = member.finalDestination.rawValue
        }

        // Detect cycle covering all directed nodes.
        let directedSources = Set(next.keys)
        if !directedSources.isEmpty,
           directedSources.count == next.values.filter({ directedSources.contains($0) }).count,
           isSingleCycle(next)
        {
            let pivotSource = directedSources.min {
                $0.localizedStandardCompare($1) == .orderedAscending
            }!
            let pivot = bySource[pivotSource]!
            let temporary = temporaryPath(for: pivot)
            var steps: [ReorganizationMoveStep] = [
                .move(from: pivot.source, to: temporary),
            ]
            // Rotate remaining: walk predecessors into freed slots.
            var currentTarget = pivotSource
            var remaining = next
            remaining.removeValue(forKey: pivotSource)
            while !remaining.isEmpty {
                guard let mover = remaining.first(where: { $0.value == currentTarget })?.key else {
                    break
                }
                let member = bySource[mover]!
                steps.append(.move(from: member.source, to: MediaRelativePath(rawValue: currentTarget)))
                remaining.removeValue(forKey: mover)
                currentTarget = mover
            }
            steps.append(.move(from: temporary, to: pivot.finalDestination))
            // Companions without directed edges move after rotation.
            for member in members
                where next[member.source.rawValue] == nil && member.source != pivot.source
            {
                steps.append(.move(from: member.source, to: member.finalDestination))
            }
            return steps
        }

        // Chain: execute from free end backward.
        var steps: [ReorganizationMoveStep] = []
        // Members whose destination is free (not a source) go first.
        let freeEnds = members.filter { bySource[$0.finalDestination.rawValue] == nil }
            .sorted { $0.source.rawValue.localizedStandardCompare($1.source.rawValue) == .orderedAscending }
        var moved = Set<String>()
        for end in freeEnds {
            appendChain(
                endingAt: end,
                bySource: bySource,
                next: next,
                moved: &moved,
                steps: &steps
            )
        }
        for member in members where !moved.contains(member.id) {
            steps.append(.move(from: member.source, to: member.finalDestination))
        }
        return steps
    }

    private static func appendChain(
        endingAt end: ReorganizationPhysicalMember,
        bySource: [String: ReorganizationPhysicalMember],
        next: [String: String],
        moved: inout Set<String>,
        steps: inout [ReorganizationMoveStep]
    ) {
        // Vacate the free end first, then move whoever claims the vacated source.
        guard !moved.contains(end.id) else { return }
        steps.append(.move(from: end.source, to: end.finalDestination))
        moved.insert(end.id)
        let predecessorKey = next.first(where: { $0.value == end.source.rawValue })?.key
        if let predecessorKey,
           let predecessor = bySource[predecessorKey],
           !moved.contains(predecessor.id)
        {
            appendChain(
                endingAt: predecessor,
                bySource: bySource,
                next: next,
                moved: &moved,
                steps: &steps
            )
        }
    }

    private static func isSingleCycle(_ next: [String: String]) -> Bool {
        guard let start = next.keys.min() else { return false }
        var seen = Set<String>()
        var current = start
        while seen.insert(current).inserted {
            guard let nxt = next[current] else { return false }
            current = nxt
        }
        return current == start && seen.count == next.count
    }

    private static func temporaryPath(for member: ReorganizationPhysicalMember) -> MediaRelativePath {
        let url = URL(fileURLWithPath: member.source.rawValue)
        let dir = url.deletingLastPathComponent().path
        // member.id is stable across processes (media:/companion: + path); never use hashValue.
        let token = member.id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = ".otos-reorg-\(token)-\(url.lastPathComponent)"
        if dir == "." || dir.isEmpty {
            return MediaRelativePath(rawValue: name)
        }
        return MediaRelativePath(rawValue: "\(dir)/\(name)")
    }

    private static func isBlockingAncestorOccupancy(_ result: NamespaceOccupancyResult?) -> Bool {
        switch result {
        case .regularFile:
            true
        case let .foreign(kind):
            kind != .directory
        case .absent, .none:
            false
        }
    }

    private static func isOccupiedFinalOccupancy(_ result: NamespaceOccupancyResult?) -> Bool {
        switch result {
        case .regularFile, .foreign:
            true
        case .absent, .none:
            false
        }
    }
}

// swiftlint:enable cyclomatic_complexity function_body_length type_body_length
