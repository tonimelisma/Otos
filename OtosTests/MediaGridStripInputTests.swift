import AppKit
@testable import OtosKit
import Testing

/// APP-022: horizontal strip scroll loading,
/// focus centering (including window-attach / layout retry), key consumption,
/// and first-responder claim after mode switches.
///
/// Uses the same synchronous snapshot + gate adoption pattern as
/// `MediaGridSelectionControllerTests` so structural applies never spin
/// `RunLoop`. Focus-centering tests that host a previously unhosted controller
/// flush one short main-queue turn so the deferred `viewDidLayout` retry can
/// run (scrolling mid-layout is a silent no-op). Serialized so concurrent
/// NSWindow hosts cannot race AppKit teardown (SIGSEGV in objc_release during
/// suite runs).
@Suite(.serialized)
@MainActor
struct MediaGridStripInputTests {
    @Test func stripScrollTriggersDetailQueries() throws {
        let harness = try StripHarness(itemCount: 40, windowWidth: 320)
        harness.controller.flushScrollDrivenWorkNow()
        let before = harness.controller.lastDetailQueryIDs
        #expect(!before.isEmpty)

        harness.scrollClipHorizontally(by: 600)
        harness.controller.flushScrollDrivenWorkNow()

        let after = harness.controller.lastDetailQueryIDs
        #expect(after != before)
        #expect(!after.isEmpty)
    }

    @Test func focusTargetParksUntilItemsExist() {
        let controller = MediaGridViewController(
            presentation: .strip(tileEdge: MediaGridPresentation.defaultStripTileEdge)
        )
        _ = controller.view
        let ids = (0 ..< 40).map { makeStripAssetID(path: "focus-\($0).jpg") }
        let target = ids[25]
        controller.receiveFocusTarget(target)
        #expect(controller.pendingFocusTargetID == target)

        adoptStripGrid(controller, ids: ids)
        #expect(controller.dataSource.indexPath(for: target) != nil)
        // Pending remains until a post-layout scroll retry (production apply completion).
        #expect(controller.pendingFocusTargetID == target)
    }

    @Test func focusTargetParkedBeforeWindowScrollsOnViewDidAppear() {
        let controller = MediaGridViewController(
            presentation: .strip(tileEdge: MediaGridPresentation.defaultStripTileEdge)
        )
        _ = controller.view
        let ids = (0 ..< 40).map { makeStripAssetID(path: "appear-\($0).jpg") }
        let target = ids[25]
        adoptStripGrid(controller, ids: ids)
        controller.receiveFocusTarget(target)
        #expect(controller.pendingFocusTargetID == target)
        #expect(controller.view.window == nil)

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Swift owns this window through a strong reference, so AppKit must not
        // also release it on close — the default `true` makes `close()` an extra
        // release on top of ARC's, which is an over-release, and `objc_release`
        // crashes during suite runs are already on record for these harnesses.
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        // AppKit's window list retains an ordered-in window, so a local binding
        // going out of scope is not enough to release it.
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
        // Flush the deferred viewDidLayout focus retry (scroll mid-layout is a no-op).
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        if controller.pendingFocusTargetID != nil {
            controller.viewDidAppear()
        }

        #expect(controller.pendingFocusTargetID == nil)
        assertStripFocusCentered(controller, target: target)
    }

    @Test func focusTargetRetryOnRedeliveredSameID() {
        let controller = MediaGridViewController(
            presentation: .strip(tileEdge: MediaGridPresentation.defaultStripTileEdge)
        )
        _ = controller.view
        let ids = (0 ..< 40).map { makeStripAssetID(path: "redeliver-\($0).jpg") }
        let target = ids[25]
        adoptStripGrid(controller, ids: ids)
        controller.receiveFocusTarget(target)
        #expect(controller.pendingFocusTargetID == target)

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Swift owns this window through a strong reference, so AppKit must not
        // also release it on close — the default `true` makes `close()` an extra
        // release on top of ARC's, which is an over-release, and `objc_release`
        // crashes during suite runs are already on record for these harnesses.
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        // AppKit's window list retains an ordered-in window, so a local binding
        // going out of scope is not enough to release it.
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
        // Flush deferred layout retry so the park is cleared before redelivery,
        // or still pending if layout attributes were not ready yet.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        // Same id redelivery must retry a parked target (belt-and-braces for
        // update-pass ordering where appear has not yet run).
        controller.receiveFocusTarget(target)
        #expect(controller.pendingFocusTargetID == nil)
        assertStripFocusCentered(controller, target: target)
    }

