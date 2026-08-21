import Foundation

// The pure import reservation loop is intentionally cohesive; splitting it only
// to satisfy arithmetic lint caps would obscure the collision algorithm.
// swiftlint:disable cyclomatic_complexity function_body_length function_parameter_count

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
        for bundle in namingBundles(from: snapshot.sourceMedia, policy: snapshot.policy) {
            guard !needsDate(policy: snapshot.policy)
                || !bundle.members.contains(where: { !$0.hasAnyDate })
            else {
                // Undatable bundles are blocked without a destination name,
                // but only when the selected policy actually needs a date.
                continue
            }
            let timestamp = namingTimestamp(for: bundle, snapshot: snapshot)
            guard !needsDate(policy: snapshot.policy) || timestamp != nil else { continue }
            folders.insert(folderPath(timestamp: timestamp, policy: snapshot.policy))
        }
        return folders
    }

    /// Whether the current import policy requires a usable date to name a
    /// destination. Under `.none`/`.original` the timestamp is never consulted,
    /// so an undatable bundle must not be blocked.
    static func needsDate(policy: ImportPolicy) -> Bool {
        policy.destinationFolderPolicy == .yearMonth
            || policy.destinationNamePolicy == .captureDateTime
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
        let bundles = namingBundles(from: snapshot.sourceMedia, policy: snapshot.policy)
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
            sourceOccupancyRevision: snapshot.sourceOccupancyRevision,
            destinationOccupancyRevision: snapshot.destinationOccupancyRevision,
            policy: snapshot.policy,
            entries: entries,
            eraseManifest: eraseManifest,
            totals: totals(from: entries, eraseCount: eraseManifest.count)
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
    struct NamingBundle {
        let members: [PlanningFileFacts]
        let stem: String
        let directoryKey: String
        let wallCompact: Int64?
        let fallbackModifiedAt: Date?
    }

    struct SuffixAttempt {
        var memberDestinations: [(PlanningFileFacts, MediaRelativePath)] = []
        var companionDestinations: [MediaRelativePath: MediaRelativePath] = [:]
        var dispositions: [MediaAssetID: MediaOperationDisposition] = [:]
        var blocked: MediaOperationBlockReason?
        var advanceSuffix = false
    }

    static func namingBundles(
        from media: [PlanningFileFacts],
        policy: ImportPolicy
    ) -> [NamingBundle] {
        let sorted = media.sorted { left, right in
            if policy.destinationNamePolicy == .captureDateTime {
                let leftKey = left.captureWallCompact ?? Int64.max
                let rightKey = right.captureWallCompact ?? Int64.max
                if leftKey != rightKey {
                    return leftKey < rightKey
                }
                let leftDate = left.contentModifiedAt ?? .distantFuture
                let rightDate = right.contentModifiedAt ?? .distantFuture
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
            }
            let leftNatural = MediaSortKey.naturalKey(left.relativePath.rawValue)
            let rightNatural = MediaSortKey.naturalKey(right.relativePath.rawValue)
            if leftNatural != rightNatural {
                return leftNatural < rightNatural
            }
            return left.relativePath.rawValue < right.relativePath.rawValue
        }

        var groups: [String: [PlanningFileFacts]] = [:]
        var order: [String] = []
        for item in sorted {
            let key = MediaCompanionPairing.directoryKey(of: item.relativePath)
                + "\u{1}"
                + MediaCompanionPairing.stem(of: item.relativePath)
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(item)
        }

        return order.compactMap { key in
            guard let members = groups[key], let first = members.first else {
                return nil
            }
            let wall = members.compactMap(\.captureWallCompact).max()
            let fallback = members.compactMap(\.contentModifiedAt).min()
            return NamingBundle(
                members: members,
                stem: MediaCompanionPairing.stem(of: first.relativePath),
                directoryKey: MediaCompanionPairing.directoryKey(of: first.relativePath),
                wallCompact: wall,
                fallbackModifiedAt: fallback
            )
        }
    }

    static func planBundle(
        _ bundle: NamingBundle,
        snapshot: ImportPlanningSnapshot,
        reserved: inout Set<FilesystemNameKey>,
        namespace: DestinationNamespace
    ) -> [MediaOperationPlanEntry] {
        let emptyMembers = bundle.members.filter { $0.byteSize == 0 }
        if !emptyMembers.isEmpty {
            let excluded = emptyMembers.map { member in
                MediaOperationPlanEntry(
                    source: member,
                    idealDestination: member.relativePath,
                    finalDestination: member.relativePath,
                    companionDestinations: [:],
                    disposition: .excluded(.empty)
                )
            }
            let nonEmptyMembers = bundle.members.filter { $0.byteSize != 0 }
            guard !nonEmptyMembers.isEmpty else { return excluded }
            let nonEmptyBundle = NamingBundle(
                members: nonEmptyMembers,
                stem: bundle.stem,
                directoryKey: bundle.directoryKey,
                wallCompact: nonEmptyMembers.compactMap(\.captureWallCompact).max(),
                fallbackModifiedAt: nonEmptyMembers.compactMap(\.contentModifiedAt).min()
            )
            return excluded + planBundle(
                nonEmptyBundle,
                snapshot: snapshot,
                reserved: &reserved,
                namespace: namespace
            )
        }
        if needsDate(policy: snapshot.policy),
           bundle.members.contains(where: { !$0.hasAnyDate })
        {
            return bundle.members.map { member in
                MediaOperationPlanEntry(
                    source: member,
                    idealDestination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                    finalDestination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                    companionDestinations: [:],
                    disposition: .blocked(.noUsableDate)
                )
            }
        }

        let timestamp = namingTimestamp(for: bundle, snapshot: snapshot)
        guard !needsDate(policy: snapshot.policy) || timestamp != nil else {
            return bundle.members.map { member in
                MediaOperationPlanEntry(
                    source: member,
                    idealDestination: member.relativePath,
                    finalDestination: member.relativePath,
                    companionDestinations: [:],
                    disposition: .blocked(.noUsableDate)
                )
            }
        }
        let folder = folderPath(timestamp: timestamp, policy: snapshot.policy)
        guard let baseName = baseFileName(
            stem: bundle.stem,
            timestamp: timestamp,
            policy: snapshot.policy,
            primary: bundle.members[0]
        ) else {
            return bundle.members.map { member in
                MediaOperationPlanEntry(
                    source: member,
                    idealDestination: member.relativePath,
                    finalDestination: member.relativePath,
                    companionDestinations: [:],
                    disposition: .blocked(.noUsableDate)
                )
            }
        }

        for suffix in 0 ..< 10000 {
            let suffixToken = suffix == 0 ? "" : String(format: "_%03d", suffix)
            var memberDestinations: [(PlanningFileFacts, MediaRelativePath)] = []
            var companionDestinations: [MediaRelativePath: MediaRelativePath] = [:]
            var dispositions: [MediaAssetID: MediaOperationDisposition] = [:]
            var blocked: MediaOperationBlockReason?
            var advanceSuffix = false

            memberLoop: for member in bundle.members {
                let memberBaseName = switch snapshot.policy.destinationNamePolicy {
                case .original:
                    URL(fileURLWithPath: member.relativePath.rawValue)
                        .deletingPathExtension()
                        .lastPathComponent
                case .captureDateTime:
                    baseName
                }
                let ext = destinationExtension(for: member, policy: snapshot.policy)
                let fileName = memberBaseName + suffixToken + (ext.isEmpty ? "" : ".\(ext)")
                let relative = MediaRelativePath(
                    rawValue: folder.isEmpty ? fileName : "\(folder)/\(fileName)"
                )
                memberDestinations.append((member, relative))

                if snapshot.policy.importSidecarFiles {
                    for companion in member.companions where companion.primaryRelativePath == member.relativePath {
                        let companionName = memberBaseName + suffixToken + ".\(companion.kind.rawValue)"
                        let companionRelative = MediaRelativePath(
                            rawValue: folder.isEmpty ? companionName : "\(folder)/\(companionName)"
                        )
                        companionDestinations[companion.relativePath] = companionRelative
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
                return bundle.members.map { member in
                    let ideal = memberDestinations.first(where: { $0.0.id == member.id })?.1
                        ?? MediaRelativePath(rawValue: member.relativePath.rawValue)
                    return MediaOperationPlanEntry(
                        source: member,
                        idealDestination: ideal,
                        finalDestination: ideal,
                        companionDestinations: [:],
                        disposition: .blocked(blocked)
                    )
                }
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
                    return bundle.members.map { member in
                        MediaOperationPlanEntry(
                            source: member,
                            idealDestination: companionPath,
                            finalDestination: companionPath,
                            companionDestinations: [:],
                            disposition: .blocked(.filesystemObservationUnavailable(
                                destination: companionPath,
                                detail: "namespaceUnreadable"
                            ))
                        )
                    }
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
                        idealDestination: relative,
                        finalDestination: relative,
                        companionDestinations: companionDestinations.filter { key, _ in
                            member.companions.contains { $0.relativePath == key }
                        },
                        disposition: disposition
                    )
                )
                switch disposition {
                case .copy, .skipPreexisting:
                    reserved.insert(FilesystemNamespaceSemantics.nameKey(relativePath: relative, capabilities: snapshot.destinationCapabilities))
                case .blocked, .relocate, .noOp, .excluded:
                    break
                }
            }
            for path in companionDestinations.values {
                reserved.insert(FilesystemNamespaceSemantics.nameKey(relativePath: path, capabilities: snapshot.destinationCapabilities))
            }
            return planned
        }

        return bundle.members.map { member in
            MediaOperationPlanEntry(
                source: member,
                idealDestination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                finalDestination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                companionDestinations: [:],
                disposition: .blocked(.filesystemObservationUnavailable(
                    destination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                    detail: "suffixExhausted"
                ))
            )
        }
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

        guard let probe = namespace.occupancy(of: candidate) else {
            // The candidate's folder was not readable, so freeness is unproven.
            // Blocking keeps an unreadable namespace from planning an overwrite.
            return .blocked(.filesystemObservationUnavailable(
                destination: candidate,
                detail: "namespaceUnreadable"
            ))
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

    static func namingTimestamp(
        for bundle: NamingBundle,
        snapshot: ImportPlanningSnapshot
    ) -> CaptureWallComponents? {
        ImportNaming.timestamp(
            wallCompact: bundle.wallCompact,
            fallbackModifiedAt: bundle.fallbackModifiedAt,
            calendar: snapshot.calendar,
            timeZone: snapshot.timeZone
        )
    }

    static func folderPath(
        timestamp: CaptureWallComponents?,
        policy: ImportPolicy
    ) -> String {
        switch policy.destinationFolderPolicy {
        case .none:
            ""
        case .yearMonth:
            timestamp?.yearMonthFolder ?? ""
        }
    }

    static func baseFileName(
        stem _: String = "",
        timestamp: CaptureWallComponents?,
        policy: ImportPolicy,
        primary: PlanningFileFacts
    ) -> String? {
        switch policy.destinationNamePolicy {
        case .original:
            URL(fileURLWithPath: primary.relativePath.rawValue).deletingPathExtension().lastPathComponent
        case .captureDateTime:
            timestamp?.dateTimeFileName
        }
    }

    static func destinationExtension(for member: PlanningFileFacts, policy: ImportPolicy) -> String {
        switch policy.destinationNamePolicy {
        case .original:
            member.fileExtension
        case .captureDateTime:
            CanonicalMediaExtension.forDateTimeName(
                contentTypeIdentifier: member.contentTypeIdentifier,
                sourceExtension: member.fileExtension
            )
        }
    }

    static func totals(from entries: [MediaOperationPlanEntry], eraseCount: Int = 0) -> MediaOperationPlanTotals {
        var totals = MediaOperationPlanTotals(
            copyCount: 0,
            skipCount: 0,
            blockedCount: 0,
            companionCopyCount: 0,
            copyBytes: 0,
            excludedCount: 0,
            eraseCount: eraseCount
        )
        for entry in entries {
            switch entry.disposition {
            case .copy:
                totals.copyCount += 1
                totals.copyBytes += entry.source.byteSize ?? 0
                totals.companionCopyCount += entry.companionDestinations.count
            case .skipPreexisting:
                totals.skipCount += 1
            case .blocked:
                totals.blockedCount += 1
            case .excluded:
                totals.excludedCount += 1
            case .relocate, .noOp:
                break
            }
        }
        return totals
    }
}
