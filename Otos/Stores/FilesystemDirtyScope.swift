import Foundation

/// Typed reconciliation scopes for one library root.
///
/// FSEvents are invalidation hints. Store accumulates the narrowest safely known
/// scope per root and reconciles that scope when no lease owns the root. A
/// `.root` entry subsumes every narrower scope; a subtree subsumes descendant
/// files and subtrees. There is no fixed path-count threshold that escalates to
/// a full-root scan.
nonisolated enum FilesystemDirtyScope: Equatable, Hashable {
    case file(MediaRelativePath)
    case subtree(MediaRelativePath)
    case root
}

/// Process-local dirty-scope accumulator for one library root.
///
/// Coalesces duplicate file paths, merges file actions conservatively, absorbs
/// descendant scopes into ancestor subtrees, and clears everything on `.root`.
nonisolated struct FilesystemDirtyAccumulator: Equatable {
    private(set) var isRootDirty = false
    /// Conservative file action per relative path. Upsert wins over delete when
    /// both shapes arrive in the same generation (current filesystem state is
    /// read at settlement time).
    private(set) var files: [MediaRelativePath: SingleFileReconcileOperation] = [:]
    private(set) var subtrees: Set<MediaRelativePath> = []

    var isEmpty: Bool {
        !isRootDirty && files.isEmpty && subtrees.isEmpty
    }

    var fileCount: Int {
        files.count
    }

    var subtreeCount: Int {
        subtrees.count
    }

    mutating func insertRoot() {
        isRootDirty = true
        files.removeAll(keepingCapacity: false)
        subtrees.removeAll(keepingCapacity: false)
    }

    mutating func insertSubtree(_ path: MediaRelativePath) {
        guard !isRootDirty else {
            return
        }
        if subtrees.contains(where: { Self.isAncestorOrEqual($0, of: path) }) {
            return
        }
        subtrees = subtrees.filter { !Self.isDescendant($0, of: path) }
        files = files.filter { !Self.isPath($0.key, insideSubtree: path) }
        subtrees.insert(path)
    }

    mutating func insertFile(_ path: MediaRelativePath, action: SingleFileReconcileOperation) {
        guard !isRootDirty else {
            return
        }
        if subtrees.contains(where: { Self.isPath(path, insideSubtree: $0) }) {
            return
        }
        if let existing = files[path] {
            files[path] = Self.merge(existing, action)
        } else {
            files[path] = action
        }
    }

    mutating func insert(_ scope: FilesystemDirtyScope, fileAction: SingleFileReconcileOperation? = nil) {
        switch scope {
        case .root:
            insertRoot()
        case let .subtree(path):
            insertSubtree(path)
        case let .file(path):
            insertFile(path, action: fileAction ?? .upsert)
        }
    }

    /// Atomically takes the current dirty generation and clears the accumulator.
    mutating func take() -> FilesystemDirtyAccumulator {
        let snapshot = self
        self = FilesystemDirtyAccumulator()
        return snapshot
    }

    /// Flattened scopes for diagnostics and serial execution ordering:
    /// root first, then subtrees (sorted), then files outside those subtrees.
    var orderedScopes: [FilesystemDirtyScope] {
        if isRootDirty {
            return [.root]
        }
        var scopes: [FilesystemDirtyScope] = subtrees
            .sorted { $0.rawValue < $1.rawValue }
            .map { .subtree($0) }
        scopes.append(contentsOf: files.keys.sorted { $0.rawValue < $1.rawValue }.map { .file($0) })
        return scopes
    }

    static func isAncestorOrEqual(_ ancestor: MediaRelativePath, of path: MediaRelativePath) -> Bool {
        ancestor == path || isDescendant(path, of: ancestor)
    }

    static func isDescendant(_ path: MediaRelativePath, of ancestor: MediaRelativePath) -> Bool {
        path.rawValue.hasPrefix(ancestor.rawValue + "/")
    }

    static func isPath(_ path: MediaRelativePath, insideSubtree subtree: MediaRelativePath) -> Bool {
        isAncestorOrEqual(subtree, of: path)
    }

    static func merge(
        _ left: SingleFileReconcileOperation,
        _ right: SingleFileReconcileOperation
    ) -> SingleFileReconcileOperation {
        if left == right {
            return left
        }
        // Mixed create/modify/remove for one path: settle from current filesystem
        // state via upsert (delete-if-missing still runs when the path is gone).
        return .upsert
    }
}
