import Foundation
@testable import OtosKit
import Testing

struct KnownMaterializationSuppressionTests {
    @Test func beginKeepsEntryActiveThroughMaterializationTimeoutWindow() {
        var state = KnownMaterializationSuppressionState()
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/library"),
            relativePath: MediaRelativePath(rawValue: "slow.mov")
        )
        let now = Date(timeIntervalSince1970: 1000)
        state.begin(id: id, now: now)

        let midOperation = now.addingTimeInterval(90)
        let active = state.activeExpiries(now: midOperation)
        #expect(active[id] != nil)
        #expect(
            KnownMaterializationSuppressionPolicy.isSuppressible(
                flags: FilesystemEventFlags(rawValue: 0x1D400),
                id: id,
                active: active,
                now: midOperation
            )
        )
    }

    @Test func endSuccessReplacesCeilingWithShortGrace() {
        var state = KnownMaterializationSuppressionState()
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/library"),
            relativePath: MediaRelativePath(rawValue: "done.heic")
        )
        let now = Date(timeIntervalSince1970: 1000)
        state.begin(id: id, now: now)
        let finished = now.addingTimeInterval(60)
        state.endSuccess(id: id, now: finished)

        let duringGrace = finished.addingTimeInterval(2)
        #expect(state.activeExpiries(now: duringGrace)[id] != nil)
        let afterGrace = finished.addingTimeInterval(6)
        #expect(state.activeExpiries(now: afterGrace)[id] == nil)
    }

    @Test func endFailureClearsEntryImmediately() {
        var state = KnownMaterializationSuppressionState()
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/library"),
            relativePath: MediaRelativePath(rawValue: "fail.heic")
        )
        let now = Date(timeIntervalSince1970: 1000)
        state.begin(id: id, now: now)
        state.endFailure(id: id, now: now.addingTimeInterval(1))
        #expect(state.activeExpiries(now: now.addingTimeInterval(1)).isEmpty)
    }

    @Test func activeCeilingIsAtLeastMaterializationTimeoutPlusLag() {
        #expect(KnownMaterializationSuppressionPolicy.activeCeiling >= .seconds(135))
    }
}
