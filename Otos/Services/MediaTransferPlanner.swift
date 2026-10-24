import Foundation

/// Media transfer planner guide
///
/// Nonisolated pure planning for import (and later reorganization). Accepts only
/// immutable Sendable values; performs no I/O, database calls, logging, or actor
/// hops. Occupancy is expressed as typed requests; the caller
/// resolves them and resumes until `.ready`.
///
/// Import collision policy: absent → copy; regular file with matching live size and
/// expected destination mtime → preexisting; every other occupant → next suffix.
nonisolated enum MediaTransferPlanner {
    /// Destination folders any candidate of this snapshot could land in.
    ///
    /// A suffix retry changes the file name, never the folder, so this set is
    /// complete before any occupancy is known. The caller enumerates exactly these
    /// folders and hands the result back to `planImport`, which then needs no
    /// further observation — the reason planning is one pass and not a fixed point.
    static func destinationFolders(for snapshot: ImportPlanningSnapshot) -> Set<String> {
        var folders: Set<String> = []
        for bundle in ImportNaming.bundles(from: snapshot.sourceMedia, policy: snapshot.policy)
            where bundle.isNameable(under: snapshot.policy)
        {
            let timestamp = ImportNaming.timestamp(of: bundle, calendar: snapshot.calendar, timeZone: snapshot.timeZone)
            if let folder = ImportNaming.folder(timestamp: timestamp, policy: snapshot.policy) {
                folders.insert(folder)
            }
        }
        return folders
    }

    /// Single pure pass over the source bundles against an already-read destination
    /// namespace. Every candidate — base name and each suffix retry — is answered
    /// from `namespace`, so the pass never suspends, never restarts, and never
    /// re-derives its bundles.
    static func planImport(
        snapshot: ImportPlanningSnapshot,
        namespace: DestinationNamespace,
        additionalReserved: Set<MediaRelativePath> = []
    ) -> MediaOperationPlan {
        var reserved = Set(snapshot.destinationOccupants.keys.map {
            FilesystemNamespaceSemantics.nameKey(
                relativePath: $0,
                capabilities: snapshot.destinationCapabilities
            )
        })
        reserved.formUnion(additionalReserved.map {
            FilesystemNamespaceSemantics.nameKey(
                relativePath: $0,
                capabilities: snapshot.destinationCapabilities
            )
        })
        let bundles = ImportNaming.bundles(from: snapshot.sourceMedia, policy: snapshot.policy)
        var entries: [MediaOperationPlanEntry] = []

        for bundle in bundles {
            entries.append(
                contentsOf: planBundle(
                    bundle,
                    snapshot: snapshot,
                    reserved: &reserved,
                    namespace: namespace
                )
            )
        }

        let eraseManifest = EraseManifest.from(planEntries: entries, sourceMedia: snapshot.sourceMedia)
        return MediaOperationPlan(
            generation: snapshot.generation,
            mode: .import(
                source: snapshot.sourceRoot,
                destination: snapshot.destinationRoot,
                batch: ImportBatchID()
            ),
            sourceNamespaceRevision: snapshot.sourceNamespaceRevision,
            sourceNamingRevision: snapshot.sourceNamingRevision,
            destinationNamespaceRevision: snapshot.destinationNamespaceRevision,
            policy: snapshot.policy,
            entries: entries,
            eraseManifest: eraseManifest,
            totals: totals(from: entries)
        )
    }

    /// Reads the destination folders this snapshot needs, then plans. The only
    /// entry point that performs I/O; `planImport` stays pure for tests.
    static func buildImportPlan(
        snapshot: ImportPlanningSnapshot,
        additionalReserved: Set<MediaRelativePath> = []
    ) -> MediaOperationPlan {
        let namespace = FilesystemNamespaceSemantics.enumerateNamespace(
            root: snapshot.destinationRoot,
            folders: destinationFolders(for: snapshot),
            capabilities: snapshot.destinationCapabilities
        )
        return planImport(snapshot: snapshot, namespace: namespace, additionalReserved: additionalReserved)
    }
}

