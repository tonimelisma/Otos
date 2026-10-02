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
    /// Backoff for a build deferred on an unreadable destination folder — a
    /// cloud provider mid-sync answers `contentsOfDirectory` with an error for a
    /// moment. Injectable so a test does not wait a minute.
    private let unreadableRetryDelays: [Duration]
    /// Reads the destination volume's available capacity for state C's
    /// "not everything will fit" line — the same reader the executor's floor
    /// uses, so "available" means one thing in Otos. Injectable for tests.
    private let volumeCapacity: @Sendable (URL) -> Int64?
    private let makeExecutor: @Sendable (LibraryRootPath) -> any ImportExecuting

    // MARK: - Stage 4 single-session model

    private typealias AttachmentGeneration = MediaOperationAttachmentGeneration

    private struct BuildGeneration: Equatable, Hashable, Sendable {
        let rawValue: UInt64
    }

    private struct BuildContext {
        let generation: BuildGeneration
        let runID: String
        let task: Task<Void, Never>
    }

    /// A build that found a destination folder it could not read is deferred,
    /// not published: the absence of an observation is not a plan. The retry
    /// is owned here — cancelled with the session on detach and shutdown —
    /// and bounded by `unreadableRetryDelays`; past the last delay the
    /// condition is presented as a planning failure the user can `Try Again`.
    private struct UnreadableRetry {
        let attempt: Int
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
        var task: Task<Void, Never>?
        let sourceKind: LibraryRootKind
        let summary: MediaOperationPlanTotals
        let generation: UInt64
        let skippedPackageCount: Int
        let prefs: ImportPreferences
        let batch: ImportBatchID
        let runID: String
        let attachment: AttachmentGeneration
        var interruption: ExecutionInterruption?
    }

    private enum ExecutionInterruption: Equatable {
        case userCancellation
        case sourceRemoved
    }

    private struct DrainingExecution {
        let context: ExecutionContext
    }

    private enum SourcePhase {
        case inventory
        case waitingForMetadata(done: Int, total: Int)
        case building(BuildContext)
        case ready(ReadyContext)
        case executing(ExecutionContext)
        case completed
        case executionUnavailable(
            summary: MediaOperationPlanTotals,
            generation: UInt64,
            attentionItems: [MediaAttentionItem]
        )
        case planningFailed(reason: MediaOperationFailureReason)
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
        /// Why this run stopped before attempting every planned entry, or `nil`
        /// for a run that attempted them all. Published as
        /// `MediaOperationSourcePresentation.stopReason` so state F's Stopped
        /// variant renders from the run's own facts across the re-plan.
        let stopReason: ImportStopReason?
        /// The number of entries this run set out to copy — the plan's
        /// `copyCount` at execution — published as `plannedCount` for
        /// "12 of 42". The re-plan's own `copyCount` is the remainder and is
        /// not this number.
        let plannedCount: Int
        /// The library this run copied into. `presentation(for:)` publishes
        /// the completion's outcome only while the session's destination is
        /// still this library: "42 copied just now · 181 items in Camera Roll"
        /// would otherwise pair a count that landed in one library with the
        /// name of another after a destination change (`import-bar.md` state
        /// F, "scoped to this attachment and to the library it copied into").
        /// The batch identity is not gated: it is the run's, whatever the
        /// destination now says.
        let destination: LibraryRootPath
    }

    /// The last run's failure, recorded beside `lastCompletion` rather than as
    /// a phase. A phase says what the session is doing *now*, and the rebuild
    /// that follows every settlement rightly replaces it; a finished run's
    /// outcome is a fact that rebuild has no business rewriting. Kept as a phase,
    /// the failure was erased by the re-plan within the same actor turn — drawn
    /// for 24 ms on 2026-09-09 — against `import-bar.md` state G's "never
    /// auto-dismisses". Planning failures (no destination, no snapshot) stay
    /// phases: they *are* the session's current condition, and a successful
    /// rebuild should replace them.
    private struct AttachmentFailure {
        let reason: MediaOperationFailureReason
        /// What this run had landed before it failed — state G states it when
        /// nonzero. Every present producer fails before any copy.
        let publishedCount: Int
        /// The run's batch, named in the settlement log when the card is
        /// removed while state G stands.
        let batch: ImportBatchID
        let destination: LibraryRootPath
    }

    /// A settled `.completed` execution's outcome, stored on the session so
    /// `presentation(for:)` reads the real outcome rather than synthesizing a
    /// zero-summary `.completed` on every publish.
    private struct SettledOutcome {
        let summary: MediaOperationPlanTotals
        let skippedForeignCount: Int
        let failedCount: Int
        let incompleteItems: [MediaAssetID]
        let eraseOutcome: EraseOutcome?
    }

    /// A proven naming count for one attachment.
    ///
    /// Named rather than a tuple so "done of total" cannot be read in the wrong order at a
    /// call site, and so the thing being held has a name in the state that holds it.
    struct NamingProgress: Equatable, Sendable {
        let done: Int
        let total: Int
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
        /// The most recent naming progress this attachment reported.
        ///
        /// Preparing is the state that owns a count, but nothing held one across a
        /// rebuild: `.building` fell through to `.planning`, which draws no L3 line and an
        /// indeterminate track. The live session alternated `.planning` and
        /// `.waitingForMetadata` about once a second with the pair ~140 ms apart, so the
        /// bar's track could not hold still while the user watched it — the count vanished
        /// and the bar went indeterminate for a fraction of every cycle.
        ///
        /// Held rather than recomputed because a rebuild has no count of its own to offer;
        /// showing the last proven one asserts nothing new, since it was already proven and
        /// published. Scoped to the attachment, so a new card starts from nothing.
        var lastNamingProgress: NamingProgress?
        /// The most recent settled `.completed` execution's outcome. Set in the
        /// same transaction as `phase = .completed`; only meaningful while
        /// `phase` is `.completed`.
        var settledOutcome: SettledOutcome?
        /// The most recent plan this attachment actually proved, kept across the
        /// rebuilds that follow it. A re-plan overwrites `phase` with `.building`, so
        /// without this the plan the user is looking at is destroyed the moment a
        /// newer one is scheduled and the bar falls back to state A — reporting
        /// "Checking the card…" as though nothing were known, once a second for as
        /// long as anything kept invalidating (ARC-047). State A means *no plan
        /// has ever existed for this attachment*; a refresh is not a first check.
        ///
        /// Written in the same transaction as `phase = .ready`, like
        /// `lastCompletion`/`lastProgress`, and cleared by nothing — a new
        /// `AttachmentGeneration` builds a fresh `SourceSession`, which is what makes
        /// ejecting and re-inserting a card forget the old plan.
        var lastReadyContext: ReadyContext?
        var lastCompletion: AttachmentCompletion?
        /// The last run's failure, if the most recent attempt failed. Cleared
        /// when the next attempt starts (`runExecution`) and when the user
        /// asks to plan again (`retryPlanning`) — never by a rebuild.
        var lastFailure: AttachmentFailure?
        /// The pending retry for a build deferred on an unreadable destination
        /// folder; `nil` when no such build is outstanding. Reset by a build
        /// that reads everything, by `Try Again`, and by a fresh attachment.
        var unreadableRetry: UnreadableRetry?
        /// Correlates the current source session's plan, execution, and
        /// presentation diagnostics. Minted at the building boundary so a
        /// re-plan cannot accidentally join an older run.
        var activeRunID: String?
        /// Whether the executing batch has at least one durably-published
        /// asset yet, per `store.importBatchAssetCount`. Gates the
        /// presentation's `batchID` so the batch row's progress indicator is
        /// keyed only once that row exists in the sidebar. Reset to `false`
        /// at the start of every new attempt in `runExecution`.
        var batchAssetCountConfirmed = false
    }

    private var sourceSessions: [LibraryRootPath: SourceSession] = [:]
    /// Last state logged per source, so `publish()` records transitions rather than a
    /// sample of whatever a timer happened to catch (B3).
    private var lastLoggedState: [LibraryRootPath: MediaOperationSourceState] = [:]
    /// Execution contexts whose source disappeared while the executor was still
    /// running. The task is the actual executor lifetime, so the result can settle
    /// the old batch without ever being eligible to mutate a replacement source
    /// session at the same path.
    private var drainingExecutions: [ImportBatchID: DrainingExecution] = [:]
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
    private var lastSeenRevisions: [LibraryRootPath: RootPlanningRevisions] = [:]

    private var continuations: [UUID: AsyncStream<[MediaOperationSourcePresentation]>.Continuation] = [:]
    private var isStarted = false
    private var consumerTask: Task<Void, Never>?
    private var catalogChangeTask: Task<Void, Never>?

    private func attachmentGeneration(for source: CatalogLibraryState) -> AttachmentGeneration {
        if source.attachmentGeneration != 0 {
            return AttachmentGeneration(rawValue: source.attachmentGeneration)
        }
        let generated = AttachmentGeneration(rawValue: nextAttachmentGeneration)
        nextAttachmentGeneration &+= 1
        return generated
    }

    private func isNewAttachment(
        _ source: CatalogLibraryState,
        replacing session: SourceSession
    ) -> Bool {
        if source.attachmentGeneration != 0,
           source.attachmentGeneration != session.root.attachmentGeneration
        {
            return true
        }
        return source.root.deviceIdentity != session.root.deviceIdentity
            || source.root.lastSeenAt != session.root.lastSeenAt
    }

    init(
        store: CatalogStore,
        preferencesDomain: PreferencesDomain,
        planBuilder: any ImportPlanBuilding = LiveImportPlanBuilder(),
        unreadableRetryDelays: [Duration] = [.seconds(1), .seconds(4), .seconds(16), .seconds(60)],
        volumeCapacity: @escaping @Sendable (URL) -> Int64? = MediaImportExecutor.importantUsageCapacity,
        makeExecutor: (@Sendable (LibraryRootPath) -> any ImportExecuting)? = nil,
        cameraImport: CameraImportAccess? = nil,
        materializationRequester: MaterializationRequesting? = nil,
        autoEjectHandler: (@Sendable (LibraryRoot) async -> Void)? = nil
    ) {
        self.store = store
        self.preferencesDomain = preferencesDomain
        preferences = preferencesDomain.makeDefaults()
        self.planBuilder = planBuilder
        self.unreadableRetryDelays = unreadableRetryDelays
        self.volumeCapacity = volumeCapacity
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
            session.unreadableRetry?.task.cancel()
            switch session.phase {
            case let .building(ctx):
                ownedBuildTasks.append(ctx.task)
                ctx.task.cancel()
            case let .executing(ctx):
                if let task = ctx.task {
                    ownedExecTasks.append(task)
                    task.cancel()
                }
                ownedExecutors.append(ctx.executor)
            default: break
            }
        }
        for draining in drainingExecutions.values {
            if let task = draining.context.task {
                ownedExecTasks.append(task)
                task.cancel()
            }
            ownedExecutors.append(draining.context.executor)
        }
        for executor in ownedExecutors {
            await executor.cancel()
        }
        drainingExecutions.removeAll()
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
            // The held plan and the settled outcome were measured against the
            // previous library — "42 new items", "139 already in", "everything
            // on this card is imported" are all claims about *it*. Holding them
            // across the rebuild (ARC-047's refresh-is-not-a-first-check rule)
            // would draw the old counts under the new library's name and offer
            // an Import whose number the click would not honour. A destination
            // change is a rebuild whose inputs changed, like a settlement, so
            // the bar returns to Checking until the new plan lands; the last
            // naming progress still carries its determinate count.
            session.lastReadyContext = nil
            session.settledOutcome = nil
            if case .completed = session.phase {
                // `.completed` presents from `settledOutcome`, which is gone.
                session.phase = .inventory
            }
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
            // Not ready yet; mark dirty so planning will begin execution when
            // ready. Publish so the bar disables Import for the held click.
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

    private func runExecution(
        source: LibraryRootPath,
        sourceState: CatalogLibraryState,
        readyContext: ReadyContext
    ) async {
        guard var session = sourceSessions[source] else { return }
        guard case .ready = session.phase else { return }

        let runID = session.activeRunID ?? "missing"
        OtosLog.catalog.noticeOperation(
            "import.activity",
            phase: "started",
            fields: ["rootPath": source.rawValue, "run": runID]
        )
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
        // it before execution starts, carried on the phase while executing and
        // on the recorded outcome afterward (`import-bar.md` "Where the user
        // is standing"). The presentation's own `batchID` field is not
        // exposed this eagerly — see `executingBatchID(for:)`.
        let batch = ImportBatchID()

        let ctx = ExecutionContext(
            plan: plan,
            claims: claims,
            executor: executor,
            task: nil,
            sourceKind: sourceState.root.kind,
            summary: summary,
            generation: generation,
            skippedPackageCount: skipped,
            prefs: prefs,
            batch: batch,
            runID: runID,
            attachment: attachmentGen,
            interruption: nil
        )
        session.phase = .executing(ctx)
        session.importRequested = false
        // A new attempt supersedes the last one's failure; its own outcome
        // will be recorded when it settles.
        session.lastFailure = nil
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

        // The task owns the actual executor lifetime. It is recorded on the
        // session before this actor can process a detach, so a source removal
        // transfers the same task into `drainingExecutions` instead of
        // cancelling a placeholder and discarding the final journal outcome.
        let coordinator = self
        let progressHandler: @Sendable (MediaOperationProgress) -> Void = { [weak coordinator] progress in
            Task { [weak coordinator] in
                await coordinator?.applyExecutionProgress(
                    source: source,
                    attachment: attachmentGen,
                    progress: progress
                )
            }
        }
        let executionTask = Task { [weak coordinator] in
            let result = await executor.execute(
                plan: plan,
                batch: batch,
                sourceKind: sourceState.root.kind,
                sourceDeviceIdentity: sourceState.root.deviceIdentity,
                deleteSourceRequested: prefs.deleteSourceAfterImport,
                runID: runID
            ) { progress in
                progressHandler(progress)
            }
            await coordinator?.finishExecution(
                result,
                source: source,
                attachment: attachmentGen,
                batch: batch,
                sourceRoot: sourceState.root
            )
        }
        guard var executingSession = sourceSessions[source],
              case var .executing(executingContext) = executingSession.phase,
              executingContext.batch == batch,
              executingSession.attachmentGeneration == attachmentGen
        else {
            executionTask.cancel()
            await executor.cancel()
            return
        }
        executingContext.task = executionTask
        executingSession.phase = .executing(executingContext)
        sourceSessions[source] = executingSession
        // Await the actual task so the public queue intent keeps its existing
        // completion semantics. Actor reentrancy still lets refreshSources()
        // detach the source while this await is suspended.
        await executionTask.value
    }

    private func finishExecution(
        _ result: MediaImportExecutionResult,
        source: LibraryRootPath,
        attachment: AttachmentGeneration,
        batch: ImportBatchID,
        sourceRoot: LibraryRoot
    ) async {
        if let session = sourceSessions[source],
           session.attachmentGeneration == attachment,
           case let .executing(context) = session.phase,
           context.batch == batch
        {
            await applyExecutionResult(
                result,
                source: source,
                attachment: attachment,
                context: context,
                sourceRoot: sourceRoot
            )
            return
        }
        guard let draining = drainingExecutions.removeValue(forKey: batch) else {
            OtosLog.catalog.notice(
                "op=import.coordinator phase=staleCompletion reason=executionOwnershipLost source=\(source.rawValue, privacy: .public) batchID=\(String(describing: batch), privacy: .public)"
            )
            return
        }
        await settleDetachedExecution(result, source: source, draining: draining)
    }

    /// Rejects a sample that would move either counter backwards.
    ///
    /// `ByteProgressTracker` is monotonic by construction — `creditedBytes` absorbs the
    /// drop when an entry finishes, and `settledCount` only increments — so a decrease is
    /// not a real regression but a sample that arrived out of order. It arrives out of
    /// order because the executor's callback fires on ~10 copy worker threads and each one
    /// spawns its own `Task` to reach this actor; Swift orders the snapshots the tracker's
    /// lock produces, but nothing orders the hops that carry them. Measured on a 999-item
    /// card: 528 of 3,925 published samples (13.5%) carried a smaller count than the one
    /// before, which the bar drew as a visible stutter.
    ///
    /// Dropping the stale sample loses nothing: samples are cumulative, so the next one
    /// carries everything the dropped one did, and the terminal value comes from
    /// `applyExecutionResult` rather than from any sample. This is the newest-value
    /// coalescing the callback always needed and never declared.
    private func applyExecutionProgress(
        source: LibraryRootPath,
        attachment: AttachmentGeneration,
        progress: MediaOperationProgress
    ) {
        guard var session = sourceSessions[source],
              session.attachmentGeneration == attachment,
              case .executing = session.phase
        else {
            return
        }
        if let previous = session.lastProgress, progress.isStale(comparedTo: previous) {
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
        guard let destination = context.plan.mode.importDestination else {
            preconditionFailure("an executing session's plan is always an import plan (mode: \(context.plan.mode))")
        }
        switch result {
        case let .completed(
            publishedCount,
            hasBlockedEntries,
            hasEntryFailures,
            skippedForeignCount,
            failedCount,
            incompleteItems
        ):
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
                stopReason: nil,
                plannedCount: summary.copyCount,
                destination: destination
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
            // The plan this run executed from is false now — its entries are
            // skips — so it must not be held across the rebuild: on 2026-09-13
            // the held pre-run plan drew `Ready · Import 368 Items` for 360 ms
            // between two Done frames. `presentation(for:)` shows the
            // settlement instead until the re-plan lands.
            session.lastReadyContext = nil
            sourceSessions[source] = session
            publish()
            if context.prefs.autoEjectAfterImport, !hasBlockedEntries, !hasEntryFailures, summary.blockedCount == 0 {
                await autoEjectIfRequested(sourceRoot)
            }
        case let .completedWithErase(
            publishedCount,
            hasBlockedEntries,
            hasEntryFailures,
            skippedForeignCount,
            failedCount,
            incompleteItems,
            eraseOutcome
        ):
            session.phase = .completed
            session.lastCompletion = AttachmentCompletion(
                batch: summary.copyCount + summary.companionCopyCount > 0 ? context.batch : nil,
                publishedCount: publishedCount,
                isFullyClean: !hasBlockedEntries && !hasEntryFailures
                    && skippedForeignCount == 0 && summary.blockedCount == 0
                    && eraseOutcome.failedCount == 0,
                incompleteItems: incompleteItems,
                eraseOutcome: eraseOutcome,
                stopReason: nil,
                plannedCount: summary.copyCount,
                destination: destination
            )
            session.settledOutcome = SettledOutcome(
                summary: summary,
                skippedForeignCount: skippedForeignCount,
                failedCount: failedCount,
                incompleteItems: incompleteItems,
                eraseOutcome: eraseOutcome
            )
            session.lastReadyContext = nil
            sourceSessions[source] = session
            publish()
            if context.prefs.autoEjectAfterImport, !hasBlockedEntries, !hasEntryFailures,
               summary.blockedCount == 0, eraseOutcome.failedCount == 0
            {
                await autoEjectIfRequested(sourceRoot)
            }
        case let .stopped(reason, publishedCount, _, _, _, _):
            // Release claim: go to inventory and rebuild. This ensures the
            // stopped execution's destination reservation does not block
            // other sources (e.g. B) from reclaiming the base name. A stopped
            // run is never fully clean (J8), so it neither auto-ejects nor
            // erases; the bar draws state F's Stopped variant from this
            // completion — what landed, of what was planned, and why it
            // stopped — and offers the re-plan's remainder as the act.
            session.phase = .inventory
            session.isDirty = true
            // The plan this run executed from is false now — its landed
            // entries are skips — and the rebuild replacing it has not run
            // yet. Holding it (ARC-047's refresh-is-not-a-first-check rule)
            // would offer the *pre-run* count as the remainder for the length
            // of the rebuild; dropping it makes the bar draw the act as
            // pending until the honest number lands (DES-030). The settled
            // outcome is this stop, not an earlier completion.
            session.lastReadyContext = nil
            session.settledOutcome = nil
            session.lastCompletion = AttachmentCompletion(
                batch: context.batch,
                publishedCount: publishedCount,
                isFullyClean: false,
                incompleteItems: [],
                eraseOutcome: nil,
                stopReason: reason,
                plannedCount: summary.copyCount,
                destination: destination
            )
            sourceSessions[source] = session
            publish()
        case let .failed(reason):
            // Recorded, not phased: the rebuild scheduled just below replaces
            // the phase and must not erase the failure (state G, "never
            // auto-dismisses"). The plan this run executed from is dropped as
            // on a stop — the run may have changed the namespace before it
            // failed — so the re-plan is what `Try Again` reveals.
            session.phase = .inventory
            session.isDirty = true
            session.lastReadyContext = nil
            session.settledOutcome = nil
            let publishedCount = await (try? store.importBatchAssetCount(context.batch)) ?? 0
            session.lastFailure = AttachmentFailure(
                reason: reason,
                publishedCount: publishedCount,
                batch: context.batch,
                destination: destination
            )
            sourceSessions[source] = session
            publish()
        }
        OtosLog.catalog.noticeOperation(
            "import.activity",
            phase: "finished",
            fields: ["rootPath": source.rawValue, "run": session.activeRunID ?? "missing"]
        )
        // Terminal settlement releases this source's claims with its phase, so
        // re-plan it against the namespace the run just changed.
        if var current = sourceSessions[source] {
            current.isDirty = true
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
                for (otherSource, dest) in destinationBySource
                    where dest == finishedDestination && otherSource != source
                {
                    guard scheduleBuildIfNeeded(otherSource) else { continue }
                    OtosLog.catalog.notice("op=import.coordinator phase=flushRebuild source=\(otherSource.rawValue, privacy: .public) destination=\(dest.rawValue, privacy: .public)")
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

    /// Removes a source session. Its outcome is status for the card's row, which
    /// no longer exists, so it is logged and dropped; the imported assets and
    /// journal remain in Store. Executing work transfers its existing task to
    /// the batch-keyed drain instead of creating a second task.
    private func disposeDetachedSession(
        path: LibraryRootPath,
        session: SourceSession,
        reason: String
    ) async {
        session.unreadableRetry?.task.cancel()
        switch session.phase {
        case let .building(context):
            context.task.cancel()
        case let .executing(existingContext):
            var context = existingContext
            context.interruption = context.interruption ?? .sourceRemoved
            drainingExecutions[context.batch] = DrainingExecution(
                context: context
            )
            context.task?.cancel()
            await context.executor.cancel()
            OtosLog.catalog.notice(
                "op=import.execution phase=draining reason=\(reason, privacy: .public) sourcePath=\(path.rawValue, privacy: .public) batchID=\(String(describing: context.batch), privacy: .public) attachment=\(session.attachmentGeneration.rawValue, privacy: .public)"
            )
        default:
            logDetachedOutcome(session)
        }
    }

    /// The import bar is drawn only on a live card's row (`import-bar.md`
    /// "Where the user is standing"), so a settled outcome has nowhere to be
    /// shown once its card is gone: the batch row's grid is the report. The
    /// outcome is logged, not kept.
    private func logDetachedOutcome(_ session: SourceSession) {
        if let failure = session.lastFailure {
            logDetachedSettlement(
                source: session.root.path,
                batch: failure.batch,
                outcome: "failed",
                publishedCount: failure.publishedCount
            )
        } else if let completion = session.lastCompletion, let batch = completion.batch {
            logDetachedSettlement(
                source: session.root.path,
                batch: batch,
                outcome: completion.isFullyClean ? "clean" : "incomplete",
                publishedCount: completion.publishedCount
            )
        }
    }

    /// Settles an execution whose card went away while it ran. The executor
    /// lifetime ends here and the outcome is logged; there is no card row
    /// left to draw it on.
    private func settleDetachedExecution(
        _ result: MediaImportExecutionResult,
        source: LibraryRootPath,
        draining: DrainingExecution
    ) async {
        let context = draining.context
        let publishedCount = await publishedCount(for: result, batch: context.batch)
        let outcome = if context.interruption == .sourceRemoved {
            "sourceRemoved"
        } else {
            switch result {
            case .completed, .completedWithErase: "completed"
            case .stopped: "stopped"
            case .failed: "failed"
            }
        }
        logDetachedSettlement(source: source, batch: context.batch, outcome: outcome, publishedCount: publishedCount)
    }

    private func publishedCount(
        for result: MediaImportExecutionResult,
        batch: ImportBatchID
    ) async -> Int {
        switch result {
        case let .completed(count, _, _, _, _, _),
             let .completedWithErase(count, _, _, _, _, _, _),
             let .stopped(_, count, _, _, _, _):
            return count
        case .failed:
            let count = try? await store.importBatchAssetCount(batch)
            return count ?? 0
        }
    }

    private func logDetachedSettlement(
        source: LibraryRootPath,
        batch: ImportBatchID,
        outcome: String,
        publishedCount: Int
    ) {
        OtosLog.catalog.notice(
            "op=import.outcome phase=settled sourcePath=\(source.rawValue, privacy: .public) batchID=\(String(describing: batch), privacy: .public) outcome=\(outcome, privacy: .public) publishedCount=\(publishedCount, privacy: .public)"
        )
    }

    func currentPresentations() -> [MediaOperationSourcePresentation] {
        sortedPresentations()
    }

    func readyPlan(for source: LibraryRootPath) -> MediaOperationPlan? {
        guard let session = sourceSessions[source], case let .ready(ctx) = session.phase else { return nil }
        return ctx.plan
    }

    func cancelImport(for source: LibraryRootPath) async {
        guard var session = sourceSessions[source], case var .executing(ctx) = session.phase else {
            OtosLog.catalog.notice("op=import.cancel phase=requested rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        ctx.interruption = ctx.interruption ?? .userCancellation
        session.phase = .executing(ctx)
        sourceSessions[source] = session
        await ctx.executor.cancel()
        OtosLog.catalog.notice("op=import.cancel phase=requested rootPath=\(source.rawValue, privacy: .public)")
    }

    func retryPlanning(for source: LibraryRootPath) async {
        guard var session = sourceSessions[source] else { return }
        // `Try Again` is the one act on state G: the user has addressed the
        // cause, so the recorded failure yields to whatever the re-plan finds,
        // and a deferred build's backoff starts over.
        session.lastFailure = nil
        session.unreadableRetry?.task.cancel()
        session.unreadableRetry = nil
        session.isDirty = true
        sourceSessions[source] = session
        scheduleBuildIfNeeded(source)
        OtosLog.catalog.notice("op=import.retry phase=requested rootPath=\(source.rawValue, privacy: .public)")
    }

    /// Applies a planning wake per role (ARC-046). A root's **namespace** revision
    /// invalidates every session reading it as source or destination; its **naming**
    /// revision invalidates only sessions reading it as *source*, because enriching an
    /// asset already in the destination renames nothing on disk and
    /// `fetchDestinationOccupants` never reads a capture wall. A wake that moves
    /// neither is `planRevision`-only churn and does no work.
    /// Wakes that moved no revision, per root, since the last one that did.
    ///
    /// Most planning-change notifications change nothing: a 999-item import measured
    /// 5,381 notifications against **16** actual plan rebuilds. A line per notification —
    /// thirteen per imported item — would bury the fact an agent actually needs, *which*
    /// wake moved a revision, under the ones that moved none.
    ///
    /// The count rides on the next line that reports a real change, so "wakes are arriving
    /// but nothing is moving" stays diagnosable without a line each.
    private var churnWakesByRoot: [LibraryRootPath: Int] = [:]

    /// Refreshes that left the source set unchanged, since the last one that did not.
    private var suppressedRefreshes = 0
    private var lastLoggedSourceCount: Int?

    /// Emit a summary after this many suppressed events even when nothing changed.
    ///
    /// Without it, a run where the source set never changes would log nothing at all and an
    /// agent debugging a stuck import would see silence — which is indistinguishable from a
    /// dead subscription. This bounds the worst case to roughly one line per 200 wakes
    /// instead of one per wake, while guaranteeing the path is never invisible.
    private static let churnSummaryThreshold = 200

    /// Logs a planning wake only when it moved a revision, or when enough have not.
    private func logPlanningWake(_ change: RootPlanningChange, moved: Bool) {
        let churn = churnWakesByRoot[change.rootPath, default: 0]
        guard moved || churn + 1 >= Self.churnSummaryThreshold else {
            churnWakesByRoot[change.rootPath] = churn + 1
            return
        }
        churnWakesByRoot[change.rootPath] = 0
        OtosLog.catalog.noticeOperation(
            "import.coordinator",
            phase: moved ? "receive" : "receiveChurn",
            fields: [
                "rootPath": change.rootPath.rawValue,
                "namespaceRevision": "\(change.namespaceRevision)",
                "namingRevision": "\(change.namingRevision)",
                "churnWakes": "\(moved ? churn : churn + 1)",
            ]
        )
    }

    private func handlePlanningChange(_ change: RootPlanningChange) async {
        let previous = lastSeenRevisions[change.rootPath]
        let namespaceChanged = previous?.namespaceRevision != change.namespaceRevision
        let namingChanged = previous?.namingRevision != change.namingRevision
        lastSeenRevisions[change.rootPath] = change.revisions
        logPlanningWake(change, moved: namespaceChanged || namingChanged)
        if namespaceChanged || namingChanged {
            let libraries = await store.currentLibraries()
            let removable = libraries.filter { $0.root.kind != .library }
            // Source role: the plan reads this root's inventory *and* its capture
            // walls (the date/time name is derived from them), so either revision
            // invalidates it.
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
            // Destination role: only a namespace change matters. An enrichment
            // naming write here moved no file, so every plan copying into this root
            // is still exactly as valid as it was — replanning on it is what
            // livelocked planning against an enriching cloud library (ARC-046).
            if namespaceChanged {
                rebuildSessionsTargeting(destination: change.rootPath)
            }
        }
        await refreshSources(reason: "planningChange")
    }

    /// The destination half of `handlePlanningChange`: every session copying *into*
    /// `destination` is stale because the names it can claim there just changed.
    private func rebuildSessionsTargeting(destination: LibraryRootPath) {
        let executingDestinations = Set(sourceSessions.values.compactMap { sess -> LibraryRootPath? in
            if case .executing = sess.phase {
                return sess.destination
            }
            return nil
        })
        let isDestinationUnderExecution = executingDestinations.contains(destination)
        for (source, _) in sourceSessions where sourceSessions[source]?.destination == destination {
            guard var sess = sourceSessions[source] else { continue }
            sess.isDirty = true
            sourceSessions[source] = sess
            if isDestinationUnderExecution {
                OtosLog.catalog.notice("op=import.coordinator phase=suppressRebuild source=\(source.rawValue, privacy: .public) destination=\(destination.rawValue, privacy: .public)")
                continue
            }
            if case .executing = sess.phase {
                continue
            }
            scheduleBuildIfNeeded(source)
        }
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
    /// the fact `executingBatchID` gates the presentation's `batchID` exposure
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

    /// Same aggregation as `receive`, and for the same reason: this fires once per wake,
    /// and the facts it carries — the reason and the source count — are unchanged across
    /// almost all of them. Extracted so `refreshSources` keeps its complexity budget.
    private func logRefresh(reason: String, sourceCount: Int) {
        guard lastLoggedSourceCount != sourceCount
            || suppressedRefreshes + 1 >= Self.churnSummaryThreshold
        else {
            suppressedRefreshes += 1
            return
        }
        OtosLog.catalog.noticeOperation("import.coordinator", phase: "refresh", fields: [
            "reason": reason,
            "sourceCount": "\(sourceCount)",
            "suppressedRefreshes": "\(suppressedRefreshes)",
        ])
        lastLoggedSourceCount = sourceCount
        suppressedRefreshes = 0
    }

    private func refreshSources(reason: String) async {
        let libraries = await store.currentLibraries()
        librariesByPath = CatalogWindowPolicy.rootsByPath(from: libraries)
        let fixedAvailable = libraries.filter { $0.root.kind == .library && $0.availability == .available }
        let removable = libraries.filter { $0.root.kind != .library && $0.availability == .available }
        var seen = Set<LibraryRootPath>()
        for source in removable {
            seen.insert(source.path)
            let currentRevisions = await store.planningRevisions(for: source.path)
            if let existing = sourceSessions[source.path], isNewAttachment(source, replacing: existing) {
                await disposeDetachedSession(path: source.path, session: existing, reason: "reattached")
                sourceSessions.removeValue(forKey: source.path)
                lastSeenRevisions.removeValue(forKey: source.path)
                lastLoggedState.removeValue(forKey: source.path)
                OtosLog.catalog.notice(
                    "op=import.attachment phase=replaced sourcePath=\(source.path.rawValue, privacy: .public) oldGeneration=\(existing.attachmentGeneration.rawValue, privacy: .public) newGeneration=\(source.attachmentGeneration, privacy: .public)"
                )
            }
            if sourceSessions[source.path] == nil {
                let attachmentGen = attachmentGeneration(for: source)
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
                    lastFailure: nil,
                    unreadableRetry: nil,
                    activeRunID: nil
                )
                sourceSessions[source.path] = newSession
                lastSeenRevisions[source.path] = currentRevisions
                scheduleBuildIfNeeded(source.path)
            } else {
                // Update root for existing session (availability may have changed)
                sourceSessions[source.path]?.root = source
                // A session's plan goes stale the moment the root it was built from
                // gains new/changed rows — device enumeration landing after attach is
                // exactly this: the session already exists (created from whatever rows
                // were persisted at attach) and this revision bump is how it learns
                // the live inventory superseded that snapshot. This root is the
                // session's *source*, so either revision counts.
                // Reuses the same `lastSeenRevisions` map `handlePlanningChange` keys
                // staleness on, so both triggering paths (the revision-aware planning
                // -change stream and this cheaper catalog-change refresh) agree on
                // what "already seen" means.
                if lastSeenRevisions[source.path] != currentRevisions {
                    lastSeenRevisions[source.path] = currentRevisions
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
                        let isCurrentValid = currentDestination
                            .map { dest in fixedAvailable.contains(where: { $0.path == dest }) } ?? false
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
                await disposeDetachedSession(path: path, session: session, reason: "detached")
            }
            sourceSessions.removeValue(forKey: path)
            // Keep destinationBySource for Settings; clear transient occupancy.
            lastSeenRevisions.removeValue(forKey: path)
            lastLoggedState.removeValue(forKey: path)
        }
        publish()
        logRefresh(reason: reason, sourceCount: removable.count)
    }

    /// Returns whether a dirty session was taken up — a build started, or the
    /// session settled as having no destination. A clean, building, or
    /// executing session is left alone and returns `false`.
    @discardableResult
    private func scheduleBuildIfNeeded(_ source: LibraryRootPath) -> Bool {
        guard !isShuttingDown else { return false }
        guard var session = sourceSessions[source] else { return false }
        guard session.isDirty else { return false }
        if case .building = session.phase {
            return false
        }
        if case .executing = session.phase {
            return false
        }
        session.isDirty = false
        let buildGen = session.nextBuildGeneration
        session.nextBuildGeneration = BuildGeneration(rawValue: buildGen.rawValue &+ 1)
        let attachmentGen = session.attachmentGeneration
        let runID = UUID().uuidString
        let destination = session.destination
        OtosLog.catalog.noticeOperation("plan.rebuild", phase: "schedule", fields: ["source": source.rawValue, "destination": destination?.rawValue ?? "none", "generation": "\(buildGen.rawValue)", "attachment": "\(attachmentGen.rawValue)", "run": runID])
        guard let destination else {
            // No destination is state B ("No destination"), not a failure —
            // `destinationPath == nil` on the presentation is what the mapper
            // reads; this reason is never shown.
            session.phase = .planningFailed(reason: .unexpected(detail: "noDestinationLibrary"))
            sourceSessions[source] = session
            publish()
            return true
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await runBuild(
                source: source,
                destination: destination,
                generation: buildGen.rawValue,
                attachment: attachmentGen
            )
        }
        session.activeRunID = runID
        session.phase = .building(BuildContext(generation: buildGen, runID: runID, task: task))
        sourceSessions[source] = session
        publish()
        return true
    }

    private func runBuild(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        generation: UInt64,
        attachment: AttachmentGeneration
    ) async {
        do {
            try await buildPlan(
                source: source,
                destination: destination,
                generation: generation,
                attachment: attachment
            )
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
            updated.phase = .planningFailed(reason: .unexpected(detail: String(describing: error)))
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
        OtosLog.catalog.noticeOperation("import.plan", phase: "finish", fields: ["rootPath": source.rawValue, "run": runID, "sourceCount": "\(sourceCount)", "folders": "\(result.namespace.folderCount)", "namespaceEntries": "\(result.namespace.entryCount)", "enumerateMs": "\(result.enumerateMs)", "planMs": "\(result.planMs)", "copyCount": "\(result.plan.totals.copyCount)", "skipCount": "\(result.plan.totals.skipCount)", "excludedCount": "\(result.plan.totals.excludedCount)", "blockedCount": "\(result.plan.totals.blockedCount)", "unreadableFolders": "\(result.namespace.unreadableFolders.count)", "namingMtimeCount": "\(namingMtimeCount)", "namingSettledCount": "\(namingSettledCount)"])
    }

    private func buildPlan(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        generation: UInt64,
        attachment: AttachmentGeneration
    ) async throws {
        guard isStarted, !isShuttingDown else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=notStarted source=\(source.rawValue, privacy: .public)")
            return
        }
        guard let session = sourceSessions[source] else {
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
            // Move out of `.building`, which `scheduleBuildIfNeeded` skips, so
            // the dirty session re-plans against its current destination.
            updated.phase = .inventory
            sourceSessions[source] = updated
            publish()
            scheduleBuildIfNeeded(source)
            return
        }
        let prefs = session.preferences
        let policy = ImportPolicy.from(prefs)
        guard let snapshot = try await store.importPlanningSnapshot(
            source: source,
            destination: destination,
            policy: policy,
            generation: generation
        ) else {
            let libraries = await store.currentLibraries()
            let reason = MediaOperationFailureReason.forMissingSnapshot(
                source: source,
                destination: destination,
                availableRoots: CatalogWindowPolicy.availablePaths(from: libraries)
            )
            var updated = session
            updated.phase = .planningFailed(reason: reason)
            sourceSessions[source] = updated
            publish()
            return
        }
        if await shouldWaitForMetadata(
            source: source,
            snapshot: snapshot,
            attachment: attachment,
            generation: generation,
            runID: runID
        ) {
            return
        }
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
            // Rows whose destination name comes from the filesystem mtime because
            // enrichment looked and found no embedded capture wall. Under the naming
            // gate this is a count of *proven* fallbacks; before the gate it silently
            // counted unproven guesses, and it read 730-of-730 on the run that
            // duplicated 23 videos without anything acting on it (ARC-057).
            namingMtimeCount: snapshot.sourceMedia.filter {
                $0.namingFactState != .pending && $0.captureWallCompact == nil && $0.hasAnyDate
            }.count,
            namingSettledCount: snapshot.sourceMedia.count { $0.namingFactState != .pending },
            result: build
        )
        guard let current = sourceSessions[source],
              current.attachmentGeneration == attachment,
              case let .building(currentCtx) = current.phase,
              currentCtx.generation.rawValue == generation
        else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=staleAfterBuild source=\(source.rawValue, privacy: .public)")
            return
        }
        guard current.destination == destination else {
            // The destination changed while this build ran. The build is still
            // the session's current one — nothing else will end `.building` —
            // so it must hand the phase back and reschedule, exactly as the
            // pre-build destination guard does. Returning here left the session
            // building forever with `isDirty` set and nothing to drain it
            // (2026-09-14, a destination change during the post-settlement
            // rebuild).
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=destinationChangedMidBuild source=\(source.rawValue, privacy: .public)")
            var updated = current
            updated.isDirty = true
            updated.phase = .inventory
            sourceSessions[source] = updated
            publish()
            scheduleBuildIfNeeded(source)
            return
        }
        // Revalidate per role, matching `handlePlanningChange`: the source's
        // namespace *and* naming, the destination's namespace only. Each pair is
        // sampled in one actor hop so the halves cannot straddle a suspension.
        let sourceRevisions = await store.planningRevisions(for: source)
        let destinationNamespace = await store.namespaceRevision(for: destination)
        guard sourceRevisions?.namespaceRevision == snapshot.sourceNamespaceRevision,
              sourceRevisions?.namingRevision == snapshot.sourceNamingRevision,
              destinationNamespace == snapshot.destinationNamespaceRevision
        else {
            OtosLog.catalog.noticeOperation("import.plan", phase: "stale", fields: ["rootPath": source.rawValue, "sourceNamespace": "\(sourceRevisions?.namespaceRevision.description ?? "none")", "snapshotSourceNamespace": "\(snapshot.sourceNamespaceRevision)", "sourceNaming": "\(sourceRevisions?.namingRevision.description ?? "none")", "snapshotSourceNaming": "\(snapshot.sourceNamingRevision)", "destinationNamespace": "\(destinationNamespace.map(String.init) ?? "none")", "snapshotDestinationNamespace": "\(snapshot.destinationNamespaceRevision)", "run": runID])
            var updated = current
            updated.isDirty = true
            updated.phase = .inventory
            sourceSessions[source] = updated
            publish()
            scheduleBuildIfNeeded(source)
            return
        }
        if !build.namespace.unreadableFolders.isEmpty {
            deferBuildOnUnreadableDestination(
                source: source,
                session: current,
                attachment: attachment,
                folders: build.namespace.unreadableFolders,
                runID: runID
            )
            return
        }
        let newClaims = planClaims(from: plan, capabilities: snapshot.destinationCapabilities)
        let currentLedger = ledgerClaims(for: destination, excluding: source)
        if !newClaims.isDisjoint(with: currentLedger) {
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
        updated.lastReadyContext = readyCtx
        updated.unreadableRetry?.task.cancel()
        updated.unreadableRetry = nil
        updated.isDirty = false
        if updated.attachToReadyMs == nil {
            let elapsed = updated.attachStartedAt.duration(to: ContinuousClock().now)
            updated.attachToReadyMs = DiagnosticsTiming.milliseconds(elapsed)
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

    /// A destination folder that exists but could not be listed is not a fact
    /// about the namespace; it is a missing observation, and a plan built on it
    /// would block every candidate in that folder as "couldn't check" — which
    /// the bar drew as `0 new items · Import 0 Items` over 368 items that were
    /// already in the library (2026-09-13, a OneDrive folder mid-sync). So the
    /// build is deferred: the phase returns to `.inventory`, the last proven plan
    /// keeps presenting (ARC-047), and a bounded backoff re-plans. Past the last
    /// delay the condition is presented as a planning failure — the destination
    /// is not available to plan against — which `Try Again` and any planning
    /// wake clear by rebuilding.
    private func deferBuildOnUnreadableDestination(
        source: LibraryRootPath,
        session: SourceSession,
        attachment: AttachmentGeneration,
        folders: [String: String],
        runID: String
    ) {
        var updated = session
        updated.phase = .inventory
        // A planning wake may have rebuilt before the pending retry fired; that
        // retry is superseded by this deferral's own.
        session.unreadableRetry?.task.cancel()
        let attempt = (session.unreadableRetry?.attempt ?? 0) + 1
        let detail = folders.map { "\($0.key.isEmpty ? "." : $0.key)=\($0.value)" }.sorted().joined(separator: ",")
        guard attempt <= unreadableRetryDelays.count else {
            updated.unreadableRetry = nil
            updated.phase = .planningFailed(reason: .destinationUnavailable)
            OtosLog.catalog.noticeOperation("import.plan", phase: "unreadableExhausted", fields: [
                "rootPath": source.rawValue,
                "run": runID,
                "attempts": "\(attempt - 1)",
                "folders": detail,
            ])
            sourceSessions[source] = updated
            publish()
            return
        }
        let delay = unreadableRetryDelays[attempt - 1]
        updated.isDirty = true
        updated.unreadableRetry = UnreadableRetry(attempt: attempt, task: Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await retryDeferredBuild(source: source, attachment: attachment)
        })
        OtosLog.catalog.noticeOperation("import.plan", phase: "deferred", fields: [
            "rootPath": source.rawValue,
            "run": runID,
            "reason": "destinationUnreadable",
            "attempt": "\(attempt)",
            "delayMs": "\(DiagnosticsTiming.milliseconds(delay))",
            "folders": detail,
        ])
        sourceSessions[source] = updated
        publish()
    }

    /// The backoff's wake: rebuilds only if the same attachment is still parked
    /// on the deferral — a newer attachment, a build a planning wake already
    /// started, or an execution in flight all mean the retry is moot.
    private func retryDeferredBuild(source: LibraryRootPath, attachment: AttachmentGeneration) {
        guard var session = sourceSessions[source],
              session.attachmentGeneration == attachment,
              session.unreadableRetry != nil,
              case .inventory = session.phase
        else {
            return
        }
        session.isDirty = true
        sourceSessions[source] = session
        scheduleBuildIfNeeded(source)
    }

    private func shouldWaitForMetadata(
        source: LibraryRootPath,
        snapshot: ImportPlanningSnapshot,
        attachment: AttachmentGeneration,
        generation: UInt64,
        runID: String
    ) async -> Bool {
        let filesWithNoDateAtAll = snapshot.sourceMedia.filter { !$0.hasAnyDate }.count
        let total = snapshot.sourceMedia.count
        // "Looked at", not "has some date": the honest denominator for state A's
        // determinate progress is how many source rows enrichment has actually read.
        let settled = snapshot.sourceMedia.count { $0.namingFactState != .pending }
        // A camera is gated exactly like a card. Its bytes are staged locally so they
        // can be enriched, and enrichment of staged bytes is what produces a capture
        // wall — `ICCameraFile`'s own dates are absolute instants, so they cannot
        // yield a local wall clock, and its modification-first precedence is
        // end-of-recording for video, the same duration-sized error that duplicated
        // 23 videos off a card. Excluding `.deviceMTP` here meant a camera import was
        // offered against exactly the fabricated names the gate exists to prevent
        // (ARC-057).
        // A row whose bytes cannot be read is never going to become non-pending, and
        // it cannot be copied either — so it must not hold the offer open. The planner
        // blocks it and state D shows it (ARC-057).
        guard MediaTransferPlanner.needsDate(policy: snapshot.policy),
              snapshot.sourceMedia.contains(where: { $0.namingFactState == .pending && !$0.isSourceUnreadable })
        else {
            return false
        }
        guard var session = sourceSessions[source],
              session.attachmentGeneration == attachment,
              case let .building(ctx) = session.phase, ctx.generation.rawValue == generation
        else {
            return false
        }
        // Revalidate the fact this decision rests on, against live rows rather than the
        // snapshot. The snapshot was read before an await, so an enrichment batch may
        // have landed since — and the catalog-change wake that revives a
        // `.waitingForMetadata` session fires only for sessions *already* parked, so a
        // batch landing mid-build is not replayed. Parking on a stale snapshot would
        // then wait for a wake that never comes, and the last batch of a card's
        // enrichment has nothing behind it to rescue the session.
        //
        // The revision pair cannot answer this: a batch that reads a file and finds no
        // embedded capture wall moves the row from `.pending` to `.terminal` without
        // changing `capture_wall_compact`, so `namingRevision` stays put while the
        // gate's answer flips.
        let liveMedia = await store.planningMedia(for: source) ?? []
        if !liveMedia.isEmpty,
           !liveMedia.contains(where: { $0.namingFactState == .pending && !$0.isSourceUnreadable })
        {
            OtosLog.catalog.notice(
                "op=import.readiness phase=namingSettledDuringBuild run=\(runID, privacy: .public) rootPath=\(source.rawValue, privacy: .public) total=\(liveMedia.count, privacy: .public)"
            )
            session.isDirty = true
            session.phase = .inventory
            sourceSessions[source] = session
            scheduleBuildIfNeeded(source)
            return true
        }
        let message = "op=import.readiness phase=waitingForMetadata run=\(runID) "
            + "rootPath=\(source.rawValue) "
            + "settled=\(settled) "
            + "total=\(total) "
            + "filesWithNoDateAtAll=\(filesWithNoDateAtAll)"
        OtosLog.catalog.notice("\(message, privacy: .public)")
        session.phase = .waitingForMetadata(done: settled, total: max(total, 1))
        session.lastNamingProgress = NamingProgress(done: settled, total: max(total, 1))
        sourceSessions[source] = session
        publish()
        return true
    }

    private func ledgerClaims(
        for destination: LibraryRootPath,
        excluding excludedSource: LibraryRootPath? = nil
    ) -> Set<FilesystemNameKey> {
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
            claims.insert(FilesystemNamespaceSemantics.nameKey(
                relativePath: entry.finalDestination,
                capabilities: capabilities
            ))
            for dest in entry.companionDestinations.values {
                claims.insert(FilesystemNamespaceSemantics.nameKey(relativePath: dest, capabilities: capabilities))
            }
        }
        return claims
    }

    /// The plan this attachment last proved, if it still passes the same guards a
    /// live `.ready` plan does. Returns nil when nothing has been proved yet — which
    /// is the one case that legitimately draws state A.
    ///
    /// Used only where a *newer plan over the same proven set* is being built. It is
    /// never used while naming facts are pending: a held plan cannot describe rows
    /// enrichment has not read yet.
    private func heldPlanState(for session: SourceSession) -> MediaOperationSourceState? {
        guard let held = session.lastReadyContext else {
            return nil
        }
        let state = readyState(for: session, ctx: held)
        // `readyState` answers `.inventory` when the source is not ready to be
        // offered; that is a refusal, not a plan, so fall through to the real phase.
        if case .inventory = state {
            return nil
        }
        return state
    }

    private func presentation(for session: SourceSession) -> MediaOperationSourcePresentation {
        // A rebuild in flight is not a reason to unshow what this attachment already
        // proved. `.inventory`, `.waitingForMetadata` and `.building` all mean "a
        // newer plan is coming"; if an older one is still true enough to have been
        // published, keep showing it until the newer one lands. Routed back through
        // `readyState` rather than reconstructing the state, so the readiness gate
        // and the `!isDirty` empty-card proof still apply — a session mid-rebuild is
        // dirty, so it can never use a held plan to claim "This card is empty".
        // A held click (`importRequested`) changes nothing here: the bar keeps
        // saying what it knows, and the presentation carries the held click as
        // its own fact so the mapper disables Import (`import-bar.md` row 7).
        let state: MediaOperationSourceState = switch session.phase {
        case .inventory:
            heldPlanState(for: session) ?? settlementState(for: session) ?? .inventory
        // Deliberately *not* held across `.waitingForMetadata`. `.building` and
        // `.inventory` re-derive a plan over a set whose naming facts are already
        // proven, so the old answer stays true until the new one lands. Waiting for
        // metadata is the opposite: rows are pending precisely because enrichment has
        // not read them, and they may not be in the held plan at all — showing its
        // count would under-report, and an empty held plan would report "nothing to
        // copy" about files it never saw. A is correct here, and its determinate
        // progress is the honest thing to draw.
        case let .waitingForMetadata(done, total):
            .waitingForMetadata(done: done, total: total)
        // A rebuild that has no proven plan to fall back on still has a proven *count*.
        // `.planning` draws neither, so it is the last resort rather than the default: it
        // is correct only before this attachment has reported any naming progress at all.
        case .building:
            if let held = heldPlanState(for: session) {
                held
            } else if let settlement = settlementState(for: session) {
                settlement
            } else if let progress = session.lastNamingProgress {
                .waitingForMetadata(done: progress.done, total: progress.total)
            } else {
                .planning
            }
        case let .ready(ctx):
            readyState(for: session, ctx: ctx)
        case .executing:
            executingState(for: session)
        case .completed:
            completedState(for: session)
        case let .executionUnavailable(summary, generation, attentionItems):
            .executionUnavailable(summary: summary, generation: generation, attentionItems: attentionItems)
        case let .planningFailed(reason):
            .planningFailed(reason: reason)
        }
        // A recorded failure outranks whatever the re-plan found (state G,
        // "never auto-dismisses"); only a new attempt — executing, or a click
        // held until the plan is ready — is a newer fact about this attachment.
        if let failure = session.lastFailure, !session.importRequested {
            switch state {
            case .executing:
                break
            default:
                return makePresentation(
                    session: session,
                    state: .failed(reason: failure.reason, publishedCount: failure.publishedCount)
                )
            }
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
    /// Between a run settling and its re-plan landing there is no proven plan
    /// to hold (the pre-run one was dropped as false), but there is a settled
    /// outcome — and Done is what the user is looking at. Presenting it across
    /// the window keeps the bar on Done instead of flashing the stale pre-run
    /// Ready (observed 2026-09-13) or falling back to Preparing.
    private func settlementState(for session: SourceSession) -> MediaOperationSourceState? {
        guard session.lastReadyContext == nil, session.settledOutcome != nil else {
            return nil
        }
        return completedState(for: session)
    }

    private func completedState(for session: SourceSession) -> MediaOperationSourceState {
        guard let outcome = session.settledOutcome else {
            preconditionFailure(
                "`.completed` phase always sets `settledOutcome` in the same transaction (applyExecutionResult)"
            )
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
    /// This checks the dirty bit rather than comparing `lastSeenRevisions`
    /// against `ctx.plan.sourceNamespaceRevision` directly: a source whose
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

    /// The batch this attachment's run is copying into, exposed only while
    /// it executes and only once it has proven itself non-empty (see
    /// `batchAssetCountConfirmed`): the sidebar's batch row exists only once it
    /// has an asset, and that row's progress indicator is the one consumer
    /// (`import-bar.md` "Ownership of status").
    private func executingBatchID(for session: SourceSession) -> ImportBatchID? {
        guard case let .executing(ctx) = session.phase, session.batchAssetCountConfirmed else {
            return nil
        }
        return ctx.batch
    }

    private func makePresentation(
        session: SourceSession,
        state: MediaOperationSourceState
    ) -> MediaOperationSourcePresentation {
        // Sampled only where the bar can compare it against a plan: a `stat`
        // per Ready publish, never per progress tick.
        let availableBytes: Int64? = switch state {
        case .ready, .executionUnavailable:
            session.destination.flatMap { volumeCapacity($0.url) }
        default:
            nil
        }
        // The run's outcome is a claim about the library it copied into. After
        // a destination change the bar measures the card against a different
        // library, so the outcome is withheld and the plan speaks for itself
        // ("Nothing new on this card" or "181 new items"); pick the original
        // library again and the outcome returns.
        let completion = session.lastCompletion.flatMap { $0.destination == session.destination ? $0 : nil }
        return MediaOperationSourcePresentation(
            sourcePath: session.root.path,
            attachmentGeneration: session.attachmentGeneration,
            sourceKind: session.root.kind,
            destinationPath: session.destination,
            destinationDisplayName: session.destination.flatMap { librariesByPath[$0]?.displayName },
            state: state,
            importRequested: session.importRequested,
            attachToReadyMs: session.attachToReadyMs,
            batchID: executingBatchID(for: session),
            copiedJustNow: completion?.publishedCount,
            isFullyClean: completion?.isFullyClean,
            stopReason: completion?.stopReason,
            plannedCount: completion?.plannedCount,
            destinationAvailableBytes: availableBytes,
            sessionPreferences: session.preferences,
            incompleteItems: completion?.incompleteItems ?? [],
            eraseOutcome: completion?.eraseOutcome
        )
    }

    private func sortedPresentations() -> [MediaOperationSourcePresentation] {
        sourceSessions.values.map { presentation(for: $0) }
            .sorted { $0.sourcePath.rawValue.localizedStandardCompare($1.sourcePath.rawValue) == .orderedAscending }
    }

    /// Publishes to every consumer, and logs each source's state **when it changes**.
    ///
    /// Not time-throttled: a throttle suits a state that changes slowly and hides one that
    /// does not. The 2026-08-30 session alternated `.planning` and `.waitingForMetadata`
    /// roughly every 1.1 s with the pair only ~140 ms apart; a 250 ms-per-source throttle
    /// recorded 33 `planning` publishes and *zero* `waitingForMetadata` ones, so the log
    /// could not show whether the counting frames ever reached the view.
    ///
    /// Logging on change keeps every transition and drops only genuine repeats. It governs
    /// only what can be diagnosed: the yield to continuations is never gated by it.
    private func publish() {
        let values = sortedPresentations()
        for presentation in values {
            guard lastLoggedState[presentation.sourcePath] != presentation.state else { continue }
            lastLoggedState[presentation.sourcePath] = presentation.state
            let progress: MediaOperationProgress? = if case let .executing(value) = presentation.state {
                value
            } else {
                nil
            }
            let batchID = presentation.batchID.map { String(describing: $0) } ?? "none"
            let runID = sourceSessions[presentation.sourcePath]?.activeRunID ?? "none"
            OtosLog.catalog.notice(
                "op=import.presentation phase=publish run=\(runID, privacy: .public) sourcePath=\(presentation.sourcePath.rawValue, privacy: .public) attachment=\(presentation.attachmentGeneration.rawValue, privacy: .public) state=\(String(describing: presentation.state), privacy: .public) completedCount=\(progress?.completedCount ?? 0, privacy: .public) totalCount=\(progress?.totalCount ?? 0, privacy: .public) completedBytes=\(progress?.completedBytes ?? 0, privacy: .public) batchID=\(batchID, privacy: .public)"
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
