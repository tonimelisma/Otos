import Foundation

// The pure import reservation loop is intentionally cohesive; splitting it only
// to satisfy arithmetic lint caps would obscure the collision algorithm.
// swiftlint:disable cyclomatic_complexity function_body_length function_parameter_count

/// Media transfer planner guide
///
/// Nonisolated pure planning for import (and later reorganization). Accepts only
/// immutable Sendable values; performs no I/O, database calls, logging, or actor
/// hops. Occupancy and equality are expressed as typed requests; the caller
/// resolves them and resumes until `.ready`.
///
/// Import collision policy (plan 0055 §7.2): absent → copy; catalog equal-size →
/// compare; unequal/different size/foreign/reserved → next suffix; unprovable →
/// blocked. Naming bundles share one timestamp, stem, and suffix.
nonisolated enum MediaTransferPlanner {
    static func planImport(
        snapshot: ImportPlanningSnapshot,
        occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:],
        comparisons: [ComparisonRequest: ComparisonResult] = [:]
    ) -> ImportPlanBuildOutcome {
        var occupancyRequests: [NamespaceOccupancyRequest] = []
        var comparisonRequests: [ComparisonRequest] = []
        var reserved = Set(snapshot.destinationOccupants.keys)
        reserved.formUnion(snapshot.knownForeignOccupants)

        let bundles = namingBundles(from: snapshot.sourceMedia, policy: snapshot.policy)
        var entries: [MediaOperationPlanEntry] = []

        for bundle in bundles {
            let outcome = planBundle(
                bundle,
                snapshot: snapshot,
                reserved: &reserved,
                occupancy: occupancy,
                comparisons: comparisons,
                pendingOccupancy: &occupancyRequests,
                pendingComparisons: &comparisonRequests
            )
            switch outcome {
            case let .entries(planned):
                entries.append(contentsOf: planned)
            case .needsProbes:
                return .needsProbes(
                    occupancy: uniqueOccupancy(occupancyRequests),
                    comparisons: uniqueComparisons(comparisonRequests)
                )
            }
        }

        if !occupancyRequests.isEmpty || !comparisonRequests.isEmpty {
            return .needsProbes(
                occupancy: uniqueOccupancy(occupancyRequests),
                comparisons: uniqueComparisons(comparisonRequests)
            )
        }

        return .ready(
            MediaOperationPlan(
                generation: snapshot.generation,
                mode: .import(
                    source: snapshot.sourceRoot,
                    destination: snapshot.destinationRoot,
                    batch: ImportBatchID()
                ),
                sourceRevision: snapshot.sourceRevision,
                destinationRevision: snapshot.destinationRevision,
                policy: snapshot.policy,
                entries: entries,
                totals: totals(from: entries)
            )
        )
    }

    /// Synchronous driver for tests and Stage D coordinator: resolve probes until ready.
    static func buildImportPlan(
        snapshot: ImportPlanningSnapshot,
        equality: ContentEqualityChecker,
        knownForeignOccupants: Set<MediaRelativePath> = []
    ) -> MediaOperationPlan {
        var occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:]
        var comparisons: [ComparisonRequest: ComparisonResult] = [:]
        var foreign = knownForeignOccupants.union(snapshot.knownForeignOccupants)
        for _ in 0 ..< 10000 {
            switch planImport(snapshot: snapshot, occupancy: occupancy, comparisons: comparisons) {
            case let .ready(plan):
                return plan
            case let .needsProbes(occupancyRequests, comparisonRequests):
                let resolvedOccupancy = FilesystemNamespaceSemantics.resolve(
                    occupancyRequests,
                    knownForeignOccupants: foreign
                )
                for (request, result) in resolvedOccupancy {
                    occupancy[request] = result
                }
                let resolvedComparisons = equality.resolve(comparisonRequests)
                for (request, result) in resolvedComparisons {
                    comparisons[request] = result
                }
            }
        }
        preconditionFailure("import planner failed to converge")
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

    struct CaptureWallComponents: Equatable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int

        var dateTimeFileName: String {
            String(
                format: "%04d%02d%02d_%02d%02d%02d",
                year, month, day, hour, minute, second
            )
        }

        var yearMonthFolder: String {
            String(format: "%04d/%02d", year, month)
        }
    }

    enum BundlePlanOutcome {
        case entries([MediaOperationPlanEntry])
        case needsProbes
    }

    struct ProbeBuffers {
        var occupancy: [NamespaceOccupancyRequest] = []
        var comparisons: [ComparisonRequest] = []
    }

    struct SuffixAttempt {
        var memberDestinations: [(PlanningFileFacts, MediaRelativePath)] = []
        var companionDestinations: [MediaRelativePath: MediaRelativePath] = [:]
        var dispositions: [MediaAssetID: MediaOperationDisposition] = [:]
        var blocked: MediaOperationBlockReason?
        var advanceSuffix = false
        var needsProbes = false
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
        reserved: inout Set<MediaRelativePath>,
        occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult],
        comparisons: [ComparisonRequest: ComparisonResult],
        pendingOccupancy: inout [NamespaceOccupancyRequest],
        pendingComparisons: inout [ComparisonRequest]
    ) -> BundlePlanOutcome {
        if bundle.members.contains(where: { !$0.hasUsableDate }) {
            return .entries(bundle.members.map { member in
                MediaOperationPlanEntry(
                    source: member,
                    idealDestination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                    finalDestination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                    companionDestinations: [:],
                    disposition: .blocked(.noUsableDate)
                )
            })
        }

        let timestamp = namingTimestamp(for: bundle, snapshot: snapshot)
        let folder = folderPath(timestamp: timestamp, policy: snapshot.policy)
        let baseName = baseFileName(
            stem: bundle.stem,
            timestamp: timestamp,
            policy: snapshot.policy,
            primary: bundle.members[0]
        )

        for suffix in 0 ..< 10000 {
            let suffixToken = suffix == 0 ? "" : String(format: "_%03d", suffix)
            var memberDestinations: [(PlanningFileFacts, MediaRelativePath)] = []
            var companionDestinations: [MediaRelativePath: MediaRelativePath] = [:]
            var dispositions: [MediaAssetID: MediaOperationDisposition] = [:]
            var blocked: MediaOperationBlockReason?
            var advanceSuffix = false

            memberLoop: for member in bundle.members {
                let ext = member.fileExtension.lowercased()
                let fileName = baseName + suffixToken + (ext.isEmpty ? "" : ".\(ext)")
                let relative = MediaRelativePath(
                    rawValue: folder.isEmpty ? fileName : "\(folder)/\(fileName)"
                )
                memberDestinations.append((member, relative))

                if snapshot.policy.importSidecarFiles {
                    for companion in member.companions where companion.primaryRelativePath == member.relativePath {
                        let companionName = baseName + suffixToken + ".\(companion.kind.rawValue)"
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
                    occupancy: occupancy,
                    comparisons: comparisons,
                    pendingOccupancy: &pendingOccupancy,
                    pendingComparisons: &pendingComparisons
                )
                switch decision {
                case .needsProbes:
                    return .needsProbes
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
                return .entries(bundle.members.map { member in
                    let ideal = memberDestinations.first(where: { $0.0.id == member.id })?.1
                        ?? MediaRelativePath(rawValue: member.relativePath.rawValue)
                    return MediaOperationPlanEntry(
                        source: member,
                        idealDestination: ideal,
                        finalDestination: ideal,
                        companionDestinations: [:],
                        disposition: .blocked(blocked)
                    )
                })
            }

            for companionPath in companionDestinations.values {
                if reserved.contains(companionPath)
                    || snapshot.destinationOccupants[companionPath] != nil
                    || snapshot.knownForeignOccupants.contains(companionPath)
                {
                    advanceSuffix = true
                    break
                }
                let request = NamespaceOccupancyRequest(
                    rootPath: snapshot.destinationRoot,
                    relativePath: companionPath
                )
                guard let result = occupancy[request] else {
                    pendingOccupancy.append(request)
                    return .needsProbes
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
                    reserved.insert(relative)
                case .blocked, .relocate, .noOp:
                    break
                }
            }
            for path in companionDestinations.values {
                reserved.insert(path)
            }
            return .entries(planned)
        }

        return .entries(bundle.members.map { member in
            MediaOperationPlanEntry(
                source: member,
                idealDestination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                finalDestination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                companionDestinations: [:],
                disposition: .blocked(.comparisonUnavailable(
                    destination: MediaRelativePath(rawValue: member.relativePath.rawValue),
                    detail: "suffixExhausted"
                ))
            )
        })
    }

    enum CandidateDecision {
        case copy(MediaRelativePath)
        case skip(MediaRelativePath)
        case blocked(MediaOperationBlockReason)
        case advanceSuffix
        case needsProbes
    }

    static func decideCandidate(
        member: PlanningFileFacts,
        candidate: MediaRelativePath,
        snapshot: ImportPlanningSnapshot,
        reserved: Set<MediaRelativePath>,
        occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult],
        comparisons: [ComparisonRequest: ComparisonResult],
        pendingOccupancy: inout [NamespaceOccupancyRequest],
        pendingComparisons: inout [ComparisonRequest]
    ) -> CandidateDecision {
        if reserved.contains(candidate), snapshot.destinationOccupants[candidate] == nil {
            // Reserved by an earlier planned copy in this plan — never collapse
            // source-internal duplicates via equality.
            return .advanceSuffix
        }

        let request = NamespaceOccupancyRequest(
            rootPath: snapshot.destinationRoot,
            relativePath: candidate
        )
        guard let probe = occupancy[request] else {
            pendingOccupancy.append(request)
            return .needsProbes
        }

        switch probe {
        case .absent:
            if let catalog = snapshot.destinationOccupants[candidate] {
                return catalogDecision(
                    member: member,
                    candidate: candidate,
                    catalog: catalog,
                    snapshot: snapshot,
                    comparisons: comparisons,
                    pendingComparisons: &pendingComparisons
                )
            }
            return .copy(candidate)
        case let .regularFile(byteSize, modifiedAt):
            if let catalog = snapshot.destinationOccupants[candidate] {
                return catalogDecision(
                    member: member,
                    candidate: candidate,
                    catalog: catalog,
                    snapshot: snapshot,
                    comparisons: comparisons,
                    pendingComparisons: &pendingComparisons
                )
            }
            // Live regular file not in catalog → foreign for equality purposes.
            _ = byteSize
            _ = modifiedAt
            return .advanceSuffix
        case .foreign:
            return .advanceSuffix
        }
    }

    static func catalogDecision(
        member: PlanningFileFacts,
        candidate: MediaRelativePath,
        catalog: DestinationOccupantFacts,
        snapshot: ImportPlanningSnapshot,
        comparisons: [ComparisonRequest: ComparisonResult],
        pendingComparisons: inout [ComparisonRequest]
    ) -> CandidateDecision {
        guard member.byteSize != nil, catalog.byteSize != nil, member.byteSize == catalog.byteSize else {
            return .advanceSuffix
        }
        let comparison = ComparisonRequest(
            sourceRoot: snapshot.sourceRoot,
            sourceRelativePath: member.relativePath,
            sourceByteSize: member.byteSize,
            sourceModifiedAt: member.contentModifiedAt,
            destinationRoot: snapshot.destinationRoot,
            destinationRelativePath: candidate,
            destinationByteSize: catalog.byteSize,
            destinationModifiedAt: catalog.contentModifiedAt,
            sourceURL: member.sourceURL,
            destinationURL: snapshot.destinationRoot.url.appending(
                path: candidate.rawValue,
                directoryHint: .notDirectory
            )
        )
        guard let result = comparisons[comparison] else {
            pendingComparisons.append(comparison)
            return .needsProbes
        }
        switch result {
        case .equal:
            return .skip(candidate)
        case .unequal:
            return .advanceSuffix
        case let .unavailable(detail):
            return .blocked(.comparisonUnavailable(destination: candidate, detail: detail))
        case .requiresMaterialization:
            return .blocked(.comparisonRequiresMaterialization(destination: candidate))
        }
    }

    static func namingTimestamp(
        for bundle: NamingBundle,
        snapshot: ImportPlanningSnapshot
    ) -> CaptureWallComponents {
        if let compact = bundle.wallCompact {
            return expandCompact(compact)
        }
        let date = bundle.fallbackModifiedAt ?? Date(timeIntervalSince1970: 0)
        var calendar = snapshot.calendar
        calendar.timeZone = snapshot.timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return CaptureWallComponents(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0
        )
    }

    static func expandCompact(_ compact: Int64) -> CaptureWallComponents {
        CaptureWallComponents(
            year: Int(compact / 10_000_000_000),
            month: Int((compact / 100_000_000) % 100),
            day: Int((compact / 1_000_000) % 100),
            hour: Int((compact / 10000) % 100),
            minute: Int((compact / 100) % 100),
            second: Int(compact % 100)
        )
    }

    static func folderPath(
        timestamp: CaptureWallComponents,
        policy: ImportPolicy
    ) -> String {
        switch policy.destinationFolderPolicy {
        case .none:
            ""
        case .yearMonth:
            timestamp.yearMonthFolder
        }
    }

    static func baseFileName(
        stem _: String = "",
        timestamp: CaptureWallComponents,
        policy: ImportPolicy,
        primary: PlanningFileFacts
    ) -> String {
        switch policy.destinationNamePolicy {
        case .original:
            URL(fileURLWithPath: primary.relativePath.rawValue).deletingPathExtension().lastPathComponent
        case .captureDateTime:
            timestamp.dateTimeFileName
        }
    }

    static func totals(from entries: [MediaOperationPlanEntry]) -> MediaOperationPlanTotals {
        var totals = MediaOperationPlanTotals(
            copyCount: 0,
            skipCount: 0,
            blockedCount: 0,
            companionCopyCount: 0,
            copyBytes: 0
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
            case .relocate, .noOp:
                break
            }
        }
        return totals
    }

    static func uniqueOccupancy(_ requests: [NamespaceOccupancyRequest]) -> [NamespaceOccupancyRequest] {
        var seen = Set<NamespaceOccupancyRequest>()
        return requests.filter { seen.insert($0).inserted }
    }

    static func uniqueComparisons(_ requests: [ComparisonRequest]) -> [ComparisonRequest] {
        var seen = Set<ComparisonRequest>()
        return requests.filter { seen.insert($0).inserted }
    }
}
