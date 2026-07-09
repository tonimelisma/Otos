import AppKit
import Foundation
import os
@testable import Otos
import Testing

/// Controller-level tests for the model-owned mouse selection (spec 0046).
///
/// These drive the **real** `MediaGridCollectionView.mouseDown(with:)` override — the same
/// path a real click takes — with synthesized `NSEvent`s positioned at the center of a
/// known item's frame. Because the override does not call `super.mouseDown`, there is no
/// AppKit tracking loop to drive, so the test does not pre-settle the selection the way
/// the prior (broken) test harness did: it exercises the actual gesture classification →
/// `GridSelection` computation → `selectionIndexPaths` write. `CGEvent` posting (real HID
/// events) was considered for hit-test fidelity but rejected for a test process: it posts
/// to absolute screen coordinates, moves the real cursor, and needs an on-screen focused
/// window plus accessibility grants. Driving `mouseDown(with:)` with a synthetic `NSEvent`
/// is deterministic, runs headless, and still exercises the owned path end-to-end — the
/// only thing it skips is AppKit's native selection tracking loop, which the design
/// deliberately never calls.
@MainActor
struct MediaGridSelectionControllerTests {
    // MARK: - Acceptance matrix (rows 1–14)

    @Test func row1_plainClickSelectsOnlyTheClickedItem() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])

        #expect(harness.selectedIDs() == [harness.ids[2]])
        #expect(harness.controller.gridSelection.anchor == harness.ids[2])
        #expect(harness.controller.gridSelection.base == [harness.ids[2]])
    }

    @Test func row2_shiftClickExtendsAForwardRange() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])
        try harness.click(harness.ids[5], modifiers: [.shift])

        #expect(harness.selectedIDs() == Set(harness.ids[2 ... 5]))
        #expect(harness.controller.gridSelection.anchor == harness.ids[2])
    }

    @Test func row3_secondShiftClickContractsAndKeepsTheClickedTile() throws {
        // B1: click 1, ⇧-click 4 → {1,2,3,4}; ⇧-click 3 → {1,2,3} (not {1,2}).
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[1], modifiers: [])
        try harness.click(harness.ids[4], modifiers: [.shift])
        #expect(harness.selectedIDs() == Set(harness.ids[1 ... 4]))

        try harness.click(harness.ids[3], modifiers: [.shift])
        #expect(harness.selectedIDs() == Set(harness.ids[1 ... 3]))
    }

    @Test func row4_shiftClickExtendsABackwardRange() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[5], modifiers: [])
        try harness.click(harness.ids[2], modifiers: [.shift])

        #expect(harness.selectedIDs() == Set(harness.ids[2 ... 5]))
    }

    @Test func row5_commandClickAddsAnIslandAndMovesTheAnchor() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[1], modifiers: [])
        try harness.click(harness.ids[4], modifiers: [.command])

        #expect(harness.selectedIDs() == [harness.ids[1], harness.ids[4]])
        #expect(harness.controller.gridSelection.anchor == harness.ids[4])
    }

    @Test func row6_shiftClickAfterCommandClickRangesFromNewAnchorKeepingIsland() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[1], modifiers: [])
        try harness.click(harness.ids[4], modifiers: [.command])
        try harness.click(harness.ids[6], modifiers: [.shift])

        #expect(harness.selectedIDs() == Set([harness.ids[1]] + harness.ids[4 ... 6]))
    }

    @Test func row7_commandClickInsideARangeRemovesOnlyThatItem() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])
        try harness.click(harness.ids[5], modifiers: [.shift]) // {C,D,E,F}
        try harness.click(harness.ids[3], modifiers: [.command]) // remove D

        #expect(harness.selectedIDs() == [harness.ids[2], harness.ids[4], harness.ids[5]])
    }

    @Test func row8_plainClickCollapsingAMultiSelectionReanchors() throws {
        // B2: select {C,D,E}, plain-click D → {D}; base becomes {D}.
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])
        try harness.click(harness.ids[3], modifiers: [.command])
        try harness.click(harness.ids[4], modifiers: [.command])
        #expect(harness.selectedIDs() == Set(harness.ids[2 ... 4]))

        try harness.click(harness.ids[3], modifiers: [])

        #expect(harness.selectedIDs() == [harness.ids[3]])
        #expect(harness.controller.gridSelection.base == [harness.ids[3]])
    }

    @Test func row9_shiftClickAfterCollapseDoesNotReAddPriorSelection() throws {
        // B2: …then ⇧-click G → {D,E,F,G}, not {C,D,E,F,G}.
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])
        try harness.click(harness.ids[3], modifiers: [.command])
        try harness.click(harness.ids[4], modifiers: [.command])
        try harness.click(harness.ids[3], modifiers: []) // collapse to D
        try harness.click(harness.ids[6], modifiers: [.shift])

        #expect(harness.selectedIDs() == Set(harness.ids[3 ... 6]))
    }

    @Test func row10_commandClickDeselectingTheSoleSelectionLeavesAnchorAsPivot() throws {
        // B3 setup: click B, ⌘-click B → ∅; anchor stays B, base ∅.
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[1], modifiers: [])
        try harness.click(harness.ids[1], modifiers: [.command])

        #expect(harness.selectedIDs().isEmpty)
        #expect(harness.controller.gridSelection.anchor == harness.ids[1])
        #expect(harness.controller.gridSelection.base.isEmpty)
    }

    @Test func row11_shiftClickAfterCommandDeselectRangesFromPivotWithNothingStale() throws {
        // B3: …then ⇧-click E → {B,C,D,E}.
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[1], modifiers: [])
        try harness.click(harness.ids[1], modifiers: [.command])
        try harness.click(harness.ids[4], modifiers: [.shift])

        #expect(harness.selectedIDs() == Set(harness.ids[1 ... 4]))
    }

    @Test func row12_emptySpaceClickClearsSelectionAndAnchor() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])

        try harness.clickEmptySpace(modifiers: [])

        #expect(harness.selectedIDs().isEmpty)
        #expect(harness.controller.gridSelection.anchor == nil)
    }

    @Test func row13_shiftClickWithEmptySelectionFallsBackToClicked() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[3], modifiers: [.shift])

        #expect(harness.selectedIDs() == [harness.ids[3]])
        #expect(harness.controller.gridSelection.anchor == harness.ids[3])
    }

    @Test func row14_commandShiftClickExtendsRangeKeepingIslands() throws {
        // {B,E} (anchor E), ⌘⇧-click H → {B,E,F,G,H}.
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[4], modifiers: []) // E
        try harness.click(harness.ids[1], modifiers: [.command]) // + B, anchor→B
        try harness.click(harness.ids[4], modifiers: [.command]) // pivot back to E
        try harness.click(harness.ids[7], modifiers: [.shift, .command]) // ⌘⇧ H

        #expect(harness.selectedIDs() == Set([harness.ids[1]] + harness.ids[4 ... 7]))
    }

    // MARK: - Structural-apply prune (rows 15–16)

    @Test func row15_structuralApplyRemovingAnItemPrunesItFromSelectionAndBase() throws {
        // F6: click C, ⇧-click D → {C,D} (anchor C, base {C}); apply removes D → {C}, base {C}.
        // ⇧-click (not ⌘-click) is used so the anchor stays on C while the range covers D.
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])
        try harness.click(harness.ids[3], modifiers: [.shift])

        let survivors = [harness.ids[0], harness.ids[1], harness.ids[2]] + Array(harness.ids[4 ... 7])
        harness.controller.restoreSelection([harness.ids[2], harness.ids[3]], in: survivors)

        #expect(harness.controller.gridSelection.selection == [harness.ids[2]])
        #expect(harness.controller.gridSelection.anchor == harness.ids[2])
        #expect(harness.controller.gridSelection.base == [harness.ids[2]])
    }

    @Test func row16_structuralApplyRemovingTheAnchorClearsAnchorAndBase() throws {
        // click C, ⇧-click D → {C,D} (anchor C, base {C}); apply removes C → {D}, anchor nil.
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])
        try harness.click(harness.ids[3], modifiers: [.shift])

        let survivors = [harness.ids[0], harness.ids[1]] + Array(harness.ids[3 ... 7]) // C removed
        harness.controller.restoreSelection([harness.ids[2], harness.ids[3]], in: survivors)

        #expect(harness.controller.gridSelection.selection == [harness.ids[3]])
        #expect(harness.controller.gridSelection.anchor == nil)
        #expect(harness.controller.gridSelection.base.isEmpty)
    }

    @Test func descriptorChangeClearsSelectionAnchorAndBase() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: [])

        harness.controller.clearSelection(reason: "descriptorChange")

        #expect(harness.controller.gridSelection == .empty)
        #expect(harness.selectedIDs().isEmpty)
    }

    @Test func descriptorChangingApplyClearsAnchorEvenWhenTheAnchoredAssetSurvives() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[1], modifiers: [])

        let grid = CatalogMediaGridState(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            orderedAssetIDs: harness.ids // the anchored asset is still present
        )
        let context = MediaGridViewController.StructuralApplyCompletionContext(
            grid: grid,
            preservedSelection: [],
            resetSelection: true,
            resetScroll: true,
            applyStart: Date(),
            applyCallStart: Date(),
            diffPolicyMs: 0,
            snapshotBuildMs: 0,
            insertedCount: 0,
            removedCount: 0,
            reorderOnly: false,
            largeApply: false,
            animatingDifferences: true,
            usesReloadDataFallback: false,
            signpost: .beginState(id: .exclusive)
        )

        harness.controller.completeStructuralApply(context, operation: nil, stallMonitor: nil)

        #expect(harness.controller.gridSelection == .empty)
        #expect(harness.selectedIDs().isEmpty)
    }

    // MARK: - Thumbnail-only hit area (spec 0049)

    @Test func clickInsideLandscapeThumbnailFaceSelects() throws {
        let harness = try makeHarness(itemCount: 8)
        let target = harness.ids[2]
        harness.configureItemWithThumbnail(target, pixelSize: CGSize(width: 400, height: 200))

        try harness.clickItem(target, target: .thumbnailFaceCenter, modifiers: [])

        #expect(harness.selectedIDs() == [target])
        #expect(harness.controller.gridSelection.anchor == target)
    }

    @Test func clickInLandscapeLetterboxDeselects() throws {
        let harness = try makeHarness(itemCount: 8)
        try harness.click(harness.ids[2], modifiers: []) // establish a selection
        #expect(!harness.selectedIDs().isEmpty)

        let target = harness.ids[3]
        harness.configureItemWithThumbnail(target, pixelSize: CGSize(width: 400, height: 200))

        try harness.clickItem(target, target: .topLetterboxCenter, modifiers: [])

        #expect(harness.selectedIDs().isEmpty)
        #expect(harness.controller.gridSelection.anchor == nil)
    }

    @Test func modifiedClickInLetterboxIsNoOp() throws {
        let harness = try makeHarness(itemCount: 8)
        let first = harness.ids[1]
        let second = harness.ids[3]
        try harness.click(first, modifiers: [])
        try harness.click(second, modifiers: [.command])
        let before = harness.selectedIDs()
        #expect(before == [first, second])

        let target = harness.ids[4]
        harness.configureItemWithThumbnail(target, pixelSize: CGSize(width: 400, height: 200))

        try harness.clickItem(target, target: .topLetterboxCenter, modifiers: [.shift])

        #expect(harness.selectedIDs() == before)
    }
}

