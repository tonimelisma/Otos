import CoreServices
import Foundation
@testable import Otos
import Testing

struct FilesystemEventFlagsTests {
    @Test func unknownFlagsRequireFullRootScan() {
        let flags = FilesystemEventFlags(rawValue: 0)
        #expect(flags.requiresFullRootScan)
        #expect(flags.singleFileAction == nil)
    }

    @Test func regularFileCreateTargetsSingleFileUpsert() {
        let flags = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        )
        #expect(!flags.requiresFullRootScan)
        #expect(flags.singleFileAction == .upsert)
    }

    @Test func regularFileRemoveTargetsDeleteIfMissing() {
        let flags = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        )
        #expect(!flags.requiresFullRootScan)
        #expect(flags.singleFileAction == .deleteIfMissing)
    }

    @Test func directoryEventsFallBackToFullRootScan() {
        let flags = FilesystemEventFlags(
            rawValue: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        )
        #expect(flags.requiresFullRootScan)
    }
}
