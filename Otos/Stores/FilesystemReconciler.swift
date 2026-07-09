import Foundation

/// Filesystem reconciler guide
///
/// Pure classifier for a debounced FSEvents batch under one library root.
/// `CatalogStore` owns debounce tasks, batch accumulation, and effectful
/// execution (targeted upsert/delete, enqueue scan, defer-until-scan). This
/// type only answers: given the current root facts and the batch, what should
/// the Store do next?
///
/// Not a second actor — confined to Store isolation like `RootRegistry`.
nonisolated enum FilesystemReconcileDecision: Equatable {
    case drop(reason: String)
    case noop
    case deferUntilScanCompletes(eventCount: Int)
    case rescanRoot(eventCount: Int)
    case targeted(events: [FilesystemEvent])
}

nonisolated enum FilesystemReconciler {
    /// Classifies a drained event batch for one root. Callers pass Store-owned
    /// facts (`rootExists`, armed/available, active scan) so this stays pure.
    static func decide(
        events: [FilesystemEvent],
        rootExists: Bool,
        isArmed: Bool,
        isAvailable: Bool,
        hasActiveScanForRoot: Bool
    ) -> FilesystemReconcileDecision {
        guard rootExists else {
            return .drop(reason: "removed")
        }
        guard isArmed else {
            return .drop(reason: "unarmed")
        }
        guard isAvailable else {
            return .drop(reason: "unavailable")
        }

        if hasActiveScanForRoot {
            return .deferUntilScanCompletes(eventCount: events.count)
        }

        guard !events.isEmpty else {
            return .noop
        }

        if events.contains(where: { FilesystemEventFlags(event: $0).requiresFullRootScan }) {
            return .rescanRoot(eventCount: events.count)
        }

        return .targeted(events: events)
    }
}