    @Test func focusTargetUnchangedDoesNotScroll() throws {
        let harness = try StripHarness(itemCount: 40, windowWidth: 320)
        let target = harness.ids[20]
        harness.controller.receiveFocusTarget(target)
        harness.layout()

        harness.scrollClipHorizontally(by: 200)
        _ = harness.controller.mutationGate.endScrollHold()
        let boundsBefore = harness.controller.scrollView.contentView.bounds
        harness.controller.receiveFocusTarget(target)
        let boundsAfter = harness.controller.scrollView.contentView.bounds
        #expect(boundsBefore.origin == boundsAfter.origin)
    }

    @Test func stripConsumesVerticalAndExtensionKeys() throws {
        let harness = try StripHarness(itemCount: 12, windowWidth: 640)
        harness.seedSelection(harness.ids[2])
        #expect(harness.controller.selectedIdentities() == [harness.ids[2]])
        #expect(harness.modelSelection.selection == [harness.ids[2]])

        harness.sendKey(keyCode: 126) // up
        harness.sendKey(keyCode: 124, modifiers: [.shift]) // ⇧→
        harness.controller.collectionView.selectAll(nil)

        #expect(harness.controller.selectedIdentities() == [harness.ids[2]])
        #expect(harness.modelSelection.selection == [harness.ids[2]])
    }

    @Test func stripClaimsFirstResponderOnAppear() throws {
        let harness = try StripHarness(itemCount: 8, windowWidth: 640)
        harness.controller.viewDidAppear()
        #expect(harness.window.firstResponder === harness.controller.collectionView)
    }
}

// MARK: - Harness

@MainActor
private final class StripHarness {
    let controller: MediaGridViewController
    let ids: [MediaAssetID]
    let window: NSWindow
    private(set) var modelSelection = GridSelection.empty

    init(itemCount: Int, windowWidth: CGFloat) throws {
        controller = MediaGridViewController(
            presentation: .strip(tileEdge: MediaGridPresentation.defaultStripTileEdge)
        )
        _ = controller.view

        ids = (0 ..< itemCount).map { makeStripAssetID(path: "strip-\($0).jpg") }
        adoptStripGrid(controller, ids: ids)

        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: windowWidth, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Swift owns this window through a strong reference, so AppKit must not
        // also release it on close — the default `true` makes `close()` an extra
        // release on top of ARC's, which is an over-release, and `objc_release`
        // crashes during suite runs are already on record for these harnesses.
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        layout()
        _ = controller.mutationGate.endScrollHold()
    }

    /// Closes the window deterministically: `makeKeyAndOrderFront` adds it to
    /// AppKit's window list, which retains it, so letting the harness go out of
    /// scope leaks a live key window instead of releasing it. `isolated deinit`
    /// runs the close on the main actor, where NSWindow requires it.
    isolated deinit {
        window.close()
    }

    func layout() {
        controller.view.layoutSubtreeIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
    }

    func scrollClipHorizontally(by delta: CGFloat) {
        let clip = controller.scrollView.contentView
        var origin = clip.bounds.origin
        origin.x += delta
        clip.scroll(to: origin)
        controller.scrollView.reflectScrolledClipView(clip)
        layout()
        _ = controller.mutationGate.endScrollHold()
    }

    /// Places the pointer for hover recomputation; `nil` means "not over the grid".
    func placePointer(_ locationInWindow: NSPoint?) {
        controller.collectionView.pointerLocationInWindow = { locationInWindow }
    }

