import Foundation
import OSLog

/// One plan build's product plus the cost split that makes it diagnosable:
/// namespace read time versus pure planning time.
private nonisolated struct ImportPlanBuildResult {
    let plan: MediaOperationPlan
    let namespace: DestinationNamespace
    let enumerateMs: Int
    let planMs: Int
}

/// Media operation coordinator guide
///
/// Owns greedy import-plan lifecycle for every attached removable source.
/// Subscribes weakly to Store planning revisions, builds immutable plans through
/// `MediaTransferPlanner` over an enumerated destination namespace, and publishes
/// per-source presentation state for the footer. Filesystem-volume and MTP camera
/// Import execute through `MediaImportExecutor`. Auto-eject runs only after
/// complete success with zero blocked entries.
///
/// Isolation: this actor serializes per-source dirtiness (at most one build in
/// flight and one dirty bit). Plan building is an **owned per-source child task**,
/// never awaited from the planning-change consumer: a build that takes seconds must
/// not make the coordinator deaf to an attaching card, and the consumer loop only
/// ever does cheap bookkeeping. Namespace enumeration and the planning pass run off
/// this actor in a nonisolated async helper. Because that helper is a suspension
/// point, every completion revalidates its typed occupancy revisions on the actor
/// before publishing, and a build that lost the race re-dirties instead of applying.
actor MediaOperationCoordinator {
    private let store: CatalogStore
    // UserDefaults is documented thread-safe; this actor is the only writer for
    // its suite, so a scoped nonisolated(unsafe) is more reviewable than a
    // module-wide retroactive conformance (ARC-042).
    private nonisolated(unsafe) let preferences: UserDefaults
    private let cameraImport: CameraImportAccess?
    private let materializationRequester: MaterializationRequesting?
    private let autoEjectHandler: (@Sendable (LibraryRoot) async -> Void)?
    private var presentations: [LibraryRootPath: MediaOperationSourcePresentation] = [:]
    private var readyPlans: [LibraryRootPath: MediaOperationPlan] = [:]
    private var destinationBySource: [LibraryRootPath: LibraryRootPath] = [:]
    private var queuedStart: Set<LibraryRootPath> = []
    private var dirty: Set<LibraryRootPath> = []
    private var building: Set<LibraryRootPath> = []
    /// Sources with an executor in flight. This single ownership fact rejects
    /// repeated clicks and plan completions while execution suspends.
    private var executing: Set<LibraryRootPath> = []
    /// One executor per executing source so the bar's Cancel reaches it (decision 20, Stage 6).
    private var executors: [LibraryRootPath: MediaImportExecutor] = [:]
    /// Last occupancy revision observed per root (source or destination) from the
    /// planning-change stream. A change whose occupancy revision differs from this
    /// is a real namespace change worth replanning; an unchanged one is
    /// `planRevision`-only churn (no-op cloud rescans, event deferrals) and is
    /// ignored. Using inequality — not `>` — keeps a removed-then-re-added root,
    /// whose revision resets, from being suppressed by a stale high value.
    private var lastSeenOccupancy: [LibraryRootPath: UInt64] = [:]
    // Incremented only in scheduleBuildIfNeeded to give a published plan an identity; not bumped on queueImport.
    private var planGeneration: UInt64 = 0
    private var attachStartedAt: [LibraryRootPath: ContinuousClock.Instant] = [:]
    private var attachToReadyMs: [LibraryRootPath: Int] = [:]
    /// One in-flight plan build per source. Held so a detaching source cancels its
    /// build instead of publishing into a presentation that no longer exists.
    private var buildTasks: [LibraryRootPath: Task<Void, Never>] = [:]
    private var consumerTask: Task<Void, Never>?
    private var catalogChangeTask: Task<Void, Never>?
    /// Reservation ledger per §5: every `.copy` final destination plus every
    /// companion destination of a live (ready or executing) plan, keyed by
    /// source. Unioned on demand per destination; never persisted, never
    /// consulted by the executor, never a second truth about D — the filesystem
    /// still wins. Invariants I1–I5 hold in one synchronous on-actor region at
    /// publish time (§5, decision 18).
    private var claimsBySource: [LibraryRootPath: Set<MediaRelativePath>] = [:]
    /// Device-identity-keyed destination persistence (Stage 5): the three-step
    /// default — saved mapping for this device identity → last-used destination
    /// → sole/first available fixed library — ensures a destination is always
    /// defaulted and `.waitingForDestination` is never presented.
    private var destinationByDeviceIdentity: [String: LibraryRootPath] = [:]
    private var lastUsedDestination: LibraryRootPath?
    /// Per-source session overrides seeded from ImportPreferences, discarded on detach (Stage 7).
    private var sessionPreferences: [LibraryRootPath: ImportPreferences] = [:]

    private var continuations: [UUID: AsyncStream<[MediaOperationSourcePresentation]>.Continuation] = [:]
    private var isStarted = false

    init(
        store: CatalogStore,
        preferences: sending UserDefaults,
        cameraImport: CameraImportAccess? = nil,
        materializationRequester: MaterializationRequesting? = nil,
        autoEjectHandler: (@Sendable (LibraryRoot) async -> Void)? = nil
    ) {
        self.store = store
        self.preferences = preferences
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
        let catalogChanges = await store.changeNotifications()
        catalogChangeTask = Task { [weak self] in
            for await _ in catalogChanges {
                guard let self else {
                    return
                }
                await handleCatalogChangeForMetadataGate()
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
        catalogChangeTask?.cancel()
        catalogChangeTask = nil
        for task in buildTasks.values {
            task.cancel()
        }
        buildTasks.removeAll()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        isStarted = false
    }

    func setDestination(_ destination: LibraryRootPath, for source: LibraryRootPath) async {
        let libraries = await store.currentLibraries()
        if let sourceState = libraries.first(where: { $0.path == source }),
           let device = sourceState.root.deviceIdentity
        {
            destinationByDeviceIdentity[device] = destination
        }
        lastUsedDestination = destination
        destinationBySource[source] = destination
        persistDestinationMappings()
        dirty.insert(source)
        scheduleBuildIfNeeded(source)
    }

    /// Preferences changed; rebuild every attached source plan.
    func preferencesDidChange() async {
        for source in presentations.keys {
            dirty.insert(source)
            scheduleBuildIfNeeded(source)
        }
    }

    func sessionPreferences(for source: LibraryRootPath) -> ImportPreferences {
        sessionPreferences[source] ?? ImportPreferencesStore.load(defaults: preferences)
    }

    func setSessionPreferences(_ prefs: ImportPreferences, for source: LibraryRootPath) async {
        sessionPreferences[source] = prefs
        dirty.insert(source)
        scheduleBuildIfNeeded(source)
    }

    func queueImport(for source: LibraryRootPath) async {
        guard !executing.contains(source) else {
            OtosLog.catalog.notice(
                "op=import.queue phase=rejected reason=alreadyExecuting rootPath=\(source.rawValue, privacy: .public)"
            )
            return
        }
        queuedStart.insert(source)
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
                scheduleBuildIfNeeded(source)
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
            scheduleBuildIfNeeded(source)
            return
        }
        if summary.copyCount == 0, summary.companionCopyCount == 0 {
            let prefs = sessionPreferences[source] ?? ImportPreferencesStore.load(defaults: preferences)
            guard prefs.deleteSourceAfterImport else {
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
        // Plan 0066 Stage 6b: publish liveness so smoke tooling can avoid
        // killing an active import. One line on entry, one on exit per source.
        OtosLog.catalog.noticeOperation("import.activity", phase: "started", fields: ["rootPath": source.rawValue])
        queuedStart.remove(source)
        let executor = MediaImportExecutor(
            store: store,
            cameraImport: cameraImport,
            materializationRequester: materializationRequester
        )
        executors[source] = executor
        let prefs = sessionPreferences[source] ?? ImportPreferencesStore.load(defaults: preferences)
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
        OtosLog.catalog.noticeOperation("import.activity", phase: "finished", fields: ["rootPath": source.rawValue])
        let finishedDestination = destinationBySource[source]
        executors.removeValue(forKey: source)
        executing.remove(source)
        // I2: conversion by death — every published name is already observable
        // on disk, every unpublished name never will be. One release point per
        // plan death keeps the ledger trivially auditable, and the next rebuild
        // seeds from disk truth.
        claimsBySource.removeValue(forKey: source)
        dirty.insert(source)
        scheduleBuildIfNeeded(source)
        // Flush coalesced destination-driven rebuilds (Stage 2 / C4).
        // While this destination was under execution, handlePlanningChange
        // suppressed rebuilds for every other source mapped to it, leaving
        // them dirty but unscheduled. After the last execution for this
        // destination finishes, schedule one rebuild per dirty source.
        if let finishedDestination {
            let stillExecutingForDestination = executing.contains {
                destinationBySource[$0] == finishedDestination
            }
            if !stillExecutingForDestination {
                for (otherSource, dest) in destinationBySource
                    where dest == finishedDestination && otherSource != source && dirty.contains(otherSource)
                {
                    if !building.contains(otherSource), !executing.contains(otherSource) {
                        scheduleBuildIfNeeded(otherSource)
                        let src = otherSource.rawValue
                        let dst = dest.rawValue
                        OtosLog.catalog.notice(
                            "op=import.coordinator phase=flushRebuild source=\(src, privacy: .public) destination=\(dst, privacy: .public)"
                        )
                    }
                }
            }
        }
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
        case let .completed(_, _, hasBlockedEntries, hasEntryFailures, skippedForeignCount, failedCount):
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: destinationBySource[source],
                state: .completed(
                    summary: summary,
                    skippedForeignCount: skippedForeignCount,
                    failedCount: failedCount
                ),
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
        case let .cancelled(_, _, _, _, skippedForeignCount, failedCount):
            // Cancelled still surfaces the counts for diagnostics, but the
            // presentation returns to ready so the user can retry. The ledger
            // was already cleared in runExecution before the rebuild.
            _ = (skippedForeignCount, failedCount)
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

    func cancelImport(for source: LibraryRootPath) async {
        if let executor = executors[source] {
            await executor.cancel()
        }
        OtosLog.catalog.notice(
            "op=import.cancel phase=requested rootPath=\(source.rawValue, privacy: .public)"
        )
    }

    func retryPlanning(for source: LibraryRootPath) async {
        dirty.insert(source)
        scheduleBuildIfNeeded(source)
        OtosLog.catalog.notice(
            "op=import.retry phase=requested rootPath=\(source.rawValue, privacy: .public)"
        )
    }

    private func handlePlanningChange(_ change: RootPlanningChange) async {
        OtosLog.catalog.noticeOperation(
            "import.coordinator",
            phase: "receive",
            fields: [
                "rootPath": change.rootPath.rawValue,
                "occupancyRevision": "\(change.occupancyRevision)",
            ]
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
                    scheduleBuildIfNeeded(change.rootPath)
                }
            }
            // C4 fix: while any execution targets this destination, suppress
            // destination-driven rebuilds for all sources mapped to it. Each
            // per-entry settlement bumps occupancy and would otherwise cause
            // every other card planning into the same library to re-enumerate
            // continuously. Dirty is retained and coalesced into one rebuild
            // after the last execution for this destination ends.
            let executingDestinations = Set(executing.compactMap { destinationBySource[$0] })
            let isDestinationUnderExecution = executingDestinations.contains(change.rootPath)
            for (source, destination) in destinationBySource where destination == change.rootPath {
                dirty.insert(source)
                if isDestinationUnderExecution {
                    let src = source.rawValue
                    let dst = destination.rawValue
                    OtosLog.catalog.notice(
                        "op=import.coordinator phase=suppressRebuild source=\(src, privacy: .public) destination=\(dst, privacy: .public)"
                    )
                    continue
                }
                if !executing.contains(source) {
                    scheduleBuildIfNeeded(source)
                }
            }
        }
        await refreshSources(reason: "planningChange")
    }

    /// Resume path for `waitingForMetadata` (Stage 1 / F3). Enrichment updates
    /// capture dates without bumping occupancy, so the occupancy-driven
    /// `handlePlanningChange` never wakes a waiting source. Any catalog change
    /// that may have supplied dates re-dirties waiting sources so they rebuild
    /// and either progress to `.planning` or remain waiting with updated counts.
    private func handleCatalogChangeForMetadataGate() async {
        var waitingSources: [LibraryRootPath] = []
        for (source, presentation) in presentations {
            if case .waitingForMetadata = presentation.state {
                waitingSources.append(source)
            }
        }
        guard !waitingSources.isEmpty else {
            return
        }
        for source in waitingSources {
            dirty.insert(source)
            if !building.contains(source), !executing.contains(source) {
                scheduleBuildIfNeeded(source)
            }
        }
        OtosLog.catalog.notice(
            "op=import.coordinator phase=catalogChangeWake waitingCount=\(waitingSources.count, privacy: .public)"
        )
    }

    private func refreshSources(reason: String) async {
        let libraries = await store.currentLibraries()
        let fixedAvailable = libraries.filter { $0.root.kind == .library && $0.availability == .available }
        let removable = libraries.filter {
            $0.root.kind != .library && $0.availability == .available
        }

        var seen = Set<LibraryRootPath>()
        for source in removable {
            seen.insert(source.path)
            if attachStartedAt[source.path] == nil {
                attachStartedAt[source.path] = ContinuousClock().now
            }
            let previousMapping = destinationBySource[source.path]
            // Three-step default (Stage 5): saved mapping for this device
            // identity → last-used destination → sole/first available fixed
            // library. A destination is always defaulted when one exists, so
            // `.waitingForDestination` is never presented.
            let currentMapped = destinationBySource[source.path]
            let isCurrentValid = currentMapped.map { dest in
                fixedAvailable.contains(where: { $0.path == dest })
            } ?? false
            if !isCurrentValid {
                let deviceDest: LibraryRootPath? = {
                    guard let device = source.root.deviceIdentity,
                          let saved = destinationByDeviceIdentity[device],
                          fixedAvailable.contains(where: { $0.path == saved })
                    else { return nil }
                    return saved
                }()
                let lastUsedValid = lastUsedDestination.flatMap { dest in
                    fixedAvailable.contains(where: { $0.path == dest }) ? dest : nil
                }
                let soleOrFirst: LibraryRootPath? = {
                    if fixedAvailable.count == 1 {
                        return fixedAvailable.first?.path
                    }
                    return fixedAvailable.sorted { $0.path.rawValue < $1.path.rawValue }.first?.path
                }()
                let newDestination = deviceDest ?? lastUsedValid ?? soleOrFirst
                if let newDestination {
                    destinationBySource[source.path] = newDestination
                    if let device = source.root.deviceIdentity {
                        destinationByDeviceIdentity[device] = newDestination
                    }
                    lastUsedDestination = newDestination
                } else {
                    destinationBySource.removeValue(forKey: source.path)
                }
                if destinationBySource[source.path] != previousMapping {
                    persistDestinationMappings()
                }
            }
            let isNewSource = presentations[source.path] == nil
            if isNewSource {
                presentations[source.path] = MediaOperationSourcePresentation(
                    sourcePath: source.path,
                    destinationPath: destinationBySource[source.path],
                    state: .inventory,
                    attachToReadyMs: nil
                )
                // Seed session overrides from global defaults; discarded on detach.
                if sessionPreferences[source.path] == nil {
                    sessionPreferences[source.path] = ImportPreferencesStore.load(defaults: preferences)
                }
            }
            // Plan a source only when it first appears or its destination mapping
            // changed. Re-dirtying stable sources on every wake is exactly the churn
            // that livelocked planning against an enriching cloud destination —
            // occupancy-driven rebuilds arrive through handlePlanningChange instead.
            if isNewSource || destinationBySource[source.path] != previousMapping {
                dirty.insert(source.path)
                scheduleBuildIfNeeded(source.path)
            }
        }
        for path in presentations.keys where !seen.contains(path) {
            // A detached source cancels its build; the task's own completion path
            // publishes nothing once its presentation is gone.
            buildTasks.removeValue(forKey: path)?.cancel()
            presentations.removeValue(forKey: path)
            readyPlans.removeValue(forKey: path)
            queuedStart.remove(path)
            dirty.remove(path)
            building.remove(path)
            executing.remove(path)
            executors.removeValue(forKey: path)
            attachStartedAt.removeValue(forKey: path)
            attachToReadyMs.removeValue(forKey: path)
            lastSeenOccupancy.removeValue(forKey: path)
            claimsBySource.removeValue(forKey: path)
            sessionPreferences.removeValue(forKey: path)
        }
        persistDestinationMappings()
        publish()
        OtosLog.catalog.noticeOperation(
            "import.coordinator",
            phase: "refresh",
            fields: ["reason": reason, "sourceCount": "\(removable.count)"]
        )
    }

    /// Starts a plan build without awaiting it.
    ///
    /// Synchronous by design: every caller reaches this from a notification or a UI
    /// intent, and awaiting the build there is what previously made the coordinator
    /// unable to notice an attaching card for minutes. The `dirty`/`building` pair
    /// is flipped here, before the task starts, so a second call during a build
    /// coalesces into one queued rebuild instead of racing.
    private func scheduleBuildIfNeeded(_ source: LibraryRootPath) {
        guard dirty.contains(source), !building.contains(source) else {
            return
        }
        dirty.remove(source)
        building.insert(source)
        planGeneration &+= 1
        let generation = planGeneration
        let destination = destinationBySource[source]
        OtosLog.catalog.noticeOperation(
            "plan.rebuild",
            phase: "schedule",
            fields: [
                "source": source.rawValue,
                "destination": destination?.rawValue ?? "none",
                "generation": "\(generation)",
            ]
        )
        guard let destination else {
            presentations[source] = MediaOperationSourcePresentation(
                sourcePath: source,
                destinationPath: nil,
                state: .failed(problem: "noDestinationLibrary"),
                attachToReadyMs: attachToReadyMs[source]
            )
            publish()
            building.remove(source)
            return
        }
        presentations[source] = MediaOperationSourcePresentation(
            sourcePath: source,
            destinationPath: destination,
            state: .planning,
            attachToReadyMs: attachToReadyMs[source]
        )
        publish()

        buildTasks[source] = Task { [weak self] in
            guard let self else {
                return
            }
            await runBuild(source: source, destination: destination, generation: generation)
        }
    }

    private func runBuild(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        generation: UInt64
    ) async {
        defer { buildTasks.removeValue(forKey: source) }
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

    /// Enumerates the destination folders this snapshot can touch, then plans.
    ///
    /// `nonisolated` and `async` so the enumeration and the planning pass run on the
    /// cooperative pool rather than on the coordinator, which stays free to service
    /// planning changes and Import intents while a build is in flight.
    private nonisolated static func buildPlanOffActor(
        snapshot: ImportPlanningSnapshot,
        additionalReserved: Set<MediaRelativePath>
    ) async -> ImportPlanBuildResult {
        let clock = ContinuousClock()
        let enumerateStart = clock.now
        let namespace = FilesystemNamespaceSemantics.enumerateNamespace(
            root: snapshot.destinationRoot,
            folders: MediaTransferPlanner.destinationFolders(for: snapshot)
        )
        let planStart = clock.now
        OtosLog.catalog.noticeOperation(
            "plan.namespace.enumerate",
            phase: "finish",
            fields: [
                "destination": snapshot.destinationRoot.rawValue,
                "folders": "\(namespace.folderCount)",
                "entries": "\(namespace.entryCount)",
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(enumerateStart.duration(to: planStart)))",
            ]
        )
        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: namespace,
            additionalReserved: additionalReserved
        )
        let planEnd = clock.now
        return ImportPlanBuildResult(
            plan: plan,
            namespace: namespace,
            enumerateMs: DiagnosticsTiming.milliseconds(enumerateStart.duration(to: planStart)),
            planMs: DiagnosticsTiming.milliseconds(planStart.duration(to: planEnd))
        )
    }

    /// One `phase=finish` line carrying the split that tells I/O cost from CPU cost.
    /// `folders`/`namespaceEntries` size the read; `enumerateMs`/`planMs` attribute
    /// the time without needing a side experiment to tell them apart.
    private nonisolated static func logPlanFinished(
        source: LibraryRootPath,
        sourceCount: Int,
        result: ImportPlanBuildResult
    ) {
        OtosLog.catalog.noticeOperation(
            "import.plan",
            phase: "finish",
            fields: [
                "rootPath": source.rawValue,
                "sourceCount": "\(sourceCount)",
                "folders": "\(result.namespace.folderCount)",
                "namespaceEntries": "\(result.namespace.entryCount)",
                "enumerateMs": "\(result.enumerateMs)",
                "planMs": "\(result.planMs)",
                "copyCount": "\(result.plan.totals.copyCount)",
                "skipCount": "\(result.plan.totals.skipCount)",
                "blockedCount": "\(result.plan.totals.blockedCount)",
            ]
        )
    }

    private func buildPlan(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        generation: UInt64
    ) async throws {
        let prefs = sessionPreferences[source] ?? ImportPreferencesStore.load(defaults: preferences)
        let policy = ImportPolicy.from(prefs)
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

        OtosLog.catalog.noticeOperation(
            "import.plan",
            phase: "start",
            fields: [
                "rootPath": source.rawValue,
                "destinationPath": destination.rawValue,
                "sourceCount": "\(snapshot.sourceMedia.count)",
                "destinationOccupants": "\(snapshot.destinationOccupants.count)",
            ]
        )
        // Seed from ledger §5: concurrent builds for the same destination stay
        // fully parallel; each seeds from the ledger at build-start time.
        let seededClaims = ledgerClaims(for: destination, excluding: source)
        let signpost = OtosSignpost.performance.beginInterval("ImportPlanBuild")
        let build = await Self.buildPlanOffActor(snapshot: snapshot, additionalReserved: seededClaims)
        OtosSignpost.performance.endInterval("ImportPlanBuild", signpost)
        let plan = build.plan
        Self.logPlanFinished(
            source: source,
            sourceCount: snapshot.sourceMedia.count,
            result: build
        )

        // Key staleness on occupancy, not planRevision: a destination that keeps
        // enriching bumps planRevision every few seconds without changing which
        // paths are occupied, and guarding on that livelocks planning. The build
        // suspended off-actor, so these revisions are re-read after the await.
        let sourceOccupancy = await store.occupancyRevision(for: source)
        let destinationOccupancy = await store.occupancyRevision(for: destination)
        guard sourceOccupancy == snapshot.sourceOccupancyRevision,
              destinationOccupancy == snapshot.destinationOccupancyRevision,
              destinationBySource[source] == destination
        else {
            OtosLog.catalog.noticeOperation(
                "import.plan",
                phase: "stale",
                fields: [
                    "rootPath": source.rawValue,
                    "sourceOccupancy": "\(sourceOccupancy.map(String.init) ?? "none")",
                    "snapshotSourceOccupancy": "\(snapshot.sourceOccupancyRevision)",
                    "destinationOccupancy": "\(destinationOccupancy.map(String.init) ?? "none")",
                    "snapshotDestinationOccupancy": "\(snapshot.destinationOccupancyRevision)",
                    "mappedDestination": "\(destinationBySource[source]?.rawValue ?? "none")",
                    "expectedDestination": destination.rawValue,
                ]
            )
            building.remove(source)
            dirty.insert(source)
            scheduleBuildIfNeeded(source)
            return
        }

        // Publish-time ledger conflict check (I4): conflict check plus
        // registration happen in one synchronous on-actor region against the
        // *current* ledger, never the build-start snapshot. A conflicting build
        // re-dirties and rebuilds; it never evicts a registered claim.
        let newClaims = planClaims(from: plan)
        let currentLedger = ledgerClaims(for: destination, excluding: source)
        if !newClaims.isDisjoint(with: currentLedger) {
            OtosLog.catalog.noticeOperation(
                "import.plan",
                phase: "conflict",
                fields: [
                    "rootPath": source.rawValue,
                    "destination": destination.rawValue,
                    "newClaims": "\(newClaims.count)",
                    "conflictingClaims": "\(newClaims.intersection(currentLedger).count)",
                ]
            )
            building.remove(source)
            dirty.insert(source)
            scheduleBuildIfNeeded(source)
            return
        }
        // No conflict: atomically release old claims and register new (I2, I3).
        if newClaims.isEmpty {
            claimsBySource.removeValue(forKey: source)
        } else {
            claimsBySource[source] = newClaims
        }

        readyPlans[source] = plan
        let skipped = await store.skippedPackageCount(for: source)
        recordAttachToReadyIfNeeded(source: source, plan: plan)
        let state: MediaOperationSourceState = if queuedStart.contains(source) {
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
        if queuedStart.contains(source) {
            await beginExecutionIfPossible(
                source: source,
                summary: plan.totals,
                generation: plan.generation,
                skippedPackageCount: skipped
            )
        } else if dirty.contains(source) {
            scheduleBuildIfNeeded(source)
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
        // already carry capture dates from enumeration. Policy-aware: if the
        // selected policy never consults a date, there is nothing to wait for.
        let libraries = await store.currentLibraries()
        let sourceKind = libraries.first(where: { $0.path == source })?.root.kind
        guard sourceKind != .deviceMTP,
              MediaTransferPlanner.needsDate(policy: snapshot.policy),
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
        attachToReadyMs[source] = DiagnosticsTiming.milliseconds(elapsed)
        let elapsedMs = attachToReadyMs[source] ?? 0
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=import.attachToReady phase=ready rootPath=\(source.rawValue, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) copyCount=\(plan.totals.copyCount, privacy: .public)"
        )
    }

    private func ledgerClaims(for destination: LibraryRootPath, excluding excludedSource: LibraryRootPath? = nil) -> Set<MediaRelativePath> {
        var result: Set<MediaRelativePath> = []
        for (source, claims) in claimsBySource where destinationBySource[source] == destination && source != excludedSource {
            result.formUnion(claims)
        }
        return result
    }

    private func planClaims(from plan: MediaOperationPlan) -> Set<MediaRelativePath> {
        var claims: Set<MediaRelativePath> = []
        for entry in plan.entries {
            if case .copy = entry.disposition {
                claims.insert(entry.finalDestination)
                for dest in entry.companionDestinations.values {
                    claims.insert(dest)
                }
            }
        }
        return claims
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
    private static let destinationByDeviceIdentityKey = "import.destinationByDeviceIdentity"
    private static let lastUsedDestinationKey = "import.lastUsedDestination"

    private func loadDestinationMappings() {
        if let raw = preferences.dictionary(forKey: Self.destinationByDeviceIdentityKey) as? [String: String] {
            for (device, dest) in raw {
                destinationByDeviceIdentity[device] = LibraryRootPath(rawValue: dest)
            }
        }
        if let last = preferences.string(forKey: Self.lastUsedDestinationKey) {
            lastUsedDestination = LibraryRootPath(rawValue: last)
        }
        // Legacy path-keyed mapping (pre-Stage 5): migrate into runtime
        // destinationBySource so existing installs keep their choice until the
        // next per-device persist. The device-identity store is authoritative
        // going forward.
        if let raw = preferences.dictionary(forKey: Self.destinationMappingKey) as? [String: String] {
            for (source, destination) in raw {
                let key = LibraryRootPath(rawValue: source)
                if destinationBySource[key] == nil {
                    destinationBySource[key] = LibraryRootPath(rawValue: destination)
                }
            }
        }
    }

    private func persistDestinationMappings() {
        var deviceRaw: [String: String] = [:]
        for (device, dest) in destinationByDeviceIdentity {
            deviceRaw[device] = dest.rawValue
        }
        preferences.set(deviceRaw, forKey: Self.destinationByDeviceIdentityKey)
        if let last = lastUsedDestination {
            preferences.set(last.rawValue, forKey: Self.lastUsedDestinationKey)
        } else {
            preferences.removeObject(forKey: Self.lastUsedDestinationKey)
        }
        // Keep legacy key in sync for diagnostics and for any external tool
        // that still reads it; the device-identity key is the source of truth.
        var legacyRaw: [String: String] = [:]
        for (source, dest) in destinationBySource {
            legacyRaw[source.rawValue] = dest.rawValue
        }
        preferences.set(legacyRaw, forKey: Self.destinationMappingKey)
    }

    /// Snapshot of all known destinations, including unavailable sources whose
    /// runtime mapping is retained for Settings display. Used by the ViewModel
    /// to render the Destination column.
    func allDestinations() -> [LibraryRootPath: LibraryRootPath] {
        destinationBySource
    }

    func allDeviceDestinations() -> [String: LibraryRootPath] {
        destinationByDeviceIdentity
    }
}
