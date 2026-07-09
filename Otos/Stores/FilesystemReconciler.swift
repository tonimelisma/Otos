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

    /// Scalar diagnostic summary for a batch — never retains catalog state.
    static func batchFields(
        root: LibraryRootPath,
        events: [FilesystemEvent],
        mode: String,
        catalogChanged: Bool
    ) -> [String: String] {
        var actionCounts: [String: Int] = [:]
        var flagCounts: [String: Int] = [:]
        for event in events {
            let flags = FilesystemEventFlags(event: event)
            let action = if flags.requiresFullRootScan {
                "fullRoot"
            } else {
                flags.singleFileAction?.diagnosticDescription ?? "unknown"
            }
            actionCounts[action, default: 0] += 1
            for name in flags.diagnosticNames {
                flagCounts[name, default: 0] += 1
            }
        }
        let samplePaths = events.prefix(3).map(\.path).joined(separator: "|")
        return [
            "rootPath": root.rawValue,
            "mode": mode,
            "eventCount": "\(events.count)",
            "uniquePathCount": "\(Set(events.map(\.path)).count)",
            "catalogChanged": "\(catalogChanged)",
            "actions": diagnosticCounts(actionCounts),
            "flags": diagnosticCounts(flagCounts),
            "samplePaths": samplePaths,
        ]
    }

    private static func diagnosticCounts(_ counts: [String: Int]) -> String {
        counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
    }
}
