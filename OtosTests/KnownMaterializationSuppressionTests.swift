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
        let now = ContinuousClock.now
        state.begin(id: id, now: now)

        let midOperation = now.advanced(by: .seconds(90))
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
        let now = ContinuousClock.now
        state.begin(id: id, now: now)
        let finished = now.advanced(by: .seconds(60))
        state.endSuccess(id: id, now: finished)

        let duringGrace = finished.advanced(by: .seconds(2))
        #expect(state.activeExpiries(now: duringGrace)[id] != nil)
        let afterGrace = finished.advanced(by: .seconds(6))
        #expect(state.activeExpiries(now: afterGrace)[id] == nil)
    }

    @Test func endFailureClearsEntryImmediately() {
        var state = KnownMaterializationSuppressionState()
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/library"),
            relativePath: MediaRelativePath(rawValue: "fail.heic")
        )
        let now = ContinuousClock.now
        state.begin(id: id, now: now)
        state.endFailure(id: id, now: now.advanced(by: .seconds(1)))
        #expect(state.activeExpiries(now: now.advanced(by: .seconds(1))).isEmpty)
    }

    @Test func activeCeilingIsAtLeastMaterializationTimeoutPlusLag() {
        #expect(KnownMaterializationSuppressionPolicy.activeCeiling >= .seconds(135))
    }
}
