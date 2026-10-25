import AppKit
import CoreGraphics
@testable import OtosKit
import QuartzCore
import Testing

extension AppKitWindowTests {
    /// Regression for APP-015: a painted visible tile must keep its
    /// image across detail-query merges and structural recycle of other IDs. The
    /// invariant lives in `TileContentStore` (pin + cost budget); the tile is a pure
    /// renderer, so these tests assert through the controller → store → tile path.
    /// Its tests host real windows, so it is nested in `AppKitWindowTests`.
    @MainActor
    struct MediaGridPaintInvariantTests {
        @Test func detailQueryMergeDoesNotBlankPaintedVisibleTile() throws {
            let harness = try PaintInvariantHarness(itemCount: 4)
            let visible = harness.ids[0]
            harness.paintThumbnail(for: visible, pixelSize: CGSize(width: 64, height: 48))
            let before = try harness.requirePaintedSize(for: visible)

            // Detail-query style merge for the same visible id (badge-only change) plus
            // another id must pin visible first and never nil the painted image.
            let refreshed = MediaTileDetail(
                libraryRootPath: visible.libraryRootPath,
                relativePath: visible.relativePath,
                thumbnailPath: "test-\(visible.relativePath.rawValue)",
                bestKind: .image,
                durationSeconds: nil,
                enrichedSourceSize: 64 * 48,
                enrichedSourceMTimeSeconds: 1
            )
            let other = harness.ids[1]
            let otherDetail = MediaTileDetail(
                libraryRootPath: other.libraryRootPath,
                relativePath: other.relativePath,
                thumbnailPath: "other.jpg",
                bestKind: .image,
                durationSeconds: nil,
                enrichedSourceSize: 10,
                enrichedSourceMTimeSeconds: 1
            )
            harness.controller.mergeTileDetails(
                [visible: refreshed, other: otherDetail],
                reason: "detailQuery"
            )
            harness.reconfigureVisible(visible)

            let after = try harness.requirePaintedSize(for: visible)
            #expect(after == before)
            #expect(harness.controller.tileContents.content(for: visible)?.image != nil)
        }

        @Test func structuralPruneOfOtherIDDoesNotBlankPaintedVisibleTile() throws {
            let harness = try PaintInvariantHarness(itemCount: 6)
            let visible = harness.ids[0]
            let recycled = harness.ids[5]
            harness.paintThumbnail(for: visible, pixelSize: CGSize(width: 80, height: 60))
            harness.paintThumbnail(for: recycled, pixelSize: CGSize(width: 32, height: 32))
            let before = try harness.requirePaintedSize(for: visible)

            // Simulate structural apply completion: prune to live IDs that still include
            // the painted visible id, drop the recycled off-screen id, and re-pin.
            let live = Set(harness.ids.prefix(4))
            harness.controller.tileContents.pinVisible([visible])
            harness.controller.tileContents.prune(to: live)
            harness.controller.tileContents.pinVisible([visible])
            harness.reconfigureVisible(visible)

            let after = try harness.requirePaintedSize(for: visible)
            #expect(after == before)
            #expect(harness.controller.tileContents.content(for: visible)?.image != nil)
            #expect(harness.controller.tileContents.content(for: recycled) == nil)
        }