// MARK: - Test harness

@MainActor
private final class GridSelectionTestHarness {
    let controller: MediaGridViewController
    let ids: [MediaAssetID]
    private let window: NSWindow

    enum ClickTarget {
        case thumbnailFaceCenter
        case topLetterboxCenter
    }

    init(itemCount: Int) throws {
        controller = MediaGridViewController()
        _ = controller.view // forces loadView()

        ids = (0 ..< itemCount).map { makeAssetID(path: "asset-\($0).jpg") }
        var snapshot = NSDiffableDataSourceSnapshot<MediaGridViewController.Section, MediaAssetID>()
        snapshot.appendSections([.media])
        snapshot.appendItems(ids, toSection: .media)
        controller.dataSource.apply(snapshot, animatingDifferences: false)

        let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids)
        _ = controller.mutationGate.receive(grid)
        _ = controller.mutationGate.completeStructuralApply(applied: grid)

        // A real window (off-screen) is required for layout, hit-testing, and first
        // responder. `indexPathForItem(at:)` and `layoutAttributesForItem(at:)` only
        // return non-nil after the collection view has been laid out in a window.
        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
        // Run a run-loop pass so AppKit completes layout and the data source reflects
        // the applied snapshot for hit-testing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// Seeds a decoded thumbnail in `TileContentStore` for `id` so its tile has a real
    /// pixel size and an aspect-fit face with letterbox zones. The detail is merged and
    /// the visible item is reconfigured so the test can click the actual rendered face.
    func configureItemWithThumbnail(_ id: MediaAssetID, pixelSize: CGSize) {
        let thumbnailPath = "test-\(id.relativePath.rawValue)"
        let detail = MediaTileDetail(
            libraryRootPath: id.libraryRootPath,
            relativePath: id.relativePath,
            thumbnailPath: thumbnailPath,
            bestKind: .image,
            durationSeconds: nil,
            enrichedSourceSize: Int64(pixelSize.width * pixelSize.height),
            enrichedSourceMTimeSeconds: 1
        )
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        controller.mergeTileDetails([id: detail], reason: "test")
        _ = controller.tileContents.applyDecoded(
            makeTestCGImage(width: Int(pixelSize.width), height: Int(pixelSize.height)),
            key: key,
            for: id
        )

        _ = controller.ensureContentAndMaybeDecode(for: id)
        if let indexPath = controller.dataSource.indexPath(for: id),
           let item = controller.collectionView.item(at: indexPath) as? MediaGridItem
        {
            item.render(
                content: controller.tileContents.content(for: id),
                change: .unchanged
            )
        }
    }

