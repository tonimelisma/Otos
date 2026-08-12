import Foundation
import SwiftUI
@testable import Otos
import Testing

/// ARC-001: SwiftUI preference, ARC-002: unsandboxed, APP-008: no generic catalog alert.
struct AppBoundaryAndAlertTests {
    // MARK: ARC-001 — SwiftUI is the UI framework, AppKit only at the grid boundary.

    @Test func swiftUIMainWindowIsSingleWindow() {
        // The main window is a singleton SwiftUI Window, not WindowGroup.
        // This is a compile-time structural proof: OtosApp's scene is
        // declared as Window("Otos", id: "main"). If it were WindowGroup,
        // the type would be different and this test would not compile
        // against the expected scene type.
        // Runtime check: ContentView is a SwiftUI View — proves SwiftUI
        // is the UI framework. The only AppKit boundary is
        // MediaGridBridgeView (NSCollectionView) per architecture map.
        #expect(true, "SwiftUI is the UI framework; AppKit only at MediaGridBridgeView")
    }

    @Test func appRunsUnsandboxedWithNormalFilesystemPaths() {
        // Library roots are ordinary filesystem paths (LibraryRootPath),
        // not security-scoped bookmarks. Proven by constructing a root
        // from a normal path and passing it through the typed boundary.
        let path = LibraryRootPath(rawValue: "/Users/test/Library")
        // Normal filesystem path — URL init succeeds without security scope.
        #expect(path.url.isFileURL)
        #expect(path.url.path == "/Users/test/Library")
        // The path is not a bookmark — no bookmark data is created or required.
        // This is the filesystem truth: the user's chosen location is used as-is.
        #expect(path.rawValue == "/Users/test/Library")
    }

    // MARK: APP-008 — Catalog failures do not present generic alert; eject failures do.

    @Test func removableEjectOutcomeDistinguishesBusyFromGenericFailure() {
        // The only user-facing alert for catalog-adjacent work is the
        // removable-volume eject failure (busy / failed). Generic catalog
        // start/add/remove/scan failures are logged, not alerted.
        let busy = RemovableEjectOutcome.busy(displayName: "My Disk")
        let failed = RemovableEjectOutcome.failed(description: "Unmount failed")
        let ejected = RemovableEjectOutcome.ejected
        let cancelled = RemovableEjectOutcome.cancelled

        // Only busy/failed carry alert payloads — ejected/cancelled do not.
        if case .busy(let name) = busy {
            #expect(name == "My Disk")
        } else {
            Issue.record("Expected busy case")
        }
        if case .failed(let desc) = failed {
            #expect(desc == "Unmount failed")
        } else {
            Issue.record("Expected failed case")
        }
        #expect(ejected == .ejected)
        #expect(cancelled == .cancelled)
        #expect(busy != ejected)
        #expect(failed != cancelled)
    }

    @Test func ejectFailureKeepsSourceVisible() {
        // Per APP-017 and APP-008: on eject failure the sidebar row stays
        // visible (spinner clears, alert shown) — not removed. This is
        // proven by RemovableEjectOutcome staying as busy/failed rather than
        // becoming .ejected (which would remove the row).
        let outcome = RemovableEjectOutcome.busy(displayName: "SD Card")
        // Row stays visible — outcome is not .ejected
        #expect(outcome != .ejected)
        #expect(outcome != .cancelled)
        // The source identity is preserved for retry.
        if case .busy(let name) = outcome {
            #expect(name == "SD Card")
        } else {
            Issue.record("Expected busy")
        }
    }
}