        /// DES-069 regression: an enrichment correcting a capture date moves an asset
        /// between day sections (same membership, same relative order, different
        /// section assignment) — the painted tile must survive exactly like any other
        /// structural churn, per APP-015.
        @Test func dayBucketChangeBetweenAppliesDoesNotBlankPaintedVisibleTile() throws {
            let harness = try PaintInvariantHarness(itemCount: 4)
            let visible = harness.ids[0]
            harness.paintThumbnail(for: visible, pixelSize: CGSize(width: 64, height: 48))
            let before = try harness.requirePaintedSize(for: visible)

            let dayOne = Date(timeIntervalSince1970: 0)
            let dayTwo = Date(timeIntervalSince1970: 86400)
            var snapshot = NSDiffableDataSourceSnapshot<MediaGridViewController.Section, MediaAssetID>()
            for run in MediaGridSectionGroupingPolicy.sectionRuns(
                orderedIDs: harness.ids,
                dayBuckets: [dayTwo, dayOne, dayOne, dayOne]
            ) {
                snapshot.appendSections([run.section])
                snapshot.appendItems(run.ids, toSection: run.section)
            }
            harness.controller.dataSource.apply(snapshot, animatingDifferences: false)
            harness.controller.tileContents.pinVisible([visible])
            harness.controller.tileContents.prune(to: Set(harness.ids))
            harness.reconfigureVisible(visible)

            let after = try harness.requirePaintedSize(for: visible)
            #expect(after == before)
            #expect(harness.controller.tileContents.content(for: visible)?.image != nil)
        }

        @Test func reconfigureVisibleItemsPinsOnce() throws {
            let harness = try PaintInvariantHarness(itemCount: 4)
            harness.controller.reconfigureVisibleItems(reason: "test")
            #expect(harness.controller.lastReconfigurePinCallCount == 1)
        }

        /// APP-015 regression: a light/dark switch redisplays every view in the window,
        /// and the painted thumbnail must survive it. AppKit updates layers for that
        /// redisplay when the transaction commits, so each switch is flushed before the
        /// thumbnail layer is read.
        @Test func appearanceChangeDoesNotBlankPaintedVisibleTile() throws {
            let harness = try PaintInvariantHarness(itemCount: 2)
            let visible = harness.ids[0]
            harness.window.appearance = NSAppearance(named: .aqua)
            harness.paintThumbnail(for: visible, pixelSize: CGSize(width: 64, height: 48))
            harness.commitDisplay()
            let painted = try harness.requireDisplayedThumbnail(for: visible)

            harness.window.appearance = NSAppearance(named: .darkAqua)
            harness.commitDisplay()
            #expect(try harness.requireDisplayedThumbnail(for: visible) === painted)

            harness.window.appearance = NSAppearance(named: .aqua)
            harness.commitDisplay()
            #expect(try harness.requireDisplayedThumbnail(for: visible) === painted)
        }

        @Test func repeatedVisibleIDsSkipScrollDetailQuery() throws {
            let harness = try PaintInvariantHarness(itemCount: 4)
            // Four tiles in an 800×600 window are all on screen.
            let visibleIDs = harness.controller.visibleAssetIDs()
            try #require(visibleIDs == harness.ids)
            #expect(harness.controller.wouldStartVisibleDetailQuery(for: visibleIDs))
            _ = harness.controller.requestVisibleDetails(reason: "scroll")
            #expect(!harness.controller.wouldStartVisibleDetailQuery(for: visibleIDs))
        }

        /// APP-015 and ADR 0032 rule 4: a visible-detail query that fails merges nothing,
        /// so the painted tile keeps its thumbnail, and it leaves the request outstanding,
        /// so the next scroll flush over the same tiles asks again and merges the rows.
        @Test(.testDirectory) func failedDetailQueryKeepsThePaintedTileAndAsksAgain() async throws {
            try await withEditableLibrary(fileCount: 2) { library in
                let harness = try PaintInvariantHarness(ids: library.ids)
                harness.controller.detailReader = MediaTileDetailReader(store: library.store)
                let visible = library.ids[0]
                harness.paintThumbnail(for: visible, pixelSize: CGSize(width: 64, height: 48))
                let before = try harness.requirePaintedSize(for: visible)
                let visibleIDs = harness.controller.visibleAssetIDs()
                try #require(visibleIDs == library.ids)
                let hidden = try await HiddenCatalogTable("asset_metadata", in: library.databaseURL)

                #expect(harness.controller.requestVisibleDetails(reason: "scroll") == visibleIDs.count)
                await harness.controller.detailQueryTask?.value
                #expect(try harness.requirePaintedSize(for: visible) == before)
                #expect(harness.controller.tileContents.content(for: visible)?.detail.byteSize == nil)
                #expect(harness.controller.wouldStartVisibleDetailQuery(for: visibleIDs))

                try await hidden.restore()
                _ = harness.controller.requestVisibleDetails(reason: "scroll")
                await harness.controller.detailQueryTask?.value
                #expect(harness.controller.tileContents.content(for: visible)?.detail.byteSize != nil)
                #expect(try harness.requirePaintedSize(for: visible) == before)
                #expect(!harness.controller.wouldStartVisibleDetailQuery(for: visibleIDs))
            }
        }
    }
}

