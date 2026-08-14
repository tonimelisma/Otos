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
    private let preferences: UserDefaults
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
        let task: Task<Void, Never>
    }

    private struct ReadyContext {
        let plan: MediaOperationPlan
        let skippedPackageCount: Int
        let claims: Set<MediaRelativePath>
        let attentionItems: [MediaAttentionItem]
    }

    private struct ExecutionContext {
        let plan: MediaOperationPlan
        let claims: Set<MediaRelativePath>
        let executor: any ImportExecuting
        let task: Task<Void, Never>
        let summary: MediaOperationPlanTotals
        let generation: UInt64
        let skippedPackageCount: Int
        let prefs: ImportPreferences
        let batch: ImportBatchID
    }

    private enum SourcePhase {
        case inventory
        case waitingForMetadata(done: Int, total: Int)
        case building(BuildContext)
        case ready(ReadyContext)
        case executing(ExecutionContext)
        case completed
        case failed(reason: MediaOperationFailureReason, publishedCount: Int)
    }

    /// The most recent execution's outcome for the current attachment, kept
    /// across the post-settlement re-plan so a card left in the reader keeps
    /// reporting what it just copied (`import-bar.md` state F) instead of that
    /// fact vanishing the moment the phase leaves `.completed`. Cleared only by
    /// a new `AttachmentGeneration` (card ejected and re-inserted) — never by a
    /// later re-plan within the same attachment.
    private struct AttachmentCompletion {
        let batch: ImportBatchID
        let publishedCount: Int
        let isFullyClean: Bool
    }

    private struct SourceSession {
        let attachmentGeneration: AttachmentGeneration
        var root: CatalogLibraryState
        var destination: LibraryRootPath?
        var preferences: ImportPreferences
        var phase: SourcePhase
        var isDirty: Bool
        var importRequested: Bool
        var nextBuildGeneration: BuildGeneration
        var attachStartedAt: ContinuousClock.Instant
        var attachToReadyMs: Int?
        var lastCompletion: AttachmentCompletion?
    }

    private var sourceSessions: [LibraryRootPath: SourceSession] = [:]
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
    private var destinationByDeviceIdentity: [String: LibraryRootPath] = [:]
    private var lastUsedDestination: LibraryRootPath?
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
        let libraries = await store.currentLibraries()
        if let sourceState = libraries.first(where: { $0.path == source }),
           let device = sourceState.root.deviceIdentity
        {
            destinationByDeviceIdentity[device] = destination
        }
        lastUsedDestination = destination
        destinationBySource[source] = destination
        persistDestinationMappings()
        guard var session = sourceSessions[source] else {
            // Source not yet attached; mapping will be applied on next refresh.
            return
        }
        let previous = session.destination
        session.destination = destination
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

    func sessionPreferences(for source: LibraryRootPath) -> ImportPreferences {
        sourceSessions[source]?.preferences ?? ImportPreferencesStore.load(defaults: preferences)
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
        // Bookkeeping so scheduleBuildIfNeeded won't rebuild this session; the
        // presentation actually shown is the `.executionUnavailable` override
        // published below, not this phase. Pre-existing risk, unchanged by
        // this diff: any later unrelated `publish()` re-derives from
        // `session.phase` via `presentation(for:)` and would show this
        // `.failed` phase instead, since nothing here is sticky.
        session.phase = .failed(reason: .unexpected(detail: "executionUnavailable"), publishedCount: 0)
        sourceSessions[source] = session
        let presentation = makePresentation(
            session: session,
            state: .executionUnavailable(summary: summary, generation: generation, attentionItems: attentionItems)
        )
        let values = sortedPresentations().map { $0.sourcePath == source ? presentation : $0 }
        for continuation in continuations.values {
            continuation.yield(values)
        }
    }

    private func runExecution(source: LibraryRootPath, sourceState: CatalogLibraryState, readyContext: ReadyContext) async {
        guard var session = sourceSessions[source] else { return }
        guard case .ready = session.phase else { return }

        OtosLog.catalog.noticeOperation("import.activity", phase: "started", fields: ["rootPath": source.rawValue])
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
        // it before execution starts, so it can publish it as state on every
        // frame from here on (`import-bar.md` "Where the user is standing").
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
            batch: batch
        )
        session.phase = .executing(ctx)
        session.importRequested = false
        sourceSessions[source] = session
        publish()

        let result = await executor.execute(
            plan: plan,
            batch: batch,
            sourceKind: sourceState.root.kind,
            sourceDeviceIdentity: sourceState.root.deviceIdentity,
            deleteSourceRequested: prefs.deleteSourceAfterImport
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
        guard let session = sourceSessions[source],
              session.attachmentGeneration == attachment,
              case .executing = session.phase
        else {
            return
        }
        // Progress is not stored on the session — published directly. The
        // session's `.executing` phase (and its batch) is unchanged.
        let progPresentation = makePresentation(session: session, state: .executing(progress: progress))
        let values = sortedPresentations().map { $0.sourcePath == source ? progPresentation : $0 }
        for continuation in continuations.values {
            continuation.yield(values)
        }
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
        case let .completed(publishedCount, hasBlockedEntries, hasEntryFailures, skippedForeignCount, failedCount):
            session.phase = .completed
            // Stricter than the auto-eject gate just below on purpose: a
            // foreign skip doesn't block physically ejecting the card, but it
            // does keep the bar from auto-dismissing, since the plan's own
            // "must join" list for the auto-dismiss gate names it explicitly
            // (`import-bar.md` "What the presentation must carry").
            session.lastCompletion = AttachmentCompletion(
                batch: context.batch,
                publishedCount: publishedCount,
                isFullyClean: !hasBlockedEntries && !hasEntryFailures
                    && skippedForeignCount == 0 && summary.blockedCount == 0
            )
            sourceSessions[source] = session
            let completedPresentation = makePresentation(
                session: session,
                state: .completed(summary: summary, skippedForeignCount: skippedForeignCount, failedCount: failedCount)
            )
            let values = sortedPresentations().map { $0.sourcePath == source ? completedPresentation : $0 }
            for continuation in continuations.values {
                continuation.yield(values)
            }
            if context.prefs.autoEjectAfterImport, !hasBlockedEntries, !hasEntryFailures, summary.blockedCount == 0 {
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
            session.lastCompletion = AttachmentCompletion(batch: context.batch, publishedCount: publishedCount, isFullyClean: false)
            sourceSessions[source] = session
            publish()
        case let .failed(reason):
            session.phase = .failed(reason: reason, publishedCount: 0)
            sourceSessions[source] = session
            publish()
        }
        OtosLog.catalog.noticeOperation("import.activity", phase: "finished", fields: ["rootPath": source.rawValue])
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

    /// Helper to retrieve plan from executing context before it was cleared.
    private func sessionForAttachment(source: LibraryRootPath, attachment: AttachmentGeneration) -> ExecutionContext? {
        guard let session = sourceSessions[source], session.attachmentGeneration == attachment else { return nil }
        if case let .executing(ctx) = session.phase {
            return ctx
        }
        return nil
    }

    private var planForExecution: MediaOperationPlan? {
        nil
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

    private func refreshSources(reason: String) async {
        let libraries = await store.currentLibraries()
        librariesByPath = CatalogWindowPolicy.rootsByPath(from: libraries)
        let fixedAvailable = libraries.filter { $0.root.kind == .library && $0.availability == .available }
        let removable = libraries.filter { $0.root.kind != .library && $0.availability == .available }
        var seen = Set<LibraryRootPath>()
        for source in removable {
            seen.insert(source.path)
            if sourceSessions[source.path] == nil {
                let attachmentGen = AttachmentGeneration(rawValue: nextAttachmentGeneration)
                nextAttachmentGeneration &+= 1
                let prefs = ImportPreferencesStore.load(defaults: preferences)
                // Determine destination via three-step default
                let previousMapping = destinationBySource[source.path]
                let currentMapped = destinationBySource[source.path]
                let isCurrentValid = currentMapped.map { dest in fixedAvailable.contains(where: { $0.path == dest }) } ?? false
                var chosen: LibraryRootPath?
                if !isCurrentValid {
                    let deviceDest: LibraryRootPath? = {
                        // swiftlint:disable:next line_length
                        guard let device = source.root.deviceIdentity, let saved = destinationByDeviceIdentity[device], fixedAvailable.contains(where: { $0.path == saved }) else { return nil }
                        return saved
                    }()
                    let lastUsedValid = lastUsedDestination.flatMap { dest in fixedAvailable.contains(where: { $0.path == dest }) ? dest : nil }
                    let firstAddedAvailable = fixedAvailable.first?.path
                    chosen = deviceDest ?? lastUsedValid ?? firstAddedAvailable
                    if let chosen {
                        destinationBySource[source.path] = chosen
                        if let device = source.root.deviceIdentity {
                            destinationByDeviceIdentity[device] = chosen
                        }
                        lastUsedDestination = chosen
                    } else {
                        destinationBySource.removeValue(forKey: source.path)
                    }
                    if destinationBySource[source.path] != previousMapping {
                        persistDestinationMappings()
                    }
                } else {
                    chosen = currentMapped
                }
                let destination = chosen
                let newSession = SourceSession(
                    attachmentGeneration: attachmentGen,
                    root: source,
                    destination: destination,
                    preferences: prefs,
                    phase: .inventory,
                    isDirty: true,
                    importRequested: false,
                    nextBuildGeneration: BuildGeneration(rawValue: 1),
                    attachStartedAt: ContinuousClock().now,
                    attachToReadyMs: nil,
                    lastCompletion: nil
                )
                sourceSessions[source.path] = newSession
                scheduleBuildIfNeeded(source.path)
            } else {
                // Update root for existing session (availability may have changed)
                sourceSessions[source.path]?.root = source
                // Also ensure destination still valid
                let currentMapped = destinationBySource[source.path]
                let isCurrentValid = currentMapped.map { dest in fixedAvailable.contains(where: { $0.path == dest }) } ?? false
                if !isCurrentValid {
                    let previousMapping = destinationBySource[source.path]
                    let deviceDest: LibraryRootPath? = {
                        // swiftlint:disable:next line_length
                        guard let device = source.root.deviceIdentity, let saved = destinationByDeviceIdentity[device], fixedAvailable.contains(where: { $0.path == saved }) else { return nil }
                        return saved
                    }()
                    let lastUsedValid = lastUsedDestination.flatMap { dest in fixedAvailable.contains(where: { $0.path == dest }) ? dest : nil }
                    let firstAddedAvailable = fixedAvailable.first?.path
                    let newDestination = deviceDest ?? lastUsedValid ?? firstAddedAvailable
                    let prev = sourceSessions[source.path]?.destination
                    if let newDestination {
                        destinationBySource[source.path] = newDestination
                        sourceSessions[source.path]?.destination = newDestination
                        if let device = source.root.deviceIdentity {
                            destinationByDeviceIdentity[device] = newDestination
                        }
                        lastUsedDestination = newDestination
                    } else {
                        destinationBySource.removeValue(forKey: source.path)
                        sourceSessions[source.path]?.destination = nil
                    }
                    if destinationBySource[source.path] != previousMapping {
                        persistDestinationMappings()
                    }
                    if prev != newDestination {
                        sourceSessions[source.path]?.isDirty = true
                        scheduleBuildIfNeeded(source.path)
                    }
                } else {
                    sourceSessions[source.path]?.destination = currentMapped
                }
            }
        }
        // Detach: remove sessions for missing sources, cancel owned work.
        for path in Array(sourceSessions.keys) where !seen.contains(path) {
            if let session = sourceSessions[path] {
                switch session.phase {
                case let .building(ctx): ctx.task.cancel()
                case let .executing(ctx):
                    ctx.task.cancel()
                    Task { await ctx.executor.cancel() }
                // J9 wants the card pulled mid-execution to fail with a
                // named cause, while this source's own row still
                // disappears (matches the existing removal below). A typed
                // `.sourceRemoved` frame published here would be
                // overwritten by this same method's final `publish()`
                // before any consumer's turn to observe it — `refreshSources`
                // has no suspension point between the two — so it is not a
                // real producer, only a misleading one. The batch this
                // execution belongs to (`ctx.batch`) is what needs to carry
                // the cause forward once a later increment gives batches
                // their own durable presentation independent of this
                // source's session; deferred there, not invented here.
                default: break
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
        let destination = session.destination
        // swiftlint:disable:next line_length
        OtosLog.catalog.noticeOperation("plan.rebuild", phase: "schedule", fields: ["source": source.rawValue, "destination": destination?.rawValue ?? "none", "generation": "\(buildGen.rawValue)", "attachment": "\(attachmentGen.rawValue)"])
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
        session.phase = .building(BuildContext(generation: buildGen, task: task))
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

    private nonisolated static func logPlanFinished(source: LibraryRootPath, sourceCount: Int, result: ImportPlanBuildResult) {
        // swiftlint:disable:next line_length
        OtosLog.catalog.noticeOperation("import.plan", phase: "finish", fields: ["rootPath": source.rawValue, "sourceCount": "\(sourceCount)", "folders": "\(result.namespace.folderCount)", "namespaceEntries": "\(result.namespace.entryCount)", "enumerateMs": "\(result.enumerateMs)", "planMs": "\(result.planMs)", "copyCount": "\(result.plan.totals.copyCount)", "skipCount": "\(result.plan.totals.skipCount)", "blockedCount": "\(result.plan.totals.blockedCount)"])
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
        if await shouldWaitForMetadata(source: source, snapshot: snapshot, attachment: attachment, generation: generation) {
            return
        }
        // swiftlint:disable:next line_length
        OtosLog.catalog.noticeOperation("import.plan", phase: "start", fields: ["rootPath": source.rawValue, "destinationPath": destination.rawValue, "sourceCount": "\(snapshot.sourceMedia.count)", "destinationOccupants": "\(snapshot.destinationOccupants.count)"])
        let seededClaims = ledgerClaims(for: destination, excluding: source)
        let signpost = OtosSignpost.performance.beginInterval("ImportPlanBuild")
        let build = await planBuilder.build(snapshot: snapshot, additionalReserved: seededClaims)
        OtosSignpost.performance.endInterval("ImportPlanBuild", signpost)
        let plan = build.plan
        Self.logPlanFinished(source: source, sourceCount: snapshot.sourceMedia.count, result: build)
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
            OtosLog.catalog.noticeOperation("import.plan", phase: "stale", fields: ["rootPath": source.rawValue, "sourceOccupancy": "\(sourceOccupancy.map(String.init) ?? "none")", "snapshotSourceOccupancy": "\(snapshot.sourceOccupancyRevision)", "destinationOccupancy": "\(destinationOccupancy.map(String.init) ?? "none")", "snapshotDestinationOccupancy": "\(snapshot.destinationOccupancyRevision)"])
            var updated = current
            updated.isDirty = true
            updated.phase = .inventory
            sourceSessions[source] = updated
            publish()
            scheduleBuildIfNeeded(source)
            return
        }
        let newClaims = planClaims(from: plan)
        let currentLedger = ledgerClaims(for: destination, excluding: source)
        if !newClaims.isDisjoint(with: currentLedger) {
            // swiftlint:disable:next line_length
            OtosLog.catalog.noticeOperation("import.plan", phase: "conflict", fields: ["rootPath": source.rawValue, "destination": destination.rawValue, "newClaims": "\(newClaims.count)", "conflictingClaims": "\(newClaims.intersection(currentLedger).count)"])
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
            OtosLog.catalog.notice("op=import.attachToReady phase=ready rootPath=\(source.rawValue, privacy: .public) elapsedMs=\(updated.attachToReadyMs ?? 0, privacy: .public) copyCount=\(plan.totals.copyCount, privacy: .public)")
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
    private func shouldWaitForMetadata(source: LibraryRootPath, snapshot: ImportPlanningSnapshot, attachment: AttachmentGeneration, generation: UInt64) async -> Bool {
        let missingDates = snapshot.sourceMedia.filter { !$0.hasUsableDate }.count
        let total = snapshot.sourceMedia.count
        let enriched = total - missingDates
        let libraries = await store.currentLibraries()
        let sourceKind = libraries.first(where: { $0.path == source })?.root.kind
        guard sourceKind != .deviceMTP,
              MediaTransferPlanner.needsDate(policy: snapshot.policy),
              snapshot.sourceMedia.contains(where: { $0.captureWallCompact == nil && $0.contentModifiedAt == nil })
        else {
            return false
        }
        guard var session = sourceSessions[source],
              session.attachmentGeneration == attachment,
              case let .building(ctx) = session.phase, ctx.generation.rawValue == generation
        else {
            return false
        }
        session.phase = .waitingForMetadata(done: enriched, total: max(total, 1))
        sourceSessions[source] = session
        publish()
        return true
    }

    private func ledgerClaims(for destination: LibraryRootPath, excluding excludedSource: LibraryRootPath? = nil) -> Set<MediaRelativePath> {
        var result: Set<MediaRelativePath> = []
        for (source, session) in sourceSessions where session.destination == destination && source != excludedSource {
            switch session.phase {
            case let .ready(ctx): result.formUnion(ctx.claims)
            case let .executing(ctx): result.formUnion(ctx.claims)
            default: break
            }
        }
        return result
    }

    private func planClaims(from plan: MediaOperationPlan) -> Set<MediaRelativePath> {
        var claims: Set<MediaRelativePath> = []
        for entry in plan.entries {
            guard case .copy = entry.disposition else { continue }
            claims.insert(entry.finalDestination)
            for dest in entry.companionDestinations.values {
                claims.insert(dest)
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
            session.importRequested ? .queuedForReadiness : .ready(
                summary: ctx.plan.totals,
                generation: ctx.plan.generation,
                skippedPackageCount: ctx.skippedPackageCount,
                attentionItems: ctx.attentionItems
            )
        case let .executing(ctx):
            .executing(progress: MediaOperationProgress(
                completedCount: 0,
                totalCount: ctx.plan.totals.copyCount,
                completedBytes: 0,
                totalBytes: 0,
                elapsedMs: 0
            ))
        case .completed:
            // Completed is a transient terminal presentation; keep summary empty for now.
            // The real completed presentation is published via execution result override.
            .completed(summary: MediaOperationPlanTotals(copyCount: 0, skipCount: 0, blockedCount: 0, companionCopyCount: 0, copyBytes: 0))
        case let .failed(reason, publishedCount):
            .failed(reason: reason, publishedCount: publishedCount)
        }
        return makePresentation(session: session, state: state)
    }

    /// The batch this attachment is currently working on or last worked on:
    /// the live execution's batch while executing, else the most recent
    /// completed execution's batch, else `nil` before any execution has
    /// started (`import-bar.md` "Where the user is standing").
    private func currentBatchID(for session: SourceSession) -> ImportBatchID? {
        if case let .executing(ctx) = session.phase {
            return ctx.batch
        }
        return session.lastCompletion?.batch
    }

    private func makePresentation(
        session: SourceSession,
        state: MediaOperationSourceState
    ) -> MediaOperationSourcePresentation {
        MediaOperationSourcePresentation(
            sourcePath: session.root.path,
            destinationPath: session.destination,
            destinationDisplayName: session.destination.flatMap { librariesByPath[$0]?.displayName },
            state: state,
            attachToReadyMs: session.attachToReadyMs,
            batchID: currentBatchID(for: session),
            cardStillExists: session.root.availability == .available,
            copiedJustNow: session.lastCompletion?.publishedCount,
            isFullyClean: session.lastCompletion?.isFullyClean
        )
    }

    private func sortedPresentations() -> [MediaOperationSourcePresentation] {
        // swiftlint:disable:next line_length
        sourceSessions.values.map { presentation(for: $0) }.sorted { $0.sourcePath.rawValue.localizedStandardCompare($1.sourcePath.rawValue) == .orderedAscending }
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
        if deviceRaw.isEmpty {
            preferences.removeObject(forKey: Self.destinationByDeviceIdentityKey)
        } else {
            preferences.set(deviceRaw, forKey: Self.destinationByDeviceIdentityKey)
        }
        if let last = lastUsedDestination {
            preferences.set(last.rawValue, forKey: Self.lastUsedDestinationKey)
        } else {
            preferences.removeObject(forKey: Self.lastUsedDestinationKey)
        }
        var legacyRaw: [String: String] = [:]
        for (source, dest) in destinationBySource {
            legacyRaw[source.rawValue] = dest.rawValue
        }
        if legacyRaw.isEmpty {
            preferences.removeObject(forKey: Self.destinationMappingKey)
        } else {
            preferences.set(legacyRaw, forKey: Self.destinationMappingKey)
        }
    }

    func allDestinations() -> [LibraryRootPath: LibraryRootPath] {
        destinationBySource
    }

    func allDeviceDestinations() -> [String: LibraryRootPath] {
        destinationByDeviceIdentity
    }
}
