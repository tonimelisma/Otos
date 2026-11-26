import AppKit
@testable import OtosKit
import Testing

/// DES-093: text holds the keyboard whenever the key window's first responder is text;
/// otherwise Copy and Select All act on photos, and Copy is available whenever photos are
/// targeted, whatever the relay last recorded.
@MainActor
@Suite(.testScope)
struct KeyboardFocusTests {
    @Test func textHoldsTheKeyboardOnlyWhileTheFirstResponderIsText() {
        #expect(KeyboardFocus.of(firstResponderIsText: true) == .text)
        #expect(KeyboardFocus.of(firstResponderIsText: false) == .photos)
    }

    /// The failure on the owner's Mac (2026-11-26): a record of which window held the
    /// keyboard read "another window" while he worked in the catalog window, Copy was
    /// disabled, and ⌘C beeped. Copy is available whenever photos are targeted, and the
    /// command acts on them when no text holds the keyboard.
    @Test func copyIsAvailableWheneverPhotosAreTargetedAndCopiesThem() async throws {
        let model = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        model.startHandOff(store: model.catalogStore)
        defer { model.handOffTask?.cancel() }
        let ids = try makeLocalMediaIDs(["a.jpg", "b.jpg"])
        model.applyState(CatalogWindowState(
            title: "Copy",
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil
        ))
        #expect(!model.canCopy)

        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)
        #expect(model.canCopy)
        model.setKeyboardFocus(.text)
        #expect(model.canCopy)
        model.setKeyboardFocus(.photos)
        #expect(model.canCopy)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        model.copyCurrentTargets(to: pasteboard)
        try await waitUntil { model.hasSettledHandOffs }
        #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] == [ids[1].fileURL])
    }

    /// A Select All with no text holding the keyboard selects every photo shown.
    @Test func selectAllWithPhotosHoldingTheKeyboardSelectsEveryPhoto() throws {
        let model = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        let ids = try makeLocalMediaIDs(["a.jpg", "b.jpg", "c.jpg"])
        model.applyState(CatalogWindowState(
            title: "Select",
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil
        ))

        model.selectAllCommand(focus: .photos)

        #expect(model.orderedSelectedAssetIDs == ids)
    }
}