@MainActor
private final class PaintInvariantHarness {
    let controller: MediaGridViewController
    let ids: [MediaAssetID]
    let window: NSWindow

    convenience init(itemCount: Int) throws {
        try self.init(ids: (0 ..< itemCount).map { index in
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "asset-\(index).jpg")
            )
        })
    }

    init(ids: [MediaAssetID]) throws {
        controller = MediaGridViewController()
        _ = controller.view

        self.ids = ids
        var snapshot = NSDiffableDataSourceSnapshot<MediaGridViewController.Section, MediaAssetID>()
        snapshot.appendSections([.ungrouped])
        snapshot.appendItems(ids, toSection: .ungrouped)
        controller.dataSource.apply(snapshot, animatingDifferences: false)

        let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids)
        _ = controller.mutationGate.receive(grid)
        _ = controller.mutationGate.completeStructuralApply(applied: grid)

        window = orderedInTestWindow(width: 800, height: 600, contentView: controller.view)
        controller.view.layoutSubtreeIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
    }

    /// Closes the window deterministically: `makeKeyAndOrderFront` adds it to
    /// AppKit's window list, which retains it, so letting the harness go out of
    /// scope leaks a live key window instead of releasing it. `isolated deinit`
    /// runs the close on the main actor, where NSWindow requires it.
    isolated deinit {
        window.close()
    }

    func paintThumbnail(for id: MediaAssetID, pixelSize: CGSize) {
        let detail = MediaTileDetail(
            libraryRootPath: id.libraryRootPath,
            relativePath: id.relativePath,
            thumbnailPath: "test-\(id.relativePath.rawValue)",
            bestKind: .image,
            durationSeconds: nil,
            enrichedSourceSize: Int64(pixelSize.width * pixelSize.height),
            enrichedSourceMTimeSeconds: 1
        )
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        controller.mergeTileDetails([id: detail], reason: "test")
        let image = makePaintImage(width: Int(pixelSize.width), height: Int(pixelSize.height))
        _ = controller.tileContents.applyDecoded(image, key: key, for: id)
        reconfigureVisible(id)
    }

    func reconfigureVisible(_ id: MediaAssetID) {
        controller.tileContents.pinVisible(Set([id]))
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

    func requirePaintedSize(for id: MediaAssetID) throws -> CGSize {
        let indexPath = try #require(controller.dataSource.indexPath(for: id))
        let item = try #require(controller.collectionView.item(at: indexPath) as? MediaGridItem)
        let tileView = try #require(item.view as? MediaAssetTileView)
        return try #require(tileView.paintedImagePixelSize, "Tile has no decoded thumbnail")
    }

    /// Runs the window's pending display and commits it, which is where AppKit
    /// updates view layers after an appearance change.
    func commitDisplay() {
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func requireDisplayedThumbnail(for id: MediaAssetID) throws -> CGImage {
        let indexPath = try #require(controller.dataSource.indexPath(for: id))
        let item = try #require(controller.collectionView.item(at: indexPath) as? MediaGridItem)
        let tileView = try #require(item.view as? MediaAssetTileView)
        return try #require(tileView.displayedThumbnail, "Tile layer shows no thumbnail")
    }
}

@MainActor
private func makePaintImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