private nonisolated extension MediaTransferPlanner {
    /// Plans one naming bundle: every member under one name and one collision suffix,
    /// or the whole bundle blocked. Empty members are excluded first and the rest are
    /// planned as their own bundle.
    // The pure import reservation loop is intentionally cohesive; splitting it only
    // to satisfy arithmetic lint caps would obscure the collision algorithm.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func planBundle(
        _ bundle: ImportNaming.Bundle,
        snapshot: ImportPlanningSnapshot,
        reserved: inout Set<FilesystemNameKey>,
        namespace: DestinationNamespace
    ) -> [MediaOperationPlanEntry] {
        func blockAll(_ reason: MediaOperationBlockReason) -> [MediaOperationPlanEntry] {
            bundle.members.map { member in
                MediaOperationPlanEntry(source: member, companionDestinations: [:], disposition: .blocked(reason))
            }
        }
        let emptyMembers = bundle.members.filter { $0.byteSize == 0 }
        if !emptyMembers.isEmpty {
            let excluded = emptyMembers.map { member in
                MediaOperationPlanEntry(source: member, companionDestinations: [:], disposition: .excluded(.empty))
            }
            let nonEmptyMembers = bundle.members.filter { $0.byteSize != 0 }
            guard !nonEmptyMembers.isEmpty else { return excluded }
            return excluded + planBundle(
                ImportNaming.Bundle(members: nonEmptyMembers),
                snapshot: snapshot,
                reserved: &reserved,
                namespace: namespace
            )
        }
        // Bytes that cannot be opened cannot be copied, whatever the naming policy.
        // Blocking surfaces the file in state D instead of letting it be silently
        // skipped or silently retried forever (ARC-057).
        if bundle.members.contains(where: \.isSourceUnreadable) {
            return blockAll(.sourceUnreadable)
        }
        guard bundle.isNameable(under: snapshot.policy) else {
            return blockAll(.noUsableDate)
        }
        let timestamp = ImportNaming.timestamp(of: bundle, calendar: snapshot.calendar, timeZone: snapshot.timeZone)
        guard let unsuffixed = ImportNaming.destination(
            for: bundle.members[0],
            timestamp: timestamp,
            policy: snapshot.policy,
            suffix: 0
        ) else {
            return blockAll(.noUsableDate)
        }

        for suffix in 0 ..< 10000 {
            var memberDestinations: [(PlanningFileFacts, MediaRelativePath)] = []
            var companionDestinations: [MediaRelativePath: MediaRelativePath] = [:]
            var dispositions: [MediaAssetID: MediaOperationDisposition] = [:]
            var blocked: MediaOperationBlockReason?
            var advanceSuffix = false

            memberLoop: for member in bundle.members {
                guard let relative = ImportNaming.destination(
                    for: member,
                    timestamp: timestamp,
                    policy: snapshot.policy,
                    suffix: suffix
                ) else {
                    return blockAll(.noUsableDate)
                }
                memberDestinations.append((member, relative))

                if snapshot.policy.importSidecarFiles {
                    for companion in member.companions where companion.primaryRelativePath == member.relativePath {
                        companionDestinations[companion.relativePath] = ImportNaming.companionDestination(
                            companion,
                            primaryDestination: relative,
                            policy: snapshot.policy
                        )
                    }
                }

                let decision = decideCandidate(
                    member: member,
                    candidate: relative,
                    snapshot: snapshot,
                    reserved: reserved,
                    namespace: namespace
                )
                switch decision {
                case let .blocked(reason):
                    blocked = reason
                case let .skip(path):
                    dispositions[member.id] = .skipPreexisting(destination: path)
                case let .copy(path):
                    dispositions[member.id] = .copy(destination: path)
                case .advanceSuffix:
                    advanceSuffix = true
                    break memberLoop
                }
            }

            if advanceSuffix {
                continue
            }
            if let blocked {
                return blockAll(blocked)
            }

            for companionPath in companionDestinations.values {
                let companionKey = FilesystemNamespaceSemantics.nameKey(
                    relativePath: companionPath,
                    capabilities: snapshot.destinationCapabilities
                )
                if reserved.contains(companionKey) || snapshot.destinationOccupantKeys.contains(companionKey) {
                    advanceSuffix = true
                    break
                }
                guard let result = namespace.occupancy(of: companionPath) else {
                    // Companion folder unobservable: block rather than risk a
                    // sidecar overwrite on an unread namespace.
                    return blockAll(.filesystemObservationUnavailable(destination: companionPath))
                }
                if case .absent = result {
                    continue
                }
                advanceSuffix = true
                break
            }
            if advanceSuffix {
                continue
            }

            var planned: [MediaOperationPlanEntry] = []
            for (member, relative) in memberDestinations {
                let disposition = dispositions[member.id] ?? .copy(destination: relative)
                planned.append(
                    MediaOperationPlanEntry(
                        source: member,
                        companionDestinations: companionDestinations.filter { key, _ in
                            member.companions.contains { $0.relativePath == key }
                        },
                        disposition: disposition
                    )
                )
                switch disposition {
                case .copy, .skipPreexisting:
                    reserved.insert(FilesystemNamespaceSemantics.nameKey(
                        relativePath: relative,
                        capabilities: snapshot.destinationCapabilities
                    ))
                case .blocked, .excluded:
                    break
                }
            }
            for path in companionDestinations.values {
                reserved.insert(FilesystemNamespaceSemantics.nameKey(
                    relativePath: path,
                    capabilities: snapshot.destinationCapabilities
                ))
            }
            return planned
        }

        return blockAll(.noFreeDestinationName(destination: unsuffixed))
    }

    enum CandidateDecision {
        case copy(MediaRelativePath)
        case skip(MediaRelativePath)
        case blocked(MediaOperationBlockReason)
        case advanceSuffix
    }

    static func decideCandidate(
        member: PlanningFileFacts,
        candidate: MediaRelativePath,
        snapshot: ImportPlanningSnapshot,
        reserved: Set<FilesystemNameKey>,
        namespace: DestinationNamespace
    ) -> CandidateDecision {
        let candidateKey = FilesystemNamespaceSemantics.nameKey(
            relativePath: candidate,
            capabilities: snapshot.destinationCapabilities
        )
        if reserved.contains(candidateKey), !snapshot.destinationOccupantKeys.contains(candidateKey) {
            // Reserved by an earlier planned copy in this plan — never collapse
            // source-internal duplicates into one destination.
            return .advanceSuffix
        }

        if let occupant = namespace.folderOccupant(of: candidate) {
            return .blocked(.destinationFolderOccupied(occupant: occupant))
        }
        guard let probe = namespace.occupancy(of: candidate) else {
            // The candidate's folder was not readable, so freeness is unproven.
            // Blocking keeps an unreadable namespace from planning an overwrite.
            return .blocked(.filesystemObservationUnavailable(destination: candidate))
        }

        switch probe {
        case .absent:
            return .copy(candidate)
        case let .regularFile(byteSize, modifiedAt):
            return catalogDecision(
                member: member,
                candidate: candidate,
                liveByteSize: byteSize,
                liveModifiedAt: modifiedAt
            )
        case .foreign:
            return .advanceSuffix
        }
    }

    static func catalogDecision(
        member: PlanningFileFacts,
        candidate: MediaRelativePath,
        liveByteSize: Int64?,
        liveModifiedAt: Date?
    ) -> CandidateDecision {
        guard let sourceByteSize = member.byteSize,
              let liveByteSize,
              sourceByteSize == liveByteSize,
              let expectedModifiedAt = ImportDestinationDate.expected(for: member),
              datesMatchToFilesystemPrecision(expectedModifiedAt, liveModifiedAt)
        else {
            return .advanceSuffix
        }
        return .skip(candidate)
    }

    static func datesMatchToFilesystemPrecision(_ left: Date?, _ right: Date?) -> Bool {
        guard let left, let right else { return false }
        return Int(left.timeIntervalSince1970) == Int(right.timeIntervalSince1970)
    }

    static func totals(from entries: [MediaOperationPlanEntry]) -> MediaOperationPlanTotals {
        var totals = MediaOperationPlanTotals(
            copyCount: 0,
            skipCount: 0,
            blockedCount: 0,
            companionCopyCount: 0,
            copyBytes: 0,
            excludedCount: 0
        )
        for entry in entries {
            switch entry.disposition {
            case .copy:
                totals.copyCount += 1
                if let size = entry.source.byteSize {
                    totals.copyBytes += size
                } else {
                    totals.unknownSizeCopyCount += 1
                }
                totals.companionCopyCount += entry.companionDestinations.count
            case .skipPreexisting:
                totals.skipCount += 1
            case .blocked:
                totals.blockedCount += 1
            case .excluded:
                totals.excludedCount += 1
            }
        }
        return totals
    }
}
