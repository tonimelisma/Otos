import Foundation
@testable import OtosKit

/// A plan builder a test steers. It records every request, holds a build the test marked
/// with `suspendNextBuild(for:)` until the test releases it with a live planner result,
/// and resolves a held build its caller cancels with an empty plan, recording the
/// cancellation.
///
/// A release waits for the build it releases. The coordinator's build reaches the
/// builder only after its own Store reads, so a test that releases right after some
/// other fact (another source turning Ready) can run before that build arrives; a
/// release that found nothing held and returned would be lost, and the build would
/// then hold forever.
///
/// Builds for different sources are held independently; each held build carries its own
/// identity, so a release or a cancellation resolves exactly one build.
actor ControlledImportPlanBuilder {
    struct RecordedRequest: Sendable {
        let snapshot: ImportPlanningSnapshot
        let additionalReserved: Set<MediaRelativePath>
    }

    /// One build held on its continuation. `id` names it, so a cancellation resolves
    /// the build it belongs to, never another build held for the same source.
    private struct HeldBuild {
        let id: UInt64
        let snapshot: ImportPlanningSnapshot
        let reserved: Set<MediaRelativePath>
        let continuation: CheckedContinuation<ImportPlanBuildResult, Never>
    }

    private var recorded: [RecordedRequest] = []
    /// Held builds per source, oldest first.
    private var pending: [LibraryRootPath: [HeldBuild]] = [:]
    private var nextHeldID: UInt64 = 0
    private var suspendNext: [LibraryRootPath: Int] = [:]
    /// Releases waiting for a build of their source to be held, woken when one is.
    private var arrivalWaiters: [LibraryRootPath: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelled: Set<LibraryRootPath> = []

    /// Holds the next build for `source` until `resumePendingBuild(for:)` releases it or
    /// its caller cancels it. Each call holds one more build.
    func suspendNextBuild(for source: LibraryRootPath) {
        suspendNext[source, default: 0] += 1
    }

    /// Resume the oldest suspended build for `source` with a real live result,
    /// waiting first for one to be held if none is yet. The result is computed via
    /// `LiveImportPlanBuilder` from the stored snapshot and reserved set, preserving
    /// the live planner's semantics.
    func resumePendingBuild(for source: LibraryRootPath) async {
        // Take again after every wake: the actor is reentrant, and a cancellation may
        // resolve the held build before this release runs.
        while true {
            if let entry = takeHeld(source: source, where: { _ in true }) {
                let result = await LiveImportPlanBuilder().build(
                    snapshot: entry.snapshot,
                    additionalReserved: entry.reserved
                )
                entry.continuation.resume(returning: result)
                return
            }
            await withCheckedContinuation { arrivalWaiters[source, default: []].append($0) }
        }
    }

    func waitingReleaseCount(for source: LibraryRootPath) -> Int {
        arrivalWaiters[source]?.count ?? 0
    }

    func recordedRequests() -> [RecordedRequest] {
        recorded
    }

    func pendingCount(for source: LibraryRootPath) -> Int {
        pending[source]?.count ?? 0
    }

    func recordedCancelled() -> Set<LibraryRootPath> {
        cancelled
    }

    /// Removes and returns the oldest held build for `source` that `matches` accepts.
    private func takeHeld(source: LibraryRootPath, where matches: (HeldBuild) -> Bool) -> HeldBuild? {
        guard var queue = pending[source], let index = queue.firstIndex(where: matches) else {
            return nil
        }
        let entry = queue.remove(at: index)
        pending[source] = queue.isEmpty ? nil : queue
        return entry
    }

    /// Records the cancellation and resolves the held build `id` with an empty plan, so a
    /// cancelled build does not hold its task forever. The coordinator discards it as stale
    /// by its post-build identity checks (attachment/generation/session). A build a release
    /// already took is gone and is left alone.
    private func cancelHeldBuild(_ id: UInt64, source: LibraryRootPath) {
        cancelled.insert(source)
        guard let entry = takeHeld(source: source, where: { $0.id == id }) else { return }
        let dummyPlan = MediaOperationPlan(
            generation: entry.snapshot.generation,
            mode: .import(
                source: entry.snapshot.sourceRoot,
                destination: entry.snapshot.destinationRoot
            ),
            sourceNamespaceRevision: entry.snapshot.sourceNamespaceRevision,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: entry.snapshot.destinationNamespaceRevision,
            policy: entry.snapshot.policy,
            entries: [],
            totals: MediaOperationPlanTotals(
                copyCount: 0,
                skipCount: 0,
                blockedCount: 0,
                companionCopyCount: 0,
                copyBytes: 0
            )
        )
        let dummy = ImportPlanBuildResult(plan: dummyPlan, namespace: .empty, enumerateMs: 0, planMs: 0)
        entry.continuation.resume(returning: dummy)
    }
}

// MARK: - Waiting for held builds

func waitForPendingBuilder(
    _ builder: ControlledImportPlanBuilder,
    source: LibraryRootPath
) async throws {
    try await waitForPendingBuilderCount(builder, source: source, count: 1)
}

func waitForPendingBuilderCount(
    _ builder: ControlledImportPlanBuilder,
    source: LibraryRootPath,
    count: Int
) async throws {
    try await waitUntil(every: .milliseconds(10)) { await builder.pendingCount(for: source) >= count }
}

// MARK: - ImportPlanBuilding

extension ControlledImportPlanBuilder: ImportPlanBuilding {
    func build(
        snapshot: ImportPlanningSnapshot,
        additionalReserved: Set<MediaRelativePath>
    ) async -> ImportPlanBuildResult {
        recorded.append(RecordedRequest(snapshot: snapshot, additionalReserved: additionalReserved))
        let source = snapshot.sourceRoot
        if let count = suspendNext[source], count > 0 {
            if count == 1 {
                suspendNext.removeValue(forKey: source)
            } else {
                suspendNext[source] = count - 1
            }
            let id = nextHeldID
            nextHeldID &+= 1
            return await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { (continuation: CheckedContinuation<ImportPlanBuildResult, Never>) in
                        pending[source, default: []].append(HeldBuild(
                            id: id,
                            snapshot: snapshot,
                            reserved: additionalReserved,
                            continuation: continuation
                        ))
                        for waiter in arrivalWaiters.removeValue(forKey: source) ?? [] {
                            waiter.resume()
                        }
                    }
                },
                onCancel: {
                    // The handler runs synchronously off the actor; the hop is the only way in.
                    Task { await self.cancelHeldBuild(id, source: source) }
                }
            )
        } else {
            return await LiveImportPlanBuilder().build(snapshot: snapshot, additionalReserved: additionalReserved)
        }
    }
}