    /// The center point of the tile for `id`, in window coordinates for the synthetic
    /// event's `locationInWindow`.
    private func windowPoint(for id: MediaAssetID) throws -> NSPoint {
        let indexPath = try #require(controller.dataSource.indexPath(for: id))
        let attrs = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
        let centerInCollectionView = NSPoint(x: attrs.frame.midX, y: attrs.frame.midY)
        let centerInContentView = controller.collectionView.convert(centerInCollectionView, to: controller.view)
        return controller.view.convert(centerInContentView, to: nil)
    }

    /// Drives the real `mouseDown(with:)` override with a synthetic event at the tile's
    /// center. `super.mouseDown` is not called by the override, so this exercises the full
    /// owned path (hit-test → `applyMouseSelection` → `selectionIndexPaths` write) without
    /// AppKit's tracking loop.
    func click(_ id: MediaAssetID, modifiers: NSEvent.ModifierFlags) throws {
        let point = try windowPoint(for: id)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        controller.collectionView.mouseDown(with: event)
    }

    /// Clicks a point outside any item frame (empty space) — the top-left gutter inside
    /// the section inset where no item frame lives.
    func clickEmptySpace(modifiers: NSEvent.ModifierFlags) throws {
        let point = NSPoint(x: 2, y: 2)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        controller.collectionView.mouseDown(with: event)
    }

