import CoreServices
import Foundation

/// Classifies macOS FSEvents into the narrowest safely known reconciliation scope.
/// Unknown, dropped, root-change, and unmappable coverage escalate to `.root`.
/// A trustworthy descendant directory or `MustScanSubDirs` becomes `.subtree`.
/// Supported regular-file membership/content shapes become `.file`.
nonisolated struct FilesystemEventFlags: Equatable {
    let rawValue: UInt32

    init(event: FilesystemEvent) {
        rawValue = event.flags
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var requiresFullRootScan: Bool {
        scopeKind == .root
    }

    /// Coarse kind used before path mapping. Prefer `classifiedScope(relativePath:isRootPath:)`
    /// when the event path relationship to the library root is known.
    var scopeKind: FilesystemDirtyScopeKind {
        if rawValue == 0 {
            return .root
        }
        if contains(kFSEventStreamEventFlagKernelDropped)
            || contains(kFSEventStreamEventFlagUserDropped)
            || contains(kFSEventStreamEventFlagRootChanged)
        {
            return .root
        }
        if contains(kFSEventStreamEventFlagItemIsSymlink) {
            return .root
        }
        if contains(kFSEventStreamEventFlagMustScanSubDirs) {
            return .subtree
        }
        if contains(kFSEventStreamEventFlagItemIsDir) {
            return .subtree
        }
        guard contains(kFSEventStreamEventFlagItemIsFile) else {
            return .root
        }
        if contains(kFSEventStreamEventFlagItemRemoved) {
            return .file
        }
        if contains(kFSEventStreamEventFlagItemCreated)
            || contains(kFSEventStreamEventFlagItemModified)
            || contains(kFSEventStreamEventFlagItemInodeMetaMod)
            || contains(kFSEventStreamEventFlagItemRenamed)
            || contains(kFSEventStreamEventFlagItemXattrMod)
            || contains(kFSEventStreamEventFlagItemChangeOwner)
            || contains(kFSEventStreamEventFlagItemFinderInfoMod)
        {
            return .file
        }
        return .root
    }

    /// Maps an event under `root` into a typed dirty scope.
    /// - Parameters:
    ///   - relativePath: path relative to the library root, or `nil` when the event
    ///     names the root itself / cannot be mapped.
    ///   - isRootPath: true when the absolute event path equals the library root.
    func classifiedScope(
        relativePath: MediaRelativePath?,
        isRootPath: Bool
    ) -> FilesystemDirtyScope {
        switch scopeKind {
        case .root:
            return .root
        case .subtree:
            if isRootPath || relativePath == nil {
                return .root
            }
            return .subtree(relativePath!)
        case .file:
            guard let relativePath, !isRootPath else {
                return .root
            }
            return .file(relativePath)
        }
    }

    var singleFileAction: SingleFileReconcileOperation? {
        guard scopeKind == .file else {
            return nil
        }
        if contains(kFSEventStreamEventFlagItemRemoved) {
            return .deleteIfMissing
        }
        return .upsert
    }

    /// Proven OneDrive hydration-shaped events from the 2026-07-11 capture:
    /// regular-file metadata/content flags with no membership or coverage bits.
    var isKnownMaterializationSuppressibleShape: Bool {
        guard contains(kFSEventStreamEventFlagItemIsFile) else {
            return false
        }
        if contains(kFSEventStreamEventFlagItemCreated)
            || contains(kFSEventStreamEventFlagItemRemoved)
            || contains(kFSEventStreamEventFlagItemRenamed)
            || contains(kFSEventStreamEventFlagItemIsDir)
            || contains(kFSEventStreamEventFlagItemIsSymlink)
            || contains(kFSEventStreamEventFlagMustScanSubDirs)
            || contains(kFSEventStreamEventFlagKernelDropped)
            || contains(kFSEventStreamEventFlagUserDropped)
            || contains(kFSEventStreamEventFlagRootChanged)
            || rawValue == 0
        {
            return false
        }
        return contains(kFSEventStreamEventFlagItemInodeMetaMod)
            || contains(kFSEventStreamEventFlagItemModified)
            || contains(kFSEventStreamEventFlagItemXattrMod)
            || contains(kFSEventStreamEventFlagItemChangeOwner)
            || contains(kFSEventStreamEventFlagItemFinderInfoMod)
    }

    var diagnosticNames: [String] {
        var names: [String] = []
        appendName("mustScanSubDirs", for: kFSEventStreamEventFlagMustScanSubDirs, to: &names)
        appendName("kernelDropped", for: kFSEventStreamEventFlagKernelDropped, to: &names)
        appendName("userDropped", for: kFSEventStreamEventFlagUserDropped, to: &names)
        appendName("rootChanged", for: kFSEventStreamEventFlagRootChanged, to: &names)
        appendName("itemCreated", for: kFSEventStreamEventFlagItemCreated, to: &names)
        appendName("itemRemoved", for: kFSEventStreamEventFlagItemRemoved, to: &names)
        appendName("itemInodeMetaMod", for: kFSEventStreamEventFlagItemInodeMetaMod, to: &names)
        appendName("itemRenamed", for: kFSEventStreamEventFlagItemRenamed, to: &names)
        appendName("itemModified", for: kFSEventStreamEventFlagItemModified, to: &names)
        appendName("itemFinderInfoMod", for: kFSEventStreamEventFlagItemFinderInfoMod, to: &names)
        appendName("itemChangeOwner", for: kFSEventStreamEventFlagItemChangeOwner, to: &names)
        appendName("itemXattrMod", for: kFSEventStreamEventFlagItemXattrMod, to: &names)
        appendName("itemIsFile", for: kFSEventStreamEventFlagItemIsFile, to: &names)
        appendName("itemIsDir", for: kFSEventStreamEventFlagItemIsDir, to: &names)
        appendName("itemIsSymlink", for: kFSEventStreamEventFlagItemIsSymlink, to: &names)
        if names.isEmpty {
            names.append(rawValue == 0 ? "none" : "unknown")
        }
        return names
    }

    var diagnosticDescription: String {
        diagnosticNames.joined(separator: ",")
    }

    private func contains(_ flag: Int) -> Bool {
        rawValue & UInt32(flag) != 0
    }

    private func appendName(_ name: String, for flag: Int, to names: inout [String]) {
        if contains(flag) {
            names.append(name)
        }
    }
}

nonisolated enum FilesystemDirtyScopeKind: Equatable {
    case file
    case subtree
    case root
}

nonisolated enum SingleFileReconcileOperation: Equatable {
    case upsert
    case deleteIfMissing

    var diagnosticDescription: String {
        switch self {
        case .upsert:
            "upsert"
        case .deleteIfMissing:
            "deleteIfMissing"
        }
    }
}
