import Foundation
import OSLog

/// Orchestrates one fixed-library reorganization run (ARC-051).
///
/// Plans via `ReorganizationPlanner`, journals/executes each component, settles
/// catalog identities, and returns remap batches for ViewModel/TileContentStore.
actor LibraryReorganizationRunner {
    private let store: CatalogStore
    /// The actor owns this instance for the injected domain. Callers transfer only
    /// the Sendable domain value, never a shared UserDefaults reference (ARC-042).
    private let preferences: UserDefaults
    private let preferencesDomain: PreferencesDomain

    init(store: CatalogStore, preferencesDomain: PreferencesDomain) {
        self.store = store
        self.preferencesDomain = preferencesDomain
        preferences = preferencesDomain.makeDefaults()
    }

    enum Outcome: Equatable, Sendable {
        case completed(remapBatches: [CatalogIdentityRemapBatch], noOpCount: Int, relocateCount: Int)
        case needsConfirmation(summary: ReorganizationPlanSummary)
        case blocked(reason: String)
        case cancelled
        case failed(reason: String)
    }

    struct ReorganizationPlanSummary: Equatable, Sendable {
        let libraryRoot: LibraryRootPath
        let noOpCount: Int
        let relocateCount: Int
        let blockedCount: Int
        let componentCount: Int
    }

    /// Interprets durable component phases before Store starts filesystem scans.
    /// Store owns each transaction and scan-exclusion lease; this operation owner
    /// decides what recovery action each journal state requires.
    nonisolated static func recoverJournal(store: CatalogStore) async throws {
        let components = try await store.activeReorganizationComponents()
        for component in components {
            switch component.phase {
            case .catalogCommitted:
                try await store.discardCommittedReorganizationComponent(component.componentKey)
            case .filesystemComplete:
                OtosLog.catalog.notice(
                    // swiftlint:disable:next line_length
                    "op=reorganization.recover phase=retrySettlement key=\(component.componentKey.rawValue, privacy: .public)"
                )
                do {
                    _ = try await store.settleReorganizationComponent(
                        key: component.componentKey,
                        remaps: identityRemaps(for: component)
                    )
                } catch {
                    OtosLog.catalog.error(
                        // swiftlint:disable:next line_length
                        "op=reorganization.recover phase=settlementFailed key=\(component.componentKey.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
            case .prepared, .moving, .rollingBack, .blocked:
                OtosLog.catalog.notice(
                    // swiftlint:disable:next line_length
                    "op=reorganization.recover phase=retainJournal key=\(component.componentKey.rawValue, privacy: .public) componentPhase=\(component.phase.rawValue, privacy: .public)"
                )
                _ = await store.acquireReorganizationLease(for: component.libraryRootPath)
            }
        }
    }

    private nonisolated static func identityRemaps(
        for component: ActiveReorganizationComponent
    ) -> [CatalogIdentityRemap] {
        component.members.compactMap { member in
            guard member.kind == .media else { return nil }
            return CatalogIdentityRemap(
                oldID: MediaAssetID(
                    libraryRootPath: component.libraryRootPath,
                    relativePath: member.logicalSourceRelativePath
                ),
                newID: MediaAssetID(
                    libraryRootPath: component.libraryRootPath,
                    relativePath: member.finalRelativePath
                )
            )
        }
    }

    /// Builds a ready plan (resolving occupancy probes) without mutating the filesystem.
    func preview(libraryRoot: LibraryRootPath) async -> Outcome {
        switch await buildReadyPlan(libraryRoot: libraryRoot) {
        case let .ready(plan):
            .needsConfirmation(
                summary: ReorganizationPlanSummary(
                    libraryRoot: libraryRoot,
                    noOpCount: plan.noOpCount,
                    relocateCount: plan.relocateCount,
                    blockedCount: plan.blockedCount,
                    componentCount: plan.components.count
                )
            )
        case let .blocked(reason):
            .blocked(reason: reason)
        case let .failed(reason):
            .failed(reason: reason)
        }
    }

    /// Executes a confirmed reorganization for one fixed library.
    // Component loop + lease/settlement is intentionally cohesive.
    // swiftlint:disable:next function_body_length
    func run(libraryRoot: LibraryRootPath) async -> Outcome {
        guard let lease = await store.acquireReorganizationLease(for: libraryRoot) else {
            return .failed(reason: "leaseUnavailable")
        }

        let built = await buildReadyPlan(libraryRoot: libraryRoot)
        guard case let .ready(plan) = built else {
            _ = await store.releaseReorganizationLease(lease)
            if case let .blocked(reason) = built {
                return .blocked(reason: reason)
            }
            if case let .failed(reason) = built {
                return .failed(reason: reason)
            }
            return .failed(reason: "planUnavailable")
        }

        if plan.components.isEmpty {
            _ = await store.releaseReorganizationLease(lease)
            return .completed(remapBatches: [], noOpCount: plan.noOpCount, relocateCount: 0)
        }

        let rootURL = libraryRoot.url
        var factsByPath: [MediaRelativePath: (byteSize: Int64, contentModifiedAt: Date)] = [:]
        // Prefer snapshot facts from planning media via Store query.
        if let snapshotMedia = await store.planningMedia(for: libraryRoot) {
            for item in snapshotMedia {
                if let size = item.byteSize, let modified = item.contentModifiedAt {
                    factsByPath[item.relativePath] = (size, modified)
                }
                for companion in item.companions {
                    if let size = companion.byteSize, let modified = companion.contentModifiedAt {
                        factsByPath[companion.relativePath] = (size, modified)
                    }
                }
            }
        }

        var remapBatches: [CatalogIdentityRemapBatch] = []
        for plannerComponent in plan.components {
            guard let journal = ReorganizationExecutor.makeJournalComponent(
                plan: plan,
                plannerComponent: plannerComponent,
                snapshot: ReorganizationPlanningSnapshot(
                    libraryRoot: plan.libraryRoot,
                    volumeIdentifier: "run",
                    capabilities: .caseInsensitiveAPFS,
                    generation: plan.generation,
                    rootRevision: plan.rootRevision,
                    policy: plan.policy,
                    media: [],
                    knownForeignOccupants: []
                ),
                factsByPath: factsByPath
            ) else {
                _ = await store.releaseReorganizationLease(lease)
                return .failed(reason: "journalBuildFailed")
            }

            do {
                try await store.prepareReorganizationComponent(journal)
            } catch {
                _ = await store.releaseReorganizationLease(lease)
                return .failed(reason: "journalInsert")
            }

            let key = journal.componentKey
            let outcome = await ReorganizationExecutor.executeComponent(
                component: journal,
                rootURL: rootURL,
                markWillMove: { step in
                    try await self.store.recordReorganizationMoveIntent(
                        key: key,
                        stepIndex: step.stepIndex
                    )
                },
                markDidMove: { step, _ in
                    try await self.store.recordReorganizationMoveCompletion(
                        key: key,
                        step: step,
                        nextStepIndex: step.stepIndex + 1
                    )
                },
                markFilesystemComplete: {
                    try await self.store.recordReorganizationFilesystemCompletion(
                        key: key,
                        nextStepIndex: journal.steps.count
                    )
                },
                shouldContinue: { true }
            )

            switch outcome {
            case .filesystemComplete:
                let remaps = journal.members.compactMap { member -> CatalogIdentityRemap? in
                    guard member.kind == .media else { return nil }
                    return CatalogIdentityRemap(
                        oldID: MediaAssetID(
                            libraryRootPath: libraryRoot,
                            relativePath: member.logicalSourceRelativePath
                        ),
                        newID: MediaAssetID(
                            libraryRootPath: libraryRoot,
                            relativePath: member.finalRelativePath
                        )
                    )
                }
                do {
                    let batch = try await store.settleReorganizationComponent(key: key, remaps: remaps)
                    remapBatches.append(batch)
                } catch {
                    _ = await store.releaseReorganizationLease(lease)
                    return .failed(reason: "settlementFailed")
                }
            case .cancelled:
                _ = await store.releaseReorganizationLease(lease)
                return .cancelled
            case let .blocked(reason), let .failed(reason):
                _ = await store.releaseReorganizationLease(lease)
                return .failed(reason: reason)
            }
        }

        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=reorganization.run phase=finish rootPath=\(libraryRoot.rawValue, privacy: .public) components=\(remapBatches.count, privacy: .public)"
        )
        _ = await store.releaseReorganizationLease(lease)
        return .completed(
            remapBatches: remapBatches,
            noOpCount: plan.noOpCount,
            relocateCount: plan.relocateCount
        )
    }

    private enum BuildResult {
        case ready(ReorganizationPlan)
        case blocked(String)
        case failed(String)
    }

    private func buildReadyPlan(libraryRoot: LibraryRootPath) async -> BuildResult {
        guard let media = await store.planningMedia(for: libraryRoot),
              let revision = await store.planRevision(for: libraryRoot)
        else {
            return .failed("snapshotUnavailable")
        }
        let policy = ImportPolicy.from(ImportPreferencesStore.load(defaults: preferences))
        let capabilities = FilesystemNamespaceSemantics.probeVolumeCapabilities(rootURL: libraryRoot.url)
        var occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:]
        let snapshot = ReorganizationPlanningSnapshot(
            libraryRoot: libraryRoot,
            volumeIdentifier: libraryRoot.rawValue,
            capabilities: capabilities,
            generation: 1,
            rootRevision: revision,
            policy: policy,
            media: media,
            knownForeignOccupants: []
        )
        for _ in 0 ..< 8 {
            let outcome = ReorganizationPlanner.plan(snapshot: snapshot, occupancy: occupancy)
            switch outcome {
            case let .ready(plan):
                return .ready(plan)
            case let .needsProbes(requests):
                for request in requests {
                    occupancy[request] = FilesystemNamespaceSemantics.occupancy(
                        rootPath: request.rootPath,
                        relativePath: request.relativePath
                    )
                }
            case let .blocked(reason):
                return .blocked(reason)
            }
        }
        return .failed("probeLoopExhausted")
    }
}
