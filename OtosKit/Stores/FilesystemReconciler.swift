import Foundation

/// Filesystem reconciler guide
///
/// Pure classifier for a debounced FSEvents batch under one library root.
/// `CatalogStore` owns debounce tasks, the per-root dirty-scope accumulator, and
/// effectful execution (file/subtree/root reconciliation). This type only answers:
/// given the current root facts and the batch, which typed dirty scopes should
/// enter the accumulator?
///
/// Active-scan state does not discard event granularity. Safe file and subtree
/// events still classify; Store retains them in the next dirty generation until
/// the root lease is free.
///
/// Not a second actor — confined to Store isolation like `RootRegistry`.
nonisolated enum FilesystemReconcileDecision: Equatable {
    case drop(reason: String)
    case noop
    /// Typed dirty scopes to merge into the Store-owned accumulator for this root.
    case accumulate(scopes: [ClassifiedFilesystemDirt])
}

nonisolated struct ClassifiedFilesystemDirt: Equatable {
    let scope: FilesystemDirtyScope
    let fileAction: SingleFileReconcileOperation?
    let eventCount: Int
    /// Why a `.root` scope is one (`FilesystemEventFlags.rootReason`).
    let rootReason: ScanReason

    init(
        scope: FilesystemDirtyScope,
        fileAction: SingleFileReconcileOperation? = nil,
        eventCount: Int = 1,
        rootReason: ScanReason = .events
    ) {
        self.scope = scope
        self.fileAction = fileAction
        self.eventCount = eventCount
        self.rootReason = rootReason
    }
}

nonisolated enum FilesystemReconciler {
    /// Classifies a drained event batch for one root. Callers pass Store-owned
    /// facts (`rootExists`, armed/available) so this stays pure. Active-scan
    /// ownership is not a drop/defer signal — scopes still accumulate.
    static func decide(
        events: [FilesystemEvent],
        root: LibraryRootPath,
        rootExists: Bool,
        isArmed: Bool,
        isAvailable: Bool
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
        guard !events.isEmpty else {
            return .noop
        }

        var dirt: [ClassifiedFilesystemDirt] = []
        dirt.reserveCapacity(events.count)
        for event in events {
            dirt.append(classify(event: event, root: root))
        }
        return .accumulate(scopes: dirt)
    }

    static func classify(event: FilesystemEvent, root: LibraryRootPath) -> ClassifiedFilesystemDirt {
        let flags = FilesystemEventFlags(event: event)
        let isRootPath = event.path == root.rawValue
        let relativePath: MediaRelativePath? = if isRootPath {
            nil
        } else {
            CatalogPath.relativePath(rootPath: root, absolutePath: event.path)
        }
        let scope = flags.classifiedScope(relativePath: relativePath, isRootPath: isRootPath)
        let action: SingleFileReconcileOperation? = if case .file = scope {
            flags.singleFileAction
        } else {
            nil
        }
        return ClassifiedFilesystemDirt(scope: scope, fileAction: action, eventCount: 1, rootReason: flags.rootReason)
    }
}
