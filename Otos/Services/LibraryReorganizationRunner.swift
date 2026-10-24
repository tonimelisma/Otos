import Foundation
import OSLog

/// Orchestrates one fixed-library reorganization run (ARC-051).
///
/// Plans via `ReorganizationPlanner`, journals/executes each component, settles
/// catalog identities, and returns remap batches for ViewModel/TileContentStore.
actor LibraryReorganizationRunner {
    private let store: CatalogStore
    /// The actor owns this instance for the injected domain. Callers transfer only
    /// the Sendable domain value, never a shared PreferenceStore reference (ARC-042).
    private let preferences: any PreferenceStore
    private let preferencesDomain: PreferencesDomain

    init(store: CatalogStore, preferencesDomain: PreferencesDomain) {
        self.store = store
        self.preferencesDomain = preferencesDomain
        preferences = preferencesDomain.makeDefaults()
    }

    enum Outcome: Equatable, Sendable {
        /// Every component finished and settled.
        case completed(relocatedCount: Int)
        /// The library's plan differs from the one the user last confirmed (or none was
        /// confirmed yet): this is what running it now would do.
        case needsConfirmation(summary: ReorganizationPlanSummary)
        /// Nothing was changed: the run could not start.
        case unavailable(ReorganizationUnavailability)
        /// The run started and stopped partway. Components before the failing one are
        /// settled; the failing one was rolled back unless `libraryRestored` is false.
        case stopped(ReorganizationStop)
    }

    struct ReorganizationPlanSummary: Equatable, Sendable {
        let libraryRoot: LibraryRootPath
        /// The library revision this plan was built from. A run confirmed against it
        /// proceeds only while the library is still at it.
        let rootRevision: UInt64
        let noOpCount: Int
        let relocateCount: Int
        let blockedCount: Int
        let componentCount: Int
    }

    /// Interprets durable component phases before Store starts filesystem scans.
    /// Store owns each transaction and scan-exclusion lease; this operation owner
    /// decides what recovery action each journal state requires: a component that was
    /// moving resumes, one whose files all moved settles, and one that was rolling back
    /// (or was stuck rolling back) resumes its rollback. Every resolved component
    /// releases its lease; a component still stuck keeps the root under it.
    nonisolated static func recoverJournal(store: CatalogStore) async throws {
        let components = try await store.activeReorganizationComponents()
        for component in components {
            let root = component.libraryRootPath
            guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
                for: root,
                owner: .reorganization
            ) else {
                OtosLog.catalog.errorOperation("reorganization.recover", phase: "leaseUnavailable", fields: [
                    "key": component.componentKey.rawValue,
                    "rootPath": root.rawValue,
                ])
                continue
            }
            OtosLog.catalog.noticeOperation("reorganization.recover", phase: "start", fields: [
                "key": component.componentKey.rawValue,
                "componentPhase": component.phase.rawValue,
            ])
            let resolved = await finish(component, store: store)
            if resolved {
                _ = await store.releaseNamespaceMutationLease(lease)
            }
        }
    }

    /// Drives one journaled component to an end state: settled, or rolled back. Returns
    /// whether it got there; a component stuck rolling back stays journaled and blocked.
    private nonisolated static func finish(
        _ component: ActiveReorganizationComponent,
        store: CatalogStore
    ) async -> Bool {
        let rootURL = component.libraryRootPath.url
        switch component.phase {
        case .prepared, .moving, .filesystemComplete:
            let forward: ReorganizationExecutionOutcome = component.phase == .filesystemComplete
                ? .filesystemComplete
                : await ReorganizationExecutor.executeComponent(component, rootURL: rootURL, store: store)
            if case .filesystemComplete = forward {
                do {
                    try await store.settleReorganizationComponent(key: component.componentKey)
                    return true
                } catch {
                    OtosLog.catalog.errorOperation("reorganization.settle", phase: "failed", fields: [
                        "key": component.componentKey.rawValue,
                        "error": String(describing: error),
                    ])
                }
            }
            return await rollBack(component.componentKey, store: store)
        case .rollingBack, .blocked:
            return await rollBack(component.componentKey, store: store)
        }
    }

    /// Rolls back from the journal as it stands now, which records every step the
    /// forward pass completed.
    private nonisolated static func rollBack(_ key: ReorganizationComponentKey, store: CatalogStore) async -> Bool {
        let current: ActiveReorganizationComponent?
        do {
            current = try await store.activeReorganizationComponents().first { $0.componentKey == key }
        } catch {
            OtosLog.catalog.errorOperation("reorganization.rollback", phase: "journalUnreadable", fields: [
                "key": key.rawValue,
                "error": String(describing: error),
            ])
            return false
        }
        guard let current else {
            return true
        }
        switch await ReorganizationExecutor.rollBackComponent(
            current,
            rootURL: current.libraryRootPath.url,
            store: store
        ) {
        case .restored:
            return true
        case .stuck:
            return false
        }
    }

    /// Builds a ready plan (resolving occupancy probes) without mutating the filesystem.
    func preview(libraryRoot: LibraryRootPath) async -> Outcome {
        switch await buildReadyPlan(libraryRoot: libraryRoot) {
        case let .ready(plan):
            .needsConfirmation(summary: Self.summary(of: plan))
        case let .unavailable(reason):
            .unavailable(reason)
        }
    }

    /// Executes a reorganization the user confirmed for `confirmedRevision`. Each
    /// component either settles whole or is rolled back; a failure stops the run there
    /// and leaves every later component untouched. Identity remaps reach the window
    /// through the catalog (ARC-052), never through this outcome, so a run that stops
    /// partway delivers the components it did settle exactly like a complete one.
    func run(libraryRoot: LibraryRootPath, confirmedRevision: UInt64) async -> Outcome {
        let lease: RootNamespaceMutationLease
        let acquisition = await store.acquireNamespaceMutationLease(for: libraryRoot, owner: .reorganization)
        switch acquisition {
        case let .acquired(acquired):
            lease = acquired
        case let .busy(owner):
            return .unavailable(.libraryBusy(owner))
        case .rootNotRegistered:
            return .unavailable(.libraryUnavailable)
        case .catalogUnavailable:
            return .unavailable(.catalogUnreadable)
        }

        let plan: ReorganizationPlan
        switch await buildReadyPlan(libraryRoot: libraryRoot) {
        case let .ready(ready):
            plan = ready
        case let .unavailable(reason):
            _ = await store.releaseNamespaceMutationLease(lease)
            return .unavailable(reason)
        }
        guard plan.rootRevision == confirmedRevision else {
            _ = await store.releaseNamespaceMutationLease(lease)
            OtosLog.catalog.noticeOperation("reorganization.run", phase: "reconfirm", fields: [
                "rootPath": libraryRoot.rawValue,
                "confirmedRevision": "\(confirmedRevision)",
                "currentRevision": "\(plan.rootRevision)",
            ])
            return .needsConfirmation(summary: Self.summary(of: plan))
        }

        guard let factsByPath = await memberFacts(libraryRoot: libraryRoot) else {
            _ = await store.releaseNamespaceMutationLease(lease)
            return .unavailable(.catalogUnreadable)
        }
        let rootURL = libraryRoot.url
        var relocatedCount = 0
        for (index, plannerComponent) in plan.components.enumerated() {
            let progress = ReorganizationStop.Progress(
                settledComponentCount: index,
                componentCount: plan.components.count,
                relocatedCount: relocatedCount
            )
            guard let journal = ReorganizationExecutor.makeJournalComponent(
                plan: plan,
                plannerComponent: plannerComponent,
                factsByPath: factsByPath
            ) else {
                // The plan names a member the catalog no longer has facts for. Nothing
                // of this component moved.
                _ = await store.releaseNamespaceMutationLease(lease)
                return stop(.libraryChanged, progress: progress, libraryRestored: true, root: libraryRoot)
            }
            do {
                try await store.prepareReorganizationComponent(journal)
            } catch {
                _ = await store.releaseNamespaceMutationLease(lease)
                return stop(.journalWrite, progress: progress, libraryRestored: true, root: libraryRoot)
            }

            let fault: ReorganizationFault
            switch await ReorganizationExecutor.executeComponent(journal, rootURL: rootURL, store: store) {
            case .filesystemComplete:
                do {
                    try await store.settleReorganizationComponent(key: journal.componentKey)
                    relocatedCount += journal.members.count(where: { $0.kind == .media })
                    continue
                } catch {
                    OtosLog.catalog.errorOperation("reorganization.settle", phase: "failed", fields: [
                        "key": journal.componentKey.rawValue,
                        "error": String(describing: error),
                    ])
                    fault = .journalWrite
                }
            case let .stopped(stopFault):
                fault = stopFault
            }
            let restored = await Self.rollBack(journal.componentKey, store: store)
            if restored {
                _ = await store.releaseNamespaceMutationLease(lease)
            }
            return stop(fault, progress: progress, libraryRestored: restored, root: libraryRoot)
        }

        OtosLog.catalog.noticeOperation("reorganization.run", phase: "finish", fields: [
            "rootPath": libraryRoot.rawValue,
            "components": "\(plan.components.count)",
            "relocated": "\(relocatedCount)",
        ])
        _ = await store.releaseNamespaceMutationLease(lease)
        return .completed(relocatedCount: relocatedCount)
    }

    private func stop(
        _ fault: ReorganizationFault,
        progress: ReorganizationStop.Progress,
        libraryRestored: Bool,
        root: LibraryRootPath
    ) -> Outcome {
        OtosLog.catalog.errorOperation("reorganization.run", phase: "stopped", fields: [
            "rootPath": root.rawValue,
            "fault": fault.logCode,
            "settledComponents": "\(progress.settledComponentCount)",
            "components": "\(progress.componentCount)",
            "libraryRestored": "\(libraryRestored)",
        ])
        return .stopped(ReorganizationStop(fault: fault, progress: progress, libraryRestored: libraryRestored))
    }

    private static func summary(of plan: ReorganizationPlan) -> ReorganizationPlanSummary {
        ReorganizationPlanSummary(
            libraryRoot: plan.libraryRoot,
            rootRevision: plan.rootRevision,
            noOpCount: plan.noOpCount,
            relocateCount: plan.relocateCount,
            blockedCount: plan.blockedCount,
            componentCount: plan.components.count
        )
    }

    /// Size and modification date for every media and companion path the catalog knows,
    /// which the journal records so recovery can tell a moved file from a different one.
    private func memberFacts(
        libraryRoot: LibraryRootPath
    ) async -> [MediaRelativePath: (byteSize: Int64, contentModifiedAt: Date)]? {
        guard let media = await store.planningMedia(for: libraryRoot) else {
            return nil
        }
        var factsByPath: [MediaRelativePath: (byteSize: Int64, contentModifiedAt: Date)] = [:]
        for item in media {
            if let size = item.byteSize, let modified = item.contentModifiedAt {
                factsByPath[item.relativePath] = (size, modified)
            }
            for companion in item.companions {
                if let size = companion.byteSize, let modified = companion.contentModifiedAt {
                    factsByPath[companion.relativePath] = (size, modified)
                }
            }
        }
        return factsByPath
    }

    private enum BuildResult {
        case ready(ReorganizationPlan)
        case unavailable(ReorganizationUnavailability)
    }

    private func buildReadyPlan(libraryRoot: LibraryRootPath) async -> BuildResult {
        guard let media = await store.planningMedia(for: libraryRoot),
              let revision = await store.planRevision(for: libraryRoot)
        else {
            return .unavailable(.catalogUnreadable)
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
            calendar: .current,
            timeZone: .current,
            media: media,
            knownForeignOccupants: []
        )
        // Each pass asks only for paths the previous one did not resolve, so the loop
        // ends; the bound turns a planner that keeps asking into a reported failure.
        for _ in 0 ..< 8 {
            switch ReorganizationPlanner.plan(snapshot: snapshot, occupancy: occupancy) {
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
                OtosLog.catalog.errorOperation("reorganization.plan", phase: "inconsistent", fields: [
                    "rootPath": libraryRoot.rawValue,
                    "reason": reason,
                ])
                return .unavailable(.planInconsistent)
            }
        }
        OtosLog.catalog.errorOperation("reorganization.plan", phase: "probesUnresolved", fields: [
            "rootPath": libraryRoot.rawValue,
        ])
        return .unavailable(.planInconsistent)
    }
}