    /// Places the pointer over an item's centre and drives the real recompute, so
    /// tests establish hover through the same path production uses rather than
    /// poking the controller callback (which would leave the collection view's own
    /// hovered-item state unset, and the next clear deduplicated away).
    func hoverItem(_ item: Int) {
        guard let attributes = controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: item, section: 0))
        else {
            return
        }
        placePointer(controller.collectionView.convert(
            NSPoint(x: attributes.frame.midX, y: attributes.frame.midY),
            to: nil
        ))
        controller.collectionView.refreshHover()
    }

    func hoveredItemIndexes() -> [Int] {
        controller.collectionView.visibleItems()
            .compactMap { $0 as? MediaGridItem }
            .filter(\.isChoiceControlVisible)
            .compactMap { controller.collectionView.indexPath(for: $0)?.item }
            .sorted()
    }

    func tilesShowingChoiceControl() -> Int {
        controller.collectionView.visibleItems()
            .compactMap { $0 as? MediaGridItem }
            .filter(\.isChoiceControlVisible)
            .count
    }

    func seedSelection(_ id: MediaAssetID) {
        modelSelection = GridSelection.empty.plainClick(id)
        controller.selectionHandlers = MediaGridSelectionHandlers(
            currentSelection: { [unowned self] in modelSelection },
            applyClick: { [unowned self] hit, modifiers, orderedIDs in
                let shift = modifiers.contains(.shift)
                let command = modifiers.contains(.command)
                guard let hit else {
                    if !shift, !command {
                        modelSelection = modelSelection.clearedBySpace()
                    }
                    return modelSelection
                }
                switch (shift, command) {
                case (false, false):
                    modelSelection = modelSelection.plainClick(hit)
                case (false, true):
                    modelSelection = modelSelection.commandClick(hit)
                case (true, false):
                    modelSelection = modelSelection.shiftClick(hit, orderedIDs: orderedIDs)
                case (true, true):
                    modelSelection = modelSelection.commandShiftClick(
                        hit,
                        orderedIDs: orderedIDs
                    )
                }
                return modelSelection
            },
            reconcileNative: { [unowned self] live in
                modelSelection = modelSelection.reconcilingSelection(live)
                return modelSelection
            }
        )
        controller.renderSelectionFromModel(reason: "testSeed")
    }

    func sendKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            Issue.record("Failed to synthesize key event keyCode=\(keyCode)")
            return
        }
        controller.collectionView.keyDown(with: event)
    }
}

/// Synchronously install strip identities (same pattern as selection harness).
@MainActor
private func adoptStripGrid(_ controller: MediaGridViewController, ids: [MediaAssetID]) {
    var snapshot = NSDiffableDataSourceSnapshot<MediaGridViewController.Section, MediaAssetID>()
    snapshot.appendSections([.ungrouped])
    snapshot.appendItems(ids, toSection: .ungrouped)
    controller.dataSource.apply(snapshot, animatingDifferences: false)

    let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids)
    _ = controller.mutationGate.receive(grid)
    _ = controller.mutationGate.completeStructuralApply(applied: grid)
    controller.renderSelectionFromModel(reason: "structuralApply")
    // Do not scroll here — `scrollToItems` before the view is window-hosted /
    // laid out leaves AppKit in a bad state (SIGSEGV on later teardown).
}

@MainActor
private func assertStripFocusCentered(
    _ controller: MediaGridViewController,
    target: MediaAssetID
) {
    guard let path = controller.dataSource.indexPath(for: target),
          let attributes = controller.collectionView.layoutAttributesForItem(at: path)
    else {
        Issue.record("Missing layout attributes for focus target")
        return
    }
    let clip = controller.scrollView.contentView.bounds
    let itemCenterX = attributes.frame.midX
    let clipCenterX = clip.midX
    #expect(abs(itemCenterX - clipCenterX) < attributes.frame.width)
}

@MainActor
private func makeStripAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}

/// Two defects the 2026-09-02 import surfaced, both of the same shape: the grid
/// only reacted to *scrolling*, so a grid at rest under a stationary cursor was
/// left stale.
///
/// Serialized for the same reason as `MediaGridStripInputTests` — concurrent
/// NSWindow hosts race AppKit teardown.
@Suite(.serialized)
@MainActor
struct MediaGridAtRestTests {
    /// The blank-import-grid bug, at its actual condition: the scroll view is
    /// laid out and the layout knows the items, but AppKit has attached no item
    /// views. `indexPathsForVisibleItems()` reports only attached items, so the
    /// post-apply pass asked for detail on nothing — and nothing re-asked until
    /// the next scroll tick. In the field that was twelve consecutive applies
    /// logging `visibleDetailRequestCount=0`, with the first tile-detail query of
    /// the whole import landing 240 ms after the first scroll in 26 s.
    ///
    /// `reloadData()` without a following layout pass is what makes that state
    /// deterministic: it detaches every item view while the laid-out scroll view
    /// keeps its bounds and the layout still answers for the visible rect.
    /// Skipping layout entirely would *not* reproduce it — the scroll view would
    /// have no bounds either, and reporting nothing visible would be correct.
    @Test func aGridWithNoAttachedItemsStillKnowsWhatIsVisible() throws {
        let harness = try StripHarness(itemCount: 40, windowWidth: 320)
        #expect(!harness.controller.collectionView.indexPathsForVisibleItems().isEmpty)

        harness.controller.collectionView.reloadData()

        #expect(harness.controller.collectionView.indexPathsForVisibleItems().isEmpty)
        #expect(!harness.controller.visibleAssetIDs().isEmpty)
        #expect(harness.controller.requestVisibleDetails(reason: "test") > 0)
    }

