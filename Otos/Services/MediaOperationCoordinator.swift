import Foundation
import OSLog

/// Media operation coordinator guide
///
/// Owns greedy import-plan lifecycle for every attached removable source.
/// Single source of truth is `sourceSessions` — one `SourceSession` per attached
/// source path, keyed by `LibraryRootPath`. Every session carries its current
/// attachment generation, destination, preferences, phase, dirtiness, import intent,
/// build generation, and timing. Claims and presentations are derived from live
/// sessions, never separately authoritative. Every asynchronous completion carries
/// typed `AttachmentGeneration` + `BuildGeneration` and is discarded if it no longer
/// belongs to the current session. Cancellation is resource management only;
/// identity validation is the correctness proof.
///
/// Isolation: actor serializes per-source dirtiness (at most one build in flight
/// and one dirty bit per session). Plan building runs off-actor via
/// `ImportPlanBuilding`; the coordinator never awaits a build from the
/// planning-change consumer. Namespace enumeration and planning run off-actor,
/// and every completion revalidates typed occupancy revisions and ledger identity
/// before publishing.
actor MediaOperationCoordinator {
    private let store: CatalogStore
    private let preferences: any PreferenceStore
    private let preferencesDomain: PreferencesDomain
    private let cameraImport: CameraImportAccess?
    private let materializationRequester: MaterializationRequesting?
    private let autoEjectHandler: (@Sendable (LibraryRoot) async -> Void)?
    private let planBuilder: any ImportPlanBuilding
    private let makeExecutor: @Sendable (LibraryRootPath) -> any ImportExecuting

    // MARK: - Stage 4 single-session model

    private struct AttachmentGeneration: Equatable, Hashable, Sendable {
        let rawValue: UInt64
    }

    private struct BuildGeneration: Equatable, Hashable, Sendable {
        let rawValue: UInt64
    }

    private struct BuildContext {
        let generation: BuildGeneration
        let runID: String
        let task: Task<Void, Never>
    }

    private struct ReadyContext {
        let plan: MediaOperationPlan
        let skippedPackageCount: Int
        let claims: Set<FilesystemNameKey>
        let attentionItems: [MediaAttentionItem]
    }

    private struct ExecutionContext {
        let plan: MediaOperationPlan
        let claims: Set<FilesystemNameKey>
        let executor: any ImportExecuting
        let task: Task<Void, Never>
        let summary: MediaOperationPlanTotals
        let generation: UInt64
        let skippedPackageCount: Int
        let prefs: ImportPreferences
        let batch: ImportBatchID
        let runID: String
    }

    private enum SourcePhase {
        case inventory
        case waitingForMetadata(done: Int, total: Int)
        case building(BuildContext)
        case ready(ReadyContext)
        case executing(ExecutionContext)
        case completed
        case executionUnavailable(summary: MediaOperationPlanTotals, generation: UInt64, attentionItems: [MediaAttentionItem])
        case failed(reason: MediaOperationFailureReason, publishedCount: Int)
    }

    /// The most recent execution's outcome for the current attachment, kept
    /// across the post-settlement re-plan so a card left in the reader keeps
    /// reporting what it just copied (`import-bar.md` state F) instead of that
    /// fact vanishing the moment the phase leaves `.completed`. Cleared only by
    /// a new `AttachmentGeneration` (card ejected and re-inserted) — never by a
    /// later re-plan within the same attachment.
    private struct AttachmentCompletion {
        let batch: ImportBatchID?
        let publishedCount: Int
        let isFullyClean: Bool
        /// Items that started this run but did not land, carried alongside the
        /// rest of the completion so state F's incomplete variant can still
        /// select and scroll them after the post-settlement re-plan
        /// (`import-bar.md` state F).
        let incompleteItems: [MediaAssetID]
        let eraseOutcome: EraseOutcome?
        /// The instant this run actually settled, published as state
        /// (`MediaOperationSourcePresentation.settledAt`) so the ViewModel's
        /// auto-dismiss task computes its 6 s deadline from a stable anchor
        /// rather than from whenever it happened to observe a frame — an
        /// unrelated `publish()` re-emitting this same unchanged completion
        /// must not restart the countdown (`import-bar.md` "Done bar
        /// auto-dismisses after ~6 s only on a fully clean run").
        let settledAt: Date
    }

    /// A settled `.completed` execution's outcome, stored on the session so
    /// `presentation(for:)` can read a real value instead of the zero-summary
    /// literal `.completed` used to synthesize on every publish.
    private struct SettledOutcome {
        let summary: MediaOperationPlanTotals
        let skippedForeignCount: Int
        let failedCount: Int
        let incompleteItems: [MediaAssetID]
        let eraseOutcome: EraseOutcome?
    }

    private struct SourceSession {
        let attachmentGeneration: AttachmentGeneration
        var root: CatalogLibraryState
        var destination: LibraryRootPath?
        /// Whether `destination` was picked via the pop-up this attachment,
        /// rather than still tracking the default. A default destination keeps
        /// following the first available library — including through a
        /// Settings → Libraries reorder while the card is attached — a
        /// deliberate consequence of following the order rather than a fixed
        /// pick. An explicit pick only falls back when it actually becomes unavailable,
        /// per its own "must survive until that run finishes" rule. Reset to
        /// `false` only by a new attachment, never by an incidental re-plan.
        var isDestinationExplicit: Bool
        var preferences: ImportPreferences
        var phase: SourcePhase
        var isDirty: Bool
        var importRequested: Bool
        var nextBuildGeneration: BuildGeneration
        var attachStartedAt: ContinuousClock.Instant
        var attachToReadyMs: Int?
        /// The live execution's most recent progress, so a `publish()` that
        /// fires for an unrelated reason mid-execution (another source's
        /// catalog change, say) re-derives the real in-flight progress from
        /// `presentation(for:)` instead of resetting the bar to zero.
        /// Set to a true starting value the moment `.executing`
        /// begins and overwritten by every subsequent progress callback; only
        /// meaningful while `phase` is `.executing`.
        var lastProgress: MediaOperationProgress?
        /// The most recent settled `.completed` execution's outcome. Set in the
        /// same transaction as `phase = .completed`; only meaningful while
        /// `phase` is `.completed`.
        var settledOutcome: SettledOutcome?
        var lastCompletion: AttachmentCompletion?
        /// The most recently minted batch for this attachment, set the moment
        /// execution begins and left alone afterward. `lastCompletion` only
        /// exists for a *settled* execution, so a run that fails before ever
        /// producing one (out of space detected immediately, say) would
        /// otherwise lose its batch ID the instant the phase leaves
        /// `.executing` — right when state G most needs it, to stay pinned and
        /// visible on the batch row (`import-bar.md` state G, "never
        /// auto-dismisses").
        var lastAttemptedBatch: ImportBatchID?
        /// Correlates the current source session's plan, execution, and
        /// presentation diagnostics. Minted at the building boundary so a
        /// re-plan cannot accidentally join an older run.
        var activeRunID: String?
        /// Whether `lastAttemptedBatch` has at least one durably-published
        /// asset yet, per `store.importBatchAssetCount`. Gates `.executing`'s
        /// own `batchID` exposure so `followNewBatchesOnce` never navigates
        /// to a batch row before there is anything in it to show (owner
        /// decision: "move batch selection to first-asset"). Reset to
        /// `false` at the start of every new attempt in
        /// `runExecution`. Terminal-state batch visibility
        /// (`.completed`/`.cancelled`/`.failed`) is unaffected — that fallback
        /// already has its own reason to stay eager (state G pinning).
        var batchAssetCountConfirmed = false
    }

    private var sourceSessions: [LibraryRootPath: SourceSession] = [:]
    private var lastPresentationLogAt: [LibraryRootPath: ContinuousClock.Instant] = [:]
    /// The last presentation a *settled* attachment showed, captured at the
    /// moment its source session is removed (card ejected or pulled once
    /// nothing is executing). The batch row outlives the source session
    /// (`import-bar.md` "Where the user is standing"), so this is what lets F
    /// keep rendering as "card gone" from `.importBatch(id)` after the
    /// removable row disappears — the fact `MediaOperationSourcePresentation`'s
    /// `cardStillExists` documents as needing "a later increment's
    /// batch-keyed presentation that outlives the source session". Kept for
    /// the app session's lifetime, same as every other in-memory coordinator
    /// fact here; the population is bounded by how many imports a session
    /// actually runs, so no eviction is warranted yet. A source still
    /// `.executing` at detach (the card pulled mid-copy, J9) is not snapshot
    /// here — that needs the cancel-vs-detach race disentangled first, which
    /// is separate follow-up work, not this one.
    private var detachedBatchPresentations: [ImportBatchID: MediaOperationSourcePresentation] = [:]
    private var nextAttachmentGeneration: UInt64 = 1
    private var isShuttingDown = false
    /// Snapshot of `store.currentLibraries()` refreshed every `refreshSources()`
    /// call, so `presentation(for:)` can resolve the destination's display name
    /// synchronously instead of adding an actor hop to every publish.
    private var librariesByPath: [LibraryRootPath: CatalogLibraryState] = [:]

    /// Persistent per-source destination mapping, retained even after detach for
    /// Settings display (includes unavailable sources). Mirrors `session.destination`
    /// while attached but is never cleared on detach.
    private var destinationBySource: [LibraryRootPath: LibraryRootPath] = [:]
    private var lastSeenOccupancy: [LibraryRootPath: UInt64] = [:]

    private var continuations: [UUID: AsyncStream<[MediaOperationSourcePresentation]>.Continuation] = [:]
    private var isStarted = false
    private var consumerTask: Task<Void, Never>?
    private var catalogChangeTask: Task<Void, Never>?

    init(
        store: CatalogStore,
        preferencesDomain: PreferencesDomain,
        planBuilder: any ImportPlanBuilding = LiveImportPlanBuilder(),
        makeExecutor: (@Sendable (LibraryRootPath) -> any ImportExecuting)? = nil,
        cameraImport: CameraImportAccess? = nil,
        materializationRequester: MaterializationRequesting? = nil,
        autoEjectHandler: (@Sendable (LibraryRoot) async -> Void)? = nil
    ) {
        self.store = store
        self.preferencesDomain = preferencesDomain
        preferences = preferencesDomain.makeDefaults()
        self.planBuilder = planBuilder
        self.cameraImport = cameraImport
        self.materializationRequester = materializationRequester
        self.autoEjectHandler = autoEjectHandler
        if let makeExecutor {
            self.makeExecutor = makeExecutor
        } else {
            let capturedStore = store
            let capturedCamera = cameraImport
            let capturedMaterialization = materializationRequester
            self.makeExecutor = { _ in
                LiveImportExecutor(
                    store: capturedStore,
                    cameraImport: capturedCamera,
                    materializationRequester: capturedMaterialization
                )
            }
        }
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
        guard !isStarted else { return }
        isStarted = true
        isShuttingDown = false
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
                guard let self else { return }
                await handlePlanningChange(change)
            }
        }
        let catalogChanges = await store.changeNotifications()
        catalogChangeTask = Task { [weak self] in
            for await _ in catalogChanges {
                guard let self else { return }
                await handleCatalogChangeForMetadataGate()
                await confirmExecutingBatchAssetCounts()
                await refreshSources(reason: "catalogChange")
            }
        }
        let subscribed = consumerTask != nil
        OtosLog.catalog.notice(
            "op=import.coordinator phase=subscribed planningStream=\(subscribed, privacy: .public)"
        )
    }

    func shutdown() async {
        guard isStarted else { return }
        isShuttingDown = true
        consumerTask?.cancel()
        catalogChangeTask?.cancel()
        // Snapshot owned tasks before clearing sessions so we can await them.
        var ownedBuildTasks: [Task<Void, Never>] = []
        var ownedExecTasks: [Task<Void, Never>] = []
        var ownedExecutors: [any ImportExecuting] = []
        for session in sourceSessions.values {
            switch session.phase {
            case let .building(ctx):
                ownedBuildTasks.append(ctx.task)
                ctx.task.cancel()
            case let .executing(ctx):
                ownedExecTasks.append(ctx.task)
                ownedExecutors.append(ctx.executor)
                ctx.task.cancel()
                Task { await ctx.executor.cancel() }
            default: break
            }
        }
        // Clear sessions synchronously so claims and presentations die immediately.
        sourceSessions.removeAll()
        publish()
        _ = await consumerTask?.value
        consumerTask = nil
        _ = await catalogChangeTask?.value
        catalogChangeTask = nil
        for task in ownedBuildTasks {
            _ = await task.value
        }
        for task in ownedExecTasks {
            _ = await task.value
        }
        // Executors already asked to cancel; nothing more to do. Journal remains recoverable.
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        isStarted = false
        isShuttingDown = false
    }

    func setDestination(_ destination: LibraryRootPath, for source: LibraryRootPath) async {
        destinationBySource[source] = destination
        persistDestinationMappings()
        guard var session = sourceSessions[source] else {
            // Source not yet attached. `destinationBySource` above is
            // recorded for Settings display only — a session created later
            // always starts on the default (first available library), not
            // this value.
            return
        }
        let previous = session.destination
        session.destination = destination
        session.isDestinationExplicit = true
        if previous != destination {
            session.isDirty = true
        }
        sourceSessions[source] = session
        if session.isDirty {
            scheduleBuildIfNeeded(source)
        }
        publish()
    }

    func preferencesDidChange() async {
        for source in sourceSessions.keys {
            sourceSessions[source]?.isDirty = true
            scheduleBuildIfNeeded(source)
        }
    }

    func setSessionPreferences(_ prefs: ImportPreferences, for source: LibraryRootPath) async {
        guard var session = sourceSessions[source] else { return }
        session.preferences = prefs
        session.isDirty = true
        sourceSessions[source] = session
        scheduleBuildIfNeeded(source)
    }

    func queueImport(for source: LibraryRootPath) async {
        guard var session = sourceSessions[source] else {
            OtosLog.catalog.notice("op=import.queue phase=rejected reason=noSession rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        // Reject if already executing.
        if case .executing = session.phase {
            OtosLog.catalog.notice("op=import.queue phase=rejected reason=alreadyExecuting rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        session.importRequested = true
        sourceSessions[source] = session
        switch session.phase {
        case let .ready(ctx):
            // Move to queued presentation via derived state and begin execution.
            publish()
            await beginExecutionIfPossible(source: source, readyContext: ctx)
        case .executing:
            // Already handled above.
            break
        default:
            // Not ready yet; mark dirty so planning will queue execution when ready.
            // Show queuedForReadiness immediately if not already building/executing.
            publish()
            session.isDirty = true
            sourceSessions[source]?.isDirty = true
            scheduleBuildIfNeeded(source)
        }
        OtosLog.catalog.notice("op=import.queue phase=start rootPath=\(source.rawValue, privacy: .public)")
    }

    private func beginExecutionIfPossible(source: LibraryRootPath, readyContext: ReadyContext) async {
        guard var session = sourceSessions[source] else { return }
        guard case let .ready(ctx) = session.phase, ctx.plan.generation == readyContext.plan.generation else {
            // Plan changed; need rebuild.
            session.isDirty = true
            sourceSessions[source] = session
            scheduleBuildIfNeeded(source)
            return
        }
        let libraries = await store.currentLibraries()
        guard let sourceState = libraries.first(where: { $0.path == source }) else { return }
        guard ImportSourceReadiness.evaluate(sourceState) == .ready else {
            // Still enumerating/scanning, or unreachable. `importRequested`
            // stays set; the next occupancy-driven rebuild (D2) or the
            // catalog-change refresh once activity flips idle (see
            // `refreshSources`) retries this same request.
            OtosLog.catalog.notice("op=import.execute phase=deferred reason=sourceNotReady rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        guard isExecutableSource(sourceState) else {
            markExecutionUnavailable(
                source: source,
                summary: ctx.plan.totals,
                generation: ctx.plan.generation,
                attentionItems: ctx.attentionItems
            )
            return
        }
        // Zero-copy without delete: stay ready.
        if ctx.plan.totals.copyCount == 0, ctx.plan.totals.companionCopyCount == 0 {
            guard session.preferences.deleteSourceAfterImport else {
                // Remain ready, clear import request so it doesn't auto-requeue.
                session.importRequested = false
                sourceSessions[source] = session
                publish()
                return
            }
        }
        await runExecution(source: source, sourceState: sourceState, readyContext: ctx)
    }

    private func isExecutableSource(_ sourceState: CatalogLibraryState) -> Bool {
        switch sourceState.root.kind {
        case .removableVolume: true
        case .deviceMTP: cameraImport != nil
        case .library: false
        }
    }

    private func markExecutionUnavailable(
        source: LibraryRootPath,
        summary: MediaOperationPlanTotals,
        generation: UInt64,
        attentionItems: [MediaAttentionItem]
    ) {
        guard var session = sourceSessions[source] else { return }
        session.phase = .executionUnavailable(
            summary: summary,
            generation: generation,
            attentionItems: attentionItems
        )
        sourceSessions[source] = session
        publish()
    }

    private func runExecution(source: LibraryRootPath, sourceState: CatalogLibraryState, readyContext: ReadyContext) async {
        guard var session = sourceSessions[source] else { return }
        guard case .ready = session.phase else { return }

        let runID = session.activeRunID ?? "missing"
        OtosLog.catalog.noticeOperation("import.activity", phase: "started", fields: ["rootPath": source.rawValue, "run": runID])
        let executor = makeExecutor(source)
        let claims = readyContext.claims
        let plan = readyContext.plan
        let summary = plan.totals
        let generation = plan.generation
        let skipped = readyContext.skippedPackageCount
        let prefs = session.preferences
        let attachmentGen = session.attachmentGeneration
        // Minted here, not read off `plan.mode` (a throwaway id re-minted on
        // every re-plan — trap #6) and not left to the executor to mint deep
        // inside `execute()`: the coordinator is the one place that must know
        // it before execution starts, tracked as session state
        // (`lastAttemptedBatch`) from here on (`import-bar.md` "Where the
        // user is standing"). The presentation's own `batchID` field is not
        // exposed this eagerly — see `currentBatchID(for:)`.
        let batch = ImportBatchID()

        // Keep execution task for cancellation/shutdown, but execution itself
        // runs as the current actor task (awaited) so the caller (queueImport)
        // blocks until the batch is committed. The stored task mirrors the work
        // for shutdown cancellation without creating a detached race.
        let execTask = Task {}
        let ctx = ExecutionContext(
            plan: plan,
            claims: claims,
            executor: executor,
            task: execTask,
            summary: summary,
            generation: generation,
            skippedPackageCount: skipped,
            prefs: prefs,
            batch: batch,
            runID: runID
        )
        session.phase = .executing(ctx)
        session.importRequested = false
        session.lastAttemptedBatch = batch
        session.batchAssetCountConfirmed = false
        // A true starting value (real totals, zero completed), overwritten by
        // the executor's first progress callback moments later — not a
        // fabricated zero, since it's what's actually true before any bytes
        // have moved.
        session.lastProgress = MediaOperationProgress(
            completedCount: 0,
            totalCount: summary.copyCount,
            completedBytes: 0,
            totalBytes: summary.copyBytes,
            elapsedMs: 0
        )
        sourceSessions[source] = session
        publish()

        let result = await executor.execute(
            plan: plan,
            batch: batch,
            sourceKind: sourceState.root.kind,
            sourceDeviceIdentity: sourceState.root.deviceIdentity,
            deleteSourceRequested: prefs.deleteSourceAfterImport,
            runID: runID
        ) { progress in
            Task { await self.applyExecutionProgress(source: source, attachment: attachmentGen, progress: progress) }
        }
        await applyExecutionResult(
            result,
            source: source,
            attachment: attachmentGen,
            context: ctx,
            sourceRoot: sourceState.root
        )
    }

    private func applyExecutionProgress(source: LibraryRootPath, attachment: AttachmentGeneration, progress: MediaOperationProgress) {
        guard var session = sourceSessions[source],
              session.attachmentGeneration == attachment,
              case .executing = session.phase
        else {
            return
        }
        // Stored on the session so any later `publish()` — including one fired
        // for an unrelated reason mid-execution — re-derives this same live
        // value via `presentation(for:)` instead of resetting to zero.
        // `publish()` is the only yield to continuations.
        session.lastProgress = progress
        sourceSessions[source] = session
        publish()
    }

    private func applyExecutionResult(
        _ result: MediaImportExecutionResult,
        source: LibraryRootPath,
        attachment: AttachmentGeneration,
        context: ExecutionContext,
        sourceRoot: LibraryRoot
    ) async {
        guard var session = sourceSessions[source],
              session.attachmentGeneration == attachment,
              case .executing = session.phase
        else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=execResultStale source=\(source.rawValue, privacy: .public)")
            return
        }
        let summary = context.summary
        switch result {
        case let .completed(publishedCount, hasBlockedEntries, hasEntryFailures, skippedForeignCount, failedCount, incompleteItems):
            session.phase = .completed
            // Stricter than the auto-eject gate just below on purpose: a
            // foreign skip doesn't block physically ejecting the card, but it
            // does keep the bar from auto-dismissing, since the plan's own
            // "must join" list for the auto-dismiss gate names it explicitly
            // (`import-bar.md` "What the presentation must carry").
            session.lastCompletion = AttachmentCompletion(
                batch: summary.copyCount + summary.companionCopyCount > 0 ? context.batch : nil,
                publishedCount: publishedCount,
                isFullyClean: !hasBlockedEntries && !hasEntryFailures
                    && skippedForeignCount == 0 && summary.blockedCount == 0,
                incompleteItems: incompleteItems,
                eraseOutcome: nil,
                settledAt: Date()
            )
            // Stored on the session so `presentation(for:)` reads the real
            // outcome instead of the zero-summary literal `.completed` used to
            // synthesize on every publish. `publish()` is the only yield to
            // continuations.
            session.settledOutcome = SettledOutcome(
                summary: summary,
                skippedForeignCount: skippedForeignCount,
                failedCount: failedCount,
                incompleteItems: incompleteItems,
                eraseOutcome: nil
            )
            if summary.copyCount + summary.companionCopyCount == 0 {
                session.lastAttemptedBatch = nil
            }
            sourceSessions[source] = session
            publish()
            if context.prefs.autoEjectAfterImport, !hasBlockedEntries, !hasEntryFailures, summary.blockedCount == 0 {
                await autoEjectIfRequested(sourceRoot)
            }
        case let .completedWithErase(publishedCount, hasBlockedEntries, hasEntryFailures, skippedForeignCount, failedCount, incompleteItems, eraseOutcome):
            session.phase = .completed
            session.lastCompletion = AttachmentCompletion(
                batch: summary.copyCount + summary.companionCopyCount > 0 ? context.batch : nil,
                publishedCount: publishedCount,
                isFullyClean: !hasBlockedEntries && !hasEntryFailures
                    && skippedForeignCount == 0 && summary.blockedCount == 0
                    && eraseOutcome.failedCount == 0,
                incompleteItems: incompleteItems,
                eraseOutcome: eraseOutcome,
                settledAt: Date()
            )
            session.settledOutcome = SettledOutcome(
                summary: summary,
                skippedForeignCount: skippedForeignCount,
                failedCount: failedCount,
                incompleteItems: incompleteItems,
                eraseOutcome: eraseOutcome
            )
            if summary.copyCount + summary.companionCopyCount == 0 {
                session.lastAttemptedBatch = nil
            }
            sourceSessions[source] = session
            publish()
            if context.prefs.autoEjectAfterImport, !hasBlockedEntries, !hasEntryFailures,
               summary.blockedCount == 0, eraseOutcome.failedCount == 0
            {
                await autoEjectIfRequested(sourceRoot)
            }
        case let .cancelled(publishedCount, _, _, _, _):
            // Release claim: go to inventory and rebuild. This ensures the
            // cancelled execution's destination reservation does not block
            // other sources (e.g. B) from reclaiming the base name. A cancelled
            // run is never fully clean (J8): the re-planned Ready state still
            // reports what landed before the stop.
            session.phase = .inventory
            session.isDirty = true
            session.lastCompletion = AttachmentCompletion(
                batch: context.batch,
                publishedCount: publishedCount,
                isFullyClean: false,
                incompleteItems: [],
                eraseOutcome: nil,
                settledAt: Date()
            )
            sourceSessions[source] = session
            publish()
        case let .failed(reason):
            session.phase = .failed(reason: reason, publishedCount: 0)
            sourceSessions[source] = session
            publish()
        }
        OtosLog.catalog.noticeOperation("import.activity", phase: "finished", fields: ["rootPath": source.rawValue, "run": session.activeRunID ?? "missing"])
        // After terminal settlement, claims die with phase. Dirty to rebuild (new occupancy etc.)
        session = sourceSessions[source] ?? session
        // For completed/cancelled/failed, we want to rebuild to reflect new namespace truth.
        // Keep destination, mark dirty, and flush if needed.
        if var current = sourceSessions[source] {
            // Don't immediately remove completed; keep completed presentation briefly then rebuild.
            // Per original, after execution, it dirties and schedules rebuild.
            current.isDirty = true
            // For completed, keep completed briefly? Original dirtied and scheduled, but
            // presentation went to completed; next build will move to planning.
            // We schedule after a short delay via handlePlanningChange occupancy bump.
            // For now, schedule rebuild.
            sourceSessions[source] = current
            scheduleBuildIfNeeded(source)
        }
        // Flush coalesced destination-driven rebuilds.
        if let finishedDestination = destinationBySource[source] {
            let stillExecuting = sourceSessions.values.contains { sess in
                if case .executing = sess.phase, sess.destination == finishedDestination {
                    return true
                }
                return false
            }
            if !stillExecuting {
                for (otherSource, dest) in destinationBySource where dest == finishedDestination && otherSource != source {
                    if var otherSession = sourceSessions[otherSource], otherSession.isDirty {
                        if case .building = otherSession.phase {
                            continue
                        }
                        if case .executing = otherSession.phase {
                            continue
                        }
                        scheduleBuildIfNeeded(otherSource)
                        // swiftlint:disable:next line_length
                        OtosLog.catalog.notice("op=import.coordinator phase=flushRebuild source=\(otherSource.rawValue, privacy: .public) destination=\(dest.rawValue, privacy: .public)")
                    }
                }
            }
        }
    }

    private func autoEjectIfRequested(_ root: LibraryRoot) async {
        if root.kind == .deviceMTP {
            guard let identity = root.deviceIdentity, let cameraImport else { return }
            let outcome = await cameraImport.eject(identity: identity)
            OtosLog.catalog.notice("op=import.autoEject phase=camera outcome=\(String(describing: outcome), privacy: .public)")
            return
        }
        if let autoEjectHandler {
            await autoEjectHandler(root)
        }
    }

    func currentPresentations() -> [MediaOperationSourcePresentation] {
        sortedPresentations()
    }

    func readyPlan(for source: LibraryRootPath) -> MediaOperationPlan? {
        guard let session = sourceSessions[source], case let .ready(ctx) = session.phase else { return nil }
        return ctx.plan
    }

    func cancelImport(for source: LibraryRootPath) async {
        guard let session = sourceSessions[source], case let .executing(ctx) = session.phase else {
            OtosLog.catalog.notice("op=import.cancel phase=requested rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        await ctx.executor.cancel()
        OtosLog.catalog.notice("op=import.cancel phase=requested rootPath=\(source.rawValue, privacy: .public)")
    }

    func retryPlanning(for source: LibraryRootPath) async {
        guard var session = sourceSessions[source] else { return }
        session.isDirty = true
        sourceSessions[source] = session
        scheduleBuildIfNeeded(source)
        OtosLog.catalog.notice("op=import.retry phase=requested rootPath=\(source.rawValue, privacy: .public)")
    }

    private func handlePlanningChange(_ change: RootPlanningChange) async {
        // swiftlint:disable:next line_length
        OtosLog.catalog.noticeOperation("import.coordinator", phase: "receive", fields: ["rootPath": change.rootPath.rawValue, "occupancyRevision": "\(change.occupancyRevision)"])
        let occupancyChanged = lastSeenOccupancy[change.rootPath] != change.occupancyRevision
        lastSeenOccupancy[change.rootPath] = change.occupancyRevision
        if occupancyChanged {
            let libraries = await store.currentLibraries()
            let removable = libraries.filter { $0.root.kind != .library }
            if removable.contains(where: { $0.path == change.rootPath }) {
                if var sess = sourceSessions[change.rootPath], case .executing = sess.phase {
                    // Don't rebuild executing source itself; it will rebuild after execution.
                    sess.isDirty = true
                    sourceSessions[change.rootPath] = sess
                } else if var sess = sourceSessions[change.rootPath] {
                    sess.isDirty = true
                    sourceSessions[change.rootPath] = sess
                    scheduleBuildIfNeeded(change.rootPath)
                }
            }
            // Destination-driven rebuilds
            let executingDestinations = Set(sourceSessions.values.compactMap { sess -> LibraryRootPath? in
                if case .executing = sess.phase {
                    return sess.destination
                }
                return nil
            })
            let isDestinationUnderExecution = executingDestinations.contains(change.rootPath)
            for (source, _) in sourceSessions where sourceSessions[source]?.destination == change.rootPath {
                guard var sess = sourceSessions[source] else { continue }
                sess.isDirty = true
                sourceSessions[source] = sess
                if isDestinationUnderExecution {
                    // swiftlint:disable:next line_length
                    OtosLog.catalog.notice("op=import.coordinator phase=suppressRebuild source=\(source.rawValue, privacy: .public) destination=\(change.rootPath.rawValue, privacy: .public)")
                    continue
                }
                if case .executing = sess.phase {
                    continue
                }
                scheduleBuildIfNeeded(source)
            }
        }
        await refreshSources(reason: "planningChange")
    }

    private func handleCatalogChangeForMetadataGate() async {
        var waitingSources: [LibraryRootPath] = []
        for (source, session) in sourceSessions {
            if case .waitingForMetadata = session.phase {
                waitingSources.append(source)
            }
        }
        guard !waitingSources.isEmpty else { return }
        for source in waitingSources {
            guard var sess = sourceSessions[source] else { continue }
            sess.isDirty = true
            sourceSessions[source] = sess
            scheduleBuildIfNeeded(source)
        }
        OtosLog.catalog.notice("op=import.coordinator phase=catalogChangeWake waitingCount=\(waitingSources.count, privacy: .public)")
    }

    /// Confirms, for every still-executing session that hasn't proven itself
    /// yet, whether its batch now has at least one durably-published asset —
    /// the fact `currentBatchID` gates `.executing`'s own `batchID` exposure
    /// on. Piggybacks on the catalog-change notification
    /// this coordinator already consumes for every attached source rather
    /// than adding a second, dedicated polling loop: an import's own
    /// publish/settle writes are themselves catalog changes, so this fires
    /// promptly without inventing new machinery for it.
    private func confirmExecutingBatchAssetCounts() async {
        let candidates = sourceSessions.compactMap { source, session -> (LibraryRootPath, ImportBatchID)? in
            guard case let .executing(ctx) = session.phase, !session.batchAssetCountConfirmed else {
                return nil
            }
            return (source, ctx.batch)
        }
        guard !candidates.isEmpty else { return }
        var didConfirm = false
        for (source, batch) in candidates {
            let count = await (try? store.importBatchAssetCount(batch)) ?? 0
            guard count > 0,
                  var session = sourceSessions[source],
                  case let .executing(ctx) = session.phase,
                  ctx.batch == batch
            else {
                continue
            }
            session.batchAssetCountConfirmed = true
            sourceSessions[source] = session
            didConfirm = true
        }
        if didConfirm {
            publish()
        }
    }

    private func refreshSources(reason: String) async {
        let libraries = await store.currentLibraries()
        librariesByPath = CatalogWindowPolicy.rootsByPath(from: libraries)
        let fixedAvailable = libraries.filter { $0.root.kind == .library && $0.availability == .available }
        let removable = libraries.filter { $0.root.kind != .library && $0.availability == .available }
        var seen = Set<LibraryRootPath>()
        for source in removable {
            seen.insert(source.path)
            let currentOccupancy = await store.occupancyRevision(for: source.path)
            if sourceSessions[source.path] == nil {
                let attachmentGen = AttachmentGeneration(rawValue: nextAttachmentGeneration)
                nextAttachmentGeneration &+= 1
                let prefs = ImportPreferencesStore.load(defaults: preferences)
                // The destination is remembered per removable source (plan
                // 0095 D19, owner decision — `import-bar.md` "Destination
                // control"): a source seen before resumes wherever it last
                // landed, explicit pick or default-tracked alike, both of
                // which `destinationBySource` already records unconditionally
                // (see `setDestination` and the reorder-tracking branch
                // below). `isDestinationExplicit: true` is what makes the
                // memory stick — without it, the very next reorder-tracking
                // refresh would immediately overwrite it back to
                // `fixedAvailable.first`, silently discarding the memory the
                // moment it was restored. First sight of a source (no
                // remembered value, or its library is gone) falls back to
                // the first available library and stays a true default,
                // tracking future reorders per the existing mechanic.
                let remembered = destinationBySource[source.path]
                let isRememberedValid = remembered.map { dest in
                    fixedAvailable.contains { $0.path == dest }
                } ?? false
                let destination = isRememberedValid ? remembered : fixedAvailable.first?.path
                if destinationBySource[source.path] != destination {
                    if let destination {
                        destinationBySource[source.path] = destination
                    } else {
                        destinationBySource.removeValue(forKey: source.path)
                    }
                    persistDestinationMappings()
                }
                let newSession = SourceSession(
                    attachmentGeneration: attachmentGen,
                    root: source,
                    destination: destination,
                    isDestinationExplicit: isRememberedValid,
                    preferences: prefs,
                    phase: .inventory,
                    isDirty: true,
                    importRequested: false,
                    nextBuildGeneration: BuildGeneration(rawValue: 1),
                    attachStartedAt: ContinuousClock().now,
                    attachToReadyMs: nil,
                    lastProgress: nil,
                    settledOutcome: nil,
                    lastCompletion: nil,
                    lastAttemptedBatch: nil,
                    activeRunID: nil
                )
                sourceSessions[source.path] = newSession
                lastSeenOccupancy[source.path] = currentOccupancy
                scheduleBuildIfNeeded(source.path)
            } else {
                // Update root for existing session (availability may have changed)
                sourceSessions[source.path]?.root = source
                // A session's plan goes stale the moment the root it was built from
                // gains new/changed rows — device enumeration landing after attach is
                // exactly this: the session already exists (created
                // from whatever rows were persisted at attach) and this occupancy
                // bump is how it learns the live inventory superseded that snapshot.
                // Reuses the same `lastSeenOccupancy` map `handlePlanningChange` keys
                // staleness on, so both triggering paths (the occupancy-aware
                // planning-change stream and this cheaper catalog-change refresh)
                // agree on what "already seen" means.
                if lastSeenOccupancy[source.path] != currentOccupancy {
                    lastSeenOccupancy[source.path] = currentOccupancy
                    sourceSessions[source.path]?.isDirty = true
                    if case .executing = sourceSessions[source.path]?.phase {
                        // Don't rebuild the executing source itself; it rebuilds
                        // after execution settles, same as handlePlanningChange.
                    } else {
                        scheduleBuildIfNeeded(source.path)
                    }
                }
                // Never touch the destination of a session that is actively
                // executing: its ExecutionContext (claims, namespace lease)
                // already committed to a specific destination, and rewriting
                // `session.destination` out from under a live copy would
                // desync it from the ledger it's actually writing into.
                let isExecuting = if case .executing = sourceSessions[source.path]?.phase {
                    true
                } else {
                    false
                }
                let currentDestination = sourceSessions[source.path]?.destination
                let isExplicit = sourceSessions[source.path]?.isDestinationExplicit ?? false
                // A default destination keeps tracking the first available
                // library on every refresh, including a Settings → Libraries
                // reorder while attached. An explicit pop-up pick instead
                // survives an ordinary refresh until it actually becomes
                // unavailable, at which point it reverts to tracking the
                // default again rather than staying pinned to the fallback.
                var newDestination = currentDestination
                var explicitAfterUpdate = isExplicit
                if !isExecuting {
                    if isExplicit {
                        let isCurrentValid = currentDestination.map { dest in fixedAvailable.contains(where: { $0.path == dest }) } ?? false
                        if !isCurrentValid {
                            newDestination = fixedAvailable.first?.path
                            explicitAfterUpdate = false
                        }
                    } else {
                        newDestination = fixedAvailable.first?.path
                    }
                }
                if newDestination != currentDestination || explicitAfterUpdate != isExplicit {
                    sourceSessions[source.path]?.destination = newDestination
                    sourceSessions[source.path]?.isDestinationExplicit = explicitAfterUpdate
                    if destinationBySource[source.path] != newDestination {
                        if let newDestination {
                            destinationBySource[source.path] = newDestination
                        } else {
                            destinationBySource.removeValue(forKey: source.path)
                        }
                        persistDestinationMappings()
                    }
                    sourceSessions[source.path]?.isDirty = true
                    scheduleBuildIfNeeded(source.path)
                }
                // Readiness can turn `.ready` (enumeration/scan activity flips
                // idle) via this cheap catalog-change refresh alone, without an
                // occupancy change of its own — device enumeration's final
                // completion bump already retried a still-not-ready
                // `beginExecutionIfPossible` once above, but the idle flip
                // itself lands as a separate, occupancy-unchanged event.
                // Without this, a queued Import that lost that race would
                // never be retried. Safe to call unconditionally: it no-ops
                // unless the session is genuinely `.ready` with a matching
                // plan generation and still has `importRequested` set.
                if let session = sourceSessions[source.path],
                   session.importRequested,
                   case let .ready(ctx) = session.phase
                {
                    await beginExecutionIfPossible(source: source.path, readyContext: ctx)
                }
            }
        }
        // Detach: remove sessions for missing sources, cancel owned work.
        for path in Array(sourceSessions.keys) where !seen.contains(path) {
            if let session = sourceSessions[path] {
                var isExecutingNewImport = false
                switch session.phase {
                case let .building(ctx): ctx.task.cancel()
                case let .executing(ctx):
                    ctx.task.cancel()
                    Task { await ctx.executor.cancel() }
                    isExecutingNewImport = true
                default: break
                }
                // A settled attachment snapshots its final presentation under
                // its batch identity before the session disappears, so F
                // (card gone) can still render on the batch row
                // (`import-bar.md` state F, J1 step 7). `.building` here is
                // the ordinary post-settlement re-plan racing this same
                // detach, not a fresh execution — `lastCompletion` already
                // carries what matters and must snapshot the same as any
                // other non-executing phase.
                //
                // J9 wants the card pulled *while a new import is executing*
                // to fail with a named cause instead. A typed `.sourceRemoved`
                // frame published here would be overwritten by this same
                // method's final `publish()` before any consumer's turn to
                // observe it — `refreshSources` has no suspension point
                // between the two — so it is not a real producer, only a
                // misleading one. Doing this right needs the cancel-vs-detach
                // race disentangled from an ordinary user Cancel, which this
                // snapshot does not attempt — follow-up work, not this one.
                if !isExecutingNewImport, let completion = session.lastCompletion, let batch = completion.batch {
                    detachedBatchPresentations[batch] = makePresentation(
                        session: session,
                        state: .completed(
                            summary: MediaOperationPlanTotals(
                                copyCount: completion.publishedCount,
                                skipCount: 0,
                                blockedCount: 0,
                                companionCopyCount: 0,
                                copyBytes: 0
                            ),
                            incompleteItems: completion.incompleteItems
                        ),
                        cardStillExists: false
                    )
                }
            }
            sourceSessions.removeValue(forKey: path)
            // Keep destinationBySource for Settings; clear transient occupancy.
            lastSeenOccupancy.removeValue(forKey: path)
        }
        publish()
        OtosLog.catalog.noticeOperation("import.coordinator", phase: "refresh", fields: ["reason": reason, "sourceCount": "\(removable.count)"])
    }

    private func scheduleBuildIfNeeded(_ source: LibraryRootPath) {
        guard !isShuttingDown else { return }
        guard var session = sourceSessions[source] else { return }
        guard session.isDirty else { return }
        if case .building = session.phase {
            return
        }
        if case .executing = session.phase {
            return
        }
        session.isDirty = false
        let buildGen = session.nextBuildGeneration
        session.nextBuildGeneration = BuildGeneration(rawValue: buildGen.rawValue &+ 1)
        let attachmentGen = session.attachmentGeneration
        let runID = UUID().uuidString
        let destination = session.destination
        // swiftlint:disable:next line_length
        OtosLog.catalog.noticeOperation("plan.rebuild", phase: "schedule", fields: ["source": source.rawValue, "destination": destination?.rawValue ?? "none", "generation": "\(buildGen.rawValue)", "attachment": "\(attachmentGen.rawValue)", "run": runID])
        guard let destination else {
            // No destination is state B ("No destination"), not a failure —
            // `destinationPath == nil` on the presentation is what the mapper
            // reads; this reason is never shown.
            session.phase = .failed(reason: .unexpected(detail: "noDestinationLibrary"), publishedCount: 0)
            sourceSessions[source] = session
            publish()
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await runBuild(source: source, destination: destination, generation: buildGen.rawValue, attachment: attachmentGen)
        }
        session.activeRunID = runID
        session.phase = .building(BuildContext(generation: buildGen, runID: runID, task: task))
        sourceSessions[source] = session
        publish()
    }

    private func runBuild(source: LibraryRootPath, destination: LibraryRootPath, generation: UInt64, attachment: AttachmentGeneration) async {
        defer {
            // Conditional cleanup is implicit via phase identity; no legacy dictionary to clean.
            // If session still building with same generation/attachment, caller will clear.
            // No action needed here beyond logging stale if needed.
        }
        do {
            try await buildPlan(source: source, destination: destination, generation: generation, attachment: attachment)
        } catch {
            guard let session = sourceSessions[source],
                  session.attachmentGeneration == attachment,
                  case let .building(ctx) = session.phase,
                  ctx.generation.rawValue == generation
            else {
                OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=buildFailureStale source=\(source.rawValue, privacy: .public)")
                return
            }
            var updated = session
            updated.phase = .failed(reason: .unexpected(detail: String(describing: error)), publishedCount: 0)
            sourceSessions[source] = updated
            publish()
        }
    }

    private nonisolated static func logPlanFinished(
        source: LibraryRootPath,
        runID: String,
        sourceCount: Int,
        namingMtimeCount: Int,
        namingSettledCount: Int,
        result: ImportPlanBuildResult
    ) {
        // swiftlint:disable:next line_length
        OtosLog.catalog.noticeOperation("import.plan", phase: "finish", fields: ["rootPath": source.rawValue, "run": runID, "sourceCount": "\(sourceCount)", "folders": "\(result.namespace.folderCount)", "namespaceEntries": "\(result.namespace.entryCount)", "enumerateMs": "\(result.enumerateMs)", "planMs": "\(result.planMs)", "copyCount": "\(result.plan.totals.copyCount)", "skipCount": "\(result.plan.totals.skipCount)", "excludedCount": "\(result.plan.totals.excludedCount)", "blockedCount": "\(result.plan.totals.blockedCount)", "namingMtimeCount": "\(namingMtimeCount)", "namingSettledCount": "\(namingSettledCount)"])
    }

    private func buildPlan(source: LibraryRootPath, destination: LibraryRootPath, generation: UInt64, attachment: AttachmentGeneration) async throws {
        guard isStarted, !isShuttingDown else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=notStarted source=\(source.rawValue, privacy: .public)")
            return
        }
        guard var session = sourceSessions[source] else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=noSession source=\(source.rawValue, privacy: .public)")
            return
        }
        guard session.attachmentGeneration == attachment else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=attachmentMismatch source=\(source.rawValue, privacy: .public)")
            return
        }
        guard case let .building(ctx) = session.phase, ctx.generation.rawValue == generation else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=phaseMismatch source=\(source.rawValue, privacy: .public)")
            return
        }
        let runID = ctx.runID
        guard session.destination == destination else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=destinationMismatch source=\(source.rawValue, privacy: .public)")
            var updated = session
            updated.isDirty = true
            // Keep phase as building? Need to reset to inventory to allow rebuild.
            updated.phase = .inventory
            sourceSessions[source] = updated
            publish()
            scheduleBuildIfNeeded(source)
            return
        }
        let prefs = session.preferences
        let policy = ImportPolicy.from(prefs)
        guard let snapshot = try await store.importPlanningSnapshot(source: source, destination: destination, policy: policy, generation: generation) else {
            let libraries = await store.currentLibraries()
            let reason = MediaOperationFailureReason.forMissingSnapshot(
                source: source,
                destination: destination,
                availableRoots: CatalogWindowPolicy.availablePaths(from: libraries)
            )
            var updated = session
            updated.phase = .failed(reason: reason, publishedCount: 0)
            sourceSessions[source] = updated
            publish()
            return
        }
        if await shouldWaitForMetadata(source: source, snapshot: snapshot, attachment: attachment, generation: generation, runID: runID) {
            return
        }
        // swiftlint:disable:next line_length
        OtosLog.catalog.noticeOperation("import.plan", phase: "start", fields: ["rootPath": source.rawValue, "destinationPath": destination.rawValue, "sourceCount": "\(snapshot.sourceMedia.count)", "destinationOccupants": "\(snapshot.destinationOccupants.count)", "run": runID])
        let seededClaims = ledgerClaims(for: destination, excluding: source)
        let signpost = OtosSignpost.performance.beginInterval("ImportPlanBuild")
        let build = await planBuilder.build(
            snapshot: snapshot,
            additionalReserved: Set(seededClaims.map { MediaRelativePath(rawValue: $0.rawValue) })
        )
        OtosSignpost.performance.endInterval("ImportPlanBuild", signpost)
        let plan = build.plan
        Self.logPlanFinished(
            source: source,
            runID: runID,
            sourceCount: snapshot.sourceMedia.count,
            namingMtimeCount: snapshot.sourceMedia.filter {
                $0.namingFactState != .pending && $0.captureWallCompact == nil && $0.hasAnyDate
            }.count,
            namingSettledCount: snapshot.sourceMedia.count { $0.namingFactState != .pending },
            result: build
        )
        guard let current = sourceSessions[source],
              current.attachmentGeneration == attachment,
              case let .building(currentCtx) = current.phase,
              currentCtx.generation.rawValue == generation,
              current.destination == destination
        else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=staleAfterBuild source=\(source.rawValue, privacy: .public)")
            return
        }
        let sourceOccupancy = await store.occupancyRevision(for: source)
        let destinationOccupancy = await store.occupancyRevision(for: destination)
        guard sourceOccupancy == snapshot.sourceOccupancyRevision,
              destinationOccupancy == snapshot.destinationOccupancyRevision
        else {
            // swiftlint:disable:next line_length
            OtosLog.catalog.noticeOperation("import.plan", phase: "stale", fields: ["rootPath": source.rawValue, "sourceOccupancy": "\(sourceOccupancy.map(String.init) ?? "none")", "snapshotSourceOccupancy": "\(snapshot.sourceOccupancyRevision)", "destinationOccupancy": "\(destinationOccupancy.map(String.init) ?? "none")", "snapshotDestinationOccupancy": "\(snapshot.destinationOccupancyRevision)", "run": runID])
            var updated = current
            updated.isDirty = true
            updated.phase = .inventory
            sourceSessions[source] = updated
            publish()
            scheduleBuildIfNeeded(source)
            return
        }
        let newClaims = planClaims(from: plan, capabilities: snapshot.destinationCapabilities)
        let currentLedger = ledgerClaims(for: destination, excluding: source)
        if !newClaims.isDisjoint(with: currentLedger) {
            // swiftlint:disable:next line_length
            OtosLog.catalog.noticeOperation("import.plan", phase: "conflict", fields: ["rootPath": source.rawValue, "destination": destination.rawValue, "newClaims": "\(newClaims.count)", "conflictingClaims": "\(newClaims.intersection(currentLedger).count)", "run": runID])
            var updated = current
            updated.isDirty = true
            updated.phase = .inventory
            sourceSessions[source] = updated
            publish()
            scheduleBuildIfNeeded(source)
            return
        }
        let skipped = await store.skippedPackageCount(for: source)
        let readyCtx = ReadyContext(
            plan: plan,
            skippedPackageCount: skipped,
            claims: newClaims,
            attentionItems: plan.attentionItems
        )
        var updated = current
        updated.phase = .ready(readyCtx)
        updated.isDirty = false
        if updated.attachToReadyMs == nil {
            let elapsed = updated.attachStartedAt.duration(to: ContinuousClock().now)
            updated.attachToReadyMs = DiagnosticsTiming.milliseconds(elapsed)
            // swiftlint:disable:next line_length
            OtosLog.catalog.notice("op=import.attachToReady phase=ready run=\(runID, privacy: .public) rootPath=\(source.rawValue, privacy: .public) elapsedMs=\(updated.attachToReadyMs ?? 0, privacy: .public) copyCount=\(plan.totals.copyCount, privacy: .public)")
        }
        sourceSessions[source] = updated
        publish()
        if updated.importRequested {
            await beginExecutionIfPossible(source: source, readyContext: readyCtx)
        } else if updated.isDirty {
            scheduleBuildIfNeeded(source)
        }
    }

    // swiftlint:disable:next line_length
    private func shouldWaitForMetadata(source: LibraryRootPath, snapshot: ImportPlanningSnapshot, attachment: AttachmentGeneration, generation: UInt64, runID: String) async -> Bool {
        let filesWithNoDateAtAll = snapshot.sourceMedia.filter { !$0.hasAnyDate }.count
        let total = snapshot.sourceMedia.count
        let settled = snapshot.sourceMedia.count { $0.namingFactState != .pending }
        let libraries = await store.currentLibraries()
        let sourceKind = libraries.first(where: { $0.path == source })?.root.kind
        guard sourceKind != .deviceMTP,
              MediaTransferPlanner.needsDate(policy: snapshot.policy),
              snapshot.sourceMedia.contains(where: { $0.namingFactState == .pending })
        else {
            return false
        }
        guard var session = sourceSessions[source],
              session.attachmentGeneration == attachment,
              case let .building(ctx) = session.phase, ctx.generation.rawValue == generation
        else {
            return false
        }
        let message = "op=import.readiness phase=waitingForMetadata run=\(runID) "
            + "rootPath=\(source.rawValue) "
            + "settled=\(settled) "
            + "total=\(total) "
            + "filesWithNoDateAtAll=\(filesWithNoDateAtAll)"
        OtosLog.catalog.notice("\(message, privacy: .public)")
        session.phase = .waitingForMetadata(done: settled, total: max(total, 1))
        sourceSessions[source] = session
        publish()
        return true
    }

    private func ledgerClaims(for destination: LibraryRootPath, excluding excludedSource: LibraryRootPath? = nil) -> Set<FilesystemNameKey> {
        var result: Set<FilesystemNameKey> = []
        for (source, session) in sourceSessions where session.destination == destination && source != excludedSource {
            switch session.phase {
            case let .ready(ctx): result.formUnion(ctx.claims)
            case let .executing(ctx): result.formUnion(ctx.claims)
            default: break
            }
        }
        return result
    }

    private func planClaims(
        from plan: MediaOperationPlan,
        capabilities: VolumeNamespaceCapabilities
    ) -> Set<FilesystemNameKey> {
        var claims: Set<FilesystemNameKey> = []
        for entry in plan.entries {
            guard case .copy = entry.disposition else { continue }
            claims.insert(FilesystemNamespaceSemantics.nameKey(relativePath: entry.finalDestination, capabilities: capabilities))
            for dest in entry.companionDestinations.values {
                claims.insert(FilesystemNamespaceSemantics.nameKey(relativePath: dest, capabilities: capabilities))
            }
        }
        return claims
    }

    private func presentation(for session: SourceSession) -> MediaOperationSourcePresentation {
        let state: MediaOperationSourceState = switch session.phase {
        case .inventory:
            session.importRequested ? .queuedForReadiness : .inventory
        case let .waitingForMetadata(done, total):
            session.importRequested ? .queuedForReadiness : .waitingForMetadata(done: done, total: total)
        case .building:
            session.importRequested ? .queuedForReadiness : .planning
        case let .ready(ctx):
            session.importRequested ? .queuedForReadiness : readyState(for: session, ctx: ctx)
        case .executing:
            executingState(for: session)
        case .completed:
            completedState(for: session)
        case let .executionUnavailable(summary, generation, attentionItems):
            .executionUnavailable(summary: summary, generation: generation, attentionItems: attentionItems)
        case let .failed(reason, publishedCount):
            .failed(reason: reason, publishedCount: publishedCount)
        }
        return makePresentation(session: session, state: state)
    }

    /// `runExecution` sets `lastProgress` in the same transaction it sets
    /// `phase = .executing`, and `applyExecutionProgress` is the only other
    /// writer of either — so a `.executing` phase with no stored progress is
    /// unreachable, not a case to paper over with a fabricated zero.
    private func executingState(for session: SourceSession) -> MediaOperationSourceState {
        guard let progress = session.lastProgress else {
            preconditionFailure("`.executing` phase always sets `lastProgress` in the same transaction (runExecution)")
        }
        return .executing(progress: progress)
    }

    /// `applyExecutionResult` sets `settledOutcome` in the same transaction it
    /// sets `phase = .completed`, and is the only writer of either — so a
    /// `.completed` phase with no stored outcome is unreachable, not a case to
    /// paper over with a fabricated zero-summary literal.
    private func completedState(for session: SourceSession) -> MediaOperationSourceState {
        guard let outcome = session.settledOutcome else {
            preconditionFailure("`.completed` phase always sets `settledOutcome` in the same transaction (applyExecutionResult)")
        }
        return .completed(
            summary: outcome.summary,
            skippedForeignCount: outcome.skippedForeignCount,
            failedCount: outcome.failedCount,
            incompleteItems: outcome.incompleteItems
        )
    }

    /// A built, internally-`.ready` plan is only shown as state C once the
    /// source itself proves its live inventory is trustworthy (ADR 0024):
    /// a plan built the instant a device root became available — from
    /// whatever rows were already persisted at attach — must not be offered
    /// while enumeration is still filling in the real picture. Readiness alone
    /// isn't quite enough for the empty-card branch specifically: readiness
    /// can flip to `.ready` (activity idle) in the same beat an occupancy bump
    /// lands, before this session's own plan has had a chance to rebuild
    /// against it, so a *provably* empty plan additionally requires
    /// `!session.isDirty` — no rebuild is currently owed against a staleness
    /// signal the coordinator has already received — otherwise a genuinely-
    /// populated source could flash "This card is empty" for one frame.
    ///
    /// This checks the dirty bit rather than comparing `lastSeenOccupancy`
    /// against `ctx.plan.sourceOccupancyRevision` directly: a source whose
    /// inventory never changes again after settling (an empty card that never
    /// gains a file) never earns another occupancy bump to reconcile the two
    /// independently-sampled values, so an equality check between them can
    /// permanently disagree with no future event able to fix it — the dirty
    /// bit is the coordinator's own accounting of whether it is guaranteed
    /// caught up, not a second, freestanding derivation of the same fact.
    private func readyState(for session: SourceSession, ctx: ReadyContext) -> MediaOperationSourceState {
        guard ImportSourceReadiness.evaluate(session.root) == .ready else {
            return .inventory
        }
        let totals = ctx.plan.totals
        let isEmptyCard = totals.copyCount == 0 && totals.companionCopyCount == 0 && totals.skipCount == 0
        if isEmptyCard, session.isDirty {
            return .inventory
        }
        return .ready(
            summary: totals,
            generation: ctx.plan.generation,
            skippedPackageCount: ctx.skippedPackageCount,
            attentionItems: ctx.attentionItems
        )
    }

    /// The batch this attachment is currently working on or last worked on:
    /// the live execution's batch while executing (once it has proven itself
    /// non-empty — see `batchAssetCountConfirmed`), else the most recent
    /// *settled* execution's batch, else the most recent *attempted* one —
    /// covering a run that failed before ever settling — else `nil` before any
    /// execution has started (`import-bar.md` "Where the user is standing").
    ///
    /// The `.executing` branch is gated and the terminal fallback is not: a
    /// long-running import must not surface `batchID` — and so pull
    /// `followNewBatchesOnce` into a batch row with nothing in it yet —
    /// before its first asset actually lands (owner decision), but a
    /// *failed* run still needs its batch pinned and visible
    /// on state G regardless of whether anything ever published, which is
    /// exactly what `lastAttemptedBatch`'s existing fallback already
    /// guarantees.
    private func currentBatchID(for session: SourceSession) -> ImportBatchID? {
        if case let .executing(ctx) = session.phase {
            return session.batchAssetCountConfirmed ? ctx.batch : nil
        }
        return session.lastCompletion?.batch ?? session.lastAttemptedBatch
    }

    private func makePresentation(
        session: SourceSession,
        state: MediaOperationSourceState,
        cardStillExists: Bool? = nil
    ) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: session.root.path,
            sourceKind: session.root.kind,
            destinationPath: session.destination,
            destinationDisplayName: session.destination.flatMap { librariesByPath[$0]?.displayName },
            state: state,
            attachToReadyMs: session.attachToReadyMs,
            batchID: currentBatchID(for: session),
            cardStillExists: cardStillExists ?? (session.root.availability == .available),
            copiedJustNow: session.lastCompletion?.publishedCount,
            isFullyClean: session.lastCompletion?.isFullyClean,
            settledAt: session.lastCompletion?.settledAt,
            sessionPreferences: session.preferences,
            incompleteItems: session.lastCompletion?.incompleteItems ?? [],
            eraseOutcome: session.lastCompletion?.eraseOutcome
        )
    }

    private func sortedPresentations() -> [MediaOperationSourcePresentation] {
        let live = sourceSessions.values.map { presentation(for: $0) }
        let liveBatchIDs = Set(live.compactMap(\.batchID))
        let detached = detachedBatchPresentations.filter { batchID, _ in !liveBatchIDs.contains(batchID) }.values
        // swiftlint:disable:next line_length
        return (live + detached).sorted { $0.sourcePath.rawValue.localizedStandardCompare($1.sourcePath.rawValue) == .orderedAscending }
    }

    private func publish() {
        let values = sortedPresentations()
        let now = ContinuousClock().now
        for presentation in values {
            let shouldLog = lastPresentationLogAt[presentation.sourcePath].map {
                $0.duration(to: now) >= .milliseconds(250)
            } ?? true
            guard shouldLog else { continue }
            lastPresentationLogAt[presentation.sourcePath] = now
            let progress: MediaOperationProgress? = if case let .executing(value) = presentation.state {
                value
            } else {
                nil
            }
            let batchID = presentation.batchID.map { String(describing: $0) } ?? "none"
            let runID = sourceSessions[presentation.sourcePath]?.activeRunID ?? "none"
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=import.presentation phase=publish run=\(runID, privacy: .public) sourcePath=\(presentation.sourcePath.rawValue, privacy: .public) state=\(String(describing: presentation.state), privacy: .public) completedCount=\(progress?.completedCount ?? 0, privacy: .public) totalCount=\(progress?.totalCount ?? 0, privacy: .public) completedBytes=\(progress?.completedBytes ?? 0, privacy: .public) batchID=\(batchID, privacy: .public)"
            )
        }
        for continuation in continuations.values {
            continuation.yield(values)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static let destinationMappingKey = "import.destinationBySource"
    // Unused by any current logic — named only so `loadDestinationMappings`
    // can clear whatever an earlier build persisted under these keys.
    private static let retiredDestinationByDeviceIdentityKey = "import.destinationByDeviceIdentity"
    private static let retiredLastUsedDestinationKey = "import.lastUsedDestination"

    private func loadDestinationMappings() {
        preferences.removeObject(forKey: Self.retiredDestinationByDeviceIdentityKey)
        preferences.removeObject(forKey: Self.retiredLastUsedDestinationKey)
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
        var raw: [String: String] = [:]
        for (source, dest) in destinationBySource {
            raw[source.rawValue] = dest.rawValue
        }
        if raw.isEmpty {
            preferences.removeObject(forKey: Self.destinationMappingKey)
        } else {
            preferences.set(raw, forKey: Self.destinationMappingKey)
        }
    }

    func allDestinations() -> [LibraryRootPath: LibraryRootPath] {
        destinationBySource
    }
}
