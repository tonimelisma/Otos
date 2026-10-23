import Foundation
import OSLog

/// Media operation coordinator guide
///
/// The shell around `ImportSessionMachine`. The machine owns every fact about an
/// attached import source and changes only in `handle(_:)`, which is synchronous and
/// returns effects; this actor owns the I/O and the task lifetimes those effects ask for:
///
/// - **Reads.** Store reads (the sources snapshot, the plan-build pipeline, batch asset
///   counts) happen here, then their results are sent back as events. A read never
///   touches machine state, so no copy of a session lives across an `await`.
/// - **Builds and executions.** Each is one owned task. A task reports its result as an
///   event carrying the identity it was started for (`BuildID`, `ImportBatchID`); the
///   machine drops it when that identity no longer owns the session. Cancellation is
///   resource management at detach and shutdown only; identity validation is the
///   correctness proof.
/// - **Refreshes.** `librariesRefreshed` events come from one consumer task woken by a
///   doorbell, so two Store snapshots can never be applied out of order.
/// - **Presentation.** `presentation(for:)` and friends read `machine.sessions` and the
///   injected `volumeCapacity`; they derive, they never write.
///
/// Plan building runs through `ImportPlanBuilding`; the coordinator never awaits a build
/// from the planning-change consumer.
actor MediaOperationCoordinator {
    private typealias Machine = ImportSessionMachine
    private typealias SourceSession = ImportSessionMachine.SourceSession
    private typealias BuildID = ImportSessionMachine.BuildID

    private let store: CatalogStore
    private let preferences: any PreferenceStore
    private let preferencesDomain: PreferencesDomain
    private let cameraImport: CameraImportAccess?
    private let materializationRequester: MaterializationRequesting?
    private let autoEjectHandler: (@Sendable (LibraryRoot) async -> Void)?
    private let planBuilder: any ImportPlanBuilding
    /// Reads the destination volume's available capacity for state C's
    /// "not everything will fit" line — the same reader the executor's floor
    /// uses, so "available" means one thing in Otos. Injectable for tests.
    private let volumeCapacity: @Sendable (URL) -> Int64?
    private let makeExecutor: @Sendable (LibraryRootPath) -> any ImportExecuting

    private var machine: ImportSessionMachine

    /// An execution's task is the actual executor lifetime. It is registered when the
    /// machine asks for the run and removed when the run's result has been delivered.
    private struct ExecutionHandle {
        let task: Task<Void, Never>
        let executor: any ImportExecuting
    }

    private var executions: [ImportBatchID: ExecutionHandle] = [:]
    private var buildTasks: [BuildID: Task<Void, Never>] = [:]
    private var retryTasks: [LibraryRootPath: Task<Void, Never>] = [:]
    /// Short-lived tasks the machine's effects asked for (an executor cancel, a batch
    /// count read, an auto-eject). Tracked so quiescence and shutdown can see them.
    private var effectTasks: [UUID: Task<Void, Never>] = [:]
    /// Last state logged per source, so `publish()` records transitions rather than a
    /// sample of whatever a timer happened to catch (B3). Keyed with the attachment so a
    /// replaced card logs its first state even when it equals the old card's last.
    private var lastLoggedState: [LibraryRootPath: (attachment: MediaOperationAttachmentGeneration, state: MediaOperationSourceState)] = [:]
    private var continuations: [UUID: AsyncStream<[MediaOperationSourcePresentation]>.Continuation] = [:]
    private var isStarted = false
    private var consumerTask: Task<Void, Never>?
    private var catalogChangeTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshBell: AsyncStream<Void>.Continuation?
    /// Refreshes asked for and refreshes whose snapshot has been applied. A request is a
    /// counter nothing clears; the refresh loop covers the value it started from.
    private var refreshRequested: UInt64 = 0
    private var refreshCovered: UInt64 = 0
    private var pendingRefreshReason = "start"
    /// Changes the Store delivered, changes handled, and builds still running. Builds
    /// include stale ones, which keep running after their session moves on and are
    /// discarded when they return.
    private let planningChangeDeliveries = CatalogStore.DeliveryCount()
    private let catalogChangeDeliveries = CatalogStore.DeliveryCount()
    private var handledPlanningChanges: UInt64 = 0
    private var handledCatalogChanges: UInt64 = 0
    private var runningBuildCount = 0

    /// True once every planning and catalog change the Store delivered has been
    /// handled, every refresh asked for has been applied, and every build and effect
    /// task the coordinator started has returned. A caller can then assert what a change
    /// did — including that it published nothing — instead of guessing how long the
    /// coordinator takes.
    var isQuiescent: Bool {
        handledPlanningChanges == planningChangeDeliveries.delivered
            && handledCatalogChanges == catalogChangeDeliveries.delivered
            && refreshRequested == refreshCovered
            && runningBuildCount == 0
            && effectTasks.isEmpty
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
        self.volumeCapacity = volumeCapacity
        self.cameraImport = cameraImport
        self.materializationRequester = materializationRequester
        self.autoEjectHandler = autoEjectHandler
        machine = ImportSessionMachine(
            destinationBySource: [:],
            unreadableRetryDelays: unreadableRetryDelays,
            canExecuteCameraImport: cameraImport != nil
        )
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
        loadDestinationMappings()
        let executor = MediaImportExecutor(
            store: store,
            cameraImport: cameraImport,
            materializationRequester: materializationRequester
        )
        await executor.recoverJournal()
        // Subscribe before the first refresh: a change emitted while the refresh reads
        // the Store is then buffered and handled afterwards, never lost between the two.
        let changes = await store.planningChangeNotifications(deliveries: planningChangeDeliveries)
        let catalogChanges = await store.changeNotifications(deliveries: catalogChangeDeliveries)
        // The first refresh runs inline so sessions exist when `start()` returns; the
        // loop that serializes every later one starts after it.
        await send(.librariesRefreshed(readSourcesSnapshot(reason: "start")))
        startRefreshLoop()
        consumerTask = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                await handlePlanningChange(change)
            }
        }
        catalogChangeTask = Task { [weak self] in
            for await _ in catalogChanges {
                guard let self else { return }
                await handleCatalogChange()
            }
        }
        let subscribed = consumerTask != nil
        OtosLog.catalog.notice(
            "op=import.coordinator phase=subscribed planningStream=\(subscribed, privacy: .public)"
        )
    }

    func shutdown() async {
        guard isStarted else { return }
        send(.shutdown)
        consumerTask?.cancel()
        catalogChangeTask?.cancel()
        refreshTask?.cancel()
        refreshBell?.finish()
        // Snapshot owned tasks before clearing them so we can await them.
        let ownedRetryTasks = Array(retryTasks.values)
        let ownedBuildTasks = Array(buildTasks.values)
        let ownedExecutions = Array(executions.values)
        let ownedEffectTasks = Array(effectTasks.values)
        for task in ownedRetryTasks + ownedBuildTasks + ownedEffectTasks {
            task.cancel()
        }
        retryTasks.removeAll()
        for handle in ownedExecutions {
            handle.task.cancel()
        }
        for handle in ownedExecutions {
            await handle.executor.cancel()
        }
        _ = await consumerTask?.value
        consumerTask = nil
        _ = await catalogChangeTask?.value
        catalogChangeTask = nil
        _ = await refreshTask?.value
        refreshTask = nil
        refreshBell = nil
        for task in ownedBuildTasks + ownedEffectTasks + ownedExecutions.map(\.task) {
            _ = await task.value
        }
        // Nothing the loop was owed survives the shutdown.
        refreshCovered = refreshRequested
        // Executors already asked to cancel; nothing more to do. Journal remains recoverable.
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        send(.shutdownCompleted)
        isStarted = false
    }

    // MARK: - Intents

    func setDestination(_ destination: LibraryRootPath, for source: LibraryRootPath) async {
        send(.destinationPicked(destination, source: source))
    }

    func preferencesDidChange() async {
        send(.preferencesChanged)
    }

    func setSessionPreferences(_ prefs: ImportPreferences, for source: LibraryRootPath) async {
        send(.sessionPreferencesChanged(prefs, source: source))
    }

    /// Queues the import. When this call starts a run, it completes when the run does.
    func queueImport(for source: LibraryRootPath) async {
        let runningBefore = machine.executingBatch(for: source)
        send(.importQueued(source: source))
        if let batch = machine.executingBatch(for: source), batch != runningBefore,
           let task = executions[batch]?.task
        {
            await task.value
        }
    }

    func cancelImport(for source: LibraryRootPath) async {
        for task in send(.cancelRequested(source: source)) {
            await task.value
        }
    }

    func retryPlanning(for source: LibraryRootPath) async {
        send(.retryRequested(source: source))
    }

    func currentPresentations() -> [MediaOperationSourcePresentation] {
        sortedPresentations()
    }

    func readyPlan(for source: LibraryRootPath) -> MediaOperationPlan? {
        guard let session = machine.sessions[source], case let .ready(ctx) = session.phase else { return nil }
        return ctx.plan
    }

    // MARK: - Events in, effects out

    /// The one entry point for state changes: applies the event to the machine, then
    /// performs the effects it returned, in order. Synchronous, so nothing interleaves
    /// between the transition and its effects. Returns the owned tasks the effects
    /// started, for an intent that must not complete before they do.
    @discardableResult
    private func send(_ event: ImportSessionMachine.Event) -> [Task<Void, Never>] {
        var started: [Task<Void, Never>] = []
        for effect in machine.handle(event) {
            if let task = perform(effect) {
                started.append(task)
            }
        }
        return started
    }

    /// Entry for results that come back from owned tasks.
    private func deliver(_ event: ImportSessionMachine.Event) {
        send(event)
    }

    private func perform(_ effect: ImportSessionMachine.Effect) -> Task<Void, Never>? {
        switch effect {
        case let .startBuild(request):
            startBuild(request)
        case let .cancelBuild(id):
            buildTasks[id]?.cancel()
        case let .startExecution(request):
            startExecution(request)
        case let .cancelExecution(batch, alsoCancelTask):
            guard let handle = executions[batch] else { return nil }
            if alsoCancelTask {
                handle.task.cancel()
            }
            return spawnEffectTask { _ in await handle.executor.cancel() }
        case let .scheduleUnreadableRetry(source, attachment, delay):
            retryTasks[source]?.cancel()
            retryTasks[source] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                await deliver(.unreadableRetryFired(source: source, attachment: attachment))
            }
        case let .cancelUnreadableRetry(source):
            retryTasks.removeValue(forKey: source)?.cancel()
        case let .readBatchAssetCount(batch):
            let store = store
            return spawnEffectTask { coordinator in
                // A count that cannot be read confirms nothing; the next catalog change asks again.
                let count = try? await store.importBatchAssetCount(batch)
                await coordinator.deliver(.batchAssetCountRead(batch, count: count))
            }
        case .persistDestinations:
            persistDestinationMappings()
        case let .autoEject(root):
            return spawnEffectTask { coordinator in await coordinator.autoEjectIfRequested(root) }
        case .publish:
            publish()
        }
        return nil
    }

    private func spawnEffectTask(
        _ body: @escaping @Sendable (MediaOperationCoordinator) async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await body(self)
            await effectTaskFinished(id)
        }
        effectTasks[id] = task
        return task
    }

    private func effectTaskFinished(_ id: UUID) {
        effectTasks.removeValue(forKey: id)
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

    // MARK: - Store changes and refreshes

    private func handlePlanningChange(_ change: RootPlanningChange) {
        send(.planningChanged(change))
        requestRefresh(reason: "planningChange")
        handledPlanningChanges += 1
    }

    private func handleCatalogChange() {
        send(.catalogChanged)
        requestRefresh(reason: "catalogChange")
        handledCatalogChanges += 1
    }

    private func startRefreshLoop() {
        let (bell, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        refreshBell = continuation
        refreshTask = Task { [weak self] in
            for await _ in bell {
                guard let self else { return }
                await refreshPass()
            }
        }
    }

    private func requestRefresh(reason: String) {
        refreshRequested &+= 1
        pendingRefreshReason = reason
        refreshBell?.yield()
    }

    /// One refresh: read the Store, apply the snapshot as one event. Only the refresh
    /// loop runs it, so two snapshots can never be applied out of order.
    private func refreshPass() async {
        let startedFrom = refreshRequested
        guard startedFrom != refreshCovered else { return }
        let snapshot = await readSourcesSnapshot(reason: pendingRefreshReason)
        send(.librariesRefreshed(snapshot))
        refreshCovered = startedFrom
    }

    /// Reads everything one refresh needs. Writes nothing.
    private func readSourcesSnapshot(reason: String) async -> Machine.SourcesSnapshot {
        let libraries = await store.currentLibraries()
        var revisions: [LibraryRootPath: RootPlanningRevisions] = [:]
        for source in libraries where source.root.kind != .library && source.availability == .available {
            if let current = await store.planningRevisions(for: source.path) {
                revisions[source.path] = current
            }
        }
        return Machine.SourcesSnapshot(
            reason: reason,
            libraries: libraries,
            revisions: revisions,
            defaultPreferences: ImportPreferencesStore.load(defaults: preferences)
        )
    }

    // MARK: - Builds

    private func startBuild(_ request: Machine.BuildRequest) {
        runningBuildCount += 1
        buildTasks[request.id] = Task { [weak self] in
            guard let self else { return }
            await runBuild(request)
        }
    }

    private func runBuild(_ request: Machine.BuildRequest) async {
        let outcome = await buildOutcome(for: request)
        send(.buildFinished(request.id, outcome))
        buildTasks.removeValue(forKey: request.id)
        runningBuildCount -= 1
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

    /// The Store reads and the plan build for one build request. It touches no machine
    /// state; the outcome is judged against the session when it is delivered.
    private func buildOutcome(for request: Machine.BuildRequest) async -> Machine.BuildOutcome {
        let source = request.id.source
        let destination = request.destination
        let runID = request.runID
        do {
            guard let snapshot = try await store.importPlanningSnapshot(
                source: source,
                destination: destination,
                policy: request.policy,
                generation: request.id.generation.rawValue
            ) else {
                let libraries = await store.currentLibraries()
                return .noSnapshot(availableRoots: CatalogWindowPolicy.availablePaths(from: libraries))
            }
            if let pending = await namingPending(for: snapshot, source: source) {
                return .namingPending(pending)
            }
            OtosLog.catalog.noticeOperation("import.plan", phase: "start", fields: ["rootPath": source.rawValue, "destinationPath": destination.rawValue, "sourceCount": "\(snapshot.sourceMedia.count)", "destinationOccupants": "\(snapshot.destinationOccupants.count)", "run": runID])
            let signpost = OtosSignpost.performance.beginInterval("ImportPlanBuild")
            let build = await planBuilder.build(
                snapshot: snapshot,
                additionalReserved: Set(request.seededClaims.map { MediaRelativePath(rawValue: $0.rawValue) })
            )
            OtosSignpost.performance.endInterval("ImportPlanBuild", signpost)
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
            // Each revision pair is sampled in one actor hop so the halves cannot straddle
            // a suspension; the machine judges them against the snapshot.
            let sourceRevisions = await store.planningRevisions(for: source)
            let destinationNamespace = await store.namespaceRevision(for: destination)
            let skipped = await store.skippedPackageCount(for: source)
            return .built(Machine.BuiltPlan(
                snapshot: snapshot,
                build: build,
                sourceRevisions: sourceRevisions,
                destinationNamespaceRevision: destinationNamespace,
                skippedPackageCount: skipped
            ))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Whether naming facts the plan needs are still pending, and if so whether live rows
    /// say they have settled since the snapshot was read.
    private func namingPending(
        for snapshot: ImportPlanningSnapshot,
        source: LibraryRootPath
    ) async -> Machine.NamingPending? {
        // A camera is gated exactly like a card. Its bytes are staged locally so they can
        // be enriched, and enrichment of staged bytes is what produces a capture wall —
        // `ICCameraFile`'s own dates are absolute instants, so they cannot yield a local
        // wall clock, and its modification-first precedence is end-of-recording for video,
        // the same duration-sized error that duplicated 23 videos off a card (ARC-057).
        // A row whose bytes cannot be read is never going to become non-pending, and it
        // cannot be copied either — so it must not hold the offer open. The planner blocks
        // it and state D shows it (ARC-057).
        guard MediaTransferPlanner.needsDate(policy: snapshot.policy),
              snapshot.sourceMedia.contains(where: { $0.namingFactState == .pending && !$0.isSourceUnreadable })
        else {
            return nil
        }
        // Revalidate the fact this decision rests on, against live rows rather than the
        // snapshot. The snapshot was read before an await, so an enrichment batch may have
        // landed since — and the catalog-change wake that revives a `.waitingForMetadata`
        // session fires only for sessions *already* parked, so a batch landing mid-build is
        // not replayed. Parking on a stale snapshot would then wait for a wake that never
        // comes, and the last batch of a card's enrichment has nothing behind it to rescue
        // the session. The revision pair cannot answer this: a batch that reads a file and
        // finds no embedded capture wall moves the row from `.pending` to `.terminal`
        // without changing `capture_wall_compact`, so `namingRevision` stays put while the
        // gate's answer flips.
        let liveMedia = await store.planningMedia(for: source) ?? []
        let liveNamingSettled = !liveMedia.isEmpty
            && !liveMedia.contains(where: { $0.namingFactState == .pending && !$0.isSourceUnreadable })
        return Machine.NamingPending(
            // "Looked at", not "has some date": the honest denominator for state A's
            // determinate progress is how many source rows enrichment has actually read.
            settled: snapshot.sourceMedia.count { $0.namingFactState != .pending },
            total: liveNamingSettled ? liveMedia.count : snapshot.sourceMedia.count,
            filesWithNoDateAtAll: snapshot.sourceMedia.filter { !$0.hasAnyDate }.count,
            liveNamingSettled: liveNamingSettled
        )
    }

    // MARK: - Executions

    private func startExecution(_ request: Machine.ExecutionRequest) {
        let executor = makeExecutor(request.source)
        let batch = request.batch
        // Each callback hops to this actor on its own task, so samples can arrive out of
        // order; the machine's staleness guard drops the ones that would move a counter
        // backwards.
        let progressHandler: @Sendable (MediaOperationProgress) -> Void = { [weak self] progress in
            Task { [weak self] in
                await self?.deliver(.executionProgress(batch, progress))
            }
        }
        // The task owns the actual executor lifetime. It is registered before this actor
        // can process a detach, so a source removal cancels this same task and the run's
        // final journal outcome still settles the old batch.
        let task = Task { [weak self] in
            let result = await executor.execute(
                plan: request.plan,
                batch: batch,
                sourceKind: request.sourceKind,
                sourceDeviceIdentity: request.sourceDeviceIdentity,
                deleteSourceRequested: request.deleteSourceRequested,
                runID: request.runID
            ) { progress in
                progressHandler(progress)
            }
            await self?.executionTaskFinished(result, batch: batch)
        }
        executions[batch] = ExecutionHandle(task: task, executor: executor)
    }

    private func executionTaskFinished(_ result: MediaImportExecutionResult, batch: ImportBatchID) async {
        // A failed run's published count is read here, before the event, so the machine
        // applies one complete fact. A count that cannot be read stays unknown.
        let failedPublishedCount: Int? = if case .failed = result {
            try? await store.importBatchAssetCount(batch)
        } else {
            nil
        }
        send(.executionFinished(batch, result, failedPublishedCount: failedPublishedCount))
        executions.removeValue(forKey: batch)
    }

    // MARK: - Presentation

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
        // and the `!needsPlan` empty-card proof still apply — a session mid-rebuild
        // owes a plan, so it can never use a held plan to claim "This card is empty".
        // A held click (`importRequested`) changes nothing here: the bar keeps
        // saying what it knows, and the presentation carries the held click as
        // its own fact so the mapper disables Import (`import-bar.md` row 7).
        let state: MediaOperationSourceState = switch session.phase {
        case .inventory:
            interimState(for: session) ?? .inventory
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
        // `.planning` draws neither a plan nor a count, so it is the last resort: it is
        // correct only before this attachment has proven anything at all.
        case .building:
            interimState(for: session) ?? .planning
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
                    state: .failed(reason: failure.reason, publishedCount: failure.publishedCount ?? 0)
                )
            }
        }
        return makePresentation(session: session, state: state)
    }

    /// What a session between proofs shows while a newer plan is coming: the last
    /// thing this attachment proved — a plan, then a settled run, then a naming count.
    /// Shared by `.inventory` and `.building` so a stale build and a rebuild draw the
    /// same answer. Entering `.waitingForMetadata` drops the plan and the settlement,
    /// so during a metadata wait the count is the only answer left, and every frame
    /// between two counts is a count too.
    private func interimState(for session: SourceSession) -> MediaOperationSourceState? {
        heldPlanState(for: session)
            ?? settlementState(for: session)
            ?? session.lastNamingProgress.map { .waitingForMetadata(done: $0.done, total: $0.total) }
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
    /// `!session.needsPlan` — no rebuild is currently owed against a staleness
    /// signal the coordinator has already received — otherwise a genuinely-
    /// populated source could flash "This card is empty" for one frame.
    ///
    /// This checks the owed-plan counters rather than comparing `lastSeenRevisions`
    /// against `ctx.plan.sourceNamespaceRevision` directly: a source whose
    /// inventory never changes again after settling (an empty card that never
    /// gains a file) never earns another occupancy bump to reconcile the two
    /// independently-sampled values, so an equality check between them can
    /// permanently disagree with no future event able to fix it — the owed-plan
    /// accounting is the coordinator's own accounting of whether it is guaranteed
    /// caught up, not a second, freestanding derivation of the same fact.
    private func readyState(for session: SourceSession, ctx: Machine.ReadyContext) -> MediaOperationSourceState {
        guard ImportSourceReadiness.evaluate(session.root) == .ready else {
            return .inventory
        }
        let totals = ctx.plan.totals
        let isEmptyCard = totals.copyCount == 0 && totals.companionCopyCount == 0 && totals.skipCount == 0
        if isEmptyCard, session.needsPlan {
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
            destinationDisplayName: session.destination.flatMap { machine.displayName(ofLibrary: $0) },
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
        machine.sessions.values.map { presentation(for: $0) }
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
        lastLoggedState = lastLoggedState.filter { path, logged in
            machine.sessions[path]?.attachmentGeneration == logged.attachment
        }
        for presentation in values {
            guard lastLoggedState[presentation.sourcePath]?.state != presentation.state else { continue }
            lastLoggedState[presentation.sourcePath] = (presentation.attachmentGeneration, presentation.state)
            let progress: MediaOperationProgress? = if case let .executing(value) = presentation.state {
                value
            } else {
                nil
            }
            let batchID = presentation.batchID.map { String(describing: $0) } ?? "none"
            let runID = machine.sessions[presentation.sourcePath]?.activeRunID ?? "none"
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
            send(.destinationsRestored(Dictionary(uniqueKeysWithValues: raw.map {
                (LibraryRootPath(rawValue: $0.key), LibraryRootPath(rawValue: $0.value))
            })))
        }
    }

    private func persistDestinationMappings() {
        var raw: [String: String] = [:]
        for (source, dest) in machine.destinationBySource {
            raw[source.rawValue] = dest.rawValue
        }
        if raw.isEmpty {
            preferences.removeObject(forKey: Self.destinationMappingKey)
        } else {
            preferences.set(raw, forKey: Self.destinationMappingKey)
        }
    }

    func allDestinations() -> [LibraryRootPath: LibraryRootPath] {
        machine.destinationBySource
    }
}