    /// The hover-overlay leak. A tile that scrolls *under* a stationary cursor
    /// gets `mouseEntered`, but the one scrolling away never gets `mouseExited`,
    /// so with per-tile tracking areas every tile the pointer passed kept its
    /// control lit. Hover now has one owner that recomputes on every scroll tick.
    ///
    /// The pointer is placed explicitly. Reading the real one made this depend on
    /// where the mouse happened to be sitting, which is not a test. The scroll is
    /// also deliberately small: a long scroll recycles the hovered tile and
    /// `prepareForReuse` hides the control on its own, so it would pass whether
    /// or not hover is ever recomputed.
    @Test func scrollingClearsHoverOnATileThatStaysAttached() throws {
        let harness = try StripHarness(itemCount: 40, windowWidth: 320)
        harness.hoverItem(0)
        harness.layout()
        #expect(harness.hoveredItemIndexes() == [0])
        let hovered = try #require(harness.controller.dataSource.indexPath(for: harness.ids[0]))

        // The pointer leaves the grid while the tiles move under it — the exact
        // shape of the leak, since neither produces a `mouseExited`.
        harness.placePointer(nil)
        harness.scrollClipHorizontally(by: 24)
        harness.controller.flushScrollDrivenWorkNow()
        harness.layout()

        // Still on screen, so recycling is not what cleared it.
        #expect(harness.controller.collectionView.indexPathsForVisibleItems().contains(hovered))
        #expect(harness.tilesShowingChoiceControl() == 0)
    }

    /// The other half: a pointer that *is* over a tile after the scroll lights
    /// exactly that tile, so the recompute is a real reassignment rather than a
    /// blanket clear.
    @Test func scrollingReassignsHoverToTheTileNowUnderThePointer() throws {
        let harness = try StripHarness(itemCount: 40, windowWidth: 320)
        harness.hoverItem(0)
        harness.layout()
        #expect(harness.hoveredItemIndexes() == [0])

        harness.hoverItem(2)
        harness.controller.flushScrollDrivenWorkNow()
        harness.layout()

        #expect(harness.hoveredItemIndexes() == [2])
    }

    /// The invariant the leak violated, stated directly: hover is a single
    /// assignment, so no two tiles can ever show the control at once.
    @Test func atMostOneTileEverShowsTheChoiceControl() throws {
        let harness = try StripHarness(itemCount: 40, windowWidth: 320)

        for item in 0 ..< 5 {
            harness.hoverItem(item)
            harness.layout()
            #expect(harness.tilesShowingChoiceControl() <= 1)
        }

        harness.placePointer(nil)
        harness.controller.collectionView.refreshHover()
        harness.layout()
        #expect(harness.tilesShowingChoiceControl() == 0)
    }

    /// The flicker regression: a tile clears its own control whenever its content
    /// resets, and while the pointer holds on one thumbnail neither the asset-id
    /// guard in `setHoveredAssetID` nor the index-path guard in the collection
    /// view fires to repair it. The control then stayed dark until some unrelated
    /// apply happened to run. Hover must be re-asserted by the render itself.
    @Test func aRenderMidScrollDoesNotDropTheHoveredTilesControl() throws {
        let harness = try StripHarness(itemCount: 40, windowWidth: 320)
        harness.hoverItem(2)
        harness.layout()
        #expect(harness.tilesShowingChoiceControl() == 1)

        let hovered = harness.ids[2]
        // A content reset for the hovered tile — exactly what an enrichment
        // trickle or a visible-detail requery produces mid-scroll.
        harness.controller.renderVisibleItem(id: hovered, change: .firstImage)
        harness.layout()
        #expect(harness.tilesShowingChoiceControl() == 1)

        // And it is still the tile under the pointer, not some other one.
        harness.controller.flushScrollDrivenWorkNow()
        harness.layout()
        #expect(harness.tilesShowingChoiceControl() == 1)
    }
}
