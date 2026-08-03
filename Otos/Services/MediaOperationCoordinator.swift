import Foundation
import OSLog

/// Media operation coordinator guide
///
/// Owns greedy import-plan lifecycle for every attached removable source.
/// Subscribes weakly to Store planning revisions, builds immutable plans through
/// `MediaTransferPlanner` + occupancy probes, and publishes per-source
/// presentation state for the footer. Filesystem-volume and MTP camera Import
/// execute through `MediaImportExecutor` (Stage F). Auto-eject runs only after
/// complete success with zero blocked entries.
///
/// Isolation: this actor serializes per-source dirtiness (at most one build in
/// flight and one dirty bit). Heavy filesystem probes run off the actor via
/// nonisolated helpers. Cancellation rejects stale completions by generation.
actor MediaOperationCoordinator {
    private let store: CatalogStore
    private let cameraImport: CameraImportAccess?
    private let materializationRequester: MaterializationRequesting?
    private let autoEjectHandler: (@Sendable (LibraryRoot) async -> Void)?
    private var presentations: [LibraryRootPath: MediaOperationSourcePresentation] = [:]
    private var readyPlans: [LibraryRootPath: MediaOperationPlan] = [:]
    private var destinationBySource: [LibraryRootPath: LibraryRootPath] = [:]
    private var queuedStart: [LibraryRootPath: UInt64] = [:]
    private var dirty: Set<LibraryRootPath> = []
    private var building: Set<LibraryRootPath> = []
    /// Sources with an executor in flight. This single ownership fact rejects
    /// repeated clicks and plan completions while execution suspends.
    private var executing: Set<LibraryRootPath> = []
    /// Last occupancy revision observed per root (source or destination) from the
    /// planning-change stream. A change whose occupancy revision differs from this
    /// is a real namespace change worth replanning; an unchanged one is
    /// `planRevision`-only churn (no-op cloud rescans, event deferrals) and is
    /// ignored. Using inequality — not `>` — keeps a removed-then-re-added root,
    /// whose revision resets, from being suppressed by a stale high value.
    private var lastSeenOccupancy: [LibraryRootPath: UInt64] = [:]
    private var planGeneration: UInt64 = 0
    private var attachStartedAt: [LibraryRootPath: ContinuousClock.Instant] = [:]
    private var attachToReadyMs: [LibraryRootPath: Int] = [:]
    private var consumerTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<[MediaOperationSourcePresentation]>.Continuation] = [:]
    private var isStarted = false

    init(
        store: CatalogStore,
        cameraImport: CameraImportAccess? = nil,
        materializationRequester: MaterializationRequesting? = nil,
        autoEjectHandler: (@Sendable (LibraryRoot) async -> Void)? = nil
    ) {
        self.store = store
        self.cameraImport = cameraImport
        self.materializationRequester = materializationRequester
        self.autoEjectHandler = autoEjectHandler
    }

    func presentationsStream() -> AsyncStream<[MediaOperationSourcePresentation]> {
        let (stream, continuation) = AsyncStream<[MediaOperationSourcePresentation]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(sortedPresentations())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func start() async {
        guard !isStarted else {
            return
        }
        isStarted = true
        loadDestinationMappings()
        let executor = MediaImportExecutor(
            store: store,
            cameraImport: cameraImport,
            materializationRequester: materializationRequester
        )
        await executor.recoverJournal()
        await refreshSources(reason: "start")
        let changes = await store.planningChangeNotifications()
        consumerTask = Task { [weak self] in
            for await change in changes {
                guard let self else {
                    return
                }
                await handlePlanningChange(change)
            }
        }
        // Subscription liveness marker (plan 0064 Stage 4): a capture showing
        // `phase=subscribed` plus zero later `phase=receive` lines proves the app was
        // idle (nothing to emit), not that the coordinator stopped listening.
        let subscribed = consumerTask != nil
        OtosLog.catalog.notice(
            "op=import.coordinator phase=subscribed planningStream=\(subscribed, privacy: .public)"
        )
    }

    func shutdown() {
        consumerTask?.cancel()
        consumerTask = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        isStarted = false
    }

    func setDestination(_ destination: LibraryRootPath, for source: LibraryRootPath) async {
        destinationBySource[source] = destination
        persistDestinationMappings()
        dirty.insert(source)
        await scheduleBuildIfNeeded(source)
    }

    /// Preferences changed; rebuild every attached source plan.
    func preferencesDidChange() async {
        for source in presentations.keys {
            dirty.insert(source)
            await scheduleBuildIfNeeded(source)
        }
    }

    func queueImport(for source: LibraryRootPath) async {
        guard !executing.contains(source) else {
            OtosLog.catalog.notice(
                "op=import.queue phase=rejected reason=alreadyExecuting rootPath=\(source.rawValue, privacy: .public)"
            )
            return
        }
        planGeneration &+= 1
        queuedStart[source] = planGeneration
        if let presentation = presentations[source] {
            switch presentation.state {
            case let .ready(summary, generation, skipped):
                presentations[source] = MediaOperationSourcePresentation(
                    sourcePath: source,
                    destinationPath: presentation.destinationPath,
                    state: .queuedForReadiness,
                    attachToReadyMs: presentation.attachToReadyMs
                )
                publish()
                await beginExecutionIfPossible(
                    source: source,
                    summary: summary,
                    generation: generation,
                    skippedPackageCount: skipped
                )
            case let .executionUnavailable(summary, generation):
                // Legacy gated state from Stage D — treat as ready queue.
                presentations[source] = MediaOperationSourcePresentation(
                    sourcePath: source,
                    destinationPath: presentation.destinationPath,
                    state: .queuedForReadiness,
                    attachToReadyMs: presentation.attachToReadyMs
                )
                publish()
                await beginExecutionIfPossible(
                    source: source,
                    summary: summary,
                    generation: generation,
                    skippedPackageCount: 0
                )
            default:
                presentations[source] = MediaOperationSourcePresentation(
                    sourcePath: source,
                    destinationPath: presentation.destinationPath,
                    state: .queuedForReadiness,
                    attachToReadyMs: presentation.attachToReadyMs
                )
                publish()
                dirty.insert(source)
                await scheduleBuildIfNeeded(source)
            }
        }
        OtosLog.catalog.notice(
            "op=import.queue phase=start rootPath=\(source.rawValue, privacy: .public)"
        )
    }

    private func beginExecutionIfPossible(
        source: LibraryRootPath,
        summary: MediaOperationPlanTotals,
        generation: UInt64,
        skippedPackageCount: Int
    ) async {
        guard !executing.contains(source) else {
            OtosLog.catalog.notice(
                "op=import.execute phase=rejected reason=alreadyExecuting rootPath=\(source.rawValue, privacy: .public)"
            )
            return
        }
        let libraries = await store.currentLibraries()
        guard let sourceState = libraries.first(where: { $0.path == source }) else {
            return
        }
        guard isExecutableSource(sourceState) else {
            markExecutionUnavailable(source: source, summary: summary, generation: generation)
            return
        }
        guard let plan = readyPlans[source], plan.generation == generation else {
            dirty.insert(source)
            await scheduleBuildIfNeeded(source)
            return
        }
        if summary.copyCount == 0, summary.companionCopyCount == 0 {
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destinationBySource[source],
                state: .ready(
                    summary: summary,
                    generation: generation,
                    skippedPackageCount: skippedPackageCount
                ),
                attachToReadyMs: attachToReadyMs[source]
            )
            publish()
            return
        }
        await runExecution(
            source: source,
            sourceState: sourceState,
            plan: plan,
            summary: summary,
            generation: generation,
            skippedPackageCount: skippedPackageCount
        )
    }

    private func isExecutableSource(_ sourceState: CatalogLibraryState) -> Bool {
        switch sourceState.root.kind {
        case .removableVolume:
            true
        case .deviceMTP:
            cameraImport != nil
        case .library:
            false
        }
    }

    private func markExecutionUnavailable(
        source: LibraryRootPath,
        summary: MediaOperationPlanTotals,
        generation: UInt64
    ) {
        presentations[source] = MediaOperationSourcePresentation(
            sourcePath: source,
            destinationPath: destinationBySource[source],
            state: .executionUnavailable(summary: summary, generation: generation),
            attachToReadyMs: attachToReadyMs[source]
        )
        publish()
    }

    private func runExecution(
        source: LibraryRootPath,
        sourceState: CatalogLibraryState,
        plan: MediaOperationPlan,
        summary: MediaOperationPlanTotals,
        generation: UInt64,
        skippedPackageCount: Int
    ) async {
        guard executing.insert(source).inserted else { return }
        queuedStart.removeValue(forKey: source)
        let executor = MediaImportExecutor(
            store: store,
            cameraImport: cameraImport,
            materializationRequester: materializationRequester
        )
        let prefs = ImportPreferencesStore.load()
        presentations[source] = MediaOperationSourcePresentation(
            sourcePath: source,
            destinationPath: destinationBySource[source],
            state: .executing(
                progress: MediaOperationProgress(
                    completedCount: 0,
                    totalCount: summary.copyCount,
                    completedBytes: 0,
                    totalBytes: summary.copyBytes
                )
            ),
            attachToReadyMs: attachToReadyMs[source]
        )
        publish()

        let result = await executor.execute(
            plan: plan,
            sourceKind: sourceState.root.kind,
            sourceDeviceIdentity: sourceState.root.deviceIdentity,
            deleteSourceRequested: prefs.deleteSourceAfterImport
        ) { progress in
            Task {
                await self.applyExecutionProgress(source: source, progress: progress)
            }
        }

        await applyExecutionResult(
            result,
            source: source,
            sourceRoot: sourceState.root,
            summary: summary,
            generation: generation,
            skippedPackageCount: skippedPackageCount,
            prefs: prefs
        )
        executing.remove(source)
        dirty.insert(source)
        await scheduleBuildIfNeeded(source)
    }

    private func applyExecutionResult(
        _ result: MediaImportExecutionResult,
        source: LibraryRootPath,
        sourceRoot: LibraryRoot,
        summary: MediaOperationPlanTotals,
        generation: UInt64,
        skippedPackageCount: Int,
        prefs: ImportPreferences
    ) async {
        switch result {
        case let .completed(_, _, hasBlockedEntries, hasEntryFailures):
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destinationBySource[source],
                state: .completed(summary: summary),
                attachToReadyMs: attachToReadyMs[source]
            )
            publish()
            if prefs.autoEjectAfterImport,
               !hasBlockedEntries,
               !hasEntryFailures,
               summary.blockedCount == 0
            {
                await autoEjectIfRequested(sourceRoot)
            }
        case .cancelled:
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destinationBySource[source],
                state: .ready(
                    summary: summary,
                    generation: generation,
                    skippedPackageCount: skippedPackageCount
                ),
                attachToReadyMs: attachToReadyMs[source]
            )
            publish()
        case let .failed(problem):
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destinationBySource[source],
                state: .failed(problem: problem),
                attachToReadyMs: attachToReadyMs[source]
            )
            publish()
        }
    }

    private func autoEjectIfRequested(_ root: LibraryRoot) async {
        if root.kind == .deviceMTP {
            guard let identity = root.deviceIdentity, let cameraImport else {
                return
            }
            let outcome = await cameraImport.eject(identity: identity)
            OtosLog.catalog.notice(
                "op=import.autoEject phase=camera outcome=\(String(describing: outcome), privacy: .public)"
            )
            return
        }
        if let autoEjectHandler {
            await autoEjectHandler(root)
        }
    }

    private func applyExecutionProgress(source: LibraryRootPath, progress: MediaOperationProgress) {
        guard var presentation = presentations[source] else {
            return
        }
        presentation = MediaOperationSourcePresentation(
            sourcePath: source,
            destinationPath: presentation.destinationPath,
            state: .executing(progress: progress),
            attachToReadyMs: presentation.attachToReadyMs
        )
        presentations[source] = presentation
        publish()
    }

    func currentPresentations() -> [MediaOperationSourcePresentation] {
        sortedPresentations()
    }

    func readyPlan(for source: LibraryRootPath) -> MediaOperationPlan? {
        readyPlans[source]
    }

    private func handlePlanningChange(_ change: RootPlanningChange) async {
        OtosLog.catalog.debug(
            // swiftlint:disable:next line_length
            "op=import.coordinator phase=receive rootPath=\(change.rootPath.rawValue, privacy: .public) occupancyRevision=\(change.occupancyRevision, privacy: .public)"
        )
        // Only a real occupancy change (media/companion inventory, import/reorg
        // settlement, foreign occupant) invalidates an import plan. A wake carrying
        // the same occupancy revision is planRevision-only churn — refresh source
        // membership cheaply, but do not rebuild.
        let occupancyChanged = lastSeenOccupancy[change.rootPath] != change.occupancyRevision
        lastSeenOccupancy[change.rootPath] = change.occupancyRevision

        if occupancyChanged {
            let libraries = await store.currentLibraries()
            let removable = libraries.filter { $0.root.kind != .library }
            if removable.contains(where: { $0.path == change.rootPath }) {
                dirty.insert(change.rootPath)
                if !executing.contains(change.rootPath) {
                    await scheduleBuildIfNeeded(change.rootPath)
                }
            }
            for (source, destination) in destinationBySource where destination == change.rootPath {
                dirty.insert(source)
                if !executing.contains(source) {
                    await scheduleBuildIfNeeded(source)
                }
            }
        }
        await refreshSources(reason: "planningChange")
    }

    private func refreshSources(reason: String) async {
        let libraries = await store.currentLibraries()
        let fixedAvailable = libraries.filter { $0.root.kind == .library && $0.availability == .available }
        let removable = libraries.filter {
            $0.root.kind != .library && $0.availability == .available
        }
        let soleDestination: LibraryRootPath? = fixedAvailable.count == 1 ? fixedAvailable.first?.path : nil

        var seen = Set<LibraryRootPath>()
        for source in removable {
            seen.insert(source.path)
            if attachStartedAt[source.path] == nil {
                attachStartedAt[source.path] = ContinuousClock().now
            }
            let previousMapping = destinationBySource[source.path]
            // Auto-map only when exactly one fixed library exists and nothing is saved.
            if destinationBySource[source.path] == nil, let soleDestination {
                destinationBySource[source.path] = soleDestination
            }
            // Drop mappings whose destination is no longer an available fixed library.
            if let mapped = destinationBySource[source.path],
               !fixedAvailable.contains(where: { $0.path == mapped })
            {
                destinationBySource.removeValue(forKey: source.path)
            }
            let isNewSource = presentations[source.path] == nil
            if isNewSource {
                presentations[source.path] = MediaOperationSourcePresentation(
                    sourcePath: source.path,
                    destinationPath: destinationBySource[source.path],
                    state: .inventory,
                    attachToReadyMs: nil
                )
            }
            // Plan a source only when it first appears or its destination mapping
            // changed. Re-dirtying stable sources on every wake is exactly the churn
            // that livelocked planning against an enriching cloud destination —
            // occupancy-driven rebuilds arrive through handlePlanningChange instead.
            if isNewSource || destinationBySource[source.path] != previousMapping {
                dirty.insert(source.path)
                await scheduleBuildIfNeeded(source.path)
            }
        }
        for path in presentations.keys where !seen.contains(path) {
            presentations.removeValue(forKey: path)
            readyPlans.removeValue(forKey: path)
            queuedStart.removeValue(forKey: path)
            dirty.remove(path)
            building.remove(path)
            executing.remove(path)
            attachStartedAt.removeValue(forKey: path)
            attachToReadyMs.removeValue(forKey: path)
            lastSeenOccupancy.removeValue(forKey: path)
        }
        persistDestinationMappings()
        publish()
        OtosLog.catalog.debug(
            "op=import.coordinator phase=refresh reason=\(reason, privacy: .public) sourceCount=\(removable.count, privacy: .public)"
        )
    }

    private func scheduleBuildIfNeeded(_ source: LibraryRootPath) async {
        guard dirty.contains(source), !building.contains(source) else {
            return
        }
        dirty.remove(source)
        building.insert(source)
        planGeneration &+= 1
        let generation = planGeneration
        let destination = destinationBySource[source]
        presentations[source] = MediaOperationSourcePresentation(
            sourcePath: source,
            destinationPath: destination,
            state: destination == nil ? .waitingForDestination : .planning,
            attachToReadyMs: attachToReadyMs[source]
        )
        publish()

        guard let destination else {
            building.remove(source)
            return
        }

        do {
            try await buildPlan(source: source, destination: destination, generation: generation)
        } catch {
            building.remove(source)
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destination,
                state: .failed(problem: String(describing: error)),
                attachToReadyMs: attachToReadyMs[source]
            )
            publish()
        }
    }

    private func buildPlan(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        generation: UInt64
    ) async throws {
        let policy = ImportPolicy.from(ImportPreferencesStore.load())
        guard let snapshot = try await store.importPlanningSnapshot(
            source: source,
            destination: destination,
            policy: policy,
            generation: generation
        ) else {
            building.remove(source)
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destination,
                state: .failed(problem: "snapshotUnavailable"),
                attachToReadyMs: attachToReadyMs[source]
            )
            publish()
            return
        }

        if await shouldWaitForMetadata(source: source, snapshot: snapshot) {
            return
        }

        let plan = MediaTransferPlanner.buildImportPlan(
            snapshot: snapshot,
            knownForeignOccupants: snapshot.knownForeignOccupants
        )
        // Key staleness on occupancy, not planRevision: a destination that keeps
        // enriching bumps planRevision every few seconds without changing which
        // paths are occupied, and guarding on that livelocks planning.
        let sourceOccupancy = await store.occupancyRevision(for: source)
        let destinationOccupancy = await store.occupancyRevision(for: destination)
        guard sourceOccupancy == snapshot.sourceOccupancyRevision,
              destinationOccupancy == snapshot.destinationOccupancyRevision,
              generation == planGeneration || dirty.contains(source) == false
        else {
            building.remove(source)
            dirty.insert(source)
            await scheduleBuildIfNeeded(source)
            return
        }

        readyPlans[source] = plan
        let skipped = await store.skippedPackageCount(for: source)
        recordAttachToReadyIfNeeded(source: source, plan: plan)
        let state: MediaOperationSourceState = if queuedStart[source] != nil {
            .queuedForReadiness
        } else {
            .ready(
                summary: plan.totals,
                generation: plan.generation,
                skippedPackageCount: skipped
            )
        }
        presentations[source] = MediaOperationSourcePresentation(
            sourcePath: source,
            destinationPath: destination,
            state: state,
            attachToReadyMs: attachToReadyMs[source]
        )
        building.remove(source)
        publish()
        if queuedStart[source] != nil {
            await beginExecutionIfPossible(
                source: source,
                summary: plan.totals,
                generation: plan.generation,
                skippedPackageCount: skipped
            )
        } else if dirty.contains(source) {
            await scheduleBuildIfNeeded(source)
        }
    }

    private func shouldWaitForMetadata(
        source: LibraryRootPath,
        snapshot: ImportPlanningSnapshot
    ) async -> Bool {
        let missingDates = snapshot.sourceMedia.filter { !$0.hasUsableDate }.count
        let total = snapshot.sourceMedia.count
        let enriched = total - missingDates
        // Filesystem sources wait for enrichment wall facts when any media
        // still lacks both wall and mtime (mtime usually present). Cameras
        // already carry capture dates from enumeration.
        let libraries = await store.currentLibraries()
        let sourceKind = libraries.first(where: { $0.path == source })?.root.kind
        guard sourceKind != .deviceMTP,
              snapshot.sourceMedia.contains(where: {
                  $0.captureWallCompact == nil && $0.contentModifiedAt == nil
              })
        else {
            return false
        }
        presentations[source] = MediaOperationSourcePresentation(
            sourcePath: source,
            destinationPath: destinationBySource[source],
            state: .waitingForMetadata(done: enriched, total: max(total, 1)),
            attachToReadyMs: attachToReadyMs[source]
        )
        publish()
        building.remove(source)
        return true
    }

    /// Records the attach → ready span once. The span runs from the first time this
    /// process's coordinator observed the source through the first ready plan, so it
    /// deliberately includes any time the user spent choosing/confirming the
    /// destination and any metadata-wait state — it is NOT pure system latency, and
    /// should not be read as one (plan 0064 Stage 4).
    private func recordAttachToReadyIfNeeded(source: LibraryRootPath, plan: MediaOperationPlan) {
        guard attachToReadyMs[source] == nil,
              let started = attachStartedAt[source]
        else {
            return
        }
        let elapsed = started.duration(to: ContinuousClock().now)
        attachToReadyMs[source] = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let elapsedMs = attachToReadyMs[source] ?? 0
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=import.attachToReady phase=ready rootPath=\(source.rawValue, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) copyCount=\(plan.totals.copyCount, privacy: .public)"
        )
    }

    private func sortedPresentations() -> [MediaOperationSourcePresentation] {
        presentations.values.sorted {
            $0.sourcePath.rawValue.localizedStandardCompare($1.sourcePath.rawValue) == .orderedAscending
        }
    }

    private func publish() {
        let values = sortedPresentations()
        for continuation in continuations.values {
            continuation.yield(values)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static let destinationMappingKey = "import.destinationBySource"

    private func loadDestinationMappings() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.dictionary(forKey: Self.destinationMappingKey) as? [String: String] else {
            return
        }
        for (source, destination) in raw {
            destinationBySource[LibraryRootPath(rawValue: source)] = LibraryRootPath(rawValue: destination)
        }
    }

    private func persistDestinationMappings() {
        var raw: [String: String] = [:]
        for (source, destination) in destinationBySource {
            raw[source.rawValue] = destination.rawValue
        }
        UserDefaults.standard.set(raw, forKey: Self.destinationMappingKey)
    }
}