    func selectedIDs() -> Set<MediaAssetID> {
        controller.selectedIdentities()
    }

    /// Clicks `id` at a position relative to its rendered thumbnail face.
    func clickItem(
        _ id: MediaAssetID,
        target: ClickTarget,
        modifiers: NSEvent.ModifierFlags
    ) throws {
        let point = try windowPoint(for: id, target: target)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        controller.collectionView.mouseDown(with: event)
    }

    private func windowPoint(for id: MediaAssetID, target: ClickTarget) throws -> NSPoint {
        let indexPath = try #require(controller.dataSource.indexPath(for: id))
        let item = try #require(controller.collectionView.item(at: indexPath) as? MediaGridItem)
        let tileView = try #require(item.view as? MediaAssetTileView)
        let pixelSize = try #require(tileView.paintedImagePixelSize, "Tile has no decoded thumbnail")
        let face = MediaAssetTilePresentation.thumbnailFaceRect(
            imagePixelSize: pixelSize,
            bounds: tileView.bounds
        )

        let pointInTile = switch target {
        case .thumbnailFaceCenter:
            NSPoint(x: face.midX, y: face.midY)
        case .topLetterboxCenter:
            NSPoint(x: face.midX, y: tileView.bounds.minY + 2)
        }

        let pointInCollectionView = tileView.convert(pointInTile, to: controller.collectionView)
        return controller.collectionView.convert(pointInCollectionView, to: nil)
    }
}

@MainActor
private func makeHarness(itemCount: Int) throws -> GridSelectionTestHarness {
    try GridSelectionTestHarness(itemCount: itemCount)
}

@MainActor
private func makeAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}

private func makeTestCGImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
