import Foundation
import OSLog

/// Import session machine guide
///
/// Every fact `MediaOperationCoordinator` keeps about an attached import source lives
/// here, in a value type that changes only through `handle(_:)`. `handle` is
/// synchronous: it applies one event and returns the effects the caller performs, in
/// order. Because nothing in it can suspend, no other event can interleave with a
/// transition, and a session is never copied out across an `await` and written back.
///
/// The coordinator actor is the shell. It reads the Store, runs plan builds and
/// executions as owned tasks, and reports each result back as an event; a result
/// carries the identity it was started for (`BuildID`, `ImportBatchID`) and is dropped
/// here, not in the shell, when that identity no longer owns the session.
///
/// A plan request is a counter, never a flag: `requestPlan()` adds to `planRequested`,
/// and taking a build up sets `planCovered = planRequested`. Nothing else writes
/// `planCovered`, so a request made while a build runs — a scan batch, a preference
/// change, a destination pick — is still outstanding when that build finishes
/// (`needsPlan`), and the machine starts the next build then.
///
/// Presentation is derived from `sessions` by the shell; the machine holds no tasks and
/// does no I/O. Logging stays inline: it is not state.
nonisolated struct ImportSessionMachine {
    typealias AttachmentGeneration = MediaOperationAttachmentGeneration

    // MARK: - Identities

    nonisolated struct BuildGeneration: Equatable, Hashable, Sendable {
        let rawValue: UInt64
    }

    /// What a build was started for. A completion is applied only while this still names
    /// the session's current `.building` phase.
    nonisolated struct BuildID: Equatable, Hashable, Sendable {
        let source: LibraryRootPath
        let attachment: AttachmentGeneration
        let generation: BuildGeneration
    }

    // MARK: - Session state

    nonisolated struct BuildContext {
        let generation: BuildGeneration
        let runID: String
        let destination: LibraryRootPath
        /// Whether the source had finished being read (ADR 0024 readiness) when this build
        /// was taken up. A build taken up mid-read plans over the rows the read had reached.
        let sourceSettledAtTakeUp: Bool
    }

    /// A build that found a destination folder it could not read is deferred, not
    /// published: the absence of an observation is not a plan. The retry is bounded by
    /// `unreadableRetryDelays`; past the last delay the condition is presented as a
    /// planning failure the user can `Try Again`.
    nonisolated struct UnreadableRetry {
        let attempt: Int
    }

    /// A proven plan and what it was proven for: the library it copies into and the run
    /// that built it. Its claims are names in that library, whatever the source's
    /// destination says by the time it is read.
    nonisolated struct ReadyContext {
        let plan: MediaOperationPlan
        let destination: LibraryRootPath
        let runID: String
        let skippedPackageCount: Int
        let claims: Set<FilesystemNameKey>
        let attentionItems: [MediaAttentionItem]
        /// Whether the source had finished being read when the build began. A plan built
        /// while a card was still being scanned describes part of it — or, before the scan
        /// reaches anything, nothing — so it is never offered or run; the source's settling
        /// asks for the plan that is (ADR 0024).
        let builtFromSettledSource: Bool
    }

    nonisolated enum ExecutionInterruption: Equatable {
        case userCancellation
        case sourceRemoved
    }

    /// A running import. It holds its destination for its whole life: a destination
    /// change made while it runs is recorded for the source and applies when it settles.
    nonisolated struct ExecutionContext {
        let plan: MediaOperationPlan
        let destination: LibraryRootPath
        let claims: Set<FilesystemNameKey>
        let sourceKind: LibraryRootKind
        let sourceRoot: LibraryRoot
        let skippedPackageCount: Int
        let prefs: ImportPreferences
        let batch: ImportBatchID
        let runID: String
        let attachment: AttachmentGeneration
        var interruption: ExecutionInterruption?
        /// The run's latest progress. It starts as the true starting value (the plan's
        /// totals, nothing completed yet) and only a newer sample replaces it.
        var progress: MediaOperationProgress
        /// Whether the batch has at least one durably published asset. The sidebar's batch
        /// row exists only then, so the presentation exposes the batch only then.
        var batchHasPublishedAsset: Bool
    }

    /// An execution whose source disappeared while the executor was still running. The
    /// executor task is the actual lifetime, so its result settles the old batch without
    /// ever being eligible to mutate a replacement session at the same path.
    nonisolated struct DrainingRun {
        let context: ExecutionContext
    }

    nonisolated enum SourcePhase {
        case inventory
        case waitingForMetadata(done: Int, total: Int)
        case building(BuildContext)
        case ready(ReadyContext)
        case executing(ExecutionContext)
        case executionUnavailable(
            summary: MediaOperationPlanTotals,
            generation: UInt64,
            attentionItems: [MediaAttentionItem]
        )
        case planningFailed(reason: MediaOperationFailureReason)
    }

    /// The most recent execution's outcome for the current attachment, kept across the
    /// post-settlement re-plan so a card left in the reader keeps reporting what it just
    /// copied (`import-bar.md` state F) instead of that fact vanishing when the re-plan
    /// replaces the phase. Cleared only by a new `AttachmentGeneration` (card
    /// ejected and re-inserted) — never by a later re-plan within the same attachment.
    nonisolated struct AttachmentCompletion {
        let batch: ImportBatchID?
        let publishedCount: Int
        let isFullyClean: Bool
        /// Items that started this run but did not land, carried alongside the rest of
        /// the completion so state F's incomplete variant can still select and scroll
        /// them after the post-settlement re-plan (`import-bar.md` state F).
        let incompleteItems: [MediaAssetID]
        let eraseOutcome: EraseOutcome?
        /// Why this run stopped before attempting every planned entry, or `nil` for a run
        /// that attempted them all. Published as
        /// `MediaOperationSourcePresentation.stopReason` so state F's Stopped variant
        /// renders from the run's own facts across the re-plan.
        let stopReason: ImportStopReason?
        /// The number of entries this run set out to copy — the plan's `copyCount` at
        /// execution — published as `plannedCount` for "12 of 42". The re-plan's own
        /// `copyCount` is the remainder and is not this number.
        let plannedCount: Int
        /// The library this run copied into. `presentation(for:)` publishes the
        /// completion's outcome only while the session's destination is still this
        /// library: "42 copied just now · 181 items in Camera Roll" would otherwise pair
        /// a count that landed in one library with the name of another after a
        /// destination change (`import-bar.md` state F, "scoped to this attachment and to
        /// the library it copied into"). The batch identity is not gated: it is the run's,
        /// whatever the destination now says.
        let destination: LibraryRootPath
    }

    /// The last run's failure, recorded beside `lastCompletion` rather than as a phase. A
    /// phase says what the session is doing *now*, and the rebuild that follows every
    /// settlement rightly replaces it; a finished run's outcome is a fact that rebuild
    /// has no business rewriting. Kept as a phase, the failure was erased by the re-plan
    /// within the same actor turn — drawn for 24 ms on 2026-09-09 — against
    /// `import-bar.md` state G's "never auto-dismisses". Planning failures (no
    /// destination, no snapshot) stay phases: they *are* the session's current condition,
    /// and a successful rebuild should replace them.
    nonisolated struct AttachmentFailure {
        let reason: MediaOperationFailureReason
        /// What this run had landed before it failed, as its executor counted it — state G
        /// states it when nonzero.
        let publishedCount: Int
        /// The run's batch, named in the settlement log when the card is removed while
        /// state G stands.
        let batch: ImportBatchID
        let destination: LibraryRootPath
    }

    /// A completed run's outcome, stored on the session so `presentation(for:)` reads the
    /// real outcome rather than synthesizing a zero-summary one on every publish.
    nonisolated struct SettledOutcome {
        let summary: MediaOperationPlanTotals
        let skippedForeignCount: Int
        let failedCount: Int
        let incompleteItems: [MediaAssetID]
        let eraseOutcome: EraseOutcome?
    }

    /// A proven naming count for one attachment. Named rather than a tuple so "done of
    /// total" cannot be read in the wrong order at a call site.
    nonisolated struct NamingProgress: Equatable, Sendable {
        let done: Int
        let total: Int
    }

    nonisolated struct SourceSession {
        let attachmentGeneration: AttachmentGeneration
        var root: CatalogLibraryState
        /// Whether the source's destination was picked via the pop-up this attachment,
        /// rather than still tracking the default. The destination itself is
        /// `destinationBySource`, the machine's one record of it. A default destination keeps following the first
        /// available library — including through a Settings → Libraries reorder while the
        /// card is attached. An explicit pick only falls back when it actually becomes
        /// unavailable, per its own "must survive until that run finishes" rule. Reset to
        /// `false` only by a new attachment, never by an incidental re-plan.
        var isDestinationExplicit: Bool
        var preferences: ImportPreferences
        var phase: SourcePhase
        /// Plan requests ever made for this session, and the count the last build taken
        /// up started from. `planRequested != planCovered` is "a plan is owed". Only
        /// `requestPlan()` writes the first and only taking a build up writes the second.
        var planRequested: UInt64 = 0
        var planCovered: UInt64 = 0
        var importRequested: Bool
        var nextBuildGeneration: BuildGeneration
        var attachStartedAt: ContinuousClock.Instant
        var attachToReadyMs: Int?
        /// The most recent naming progress this attachment reported. Held rather than
        /// recomputed because a rebuild has no count of its own to offer; showing the last
        /// proven one asserts nothing new. Scoped to the attachment, so a new card starts
        /// from nothing.
        var lastNamingProgress: NamingProgress?
        /// The most recent completed run's outcome, presented through the re-plan that
        /// follows it until a plan lands. Cleared when the card enters
        /// `.waitingForMetadata`, whose pending rows the run never saw, and when the
        /// destination changes, since it was measured against the previous library.
        var settledOutcome: SettledOutcome?
        /// The most recent plan this attachment actually proved, kept across the rebuilds
        /// that follow it. A re-plan overwrites `phase` with `.building`, so without this
        /// the plan the user is looking at is destroyed the moment a newer one is
        /// scheduled and the bar falls back to state A (ARC-047). State A means *no plan
        /// has ever existed for this attachment*; a refresh is not a first check.
        /// Cleared whenever the plan stops being true of the card: a run settling,
        /// stopping or failing, a destination change, and entering `.waitingForMetadata`.
        var lastReadyContext: ReadyContext?
        var lastCompletion: AttachmentCompletion?
        /// The last run's failure, if the most recent attempt failed. Cleared when the
        /// next attempt starts and when the user asks to plan again — never by a rebuild.
        var lastFailure: AttachmentFailure?
        /// The pending retry for a build deferred on an unreadable destination folder;
        /// `nil` when no such build is outstanding.
        var unreadableRetry: UnreadableRetry?

        var needsPlan: Bool {
            planRequested != planCovered
        }

        /// Correlates this session's plan, execution and presentation diagnostics. Minted
        /// when a build is taken up and carried by the phase that build leads to, so a
        /// re-plan cannot join an older run.
        var runID: String? {
            switch phase {
            case let .building(context): context.runID
            case let .ready(context): context.runID
            case let .executing(context): context.runID
            default: nil
            }
        }

        mutating func requestPlan() {
            planRequested &+= 1
        }
    }

    // MARK: - Events and effects

    /// The Store facts one refresh needs, read before the event is sent. Reading writes
    /// nothing, so a refresh applies as one synchronous transition.
    nonisolated struct SourcesSnapshot {
        let reason: String
        let libraries: [CatalogLibraryState]
        /// Planning revisions of every available removable source. A source the Store
        /// had no revisions for is absent.
        let revisions: [LibraryRootPath: RootPlanningRevisions]
        /// What a session created by this refresh starts with.
        let defaultPreferences: ImportPreferences
    }

    nonisolated struct BuildRequest: Sendable {
        let id: BuildID
        let destination: LibraryRootPath
        let policy: ImportPolicy
        let runID: String
        /// Names other sessions already claim in this destination, so the plan reserves
        /// them. Seeded when the build is taken up and re-checked when it completes.
        let seededClaims: Set<FilesystemNameKey>
    }

    nonisolated struct ExecutionRequest: Sendable {
        let source: LibraryRootPath
        let batch: ImportBatchID
        let plan: MediaOperationPlan
        let sourceKind: LibraryRootKind
        let sourceDeviceIdentity: DeviceIdentity?
        let deleteSourceRequested: Bool
        let runID: String
    }

    nonisolated struct NamingPending {
        let settled: Int
        let total: Int
        let filesWithNoDateAtAll: Int
        /// Whether live rows (read after the snapshot) show naming already settled, so
        /// parking would wait for a wake that never comes.
        let liveNamingSettled: Bool
    }

    nonisolated struct BuiltPlan {
        let snapshot: ImportPlanningSnapshot
        let build: ImportPlanBuildResult
        /// Sampled after the build, to judge the snapshot against.
        let sourceRevisions: RootPlanningRevisions?
        let destinationNamespaceRevision: UInt64?
        let skippedPackageCount: Int
    }

    nonisolated enum BuildOutcome {
        case noSnapshot(availableRoots: Set<LibraryRootPath>)
        case namingPending(NamingPending)
        case built(BuiltPlan)
        case failed(String)
    }

    nonisolated enum Event {
        case librariesRefreshed(SourcesSnapshot)
        case planningChanged(RootPlanningChange)
        case catalogChanged
        case batchAssetCountRead(ImportBatchID, count: Int?)
        case destinationPicked(LibraryRootPath, source: LibraryRootPath)
        case preferencesChanged
        case sessionPreferencesChanged(ImportPreferences, source: LibraryRootPath)
        case importQueued(source: LibraryRootPath)
        case cancelRequested(source: LibraryRootPath)
        case retryRequested(source: LibraryRootPath)
        case buildFinished(BuildID, BuildOutcome)
        case unreadableRetryFired(source: LibraryRootPath, attachment: AttachmentGeneration)
        case executionProgress(ImportBatchID, MediaOperationProgress)
        case executionFinished(ImportBatchID, MediaImportExecutionResult)
        case shutdown
        case shutdownCompleted
    }

    nonisolated enum Effect {
        case startBuild(BuildRequest)
        /// Detach and shutdown only; a newer request never cancels a build.
        case cancelBuild(BuildID)
        case startExecution(ExecutionRequest)
        case cancelExecution(ImportBatchID, alsoCancelTask: Bool)
        case scheduleUnreadableRetry(source: LibraryRootPath, attachment: AttachmentGeneration, delay: Duration)
        case cancelUnreadableRetry(source: LibraryRootPath)
        case readBatchAssetCount(ImportBatchID)
        case persistDestinations
        case autoEject(LibraryRoot)
        case publish
    }

    // MARK: - State

    private(set) var sessions: [LibraryRootPath: SourceSession] = [:]
    /// Each source's destination, the one record of it: read by an attached session,
    /// remembered across detach for Settings and the next attachment, and written only by
    /// `setDestination`.
    private(set) var destinationBySource: [LibraryRootPath: LibraryRootPath]
    private var lastSeenRevisions: [LibraryRootPath: RootPlanningRevisions] = [:]
    private var draining: [ImportBatchID: DrainingRun] = [:]
    /// The libraries of the last refresh: `presentation(for:)` resolves the destination's
    /// display name from it, and execution readiness is judged against it.
    private(set) var libraries: [CatalogLibraryState] = []
    private var nextAttachmentGeneration: UInt64 = 1
    private var isShuttingDown = false

    private let unreadableRetryDelays: [Duration]
    private let canExecuteCameraImport: Bool

    /// Wakes that moved no revision, per root, since the last one that did. Most
    /// planning-change notifications change nothing: a 999-item import measured 5,381
    /// notifications against **16** actual plan rebuilds. A line per notification would
    /// bury the fact an agent actually needs, *which* wake moved a revision. The count
    /// rides on the next line that reports a real change.
    private var churnWakesByRoot: [LibraryRootPath: Int] = [:]
    /// Refreshes that left the source set unchanged, since the last one that did not.
    private var suppressedRefreshes = 0
    private var lastLoggedSourceCount: Int?
    /// Emit a summary after this many suppressed events even when nothing changed, so a
    /// run where the source set never changes does not log nothing at all — which is
    /// indistinguishable from a dead subscription.
    private static let churnSummaryThreshold = 200

    init(
        destinationBySource: [LibraryRootPath: LibraryRootPath],
        unreadableRetryDelays: [Duration],
        canExecuteCameraImport: Bool
    ) {
        self.destinationBySource = destinationBySource
        self.unreadableRetryDelays = unreadableRetryDelays
        self.canExecuteCameraImport = canExecuteCameraImport
    }

    /// Available fixed libraries in the user's order, as of the last refresh.
    var fixedAvailableLibraries: [CatalogLibraryState] {
        libraries.filter { $0.root.kind == .library && $0.availability == .available }
    }

    func displayName(ofLibrary path: LibraryRootPath) -> String? {
        libraries.first { $0.path == path }?.displayName
    }

    /// The library a source's session copies into: a running import's own while it runs,
    /// otherwise the source's destination.
    func destination(of source: LibraryRootPath) -> LibraryRootPath? {
        guard let session = sessions[source] else { return nil }
        if case let .executing(context) = session.phase {
            return context.destination
        }
        return destinationBySource[source]
    }

    /// The batch a session is executing, if it is.
    func executingBatch(for source: LibraryRootPath) -> ImportBatchID? {
        guard case let .executing(context) = sessions[source]?.phase else {
            return nil
        }
        return context.batch
    }

    // MARK: - Transitions

    /// Applies one event and returns the effects to perform, in order. The only writer of
    /// session state.
    mutating func handle(_ event: Event) -> [Effect] {
        var effects: [Effect] = []
        switch event {
        case let .librariesRefreshed(snapshot):
            refresh(snapshot, into: &effects)
        case let .planningChanged(change):
            applyPlanningChange(change, into: &effects)
        case .catalogChanged:
            applyCatalogChange(into: &effects)
        case let .batchAssetCountRead(batch, count):
            confirmBatchAssetCount(batch, count: count, into: &effects)
        case let .destinationPicked(destination, source):
            pickDestination(destination, for: source, into: &effects)
        case .preferencesChanged:
            for source in Array(sessions.keys) {
                sessions[source]?.requestPlan()
                takeUpBuild(source, into: &effects)
            }
        case let .sessionPreferencesChanged(prefs, source):
            guard sessions[source] != nil else { break }
            sessions[source]?.preferences = prefs
            sessions[source]?.requestPlan()
            takeUpBuild(source, into: &effects)
        case let .importQueued(source):
            queueImport(for: source, into: &effects)
        case let .cancelRequested(source):
            cancelImport(for: source, into: &effects)
        case let .retryRequested(source):
            retryPlanning(for: source, into: &effects)
        case let .buildFinished(id, outcome):
            finishBuild(id, outcome, into: &effects)
        case let .unreadableRetryFired(source, attachment):
            fireUnreadableRetry(source: source, attachment: attachment, into: &effects)
        case let .executionProgress(batch, progress):
            applyExecutionProgress(batch: batch, progress: progress, into: &effects)
        case let .executionFinished(batch, result):
            finishExecution(batch, result, into: &effects)
        case .shutdown:
            isShuttingDown = true
            sessions.removeAll()
            draining.removeAll()
            effects.append(.publish)
        case .shutdownCompleted:
            isShuttingDown = false
        }
        return effects
    }

    // MARK: Refresh

    private func attachmentGeneration(for source: CatalogLibraryState) -> (AttachmentGeneration, advancing: Bool) {
        if source.attachmentGeneration != 0 {
            return (AttachmentGeneration(rawValue: source.attachmentGeneration), false)
        }
        return (AttachmentGeneration(rawValue: nextAttachmentGeneration), true)
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

    /// Whether a refresh's revisions say a plan went stale. A snapshot read before a
    /// planning change this machine already applied is *older*, not different: taking it
    /// as a change would regress `lastSeenRevisions` and request a plan nothing asked for.
    private func revisionsMoved(
        lastSeen: RootPlanningRevisions?,
        current: RootPlanningRevisions?
    ) -> Bool {
        guard let lastSeen, let current else {
            return lastSeen != current
        }
        if lastSeen.namespaceRevision >= current.namespaceRevision,
           lastSeen.namingRevision >= current.namingRevision
        {
            return false
        }
        return lastSeen != current
    }

    private mutating func refresh(_ snapshot: SourcesSnapshot, into effects: inout [Effect]) {
        guard !isShuttingDown else { return }
        libraries = snapshot.libraries
        let fixedAvailable = fixedAvailableLibraries
        let removable = libraries.filter { $0.root.kind != .library && $0.availability == .available }
        var seen = Set<LibraryRootPath>()
        for source in removable {
            seen.insert(source.path)
            let currentRevisions = snapshot.revisions[source.path]
            if let existing = sessions[source.path], isNewAttachment(source, replacing: existing) {
                disposeDetachedSession(path: source.path, session: existing, reason: "reattached", into: &effects)
                sessions.removeValue(forKey: source.path)
                lastSeenRevisions.removeValue(forKey: source.path)
                OtosLog.catalog.notice(
                    "op=import.attachment phase=replaced sourcePath=\(source.path.rawValue, privacy: .public) oldGeneration=\(existing.attachmentGeneration.rawValue, privacy: .public) newGeneration=\(source.attachmentGeneration, privacy: .public)"
                )
            }
            if sessions[source.path] == nil {
                attach(source, revisions: currentRevisions, snapshot: snapshot, fixedAvailable: fixedAvailable, into: &effects)
            } else {
                updateAttached(source, revisions: currentRevisions, fixedAvailable: fixedAvailable, into: &effects)
            }
        }
        // Detach: remove sessions for missing sources, cancel owned work.
        for path in Array(sessions.keys) where !seen.contains(path) {
            if let session = sessions[path] {
                disposeDetachedSession(path: path, session: session, reason: "detached", into: &effects)
            }
            sessions.removeValue(forKey: path)
            // Keep destinationBySource for Settings; clear transient occupancy.
            lastSeenRevisions.removeValue(forKey: path)
        }
        effects.append(.publish)
        logRefresh(reason: snapshot.reason, sourceCount: removable.count)
    }

    private mutating func attach(
        _ source: CatalogLibraryState,
        revisions: RootPlanningRevisions?,
        snapshot: SourcesSnapshot,
        fixedAvailable: [CatalogLibraryState],
        into effects: inout [Effect]
    ) {
        let (attachmentGen, advancing) = attachmentGeneration(for: source)
        if advancing {
            nextAttachmentGeneration &+= 1
        }
        // The destination is remembered per removable source (owner decision —
        // `import-bar.md` "Destination control"): a source seen before resumes
        // wherever it last landed, explicit pick or default-tracked alike.
        // `isDestinationExplicit: true` is what makes the memory stick — without it, the
        // very next reorder-tracking refresh would overwrite it back to
        // `fixedAvailable.first`. First sight of a source (no remembered value, or its
        // library is gone) falls back to the first available library and stays a true
        // default, tracking future reorders.
        let remembered = destinationBySource[source.path]
        let isRememberedValid = remembered.map { dest in
            fixedAvailable.contains { $0.path == dest }
        } ?? false
        var session = SourceSession(
            attachmentGeneration: attachmentGen,
            root: source,
            isDestinationExplicit: isRememberedValid,
            preferences: snapshot.defaultPreferences,
            phase: .inventory,
            importRequested: false,
            nextBuildGeneration: BuildGeneration(rawValue: 1),
            attachStartedAt: ContinuousClock().now,
            attachToReadyMs: nil,
            settledOutcome: nil,
            lastCompletion: nil,
            lastFailure: nil,
            unreadableRetry: nil
        )
        session.requestPlan()
        sessions[source.path] = session
        if let revisions {
            lastSeenRevisions[source.path] = revisions
        } else {
            lastSeenRevisions.removeValue(forKey: source.path)
        }
        setDestination(
            isRememberedValid ? remembered : fixedAvailable.first?.path,
            explicit: isRememberedValid,
            for: source.path,
            into: &effects
        )
    }

    private mutating func updateAttached(
        _ source: CatalogLibraryState,
        revisions: RootPlanningRevisions?,
        fixedAvailable: [CatalogLibraryState],
        into effects: inout [Effect]
    ) {
        // Update root for existing session (availability may have changed).
        sessions[source.path]?.root = source
        // A session's plan goes stale the moment the root it was built from gains
        // new/changed rows — device enumeration landing after attach is exactly this: the
        // session already exists (created from whatever rows were persisted at attach)
        // and this revision bump is how it learns the live inventory superseded that
        // snapshot. This root is the session's *source*, so either revision counts.
        // Reuses the same `lastSeenRevisions` map the planning-change event keys
        // staleness on, so both triggering paths agree on what "already seen" means.
        if revisionsMoved(lastSeen: lastSeenRevisions[source.path], current: revisions) {
            if let revisions {
                lastSeenRevisions[source.path] = revisions
            } else {
                lastSeenRevisions.removeValue(forKey: source.path)
            }
            sessions[source.path]?.requestPlan()
            if case .executing = sessions[source.path]?.phase {
                // Don't rebuild the executing source itself; it rebuilds after execution
                // settles, same as a planning change.
            } else {
                takeUpBuild(source.path, into: &effects)
            }
        }
        // A plan built while the source was still being read is owed a successor once the
        // read settles, whether or not the read moved a revision: an identical card's scan
        // bumps only the plan revision, which asks for no rebuild of its own.
        if ImportSourceReadiness.evaluate(source) == .ready,
           case let .ready(ctx) = sessions[source.path]?.phase,
           !ctx.builtFromSettledSource
        {
            OtosLog.catalog.noticeOperation("import.plan", phase: "rebuildAfterSourceSettled", fields: [
                "rootPath": source.path.rawValue,
                "run": ctx.runID,
            ])
            sessions[source.path]?.requestPlan()
            takeUpBuild(source.path, into: &effects)
        }
        reconcileDestination(for: source.path, fixedAvailable: fixedAvailable, into: &effects)
        // Readiness can turn `.ready` (enumeration/scan activity flips idle) via this
        // cheap catalog-change refresh alone, without an occupancy change of its own. A
        // queued Import that lost that race is retried here; it no-ops unless the session
        // is genuinely `.ready` and still has `importRequested` set.
        if let session = sessions[source.path], session.importRequested, case let .ready(ctx) = session.phase {
            beginExecutionIfPossible(source: source.path, readyContext: ctx, into: &effects)
        }
    }

    /// The one rule for a source's destination. A default destination tracks the first
    /// available library; an explicit pick holds until that library becomes unavailable.
    /// A running import holds its destination, so a change that arrives mid-run is
    /// applied when the run settles, from the library order the last refresh recorded.
    private mutating func reconcileDestination(
        for source: LibraryRootPath,
        fixedAvailable: [CatalogLibraryState],
        into effects: inout [Effect]
    ) {
        guard let session = sessions[source] else { return }
        if case .executing = session.phase {
            return
        }
        let current = destinationBySource[source]
        let isCurrentAvailable = current.map { dest in fixedAvailable.contains { $0.path == dest } } ?? false
        if session.isDestinationExplicit, isCurrentAvailable {
            return
        }
        let tracked = fixedAvailable.first?.path
        guard tracked != current || session.isDestinationExplicit else { return }
        setDestination(tracked, explicit: false, for: source, into: &effects)
    }

    /// The one writer of a source's destination. Remembers it for the source and, for an
    /// attached session whose library changed, drops what was measured against the old
    /// one — the held plan and the settled outcome — and re-plans: "42 new items" or
    /// "everything on this card is imported" are claims about a library, and drawn under
    /// another's name they would be false, or offer an Import whose number the click
    /// would not honour. The last naming progress is about the card, so it stays.
    private mutating func setDestination(
        _ destination: LibraryRootPath?,
        explicit: Bool,
        for source: LibraryRootPath,
        into effects: inout [Effect]
    ) {
        let previous = destinationBySource[source]
        if previous != destination {
            destinationBySource[source] = destination
            effects.append(.persistDestinations)
        }
        guard var session = sessions[source] else { return }
        session.isDestinationExplicit = explicit
        if previous != destination {
            session.requestPlan()
            session.lastReadyContext = nil
            session.settledOutcome = nil
        }
        sessions[source] = session
        takeUpBuild(source, into: &effects)
    }

    /// Same aggregation as the planning-wake log, and for the same reason: this fires
    /// once per wake, and the facts it carries are unchanged across almost all of them.
    private mutating func logRefresh(reason: String, sourceCount: Int) {
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

    // MARK: Detach

    /// Removes a source session's owned work. Its outcome is status for the card's row,
    /// which no longer exists, so it is logged and dropped; the imported assets and
    /// journal remain in Store. An executing run moves to the batch-keyed drain.
    private mutating func disposeDetachedSession(
        path: LibraryRootPath,
        session: SourceSession,
        reason: String,
        into effects: inout [Effect]
    ) {
        if session.unreadableRetry != nil {
            effects.append(.cancelUnreadableRetry(source: path))
        }
        switch session.phase {
        case let .building(context):
            effects.append(.cancelBuild(BuildID(
                source: path,
                attachment: session.attachmentGeneration,
                generation: context.generation
            )))
        case let .executing(existingContext):
            var context = existingContext
            context.interruption = context.interruption ?? .sourceRemoved
            draining[context.batch] = DrainingRun(context: context)
            effects.append(.cancelExecution(context.batch, alsoCancelTask: true))
            OtosLog.catalog.notice(
                "op=import.execution phase=draining reason=\(reason, privacy: .public) sourcePath=\(path.rawValue, privacy: .public) batchID=\(String(describing: context.batch), privacy: .public) attachment=\(session.attachmentGeneration.rawValue, privacy: .public)"
            )
        default:
            logDetachedOutcome(session)
        }
    }

    /// The import bar is drawn only on a live card's row, so a settled outcome has
    /// nowhere to be shown once its card is gone: the batch row's grid is the report. The
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

    private func logDetachedSettlement(
        source: LibraryRootPath,
        batch: ImportBatchID,
        outcome: String,
        publishedCount: Int?
    ) {
        let count = publishedCount.map(String.init) ?? "unknown"
        OtosLog.catalog.notice(
            "op=import.outcome phase=settled sourcePath=\(source.rawValue, privacy: .public) batchID=\(String(describing: batch), privacy: .public) outcome=\(outcome, privacy: .public) publishedCount=\(count, privacy: .public)"
        )
    }

    // MARK: Store changes

    /// Applies a planning wake per role (ARC-046). A root's **namespace** revision
    /// invalidates every session reading it as source or destination; its **naming**
    /// revision invalidates only sessions reading it as *source*, because enriching an
    /// asset already in the destination renames nothing on disk and
    /// `fetchDestinationOccupants` never reads a capture wall. A wake that moves neither
    /// is `planRevision`-only churn and does no work.
    private mutating func applyPlanningChange(_ change: RootPlanningChange, into effects: inout [Effect]) {
        let previous = lastSeenRevisions[change.rootPath]
        let namespaceChanged = previous?.namespaceRevision != change.namespaceRevision
        let namingChanged = previous?.namingRevision != change.namingRevision
        lastSeenRevisions[change.rootPath] = change.revisions
        logPlanningWake(change, moved: namespaceChanged || namingChanged)
        guard namespaceChanged || namingChanged else { return }
        // Source role: the plan reads this root's inventory *and* its capture walls (the
        // date/time name is derived from them), so either revision invalidates it.
        if libraries.contains(where: { $0.root.kind != .library && $0.path == change.rootPath }),
           sessions[change.rootPath] != nil
        {
            sessions[change.rootPath]?.requestPlan()
            // Don't rebuild an executing source itself; it will rebuild after execution.
            takeUpBuild(change.rootPath, into: &effects)
        }
        // Destination role: only a namespace change matters. An enrichment naming write
        // here moved no file, so every plan copying into this root is still exactly as
        // valid as it was — replanning on it is what livelocked planning against an
        // enriching cloud library (ARC-046).
        if namespaceChanged {
            rebuildSessionsTargeting(destination: change.rootPath, into: &effects)
        }
    }

    /// Logs a planning wake only when it moved a revision, or when enough have not.
    private mutating func logPlanningWake(_ change: RootPlanningChange, moved: Bool) {
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

    /// The destination half of a planning change: every session copying *into*
    /// `destination` is stale because the names it can claim there just changed.
    private mutating func rebuildSessionsTargeting(destination: LibraryRootPath, into effects: inout [Effect]) {
        let isDestinationUnderExecution = sessions.values.contains { session in
            if case let .executing(context) = session.phase {
                return context.destination == destination
            }
            return false
        }
        for source in Array(sessions.keys) where destinationBySource[source] == destination {
            sessions[source]?.requestPlan()
            if isDestinationUnderExecution {
                OtosLog.catalog.notice("op=import.coordinator phase=suppressRebuild source=\(source.rawValue, privacy: .public) destination=\(destination.rawValue, privacy: .public)")
                continue
            }
            takeUpBuild(source, into: &effects)
        }
    }

    private mutating func applyCatalogChange(into effects: inout [Effect]) {
        // A catalog change revives every session parked on `.waitingForMetadata`: an
        // enrichment batch is what moves a pending row to settled.
        var waitingSources: [LibraryRootPath] = []
        for (source, session) in sessions {
            if case .waitingForMetadata = session.phase {
                waitingSources.append(source)
            }
        }
        if !waitingSources.isEmpty {
            for source in waitingSources {
                sessions[source]?.requestPlan()
                takeUpBuild(source, into: &effects)
            }
            OtosLog.catalog.notice("op=import.coordinator phase=catalogChangeWake waitingCount=\(waitingSources.count, privacy: .public)")
        }
        // Confirms, for every still-executing session that hasn't proven itself yet,
        // whether its batch now has at least one durably-published asset — the fact
        // `executingBatchID` gates the presentation's `batchID` exposure on. It rides the
        // catalog-change event this machine already consumes: an import's own
        // publish/settle writes are themselves catalog changes.
        for session in sessions.values {
            if case let .executing(ctx) = session.phase, !ctx.batchHasPublishedAsset {
                effects.append(.readBatchAssetCount(ctx.batch))
            }
        }
    }

    private mutating func confirmBatchAssetCount(
        _ batch: ImportBatchID,
        count: Int?,
        into effects: inout [Effect]
    ) {
        guard let count, count > 0,
              let source = source(executing: batch),
              case var .executing(context)? = sessions[source]?.phase,
              !context.batchHasPublishedAsset
        else {
            return
        }
        context.batchHasPublishedAsset = true
        sessions[source]?.phase = .executing(context)
        effects.append(.publish)
    }

    private func source(executing batch: ImportBatchID) -> LibraryRootPath? {
        sessions.first { _, session in
            if case let .executing(ctx) = session.phase {
                return ctx.batch == batch
            }
            return false
        }?.key
    }

    // MARK: User intents

    private mutating func pickDestination(
        _ destination: LibraryRootPath,
        for source: LibraryRootPath,
        into effects: inout [Effect]
    ) {
        setDestination(destination, explicit: true, for: source, into: &effects)
        effects.append(.publish)
    }

    private mutating func queueImport(for source: LibraryRootPath, into effects: inout [Effect]) {
        guard sessions[source] != nil else {
            OtosLog.catalog.notice("op=import.queue phase=rejected reason=noSession rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        // Reject if already executing.
        if case .executing = sessions[source]?.phase {
            OtosLog.catalog.notice("op=import.queue phase=rejected reason=alreadyExecuting rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        sessions[source]?.importRequested = true
        switch sessions[source]?.phase {
        case let .ready(ctx):
            // Move to queued presentation via derived state and begin execution.
            effects.append(.publish)
            beginExecutionIfPossible(source: source, readyContext: ctx, into: &effects)
        default:
            // Not ready yet; request a plan so planning will begin execution when ready.
            // Publish so the bar disables Import for the held click.
            effects.append(.publish)
            sessions[source]?.requestPlan()
            takeUpBuild(source, into: &effects)
        }
        OtosLog.catalog.notice("op=import.queue phase=start rootPath=\(source.rawValue, privacy: .public)")
    }

    private mutating func cancelImport(for source: LibraryRootPath, into effects: inout [Effect]) {
        guard var session = sessions[source], case var .executing(ctx) = session.phase else {
            OtosLog.catalog.notice("op=import.cancel phase=requested rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        ctx.interruption = ctx.interruption ?? .userCancellation
        session.phase = .executing(ctx)
        sessions[source] = session
        effects.append(.cancelExecution(ctx.batch, alsoCancelTask: false))
        OtosLog.catalog.notice("op=import.cancel phase=requested rootPath=\(source.rawValue, privacy: .public)")
    }

    private mutating func retryPlanning(for source: LibraryRootPath, into effects: inout [Effect]) {
        guard sessions[source] != nil else { return }
        // `Try Again` is the one act on state G: the user has addressed the cause, so the
        // recorded failure yields to whatever the re-plan finds, and a deferred build's
        // backoff starts over.
        sessions[source]?.lastFailure = nil
        if sessions[source]?.unreadableRetry != nil {
            effects.append(.cancelUnreadableRetry(source: source))
        }
        sessions[source]?.unreadableRetry = nil
        sessions[source]?.requestPlan()
        takeUpBuild(source, into: &effects)
        OtosLog.catalog.notice("op=import.retry phase=requested rootPath=\(source.rawValue, privacy: .public)")
    }

    // MARK: Builds

    /// Takes up the session's owed plan: starts a build, or settles the session as having
    /// no destination. Returns whether a plan was taken up. A session with nothing owed,
    /// or one already building or executing, is left alone and returns `false`; what it
    /// is owed stays outstanding and is taken up when that work finishes.
    @discardableResult
    private mutating func takeUpBuild(_ source: LibraryRootPath, into effects: inout [Effect]) -> Bool {
        guard !isShuttingDown, var session = sessions[source], session.needsPlan else { return false }
        if case .building = session.phase {
            return false
        }
        if case .executing = session.phase {
            return false
        }
        session.planCovered = session.planRequested
        let buildGen = session.nextBuildGeneration
        session.nextBuildGeneration = BuildGeneration(rawValue: buildGen.rawValue &+ 1)
        let attachmentGen = session.attachmentGeneration
        let runID = UUID().uuidString
        let destination = destinationBySource[source]
        OtosLog.catalog.noticeOperation("plan.rebuild", phase: "schedule", fields: ["source": source.rawValue, "destination": destination?.rawValue ?? "none", "generation": "\(buildGen.rawValue)", "attachment": "\(attachmentGen.rawValue)", "run": runID])
        guard let destination else {
            // No destination is state B ("No destination"), not a failure —
            // `destinationPath == nil` on the presentation is what the mapper reads; this
            // reason is never shown.
            session.phase = .planningFailed(reason: .unexpected(detail: "noDestinationLibrary"))
            sessions[source] = session
            effects.append(.publish)
            return true
        }
        let sourceSettled = libraries.first { $0.path == source }
            .map { ImportSourceReadiness.evaluate($0) == .ready } ?? false
        session.phase = .building(BuildContext(
            generation: buildGen,
            runID: runID,
            destination: destination,
            sourceSettledAtTakeUp: sourceSettled
        ))
        let policy = ImportPolicy.from(session.preferences)
        sessions[source] = session
        effects.append(.startBuild(BuildRequest(
            id: BuildID(source: source, attachment: attachmentGen, generation: buildGen),
            destination: destination,
            policy: policy,
            runID: runID,
            seededClaims: ledgerClaims(for: destination, excluding: source)
        )))
        effects.append(.publish)
        return true
    }

    /// The session this build still owns, or nil if a newer build, a new attachment, a
    /// detach or a shutdown took it.
    private func sessionOwned(by id: BuildID) -> (session: SourceSession, context: BuildContext)? {
        guard let session = sessions[id.source] else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=noSession source=\(id.source.rawValue, privacy: .public)")
            return nil
        }
        guard session.attachmentGeneration == id.attachment else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=attachmentMismatch source=\(id.source.rawValue, privacy: .public)")
            return nil
        }
        guard case let .building(context) = session.phase, context.generation == id.generation else {
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=phaseMismatch source=\(id.source.rawValue, privacy: .public)")
            return nil
        }
        return (session, context)
    }

    /// Applies a finished build. The build read the Store while other events arrived, so
    /// every fact it carries is judged against the session *now*: the session is never
    /// copied out before the build and written back after it, and a request made during
    /// the build is still outstanding (`needsPlan`) when this runs.
    private mutating func finishBuild(_ id: BuildID, _ outcome: BuildOutcome, into effects: inout [Effect]) {
        guard !isShuttingDown, let owned = sessionOwned(by: id) else { return }
        let source = id.source
        switch outcome {
        case let .failed(detail):
            sessions[source]?.phase = .planningFailed(reason: .unexpected(detail: detail))
            effects.append(.publish)
        case let .noSnapshot(availableRoots):
            let reason = MediaOperationFailureReason.forMissingSnapshot(
                source: source,
                destination: owned.context.destination,
                availableRoots: availableRoots
            )
            sessions[source]?.phase = .planningFailed(reason: reason)
            effects.append(.publish)
        case let .namingPending(pending):
            applyNamingPending(pending, id: id, runID: owned.context.runID)
            effects.append(.publish)
        case let .built(built):
            if applyBuiltPlan(built, id: id, owned: owned, into: &effects) == .deferredOnUnreadableDestination {
                // The retry owns the next build; rebuilding now would just hit the same
                // unreadable folder.
                return
            }
        }
        // A request recorded while this build ran is a fact its plan never saw.
        takeUpBuild(source, into: &effects)
    }

    private mutating func applyNamingPending(_ pending: NamingPending, id: BuildID, runID: String) {
        let source = id.source
        if pending.liveNamingSettled {
            OtosLog.catalog.notice(
                "op=import.readiness phase=namingSettledDuringBuild run=\(runID, privacy: .public) rootPath=\(source.rawValue, privacy: .public) total=\(pending.total, privacy: .public)"
            )
            sessions[source]?.requestPlan()
            sessions[source]?.phase = .inventory
            return
        }
        let message = "op=import.readiness phase=waitingForMetadata run=\(runID) "
            + "rootPath=\(source.rawValue) "
            + "settled=\(pending.settled) "
            + "total=\(pending.total) "
            + "filesWithNoDateAtAll=\(pending.filesWithNoDateAtAll)"
        OtosLog.catalog.notice("\(message, privacy: .public)")
        sessions[source]?.phase = .waitingForMetadata(done: pending.settled, total: max(pending.total, 1))
        sessions[source]?.lastNamingProgress = NamingProgress(done: pending.settled, total: max(pending.total, 1))
        // The held plan was proven over a set that did not contain these pending rows, so
        // it no longer describes the card. Holding it across the rebuilds that follow drew
        // it as Ready — and the sidebar row as its eject button — between every pair of
        // Preparing frames, once a second for the whole metadata wait. A settled run is
        // dropped for the same reason. What the run copied stays in `lastCompletion`.
        sessions[source]?.lastReadyContext = nil
        sessions[source]?.settledOutcome = nil
    }

    private enum BuiltPlanResult {
        case applied
        case deferredOnUnreadableDestination
    }

    private mutating func applyBuiltPlan(
        _ built: BuiltPlan,
        id: BuildID,
        owned: (session: SourceSession, context: BuildContext),
        into effects: inout [Effect]
    ) -> BuiltPlanResult {
        let source = id.source
        let runID = owned.context.runID
        let destination = owned.context.destination
        let snapshot = built.snapshot
        let build = built.build
        let plan = build.plan
        guard destinationBySource[source] == destination else {
            // The destination changed while this build ran. The build is still the
            // session's current one — nothing else will end `.building` — so it must hand
            // the phase back and request a plan for the new destination.
            OtosLog.catalog.notice("op=import.coordinator phase=staleCompletion reason=destinationChangedMidBuild source=\(source.rawValue, privacy: .public)")
            sessions[source]?.requestPlan()
            sessions[source]?.phase = .inventory
            effects.append(.publish)
            return .applied
        }
        // Revalidate per role, matching `applyPlanningChange`: the source's namespace
        // *and* naming, the destination's namespace only.
        guard built.sourceRevisions?.namespaceRevision == snapshot.sourceNamespaceRevision,
              built.sourceRevisions?.namingRevision == snapshot.sourceNamingRevision,
              built.destinationNamespaceRevision == snapshot.destinationNamespaceRevision
        else {
            OtosLog.catalog.noticeOperation("import.plan", phase: "stale", fields: ["rootPath": source.rawValue, "sourceNamespace": "\(built.sourceRevisions?.namespaceRevision.description ?? "none")", "snapshotSourceNamespace": "\(snapshot.sourceNamespaceRevision)", "sourceNaming": "\(built.sourceRevisions?.namingRevision.description ?? "none")", "snapshotSourceNaming": "\(snapshot.sourceNamingRevision)", "destinationNamespace": "\(built.destinationNamespaceRevision.map(String.init) ?? "none")", "snapshotDestinationNamespace": "\(snapshot.destinationNamespaceRevision)", "run": runID])
            sessions[source]?.requestPlan()
            sessions[source]?.phase = .inventory
            effects.append(.publish)
            return .applied
        }
        if !build.namespace.unreadableFolders.isEmpty {
            deferBuildOnUnreadableDestination(
                source: source,
                attachment: id.attachment,
                folders: build.namespace.unreadableFolders,
                runID: runID,
                into: &effects
            )
            return .deferredOnUnreadableDestination
        }
        let newClaims = Self.planClaims(from: plan, capabilities: snapshot.destinationCapabilities)
        let currentLedger = ledgerClaims(for: destination, excluding: source)
        if !newClaims.isDisjoint(with: currentLedger) {
            OtosLog.catalog.noticeOperation("import.plan", phase: "conflict", fields: ["rootPath": source.rawValue, "destination": destination.rawValue, "newClaims": "\(newClaims.count)", "conflictingClaims": "\(newClaims.intersection(currentLedger).count)", "run": runID])
            sessions[source]?.requestPlan()
            sessions[source]?.phase = .inventory
            effects.append(.publish)
            return .applied
        }
        let readyCtx = ReadyContext(
            plan: plan,
            destination: destination,
            runID: runID,
            skippedPackageCount: built.skippedPackageCount,
            claims: newClaims,
            attentionItems: plan.attentionItems,
            builtFromSettledSource: owned.context.sourceSettledAtTakeUp
        )
        sessions[source]?.phase = .ready(readyCtx)
        sessions[source]?.lastReadyContext = readyCtx
        if sessions[source]?.unreadableRetry != nil {
            effects.append(.cancelUnreadableRetry(source: source))
        }
        sessions[source]?.unreadableRetry = nil
        // `planRequested` is left as found: taking this build up covered what it saw, so
        // a request now is a fact this plan never saw.
        guard readyCtx.builtFromSettledSource else {
            // Built mid-read, it is never offered. A source that settled while it ran has
            // already had its settling refresh, so its successor is asked for here.
            if libraries.first(where: { $0.path == source }).map({ ImportSourceReadiness.evaluate($0) == .ready }) == true {
                OtosLog.catalog.noticeOperation("import.plan", phase: "rebuildAfterSourceSettled", fields: [
                    "rootPath": source.rawValue,
                    "run": runID,
                ])
                sessions[source]?.requestPlan()
                takeUpBuild(source, into: &effects)
            }
            effects.append(.publish)
            return .applied
        }
        if sessions[source]?.attachToReadyMs == nil, let startedAt = sessions[source]?.attachStartedAt {
            let elapsed = startedAt.duration(to: ContinuousClock().now)
            let readyMs = DiagnosticsTiming.milliseconds(elapsed)
            sessions[source]?.attachToReadyMs = readyMs
            OtosLog.catalog.notice("op=import.attachToReady phase=ready run=\(runID, privacy: .public) rootPath=\(source.rawValue, privacy: .public) elapsedMs=\(readyMs, privacy: .public) copyCount=\(plan.totals.copyCount, privacy: .public)")
        }
        effects.append(.publish)
        if sessions[source]?.importRequested == true {
            beginExecutionIfPossible(source: source, readyContext: readyCtx, into: &effects)
        }
        return .applied
    }

    /// A destination folder that exists but could not be listed is not a fact about the
    /// namespace; it is a missing observation, and a plan built on it would block every
    /// candidate in that folder as "couldn't check" — which the bar drew as `0 new items ·
    /// Import 0 Items` over 368 items that were already in the library (2026-09-13, a
    /// OneDrive folder mid-sync). So the build is deferred: the phase returns to
    /// `.inventory`, the last proven plan keeps presenting (ARC-047), and a bounded
    /// backoff re-plans. Past the last delay the condition is presented as a planning
    /// failure — the destination is not available to plan against — which `Try Again` and
    /// any planning wake clear by rebuilding.
    private mutating func deferBuildOnUnreadableDestination(
        source: LibraryRootPath,
        attachment: AttachmentGeneration,
        folders: [String: String],
        runID: String,
        into effects: inout [Effect]
    ) {
        guard var session = sessions[source] else { return }
        session.phase = .inventory
        // A planning wake may have rebuilt before the pending retry fired; that retry is
        // superseded by this deferral's own.
        let previousAttempt = session.unreadableRetry?.attempt
        if previousAttempt != nil {
            effects.append(.cancelUnreadableRetry(source: source))
        }
        let attempt = (previousAttempt ?? 0) + 1
        let detail = folders.map { "\($0.key.isEmpty ? "." : $0.key)=\($0.value)" }.sorted().joined(separator: ",")
        guard attempt <= unreadableRetryDelays.count else {
            session.unreadableRetry = nil
            session.phase = .planningFailed(reason: .destinationUnavailable)
            OtosLog.catalog.noticeOperation("import.plan", phase: "unreadableExhausted", fields: [
                "rootPath": source.rawValue,
                "run": runID,
                "attempts": "\(attempt - 1)",
                "folders": detail,
            ])
            sessions[source] = session
            effects.append(.publish)
            return
        }
        let delay = unreadableRetryDelays[attempt - 1]
        // The deferred plan is still owed; the retry takes it up.
        session.requestPlan()
        session.unreadableRetry = UnreadableRetry(attempt: attempt)
        effects.append(.scheduleUnreadableRetry(source: source, attachment: attachment, delay: delay))
        OtosLog.catalog.noticeOperation("import.plan", phase: "deferred", fields: [
            "rootPath": source.rawValue,
            "run": runID,
            "reason": "destinationUnreadable",
            "attempt": "\(attempt)",
            "delayMs": "\(DiagnosticsTiming.milliseconds(delay))",
            "folders": detail,
        ])
        sessions[source] = session
        effects.append(.publish)
    }

    /// The backoff's wake: rebuilds only if the same attachment is still parked on the
    /// deferral — a newer attachment, a build a planning wake already started, or an
    /// execution in flight all mean the retry is moot.
    private mutating func fireUnreadableRetry(
        source: LibraryRootPath,
        attachment: AttachmentGeneration,
        into effects: inout [Effect]
    ) {
        guard let session = sessions[source],
              session.attachmentGeneration == attachment,
              session.unreadableRetry != nil,
              case .inventory = session.phase
        else {
            return
        }
        sessions[source]?.requestPlan()
        takeUpBuild(source, into: &effects)
    }

    private func ledgerClaims(
        for destination: LibraryRootPath,
        excluding excludedSource: LibraryRootPath? = nil
    ) -> Set<FilesystemNameKey> {
        var result: Set<FilesystemNameKey> = []
        for (source, session) in sessions where source != excludedSource {
            switch session.phase {
            case let .ready(ctx) where ctx.destination == destination: result.formUnion(ctx.claims)
            case let .executing(ctx) where ctx.destination == destination: result.formUnion(ctx.claims)
            default: break
            }
        }
        return result
    }

    private static func planClaims(
        from plan: MediaOperationPlan,
        capabilities: VolumeNamespaceCapabilities
    ) -> Set<FilesystemNameKey> {
        var claims: Set<FilesystemNameKey> = []
        for entry in plan.entries {
            guard case let .copy(destination) = entry.disposition else { continue }
            claims.insert(FilesystemNamespaceSemantics.nameKey(
                relativePath: destination,
                capabilities: capabilities
            ))
            for dest in entry.companionDestinations.values {
                claims.insert(FilesystemNamespaceSemantics.nameKey(relativePath: dest, capabilities: capabilities))
            }
        }
        return claims
    }

    // MARK: Executions

    private func isExecutableSource(_ sourceState: CatalogLibraryState) -> Bool {
        switch sourceState.root.kind {
        case .removableVolume: true
        case .deviceMTP: canExecuteCameraImport
        case .library: false
        }
    }

    /// Starts the queued run if the plan is current and the source is ready, judged
    /// against the libraries of the last refresh. A source that is not ready keeps
    /// `importRequested` set; the refresh that sees it idle retries this same request.
    private mutating func beginExecutionIfPossible(
        source: LibraryRootPath,
        readyContext: ReadyContext,
        into effects: inout [Effect]
    ) {
        guard let session = sessions[source] else { return }
        guard case let .ready(ctx) = session.phase, ctx.plan.generation == readyContext.plan.generation else {
            // Plan changed; need rebuild.
            sessions[source]?.requestPlan()
            takeUpBuild(source, into: &effects)
            return
        }
        guard let sourceState = libraries.first(where: { $0.path == source }) else { return }
        guard ImportSourceReadiness.evaluate(sourceState) == .ready else {
            OtosLog.catalog.notice("op=import.execute phase=deferred reason=sourceNotReady rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        guard ctx.builtFromSettledSource else {
            OtosLog.catalog.notice("op=import.execute phase=deferred reason=planBuiltDuringSourceRead rootPath=\(source.rawValue, privacy: .public)")
            return
        }
        guard isExecutableSource(sourceState) else {
            sessions[source]?.phase = .executionUnavailable(
                summary: ctx.plan.totals,
                generation: ctx.plan.generation,
                attentionItems: ctx.attentionItems
            )
            effects.append(.publish)
            return
        }
        // Zero-copy without delete: stay ready.
        if ctx.plan.totals.copyCount == 0, ctx.plan.totals.companionCopyCount == 0 {
            guard session.preferences.deleteSourceAfterImport else {
                // Remain ready, clear import request so it doesn't auto-requeue.
                sessions[source]?.importRequested = false
                effects.append(.publish)
                return
            }
        }
        runExecution(source: source, sourceState: sourceState, readyContext: ctx, into: &effects)
    }

    private mutating func runExecution(
        source: LibraryRootPath,
        sourceState: CatalogLibraryState,
        readyContext: ReadyContext,
        into effects: inout [Effect]
    ) {
        guard var session = sessions[source], case .ready = session.phase else { return }
        let runID = readyContext.runID
        OtosLog.catalog.noticeOperation(
            "import.activity",
            phase: "started",
            fields: ["rootPath": source.rawValue, "run": runID]
        )
        let plan = readyContext.plan
        let prefs = session.preferences
        // Minted here, not read off `plan.mode` (a throwaway id re-minted on every re-plan
        // — trap #6) and not left to the executor to mint deep inside `execute()`: the
        // machine is the one place that must know it before execution starts, carried on
        // the phase while executing and on the recorded outcome afterward
        // (`import-bar.md` "Where the user is standing").
        let batch = ImportBatchID()
        session.phase = .executing(ExecutionContext(
            plan: plan,
            destination: readyContext.destination,
            claims: readyContext.claims,
            sourceKind: sourceState.root.kind,
            sourceRoot: sourceState.root,
            skippedPackageCount: readyContext.skippedPackageCount,
            prefs: prefs,
            batch: batch,
            runID: runID,
            attachment: session.attachmentGeneration,
            interruption: nil,
            progress: MediaOperationProgress(
                completedCount: 0,
                totalCount: plan.totals.copyCount,
                completedBytes: 0,
                totalBytes: plan.totals.copyBytes,
                elapsedMs: 0
            ),
            batchHasPublishedAsset: false
        ))
        session.importRequested = false
        // A new attempt supersedes the last one's failure; its own outcome will be
        // recorded when it settles.
        session.lastFailure = nil
        sessions[source] = session
        effects.append(.publish)
        effects.append(.startExecution(ExecutionRequest(
            source: source,
            batch: batch,
            plan: plan,
            sourceKind: sourceState.root.kind,
            sourceDeviceIdentity: sourceState.root.deviceIdentity,
            deleteSourceRequested: prefs.deleteSourceAfterImport,
            runID: runID
        )))
    }

    /// Rejects a sample that would move either counter backwards. `ByteProgressTracker` is
    /// monotonic by construction, so a decrease is a sample that arrived out of order.
    /// Dropping it loses nothing: samples are cumulative, and the terminal value comes
    /// from `executionFinished` rather than from any sample.
    private mutating func applyExecutionProgress(
        batch: ImportBatchID,
        progress: MediaOperationProgress,
        into effects: inout [Effect]
    ) {
        guard let source = source(executing: batch),
              case var .executing(context)? = sessions[source]?.phase,
              !progress.isStale(comparedTo: context.progress)
        else {
            return
        }
        // Kept on the phase so any later `publish` — including one fired for an unrelated
        // reason mid-execution — re-derives this same live value.
        context.progress = progress
        sessions[source]?.phase = .executing(context)
        effects.append(.publish)
    }

    private mutating func finishExecution(
        _ batch: ImportBatchID,
        _ result: MediaImportExecutionResult,
        into effects: inout [Effect]
    ) {
        if let source = source(executing: batch), case let .executing(context)? = sessions[source]?.phase {
            applyExecutionResult(result, source: source, context: context, into: &effects)
            return
        }
        guard let drained = draining.removeValue(forKey: batch) else {
            OtosLog.catalog.notice(
                "op=import.coordinator phase=staleCompletion reason=executionOwnershipLost batchID=\(String(describing: batch), privacy: .public)"
            )
            return
        }
        settleDetachedExecution(result, draining: drained)
    }

    /// Settles an execution whose card went away while it ran. The executor lifetime ends
    /// here and the outcome is logged; there is no card row left to draw it on.
    private func settleDetachedExecution(_ result: MediaImportExecutionResult, draining: DrainingRun) {
        let context = draining.context
        let publishedCount = switch result {
        case let .completed(tally, _, _), let .stopped(_, tally): tally.publishedCount
        case let .failed(_, publishedCount): publishedCount
        }
        let outcome = if context.interruption == .sourceRemoved {
            "sourceRemoved"
        } else {
            switch result {
            case .completed: "completed"
            case .stopped: "stopped"
            case .failed: "failed"
            }
        }
        logDetachedSettlement(
            source: context.sourceRoot.path,
            batch: context.batch,
            outcome: outcome,
            publishedCount: publishedCount
        )
    }

    /// Records a run's outcome beside the session and releases what the run held. The
    /// phase returns to `.inventory`: a phase says what the session is doing now, and the
    /// re-plan that follows replaces it, while the outcome is a fact that re-plan has no
    /// business rewriting (`import-bar.md` states F and G). The plan the run executed
    /// from is dropped in every case — its landed entries are skips now — so the bar shows
    /// the outcome, not that plan, until the re-plan lands (DES-030; on 2026-09-13 the held
    /// pre-run plan drew `Ready · Import 368 Items` for 360 ms between two Done frames).
    private mutating func applyExecutionResult(
        _ result: MediaImportExecutionResult,
        source: LibraryRootPath,
        context: ExecutionContext,
        into effects: inout [Effect]
    ) {
        guard var session = sessions[source] else { return }
        let totals = context.plan.totals
        session.phase = .inventory
        session.lastReadyContext = nil
        session.settledOutcome = nil
        switch result {
        case let .completed(tally, incompleteItems, erase):
            let eraseFailed = (erase?.failedCount ?? 0) > 0
            // Stricter than the auto-eject gate below on purpose: a foreign skip doesn't
            // block physically ejecting the card, but it does keep the bar from
            // auto-dismissing (`import-bar.md` "What the presentation must carry").
            session.lastCompletion = AttachmentCompletion(
                batch: totals.copyCount + totals.companionCopyCount > 0 ? context.batch : nil,
                publishedCount: tally.publishedCount,
                isFullyClean: !tally.hasBlockedEntries && !tally.hasEntryFailures
                    && tally.skippedForeignCount == 0 && totals.blockedCount == 0 && !eraseFailed,
                incompleteItems: incompleteItems,
                eraseOutcome: erase,
                stopReason: nil,
                plannedCount: totals.copyCount,
                destination: context.destination
            )
            session.settledOutcome = SettledOutcome(
                summary: totals,
                skippedForeignCount: tally.skippedForeignCount,
                failedCount: tally.failedCount,
                incompleteItems: incompleteItems,
                eraseOutcome: erase
            )
            if context.prefs.autoEjectAfterImport, !tally.hasBlockedEntries, !tally.hasEntryFailures,
               totals.blockedCount == 0, !eraseFailed
            {
                effects.append(.autoEject(context.sourceRoot))
            }
        case let .stopped(reason, tally):
            // A stopped run is never fully clean (J8), so it never auto-ejects; the bar
            // draws state F's Stopped variant from this completion — what landed, of what
            // was planned, and why it stopped — and offers the re-plan's remainder.
            session.lastCompletion = AttachmentCompletion(
                batch: context.batch,
                publishedCount: tally.publishedCount,
                isFullyClean: false,
                incompleteItems: [],
                eraseOutcome: nil,
                stopReason: reason,
                plannedCount: totals.copyCount,
                destination: context.destination
            )
        case let .failed(reason, publishedCount):
            // State G, "never auto-dismisses": the failure stands until the next attempt
            // or `Try Again`.
            session.lastFailure = AttachmentFailure(
                reason: reason,
                publishedCount: publishedCount,
                batch: context.batch,
                destination: context.destination
            )
        }
        sessions[source] = session
        effects.append(.publish)
        OtosLog.catalog.noticeOperation(
            "import.activity",
            phase: "finished",
            fields: ["rootPath": source.rawValue, "run": context.runID]
        )
        // A run holds its destination while it executes; settlement is when a change held
        // during the run applies, so resolve it before the re-plan below.
        reconcileDestination(for: source, fixedAvailable: fixedAvailableLibraries, into: &effects)
        // Terminal settlement releases this source's claims with its phase, so re-plan it
        // against the namespace the run just changed.
        sessions[source]?.requestPlan()
        takeUpBuild(source, into: &effects)
        flushRebuilds(released: context.destination, by: source, into: &effects)
    }

    /// Flushes the rebuilds other sources owe against the library a run just released,
    /// once no other run still holds it. The released library is the run's own, not the
    /// source's destination now: a change held during the run has just been applied.
    private mutating func flushRebuilds(
        released destination: LibraryRootPath,
        by source: LibraryRootPath,
        into effects: inout [Effect]
    ) {
        let stillExecuting = sessions.values.contains { session in
            if case let .executing(context) = session.phase {
                return context.destination == destination
            }
            return false
        }
        guard !stillExecuting else { return }
        for otherSource in Array(sessions.keys)
            where otherSource != source && destinationBySource[otherSource] == destination
        {
            guard takeUpBuild(otherSource, into: &effects) else { continue }
            OtosLog.catalog.notice("op=import.coordinator phase=flushRebuild source=\(otherSource.rawValue, privacy: .public) destination=\(destination.rawValue, privacy: .public)")
        }
    }
}
