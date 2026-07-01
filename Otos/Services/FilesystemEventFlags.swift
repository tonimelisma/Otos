import CoreServices
import Foundation

/// Classifies macOS FSEvents into targeted single-file reconciliation or a full-root
/// scan fallback. Unknown, directory, symlink, dropped, and subtree-scan flags defer
/// to the existing enumeration proof path in spec 0023.
nonisolated struct FilesystemEventFlags: Equatable {
    let rawValue: UInt32

    init(event: FilesystemEvent) {
        rawValue = event.flags
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var requiresFullRootScan: Bool {
        if rawValue == 0 {
            return true
        }
        if contains(kFSEventStreamEventFlagMustScanSubDirs)
            || contains(kFSEventStreamEventFlagKernelDropped)
            || contains(kFSEventStreamEventFlagUserDropped)
        { // swiftlint:disable:this opening_brace
            return true
        }
        if contains(kFSEventStreamEventFlagItemIsDir) || contains(kFSEventStreamEventFlagItemIsSymlink) {
            return true
        }
        guard contains(kFSEventStreamEventFlagItemIsFile) else {
            return true
        }
        if contains(kFSEventStreamEventFlagItemRemoved) {
            return false
        }
        return !(contains(kFSEventStreamEventFlagItemCreated)
            || contains(kFSEventStreamEventFlagItemModified)
            || contains(kFSEventStreamEventFlagItemInodeMetaMod)
            || contains(kFSEventStreamEventFlagItemRenamed)
            || contains(kFSEventStreamEventFlagItemXattrMod))
    }

    var singleFileAction: SingleFileReconcileOperation? {
        guard !requiresFullRootScan else {
            return nil
        }
        if contains(kFSEventStreamEventFlagItemRemoved) {
            return .deleteIfMissing
        }
        return .upsert
    }

    private func contains(_ flag: Int) -> Bool {
        rawValue & UInt32(flag) != 0
    }
}

nonisolated enum SingleFileReconcileOperation: Equatable {
    case upsert
    case deleteIfMissing
}
