import Foundation
@testable import OtosKit

/// Controlled plan builder. It records each request, can
/// suspend a selected source build on a continuation, resumes it with a real
/// planner result, and records cancellation without assuming cancellation ends
/// the continuation.
///
/// The `build` method is actor-isolated, so concurrent coordinator builds for
/// different sources suspend independently. Cancellation is observed via
/// `withTaskCancellationHandler` and recorded, but the continuation remains
/// suspended until the test explicitly resumes it — reproducing the
/// cancellation-insensitive filesystem boundary needed for Stage 4.
actor ControlledImportPlanBuilder {
    struct RecordedRequest: Sendable {
        let snapshot: ImportPlanningSnapshot
        let additionalReserved: Set<MediaRelativePath>
    }

    private var recorded: [RecordedRequest] = []
    private var pending: [LibraryRootPath: [(
        snapshot: ImportPlanningSnapshot,
        reserved: Set<MediaRelativePath>,
        continuation: CheckedContinuation<ImportPlanBuildResult, Never>
    )]] = [:]
    private var suspendNext: [LibraryRootPath: Int] = [:]
    private(set) var cancelled: Set<LibraryRootPath> = []

    /// Mark the next build for `source` as suspended. The next `build` call
    /// whose snapshot's sourceRoot matches this path will await a continuation
    /// until `resume(for:)` is called.
    func suspendNextBuild(for source: LibraryRootPath) {
        suspendNext[source, default: 0] += 1
    }

    /// Resume a suspended build for `source` with a real live result. The
    /// result is computed via `LiveImportPlanBuilder` from the stored snapshot
    /// and reserved set, preserving the live planner's semantics.
    func resumePendingBuild(for source: LibraryRootPath) async {
        guard var queue = pending[source], !queue.isEmpty else {
            return
        }
        let entry = queue.removeFirst()
        if queue.isEmpty {
            pending.removeValue(forKey: source)
        } else {
            pending[source] = queue
        }
        let result = await LiveImportPlanBuilder().build(snapshot: entry.snapshot, additionalReserved: entry.reserved)
        entry.continuation.resume(returning: result)
    }

    /// Resume all pending builds with their live results.
    func resumeAllPending() async {
        let keys = Array(pending.keys)
        for key in keys {
            while let queued = pending[key], !queued.isEmpty {
                await resumePendingBuild(for: key)
            }
        }
    }

    func recordedRequests() -> [RecordedRequest] {
        recorded
    }

    func pendingSources() -> [LibraryRootPath] {
        Array(pending.keys)
    }

    func pendingCount(for source: LibraryRootPath) -> Int {
        pending[source]?.count ?? 0
    }

    func recordedCancelled() -> Set<LibraryRootPath> {
        cancelled
    }

    private func recordCancel(for source: LibraryRootPath) {
        cancelled.insert(source)
    }

    /// Resume the oldest pending build for `source` with a dummy empty result so that
    /// a cancelled `withTaskCancellationHandler` does not leave the task hanging
    /// forever. The dummy will be discarded as stale by the coordinator's
    /// post-build identity checks (attachment/generation/session), so it is safe.
    private func resumeOnePendingWithCancellationDummy(for source: LibraryRootPath) {
        guard var queue = pending[source], !queue.isEmpty else { return }
        let entry = queue.removeFirst()
        if queue.isEmpty {
            pending.removeValue(forKey: source)
        } else {
            pending[source] = queue
        }
        let dummyPlan = MediaOperationPlan(
            generation: entry.snapshot.generation,
            mode: .import(
                source: entry.snapshot.sourceRoot,
                destination: entry.snapshot.destinationRoot,
                batch: ImportBatchID()
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

// MARK: - ImportPlanBuilding conformance via nonisolated wrapper

func waitForPendingBuilder(
    _ builder: ControlledImportPlanBuilder,
    source: LibraryRootPath
) async throws {
    try await waitUntil(every: .milliseconds(10)) { await builder.pendingSources().contains(source) }
}

func waitForPendingBuilderCount(
    _ builder: ControlledImportPlanBuilder,
    source: LibraryRootPath,
    count: Int
) async throws {
    try await waitUntil(every: .milliseconds(10)) { await builder.pendingCount(for: source) >= count }
}

func waitForRecordedCancellation(
    _ builder: ControlledImportPlanBuilder,
    source: LibraryRootPath
) async throws {
    try await waitUntil(every: .milliseconds(10)) { await builder.recordedCancelled().contains(source) }
}

/// Cancellation has two effects: the source is recorded, and the suspended
/// continuation is released with a dummy so it cannot leak. Gating on the
/// first alone leaves the second racing with the assertion that reads it.
func waitForCancellationSettled(
    _ builder: ControlledImportPlanBuilder,
    source: LibraryRootPath
) async throws {
    try await waitUntil(every: .milliseconds(10)) {
        let cancelled = await builder.recordedCancelled().contains(source)
        let pending = await builder.pendingSources().contains(source)
        return cancelled && !pending
    }
}

extension ControlledImportPlanBuilder: ImportPlanBuilding {
    nonisolated func build(
        snapshot: ImportPlanningSnapshot,
        additionalReserved: Set<MediaRelativePath>
    ) async -> ImportPlanBuildResult {
        await _build(snapshot: snapshot, additionalReserved: additionalReserved)
    }

    private func _build(
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
            return await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { (continuation: CheckedContinuation<ImportPlanBuildResult, Never>) in
                        var queue = pending[source] ?? []
                        queue.append((snapshot, additionalReserved, continuation))
                        pending[source] = queue
                    }
                },
                onCancel: {
                    Task {
                        await self.recordCancel(for: source)
                        await self.resumeOnePendingWithCancellationDummy(for: source)
                    }
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
