import Foundation
@testable import OtosKit
import Testing

/// `ImportSessionMachine` is a synchronous state machine: every interleaving the
/// coordinator's old `await`s allowed is here a sequence of `handle(_:)` calls, with no
/// store, no files and no waiting. A competing event "at an await" is the event sent
/// between the effect that starts the work and the event that reports its result.
struct ImportSessionMachineTests {
    typealias Machine = ImportSessionMachine

    // MARK: Fixtures

    private static let card = LibraryRootPath(rawValue: "/Volumes/CARD")
    private static let libraryA = LibraryRootPath(rawValue: "/Users/example/A")
    private static let libraryB = LibraryRootPath(rawValue: "/Users/example/B")

    private static func library(_ path: LibraryRootPath) -> CatalogLibraryState {
        CatalogLibraryState(root: LibraryRoot(path: path), availability: .available, activity: .idle)
    }

    private static func cardState(
        attachment: UInt64 = 1,
        activity: CatalogLibraryActivity = .idle
    ) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(path: card, kind: .removableVolume, deviceIdentity: .volume(uuid: "card")),
            availability: .available,
            activity: activity,
            attachmentGeneration: attachment
        )
    }

    private static func snapshot(
        _ libraries: [CatalogLibraryState],
        revisions: RootPlanningRevisions? = RootPlanningRevisions(namespaceRevision: 1, namingRevision: 0),
        reason: String = "test"
    ) -> Machine.SourcesSnapshot {
        Machine.SourcesSnapshot(
            reason: reason,
            libraries: libraries,
            revisions: revisions.map { [card: $0] } ?? [:],
            defaultPreferences: .default
        )
    }

    private static func machine(canExecuteCameraImport: Bool = false) -> Machine {
        Machine(
            destinationBySource: [:],
            unreadableRetryDelays: [.seconds(1), .seconds(4)],
            canExecuteCameraImport: canExecuteCameraImport
        )
    }

    private static func builds(in effects: [Machine.Effect]) -> [Machine.BuildRequest] {
        effects.compactMap { effect in
            if case let .startBuild(request) = effect {
                request
            } else {
                nil
            }
        }
    }

    private static func executions(in effects: [Machine.Effect]) -> [Machine.ExecutionRequest] {
        effects.compactMap { effect in
            if case let .startExecution(request) = effect {
                request
            } else {
                nil
            }
        }
    }

    private static func mediaFile(_ name: String = "IMG_1.JPG") -> PlanningFileFacts {
        let relative = MediaRelativePath(rawValue: name)
        return PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: card, relativePath: relative),
            sourceURL: card.url.appending(path: name),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            captureWallCompact: 20_250_101_120_000,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
    }

    private static func builtPlan(
        for request: Machine.BuildRequest,
        sourceRevisions: RootPlanningRevisions? = RootPlanningRevisions(namespaceRevision: 1, namingRevision: 0),
        unreadableFolders: [String: String] = [:]
    ) -> Machine.BuildOutcome {
        let snapshot = ImportPlanningSnapshot(
            generation: request.id.generation.rawValue,
            sourceRoot: request.id.source,
            destinationRoot: request.destination,
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            sourceMedia: [mediaFile()],
            destinationOccupants: [:],
            policy: request.policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
        // Every folder the plan can touch was read, so absence is a proven fact and the
        // file is copyable.
        let namespace = DestinationNamespace(
            entries: [:],
            enumeratedFolders: Set(MediaTransferPlanner.destinationFolders(for: snapshot)).union([""]),
            unreadableFolders: unreadableFolders
        )
        let plan = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: namespace)
        return .built(Machine.BuiltPlan(
            snapshot: snapshot,
            build: ImportPlanBuildResult(plan: plan, namespace: namespace, enumerateMs: 0, planMs: 0),
            sourceRevisions: sourceRevisions,
            destinationNamespaceRevision: 1,
            skippedPackageCount: 0
        ))
    }

    /// A machine with the card attached to library A and its first build running.
    private static func attachedWithBuildRunning(
        libraries: [CatalogLibraryState] = [library(libraryA), cardState()]
    ) -> (machine: Machine, build: Machine.BuildRequest) {
        var machine = machine()
        let effects = machine.handle(.librariesRefreshed(snapshot(libraries)))
        let started = builds(in: effects)
        #expect(started.count == 1)
        return (machine, started[0])
    }

    /// A machine whose card has an import running.
    private static func executing() throws -> (machine: Machine, run: Machine.ExecutionRequest) {
        var (machine, build) = attachedWithBuildRunning()
        _ = machine.handle(.importQueued(source: card))
        let effects = machine.handle(.buildFinished(build.id, builtPlan(for: build)))
        let run = try #require(executions(in: effects).first)
        return (machine, run)
    }

    /// The running import's phase payload.
    private static func execution(in machine: Machine) -> Machine.ExecutionContext? {
        if case let .executing(context) = machine.sessions[card]?.phase {
            return context
        }
        return nil
    }

    private static let progress = MediaOperationProgress(
        completedCount: 1,
        totalCount: 2,
        completedBytes: 5,
        totalBytes: 10,
        elapsedMs: 3
    )

    // MARK: Builds

    @Test func aRevisionMovedDuringABuildRequestsAnotherPlan() {
        var (machine, build) = Self.attachedWithBuildRunning()

        // The namespace moves while the build is reading.
        let wake = machine.handle(.planningChanged(RootPlanningChange(
            rootPath: Self.card,
            namespaceRevision: 2,
            namingRevision: 0
        )))
        #expect(Self.builds(in: wake).isEmpty)

        // The build finishes having sampled the new revision against its old snapshot.
        let effects = machine.handle(.buildFinished(
            build.id,
            Self.builtPlan(for: build, sourceRevisions: RootPlanningRevisions(namespaceRevision: 2, namingRevision: 0))
        ))

        #expect(Self.builds(in: effects).count == 1)
        #expect(Self.builds(in: effects).first?.id.generation.rawValue == build.id.generation.rawValue + 1)
    }

    @Test func aRequestMadeDuringABuildSurvivesABuildThatFinishesConsistently() {
        var (machine, build) = Self.attachedWithBuildRunning()

        // A scan batch lands mid-build and the build's own revision sample happens to match.
        _ = machine.handle(.planningChanged(RootPlanningChange(
            rootPath: Self.card,
            namespaceRevision: 2,
            namingRevision: 0
        )))
        let effects = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))

        #expect(Self.builds(in: effects).count == 1)
        #expect(machine.sessions[Self.card]?.lastReadyContext != nil)
    }

    @Test func aPreferenceChangeDuringABuildRequestsAnotherPlan() {
        var (machine, build) = Self.attachedWithBuildRunning()
        var changed = ImportPreferences.default
        changed.importSidecarFiles.toggle()

        _ = machine.handle(.sessionPreferencesChanged(changed, source: Self.card))
        let effects = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))

        let next = Self.builds(in: effects)
        #expect(next.count == 1)
        #expect(next.first?.policy.importSidecarFiles == changed.importSidecarFiles)
    }

    @Test func aDestinationPickedDuringABuildDiscardsItsResult() {
        var (machine, build) = Self.attachedWithBuildRunning(
            libraries: [Self.library(Self.libraryA), Self.library(Self.libraryB), Self.cardState()]
        )

        _ = machine.handle(.destinationPicked(Self.libraryB, source: Self.card))
        let effects = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))

        let next = Self.builds(in: effects)
        #expect(next.count == 1)
        #expect(next.first?.destination == Self.libraryB)
        #expect(machine.sessions[Self.card]?.lastReadyContext == nil)
    }

    /// ARC-047: a default destination that follows a reorder is a destination change like
    /// a pick: the plan proven against the old library is not held under the new one.
    @Test func aReorderThatMovesTheDestinationDropsThePlanMeasuredAgainstTheOldLibrary() {
        var (machine, build) = Self.attachedWithBuildRunning(
            libraries: [Self.library(Self.libraryA), Self.library(Self.libraryB), Self.cardState()]
        )
        _ = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))
        #expect(machine.sessions[Self.card]?.lastReadyContext?.destination == Self.libraryA)

        let effects = machine.handle(.librariesRefreshed(Self.snapshot(
            [Self.library(Self.libraryB), Self.library(Self.libraryA), Self.cardState()]
        )))

        #expect(machine.destination(of: Self.card) == Self.libraryB)
        #expect(machine.sessions[Self.card]?.lastReadyContext == nil)
        #expect(Self.builds(in: effects).first?.destination == Self.libraryB)
    }

    /// A run releases the library it copied into, even when a reorder held during the run
    /// moves its own source elsewhere at settlement: another source still pointed at that
    /// library rebuilds then.
    @Test func settlementFlushesRebuildsForTheLibraryTheRunReleased() throws {
        let otherCard = LibraryRootPath(rawValue: "/Volumes/OTHER")
        let otherCardState = CatalogLibraryState(
            root: LibraryRoot(path: otherCard, kind: .removableVolume, deviceIdentity: .volume(uuid: "other")),
            availability: .available,
            activity: .idle,
            attachmentGeneration: 2
        )
        var (machine, run) = try Self.executing()
        let attached = machine.handle(.librariesRefreshed(Self.snapshot(
            [Self.library(Self.libraryA), Self.library(Self.libraryB), Self.cardState(), otherCardState]
        )))
        let otherBuild = try #require(Self.builds(in: attached).first { $0.id.source == otherCard })
        _ = machine.handle(.buildFinished(otherBuild.id, .failed("unrelated")))
        _ = machine.handle(.destinationPicked(Self.libraryA, source: otherCard))
        // Library A's namespace moves while the card's run holds it: the other card, idle
        // now, owes a rebuild against A, and it is held back.
        _ = machine.handle(.planningChanged(RootPlanningChange(
            rootPath: Self.libraryA,
            namespaceRevision: 9,
            namingRevision: 0
        )))
        // The libraries reorder while the run holds A; the card's default follows to B at
        // settlement.
        _ = machine.handle(.librariesRefreshed(Self.snapshot(
            [Self.library(Self.libraryB), Self.library(Self.libraryA), Self.cardState(), otherCardState]
        )))

        #expect(machine.sessions[otherCard]?.needsPlan == true)

        let effects = machine.handle(.executionFinished(
            run.batch,
            .completed(.nothingAttempted, incompleteItems: [], erase: nil)
        ))

        #expect(machine.destination(of: Self.card) == Self.libraryB)
        #expect(Self.builds(in: effects).contains { $0.id.source == otherCard && $0.destination == Self.libraryA })
    }

    @Test func aStaleBuildResultIsDropped() {
        var (machine, build) = Self.attachedWithBuildRunning()
        let staleGeneration = Machine.BuildID(
            source: build.id.source,
            attachment: build.id.attachment,
            generation: Machine.BuildGeneration(rawValue: build.id.generation.rawValue + 7)
        )
        let otherAttachment = Machine.BuildID(
            source: build.id.source,
            attachment: MediaOperationAttachmentGeneration(rawValue: build.id.attachment.rawValue + 1),
            generation: build.id.generation
        )

        #expect(machine.handle(.buildFinished(staleGeneration, Self.builtPlan(for: build))).isEmpty)
        #expect(machine.handle(.buildFinished(otherAttachment, Self.builtPlan(for: build))).isEmpty)

        // The real build is still the session's, and still applies.
        let effects = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))
        #expect(machine.sessions[Self.card]?.lastReadyContext != nil)
        #expect(effects.contains {
            if case .publish = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func aFailedBuildStatesThePlanningFailureAndStillTakesUpWhatWasRequested() {
        var (machine, build) = Self.attachedWithBuildRunning()

        _ = machine.handle(.retryRequested(source: Self.card))
        let effects = machine.handle(.buildFinished(build.id, .failed("boom")))

        #expect(Self.builds(in: effects).count == 1)
    }

    @Test func namingSettledDuringABuildRequestsAnotherPlan() {
        var (machine, build) = Self.attachedWithBuildRunning()

        let effects = machine.handle(.buildFinished(
            build.id,
            .namingPending(Machine.NamingPending(
                settled: 1,
                total: 2,
                filesWithNoDateAtAll: 0,
                liveNamingSettled: true
            ))
        ))

        #expect(Self.builds(in: effects).count == 1)
    }

    @Test func pendingNamingParksTheSessionUntilACatalogChange() {
        var (machine, build) = Self.attachedWithBuildRunning()

        let parked = machine.handle(.buildFinished(
            build.id,
            .namingPending(Machine.NamingPending(
                settled: 1,
                total: 2,
                filesWithNoDateAtAll: 0,
                liveNamingSettled: false
            ))
        ))
        #expect(Self.builds(in: parked).isEmpty)
        guard case .waitingForMetadata(1, 2)? = machine.sessions[Self.card]?.phase else {
            Issue.record("expected the session to wait for metadata")
            return
        }

        let woken = machine.handle(.catalogChanged)
        #expect(Self.builds(in: woken).count == 1)
    }

    @Test func aCatalogChangeDuringABuildIsNotLostWhileTheSessionIsBuilding() {
        var (machine, build) = Self.attachedWithBuildRunning()

        // Not waiting for metadata: the change requests nothing and starts nothing.
        #expect(Self.builds(in: machine.handle(.catalogChanged)).isEmpty)
        #expect(machine.sessions[Self.card]?.needsPlan == false)
        _ = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))
    }

    @Test func anUnreadableDestinationDefersTheBuildToItsRetry() {
        var (machine, build) = Self.attachedWithBuildRunning()

        let deferred = machine.handle(.buildFinished(
            build.id,
            Self.builtPlan(for: build, unreadableFolders: ["2025-01": "EIO"])
        ))

        #expect(Self.builds(in: deferred).isEmpty)
        #expect(machine.sessions[Self.card]?.needsPlan == true)
        #expect(deferred.contains {
            if case .scheduleUnreadableRetry = $0 {
                true
            } else {
                false
            }
        })

        let attachment = build.id.attachment
        let retried = machine.handle(.unreadableRetryFired(source: Self.card, attachment: attachment))
        #expect(Self.builds(in: retried).count == 1)
    }

    @Test func anExhaustedRetryBudgetBecomesAPlanningFailure() {
        var (machine, build) = Self.attachedWithBuildRunning()
        var current = build
        for _ in 0 ..< 2 {
            _ = machine.handle(.buildFinished(
                current.id,
                Self.builtPlan(for: current, unreadableFolders: ["x": "EIO"])
            ))
            let retried = machine.handle(.unreadableRetryFired(source: Self.card, attachment: current.id.attachment))
            current = Self.builds(in: retried)[0]
        }

        _ = machine.handle(.buildFinished(current.id, Self.builtPlan(for: current, unreadableFolders: ["x": "EIO"])))

        guard case .planningFailed(.destinationUnavailable)? = machine.sessions[Self.card]?.phase else {
            Issue.record("expected destinationUnavailable after the retry budget")
            return
        }
    }

    // MARK: Executions

    @Test func queueingDuringABuildStartsExecutionWhenItIsReady() {
        var (machine, build) = Self.attachedWithBuildRunning()

        let queued = machine.handle(.importQueued(source: Self.card))
        #expect(Self.executions(in: queued).isEmpty)
        #expect(machine.sessions[Self.card]?.importRequested == true)

        let effects = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))
        let runs = Self.executions(in: effects)
        #expect(runs.count == 1)
        #expect(runs.first?.source == Self.card)
        #expect(machine.sessions[Self.card]?.importRequested == false)
    }

    /// ADR 0024, field trace 2026-11-06: a plan built while the card was still being
    /// scanned offered "Erase 68 items" from rows the card no longer held. Such a plan is
    /// never run, and the card settling asks for the plan that is — even when the scan
    /// moved no revision of its own.
    @Test func aPlanBuiltWhileTheCardIsReadIsNeverRunAndTheCardSettlingRebuildsIt() throws {
        let scanning = [Self.library(Self.libraryA), Self.cardState(activity: .scanning)]
        let idle = [Self.library(Self.libraryA), Self.cardState()]
        var (machine, build) = Self.attachedWithBuildRunning(libraries: scanning)
        // Import pressed mid-build asks for another plan; the card is still being read.
        _ = machine.handle(.importQueued(source: Self.card))
        let first = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))
        #expect(Self.executions(in: first).isEmpty)
        let midReadSuccessor = try #require(Self.builds(in: first).first)

        let settled = machine.handle(.librariesRefreshed(Self.snapshot(idle)))
        #expect(Self.executions(in: settled).isEmpty)

        // The successor began mid-read too, so it is not run either: it asks for the
        // plan that saw the card settled, and that one runs.
        let second = machine.handle(.buildFinished(midReadSuccessor.id, Self.builtPlan(for: midReadSuccessor)))
        #expect(Self.executions(in: second).isEmpty)
        let settledBuild = try #require(Self.builds(in: second).first)
        let third = machine.handle(.buildFinished(settledBuild.id, Self.builtPlan(for: settledBuild)))
        #expect(Self.executions(in: third).count == 1)
    }

    /// A plan built mid-read and still held when the card settles is rebuilt by the
    /// settling refresh itself, even though the scan moved no revision.
    @Test func aHeldMidReadPlanIsRebuiltWhenTheCardSettles() {
        var (machine, build) = Self.attachedWithBuildRunning(
            libraries: [Self.library(Self.libraryA), Self.cardState(activity: .scanning)]
        )
        let finished = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))
        #expect(Self.builds(in: finished).isEmpty)

        let settled = machine.handle(.librariesRefreshed(Self.snapshot([Self.library(Self.libraryA), Self.cardState()])))

        #expect(Self.builds(in: settled).count == 1)
    }

    /// The card can settle while the build that began mid-read is still running; that
    /// build's result then asks for its successor itself.
    @Test func aPlanBuiltMidReadThatLandsAfterTheCardSettledRequestsItsSuccessor() {
        var (machine, build) = Self.attachedWithBuildRunning(
            libraries: [Self.library(Self.libraryA), Self.cardState(activity: .scanning)]
        )
        let settled = machine.handle(.librariesRefreshed(Self.snapshot([Self.library(Self.libraryA), Self.cardState()])))
        #expect(Self.builds(in: settled).isEmpty)

        let finished = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))

        #expect(Self.builds(in: finished).count == 1)
        #expect(machine.sessions[Self.card]?.attachToReadyMs == nil)
    }

    @Test func queueingAnExecutingSourceIsRejected() throws {
        var (machine, _) = try Self.executing()

        let effects = machine.handle(.importQueued(source: Self.card))

        #expect(effects.isEmpty)
    }

    @Test func detachDuringExecutionDrainsTheRunAndIgnoresItsProgress() throws {
        var (machine, run) = try Self.executing()

        let detached = machine.handle(.librariesRefreshed(Self.snapshot([Self.library(Self.libraryA)])))
        #expect(machine.sessions[Self.card] == nil)
        #expect(detached.contains {
            if case let .cancelExecution(batch, alsoCancelTask) = $0 {
                batch == run.batch && alsoCancelTask
            } else {
                false
            }
        })

        #expect(machine.handle(.executionProgress(run.batch, Self.progress)).isEmpty)
        // The drained run settles the old batch without touching any session.
        let settled = machine.handle(.executionFinished(
            run.batch,
            .failed(.sourceRemoved, publishedCount: 3)
        ))
        #expect(settled.isEmpty)
        #expect(machine.sessions.isEmpty)
    }

    @Test func progressAfterFinishIsIgnored() throws {
        var (machine, run) = try Self.executing()

        _ = machine.handle(.executionFinished(
            run.batch,
            .completed(.tally(published: 1), incompleteItems: [], erase: nil)
        ))
        let late = machine.handle(.executionProgress(run.batch, Self.progress))

        #expect(late.isEmpty)
    }

    @Test func aStaleProgressSampleNeverMovesACounterBackwards() throws {
        var (machine, run) = try Self.executing()

        _ = machine.handle(.executionProgress(run.batch, Self.progress))
        let older = MediaOperationProgress(
            completedCount: 0,
            totalCount: 2,
            completedBytes: 1,
            totalBytes: 10,
            elapsedMs: 1
        )

        #expect(machine.handle(.executionProgress(run.batch, older)).isEmpty)
        #expect(Self.execution(in: machine)?.progress == Self.progress)
    }

    @Test func aFailedRunStatesTheCountItsExecutorReports() throws {
        var (machine, run) = try Self.executing()

        _ = machine.handle(.executionFinished(
            run.batch,
            .failed(.unexpected(detail: "boom"), publishedCount: 4)
        ))

        let failure = machine.sessions[Self.card]?.lastFailure
        #expect(failure?.reason == .unexpected(detail: "boom"))
        #expect(failure?.publishedCount == 4)
    }

    @Test func settlementRequestsARePlanAgainstTheNamespaceTheRunChanged() throws {
        var (machine, run) = try Self.executing()

        let effects = machine.handle(.executionFinished(
            run.batch,
            .completed(.tally(published: 1), incompleteItems: [], erase: nil)
        ))

        #expect(Self.builds(in: effects).count == 1)
        #expect(machine.sessions[Self.card]?.lastCompletion?.publishedCount == 1)
    }

    @Test func aReorderDuringARunAppliesAtSettlement() throws {
        var (machine, run) = try Self.executing()

        // The libraries reorder while the run holds library A.
        _ = machine.handle(.librariesRefreshed(Self.snapshot(
            [Self.library(Self.libraryB), Self.library(Self.libraryA), Self.cardState()]
        )))
        #expect(machine.destination(of: Self.card) == Self.libraryA)

        let effects = machine.handle(.executionFinished(
            run.batch,
            .completed(.tally(published: 1), incompleteItems: [], erase: nil)
        ))

        #expect(machine.destination(of: Self.card) == Self.libraryB)
        #expect(Self.builds(in: effects).first?.destination == Self.libraryB)
    }

    @Test func anExecutionNotYetProvenNonEmptyConfirmsOnlyOnAPositiveCount() throws {
        var (machine, run) = try Self.executing()

        #expect(machine.handle(.batchAssetCountRead(run.batch, count: nil)).isEmpty)
        #expect(machine.handle(.batchAssetCountRead(run.batch, count: 0)).isEmpty)
        #expect(Self.execution(in: machine)?.batchHasPublishedAsset == false)

        let confirmed = machine.handle(.batchAssetCountRead(run.batch, count: 2))
        #expect(Self.execution(in: machine)?.batchHasPublishedAsset == true)
        #expect(confirmed.contains {
            if case .publish = $0 {
                true
            } else {
                false
            }
        })
    }

    // MARK: Refreshes

    @Test func aSnapshotOlderThanAnAppliedPlanningChangeRequestsNothing() {
        var (machine, build) = Self.attachedWithBuildRunning()
        _ = machine.handle(.buildFinished(build.id, Self.builtPlan(for: build)))
        _ = machine.handle(.planningChanged(RootPlanningChange(
            rootPath: Self.card,
            namespaceRevision: 2,
            namingRevision: 0
        )))

        // A refresh that read revisions before that change must not look like new work.
        let effects = machine.handle(.librariesRefreshed(Self.snapshot([Self.library(Self.libraryA), Self.cardState()])))

        #expect(Self.builds(in: effects).isEmpty)
    }

    @Test func aReattachedCardGetsAFreshSessionAndCancelsTheOldBuild() {
        var (machine, build) = Self.attachedWithBuildRunning()

        let effects = machine.handle(.librariesRefreshed(Self.snapshot(
            [Self.library(Self.libraryA), Self.cardState(attachment: 2)]
        )))

        #expect(effects.contains {
            if case let .cancelBuild(id) = $0 {
                id == build.id
            } else {
                false
            }
        })
        #expect(Self.builds(in: effects).count == 1)
        // The old build's result no longer owns anything.
        #expect(machine.handle(.buildFinished(build.id, Self.builtPlan(for: build))).isEmpty)
    }

    @Test func shutdownDropsEverythingAndRefusesLateResults() {
        var (machine, build) = Self.attachedWithBuildRunning()

        _ = machine.handle(.shutdown)

        #expect(machine.sessions.isEmpty)
        #expect(machine.handle(.buildFinished(build.id, Self.builtPlan(for: build))).isEmpty)
        #expect(machine.handle(.librariesRefreshed(Self.snapshot([Self.cardState()]))).isEmpty)

        // Once shutdown completes, the card attaches as it did the first time: one
        // session, planning one build into the library.
        _ = machine.handle(.shutdownCompleted)
        let reattached = machine.handle(.librariesRefreshed(Self.snapshot([Self.library(Self.libraryA), Self.cardState()])))
        #expect(Array(machine.sessions.keys) == [Self.card])
        let rebuilds = Self.builds(in: reattached)
        #expect(rebuilds.map(\.id.source) == [Self.card])
        #expect(rebuilds.map(\.destination) == [Self.libraryA])
    }

    @Test func aCardWithNoDestinationLibrarySettlesWithoutABuild() {
        var machine = Self.machine()

        let effects = machine.handle(.librariesRefreshed(Self.snapshot([Self.cardState()])))

        #expect(Self.builds(in: effects).isEmpty)
        guard case .planningFailed? = machine.sessions[Self.card]?.phase else {
            Issue.record("expected the no-destination planning failure")
            return
        }
    }

    @Test func destinationMappingsPersistWhenTheMachineChoosesOrIsToldADestination() {
        var machine = Self.machine()
        let attached = machine.handle(.librariesRefreshed(Self.snapshot([Self.library(Self.libraryA), Self.cardState()])))
        #expect(attached.contains {
            if case .persistDestinations = $0 {
                true
            } else {
                false
            }
        })
        #expect(machine.destinationBySource[Self.card] == Self.libraryA)

        let picked = machine.handle(.destinationPicked(Self.libraryB, source: Self.card))
        #expect(picked.contains {
            if case .persistDestinations = $0 {
                true
            } else {
                false
            }
        })
        #expect(machine.destinationBySource[Self.card] == Self.libraryB)
    }
}