/// Marks every media row under `root` as one enrichment has *looked at*, the
/// precondition the naming gate puts on offering a plan (ARC-057).
///
/// In production `EnrichmentCoordinator` reads every file on an attached card before
/// the bar offers Import — a removable volume's bytes are always local, so that read
/// is guaranteed to complete. These tests construct `CatalogStore` directly with no
/// enrichment coordinator, so without this their rows stay `.pending` forever and the
/// source never reaches Ready.
///
/// Each result carries the row's own size and mtime and no timestamps: the "enrichment
/// looked and found no embedded capture wall" outcome, which makes the filesystem mtime
/// a *proven* fallback rather than an assumed one.
func markEnrichmentLookedAtEveryRow(_ store: CatalogStore, root: LibraryRootPath) async {
    guard let media = await store.planningMedia(for: root), !media.isEmpty else {
        return
    }
    let results = media.map { facts in
        EnrichmentResult(
            id: facts.id,
            metadata: AssetMetadata(),
            thumbnailPath: nil,
            sourceSize: facts.byteSize ?? 0,
            sourceMTimeSeconds: facts.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) },
            contentHash: nil
        )
    }
    _ = await store.applyEnrichmentBatch(results)
}

/// Waits until the coordinator has handled every change the Store delivered to it and
/// every build it started — stale ones included — has returned, so what a change did,
/// including publishing nothing, is final.
func waitForCoordinatorQuiescence(_ coordinator: MediaOperationCoordinator) async throws {
    try await waitUntil { await coordinator.isQuiescent }
}

extension MediaImportRunTally {
    static let nothingAttempted = MediaImportRunTally.tally(published: 0)

    /// A run's tally for a test: what it published, with nothing else happening unless
    /// the test says so.
    static func tally(
        published: Int,
        blocked: Bool = false,
        entryFailures: Bool = false,
        skippedForeign: Int = 0,
        failed: Int = 0
    ) -> MediaImportRunTally {
        MediaImportRunTally(
            publishedCount: published,
            hasBlockedEntries: blocked,
            hasEntryFailures: entryFailures,
            skippedForeignCount: skippedForeign,
            failedCount: failed
        )
    }
}
