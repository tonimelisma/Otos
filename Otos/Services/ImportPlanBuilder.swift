import Foundation
import OSLog

/// The product of one plan build: the immutable plan plus the namespace that
/// produced it and the timing split that makes I/O vs CPU cost diagnosable.
nonisolated struct ImportPlanBuildResult: Sendable {
    let plan: MediaOperationPlan
    let namespace: DestinationNamespace
    let enumerateMs: Int
    let planMs: Int
}

/// The real substitution boundary between lifecycle ownership and expensive plan
/// construction. The coordinator owns lifecycle; the builder
/// owns enumeration and pure planning. The live builder runs off the coordinator
/// actor; the controlled test builder suspends on a continuation.
///
/// This is a real boundary because plan construction is already an independently
/// owned asynchronous operation — not a test-only branch.
nonisolated protocol ImportPlanBuilding: Sendable {
    func build(
        snapshot: ImportPlanningSnapshot,
        additionalReserved: Set<MediaRelativePath>
    ) async -> ImportPlanBuildResult
}

/// The production builder: enumerates the destination namespace once and invokes
/// the pure planner. The coordinator owns the complete operation context and
/// emits the `op=import.plan` diagnostics; the builder emits the
/// `op=plan.namespace.enumerate` split so I/O cost remains attributable without
/// needing a side experiment.
nonisolated struct LiveImportPlanBuilder: ImportPlanBuilding {
    func build(
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
}
