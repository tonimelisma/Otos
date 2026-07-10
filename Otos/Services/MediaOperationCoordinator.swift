import Foundation
import OSLog

/// Media operation coordinator guide
///
/// Owns greedy import-plan lifecycle for every attached removable source.
/// Subscribes weakly to Store planning revisions, builds immutable plans through
/// `MediaTransferPlanner` + occupancy/equality probes, and publishes per-source
/// presentation state for the footer. Filesystem-volume Import executes through
/// `MediaImportExecutor`; camera Import remains gated until Stage F.
///
/// Isolation: this actor serializes per-source dirtiness (at most one build in
/// flight and one dirty bit). Heavy filesystem probes run off the actor via
/// nonisolated helpers. Cancellation rejects stale completions by generation.
actor MediaOperationCoordinator {
    private let store: CatalogStore
    private let equality: ContentEqualityChecker
    private var presentations: [LibraryRootPath: MediaOperationSourcePresentation] = [:]
    private var readyPlans: [LibraryRootPath: MediaOperationPlan] = [:]
    private var destinationBySource: [LibraryRootPath: LibraryRootPath] = [:]
    private var queuedStart: [LibraryRootPath: UInt64] = [:]
    private var dirty: Set<LibraryRootPath> = []
    private var building: Set<LibraryRootPath> = []
    private var planGeneration: UInt64 = 0
    private var attachStartedAt: [LibraryRootPath: ContinuousClock.Instant] = [:]
    private var attachToReadyMs: [LibraryRootPath: Int] = [:]
    private var consumerTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<[MediaOperationSourcePresentation]>.Continuation] = [:]
    private var isStarted = false

    init(store: CatalogStore, authorizeMaterialization: Bool = false) {
        self.store = store
        equality = ContentEqualityChecker(authorizeMaterialization: authorizeMaterialization)
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
        let executor = MediaImportExecutor(store: store)
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
        planGeneration &+= 1
        queuedStart[source] = planGeneration
        if var presentation = presentations[source] {
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
        let libraries = await store.currentLibraries()
        let sourceState = libraries.first { $0.path == source }
        guard let sourceState else {
            return
        }
        // Stage E enables filesystem volumes only; cameras remain Stage F.
        guard sourceState.root.kind == .removableVolume else {
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destinationBySource[source],
                state: .executionUnavailable(summary: summary, generation: generation),
                attachToReadyMs: attachToReadyMs[source]
            )
            publish()
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

        let executor = MediaImportExecutor(store: store)
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

        queuedStart.removeValue(forKey: source)
        switch result {
        case .completed:
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destinationBySource[source],
                state: .completed(summary: summary),
                attachToReadyMs: attachToReadyMs[source]
            )
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
        case let .failed(problem):
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destinationBySource[source],
                state: .failed(problem: problem),
                attachToReadyMs: attachToReadyMs[source]
            )
        }
        publish()
        dirty.insert(source)
        await scheduleBuildIfNeeded(source)
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
        let libraries = await store.currentLibraries()
        let removable = libraries.filter { $0.root.kind != .library }
        if removable.contains(where: { $0.path == change.rootPath })
            || destinationBySource.values.contains(change.rootPath)
        {
            if removable.contains(where: { $0.path == change.rootPath }) {
                dirty.insert(change.rootPath)
                await scheduleBuildIfNeeded(change.rootPath)
            } else {
                for (source, destination) in destinationBySource where destination == change.rootPath {
                    dirty.insert(source)
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
            if presentations[source.path] == nil {
                presentations[source.path] = MediaOperationSourcePresentation(
                    sourcePath: source.path,
                    destinationPath: destinationBySource[source.path],
                    state: .inventory,
                    attachToReadyMs: nil
                )
            }
            dirty.insert(source.path)
            await scheduleBuildIfNeeded(source.path)
        }
        for path in presentations.keys where !seen.contains(path) {
            presentations.removeValue(forKey: path)
            readyPlans.removeValue(forKey: path)
            queuedStart.removeValue(forKey: path)
            dirty.remove(path)
            building.remove(path)
            attachStartedAt.removeValue(forKey: path)
            attachToReadyMs.removeValue(forKey: path)
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
            equality: equality,
            knownForeignOccupants: snapshot.knownForeignOccupants
        )
        let sourceRevision = await store.planRevision(for: source)
        let destinationRevision = await store.planRevision(for: destination)
        guard sourceRevision == snapshot.sourceRevision,
              destinationRevision == snapshot.destinationRevision,
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
