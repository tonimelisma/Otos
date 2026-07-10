import AppKit
@testable import Otos
import Testing

/// Stage C (plan 0053) / Stage A (plan 0054): horizontal strip scroll loading,
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
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
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
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
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
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        layout()
        _ = controller.mutationGate.endScrollHold()
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
    snapshot.appendSections([.media])
    snapshot.appendItems(ids, toSection: .media)
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
