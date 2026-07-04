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

    var diagnosticNames: [String] {
        var names: [String] = []
        appendName("mustScanSubDirs", for: kFSEventStreamEventFlagMustScanSubDirs, to: &names)
        appendName("kernelDropped", for: kFSEventStreamEventFlagKernelDropped, to: &names)
        appendName("userDropped", for: kFSEventStreamEventFlagUserDropped, to: &names)
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
