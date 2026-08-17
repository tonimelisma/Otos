import CoreServices
import Foundation
@testable import OtosKit
import Testing

struct FilesystemEventFlagsTests {
    @Test func unknownFlagsRequireFullRootScan() {
        let flags = FilesystemEventFlags(rawValue: 0)
        #expect(flags.requiresFullRootScan)
        #expect(flags.singleFileAction == nil)
        #expect(flags.scopeKind == .root)
    }

    @Test func regularFileCreateTargetsSingleFileUpsert() {
        let flags = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        )
        #expect(!flags.requiresFullRootScan)
        #expect(flags.singleFileAction == .upsert)
        #expect(flags.scopeKind == .file)
    }

    @Test func regularFileRemoveTargetsDeleteIfMissing() {
        let flags = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        )
        #expect(!flags.requiresFullRootScan)
        #expect(flags.singleFileAction == .deleteIfMissing)
    }

    @Test func directoryEventsBecomeSubtreeUnlessRootPath() {
        let flags = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        )
        #expect(flags.scopeKind == .subtree)
        #expect(
            flags.classifiedScope(
                relativePath: MediaRelativePath(rawValue: "2026/03"),
                isRootPath: false
            ) == .subtree(MediaRelativePath(rawValue: "2026/03"))
        )
        #expect(flags.classifiedScope(relativePath: nil, isRootPath: true) == .root)
    }

    @Test func mustScanSubDirsBecomesSubtree() {
        let flags = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir)
        )
        #expect(flags.scopeKind == .subtree)
    }

    @Test func droppedAndRootChangedRequireRoot() {
        #expect(
            FilesystemEventFlags(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped)).scopeKind == .root
        )
        #expect(
            FilesystemEventFlags(rawValue: UInt32(kFSEventStreamEventFlagRootChanged)).scopeKind == .root
        )
    }

    @Test func directoryRenameEscalatesToRoot() {
        let flags = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)
        )
        #expect(flags.scopeKind == .root)
        #expect(
            flags.classifiedScope(
                relativePath: MediaRelativePath(rawValue: "old"),
                isRootPath: false
            ) == .root
        )
    }

    @Test func knownMaterializationShapeIsSuppressible() {
        let flags = FilesystemEventFlags(rawValue: 0x1D400)
        #expect(flags.isKnownMaterializationSuppressibleShape)
        let create = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        )
        #expect(!create.isKnownMaterializationSuppressibleShape)
    }
}
