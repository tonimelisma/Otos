import Foundation
@testable import Otos

/// Controlled builder for Stage 3 (plan 0079). It records each request, can
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
    // swiftlint:disable:next line_length
    private var pending: [LibraryRootPath: (snapshot: ImportPlanningSnapshot, reserved: Set<MediaRelativePath>, continuation: CheckedContinuation<ImportPlanBuildResult, Never>)] = [:]
    private var suspendNext: Set<LibraryRootPath> = []
    private(set) var cancelled: Set<LibraryRootPath> = []

    /// Mark the next build for `source` as suspended. The next `build` call
    /// whose snapshot's sourceRoot matches this path will await a continuation
    /// until `resume(for:)` is called.
    func suspendNextBuild(for source: LibraryRootPath) {
        suspendNext.insert(source)
    }

    /// Resume a suspended build for `source` with a real live result. The
    /// result is computed via `LiveImportPlanBuilder` from the stored snapshot
    /// and reserved set, preserving the live planner's semantics.
    func resumePendingBuild(for source: LibraryRootPath) async {
        guard let entry = pending.removeValue(forKey: source) else {
            return
        }
        let result = await LiveImportPlanBuilder().build(snapshot: entry.snapshot, additionalReserved: entry.reserved)
        entry.continuation.resume(returning: result)
    }

    /// Resume all pending builds with their live results.
    func resumeAllPending() async {
        let keys = Array(pending.keys)
        for key in keys {
            await resumePendingBuild(for: key)
        }
    }

    func recordedRequests() -> [RecordedRequest] {
        recorded
    }

    func pendingSources() -> [LibraryRootPath] {
        Array(pending.keys)
    }

    func recordedCancelled() -> Set<LibraryRootPath> {
        cancelled
    }

    private func recordCancel(for source: LibraryRootPath) {
        cancelled.insert(source)
    }
}

// MARK: - ImportPlanBuilding conformance via nonisolated wrapper

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
        if suspendNext.contains(source) {
            suspendNext.remove(source)
            return await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { (continuation: CheckedContinuation<ImportPlanBuildResult, Never>) in
                        pending[source] = (snapshot, additionalReserved, continuation)
                    }
                },
                onCancel: {
                    Task { await self.recordCancel(for: source) }
                }
            )
        } else {
            return await LiveImportPlanBuilder().build(snapshot: snapshot, additionalReserved: additionalReserved)
        }
    }
}
