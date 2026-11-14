import AppKit
import Foundation
import os
@testable import OtosKit
import Testing

extension AppKitWindowTests {
    /// Controller-level tests for the model-owned mouse selection (APP-011).
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
    ///
    /// Its tests host real windows, so it is nested in `AppKitWindowTests`.
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

        @Test func row5_commandClickAddsAnIslandAndMovesTheAnchor() throws {
            let harness = try makeHarness(itemCount: 8)
            try harness.click(harness.ids[1], modifiers: [])
            try harness.click(harness.ids[4], modifiers: [.command])

            #expect(harness.selectedIDs() == [harness.ids[1], harness.ids[4]])
            #expect(harness.controller.gridSelection.anchor == harness.ids[4])
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

        @Test func plainMouseDownOnASelectedTileWaitsForMouseUpAndADragKeepsTheSelection() throws {
            // ADR 0028: {C,D,E} selected; mouse-down on D changes nothing yet, mouse-up collapses
            // to {D}; a drag that begins in between keeps {C,D,E} and starts the drag instead.
            let harness = try makeHarness(itemCount: 8)
            try harness.click(harness.ids[2], modifiers: [])
            try harness.click(harness.ids[3], modifiers: [.command])
            try harness.click(harness.ids[4], modifiers: [.command])

            try harness.mouseDown(harness.ids[3], modifiers: [])
            #expect(harness.selectedIDs() == Set(harness.ids[2 ... 4]))
            try harness.mouseUp(harness.ids[3], modifiers: [])
            #expect(harness.selectedIDs() == [harness.ids[3]])

            try harness.click(harness.ids[2], modifiers: [])
            try harness.click(harness.ids[4], modifiers: [.shift])
            var dragStarts: [IndexPath] = []
            harness.controller.collectionView.onDragBegin = { hit, _ in dragStarts.append(hit) }
            try harness.mouseDown(harness.ids[3], modifiers: [])
            try harness.mouseDrag(from: harness.ids[3], by: MediaGridDragPolicy.dragThreshold + 1)
            try harness.mouseUp(harness.ids[3], modifiers: [])

            #expect(harness.selectedIDs() == Set(harness.ids[2 ... 4]))
            #expect(dragStarts.count == 1)
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

        @Test func row14_commandShiftClickExtendsRangeKeepingIslands() throws {
            // {B,E} (anchor E), ⌘⇧-click H → {B,E,F,G,H}.
            let harness = try makeHarness(itemCount: 8)
            try harness.click(harness.ids[4], modifiers: []) // E
            try harness.click(harness.ids[1], modifiers: [.command]) // + B, anchor→B
            try harness.click(harness.ids[4], modifiers: [.command]) // pivot back to E
            try harness.click(harness.ids[7], modifiers: [.shift, .command]) // ⌘⇧ H

            #expect(harness.selectedIDs() == Set([harness.ids[1]] + harness.ids[4 ... 7]))
        }

        // MARK: - Model → view render (structural apply no longer writes the model)

        @Test func structuralApplyRendersPrunedModelWithoutWritingIt() throws {
            // Prune lives in ViewModel.applyState; the controller only renders.
            let harness = try makeHarness(itemCount: 8)
            try harness.click(harness.ids[2], modifiers: [])
            try harness.click(harness.ids[3], modifiers: [.shift])
            #expect(harness.selectedIDs() == Set(harness.ids[2 ... 3]))

            harness.setModelSelection(
                GridSelection(
                    selection: [harness.ids[2]],
                    anchor: harness.ids[2],
                    base: [harness.ids[2]]
                )
            )
            harness.controller.renderSelectionFromModel(reason: "structuralApply")

            #expect(harness.controller.gridSelection.selection == [harness.ids[2]])
            #expect(harness.selectedIDs() == [harness.ids[2]])
        }

        @Test func structuralApplyRendersEmptyModelAfterDescriptorClear() throws {
            let harness = try makeHarness(itemCount: 8)
            try harness.click(harness.ids[1], modifiers: [])

            harness.setModelSelection(.empty)
            let grid = CatalogMediaGridState(
                scope: .library(LibraryRootPath(rawValue: "/Pictures")),
                orderedAssetIDs: harness.ids
            )
            let context = MediaGridViewController.StructuralApplyCompletionContext(
                grid: grid,
                change: .scope,
                applyStart: .now,
                applyCallStart: .now,
                diffPolicyMs: 0,
                structureBuildMs: 0,
                batchUpdatesMs: 0,
                insertedCount: 0,
                removedCount: 0,
                reorderOnly: false,
                largeApply: false,
                animatingDifferences: true,
                animationSuppressed: false,
                usesReloadDataFallback: false,
                appliedBy: .batchUpdates,
                sectionCount: 1,
                heldDuringScroll: false,
                signpost: .beginState(id: .exclusive)
            )

            harness.controller.completeStructuralApply(context, operation: nil, stallMonitor: nil)

            #expect(harness.controller.gridSelection == .empty)
            #expect(harness.selectedIDs().isEmpty)
        }

        // MARK: - Thumbnail-only hit area

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

        @Test func unmodifiedDoubleClickForwardsAfterSelection() throws {
            let harness = try makeHarness(itemCount: 8)
            var doubleClicked: MediaAssetID?
            harness.controller.onItemDoubleClick = { doubleClicked = $0 }
            try harness.doubleClick(harness.ids[2])

            #expect(harness.selectedIDs() == [harness.ids[2]])
            #expect(doubleClicked == harness.ids[2])
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
}

// MARK: - Test harness

@MainActor
private final class GridSelectionTestHarness {
    let controller: MediaGridViewController
    let ids: [MediaAssetID]
    private let window: NSWindow
    /// Local selection owner standing in for `CatalogWindowViewModel` so controller
    /// tests stay hermetic while exercising the same injected-closure path.
    private var modelSelection = GridSelection.empty

    enum ClickTarget {
        case thumbnailFaceCenter
        case topLetterboxCenter
    }

    init(itemCount: Int) throws {
        controller = MediaGridViewController()
        _ = controller.view // forces loadView()

        ids = (0 ..< itemCount).map { makeAssetID(path: "asset-\($0).jpg") }
        controller.show(MediaGridStructure(orderedIDs: ids))

        let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids)
        _ = controller.mutationGate.receive(grid)
        _ = controller.mutationGate.completeStructuralApply(applied: grid)

        // A real window (off-screen) is required for layout, hit-testing, and first
        // responder. `indexPathForItem(at:)` and `layoutAttributesForItem(at:)` only
        // return non-nil after the collection view has been laid out in a window.
        window = orderedInTestWindow(width: 800, height: 600, contentView: controller.view)
        controller.view.layoutSubtreeIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()

        installSelectionHandlers()
    }

    /// Closes the window deterministically.
    ///
    /// `makeKeyAndOrderFront` puts a window into AppKit's window list, and that
    /// list *retains* it — so a harness going out of scope leaks a live, key,
    /// ordered-in window rather than releasing it. Across a full suite run that
    /// is hundreds of them, all competing for key-window status while other
    /// window-hosting suites spin the run loop. `isolated deinit` lets the close
    /// happen on the main actor, where NSWindow requires it.
    isolated deinit {
        window.close()
    }

    private func installSelectionHandlers() {
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
    }

    func setModelSelection(_ selection: GridSelection) {
        modelSelection = selection
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
            renderedSourceSize: Int64(pixelSize.width * pixelSize.height),
            renderedSourceMTimeSeconds: 1
        )
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        controller.mergeTileDetails([id: detail], reason: "test")
        _ = controller.tileContents.applyDecoded(
            makeTestCGImage(width: Int(pixelSize.width), height: Int(pixelSize.height)),
            key: key,
            for: id
        )

        _ = controller.ensureContentAndMaybeDecode(for: id)
        if let indexPath = controller.structure.indexPath(of: id),
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
        let indexPath = try #require(controller.structure.indexPath(of: id))
        let attrs = try #require(controller.collectionView.layoutAttributesForItem(at: indexPath))
        let centerInCollectionView = NSPoint(x: attrs.frame.midX, y: attrs.frame.midY)
        let centerInContentView = controller.collectionView.convert(centerInCollectionView, to: controller.view)
        return controller.view.convert(centerInContentView, to: nil)
    }

    /// Drives the real `mouseDown(with:)` and `mouseUp(with:)` overrides with synthetic
    /// events at the tile's center — a complete click. `super.mouseDown` is not called by
    /// the override, so this exercises the full owned path (hit-test →
    /// `applyMouseSelection` → `selectionIndexPaths` write) without AppKit's tracking
    /// loop. A plain click on an already-selected tile commits on mouse-up (ADR 0028), so
    /// a click is both halves.
    func click(_ id: MediaAssetID, modifiers: NSEvent.ModifierFlags) throws {
        try mouseDown(id, modifiers: modifiers)
        try mouseUp(id, modifiers: modifiers)
    }

    func mouseDown(_ id: MediaAssetID, modifiers: NSEvent.ModifierFlags) throws {
        try controller.collectionView.mouseDown(with: mouseEvent(
            .leftMouseDown,
            at: windowPoint(for: id),
            modifiers: modifiers
        ))
    }

    func mouseUp(_ id: MediaAssetID, modifiers: NSEvent.ModifierFlags) throws {
        try controller.collectionView.mouseUp(with: mouseEvent(
            .leftMouseUp,
            at: windowPoint(for: id),
            modifiers: modifiers
        ))
    }

    /// A drag past the threshold from the tile's center.
    func mouseDrag(from id: MediaAssetID, by delta: CGFloat) throws {
        var point = try windowPoint(for: id)
        point.x += delta
        try controller.collectionView.mouseDragged(with: mouseEvent(.leftMouseDragged, at: point, modifiers: []))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ))
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

    func doubleClick(_ id: MediaAssetID) throws {
        let point = try windowPoint(for: id)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
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
        let indexPath = try #require(controller.structure.indexPath(of: id))
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
