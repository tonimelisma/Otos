import AppKit
@testable import OtosKit
import Testing

extension AppKitWindowTests {
    /// An act's result is timed from its intent to the grid that shows it
    /// (`op=ui.actToResult`, the 0.1 s target in `docs/scorecard-targets.json`): a choice
    /// ends when the grid draws the act's own tile, a Move to Trash when the grid
    /// commits an order without its items. A generated library of twelve photos, in a real
    /// window, so the grid's visible tiles are the ones AppKit lays out.
    @MainActor
    struct MediaGridActResultTests {
        @Test func anActsResultIsTimedToTheGridChangeThatShowsIt() async throws {
            let monitor = MainRunLoopStallMonitor()
            var reports: [ActResultReport] = []
            monitor.onActResult = { reports.append($0) }
            let controller = MediaGridViewController()
            _ = controller.view
            let window = orderedInTestWindow(width: 1200, height: 800, contentView: controller.view)
            defer { window.close() }
            controller.stallMonitor = monitor
            controller.view.layoutSubtreeIfNeeded()
            let ids = (0 ..< 12).map {
                MediaAssetID(
                    libraryRootPath: LibraryRootPath(rawValue: "/Generated"),
                    relativePath: MediaRelativePath(rawValue: "photo-\($0).jpg")
                )
            }
            let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids)
            controller.receive(grid)
            try await awaitGridShows(controller, grid)
            controller.collectionView.layoutSubtreeIfNeeded()
            let visible = controller.visibleAssetIDs()
            let liked = try #require(visible.first)
            let other = try #require(visible.dropFirst().first)
            for id in [liked, other] {
                controller.tileContents.mergeDetail(MediaTileDetail(libraryRootPath: id.libraryRootPath, relativePath: id.relativePath))
            }

            // A choice: another tile's change is not this act's result; its own tile is.
            monitor.beginActToResult(.choice(.liked), ids: [liked])
            controller.tileContents.setMediaChoice(.liked, for: other)
            controller.receiveTileChoiceChange(TileChoiceChange(revision: 1, ids: [other]))
            #expect(reports.isEmpty)
            controller.tileContents.setMediaChoice(.liked, for: liked)
            controller.receiveTileChoiceChange(TileChoiceChange(revision: 2, ids: [liked]))
            #expect(reports.map(\.act) == [.choice(.liked)])
            #expect(reports.last?.surface == "grid")

            // Move to Trash: an order that still holds the item is not its result; the order
            // without it is.
            monitor.beginActToResult(.moveToTrash, ids: [other])
            let reordered = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids.reversed())
            controller.receive(reordered)
            try await awaitGridShows(controller, reordered)
            #expect(reports.count == 1)
            let hidden = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids.filter { $0 != other })
            controller.receive(hidden)
            try await awaitGridShows(controller, hidden)
            #expect(reports.map(\.act) == [.choice(.liked), .moveToTrash])
            #expect(reports.map(\.revision) == [1, 2])
        }

        /// Put Back ends when the grid commits an order that shows the item again.
        @Test func aPutBackEndsWhenTheGridShowsTheItemAgain() {
            let monitor = MainRunLoopStallMonitor()
            var reports: [ActResultReport] = []
            monitor.onActResult = { reports.append($0) }
            let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Generated"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
            let other = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Generated"), relativePath: MediaRelativePath(rawValue: "b.jpg"))
            monitor.beginActToResult(.putBack, ids: [id])
            #expect(!monitor.completeMembershipToResult(committed: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: [other])))
            #expect(monitor.completeMembershipToResult(committed: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: [other, id])))
            #expect(reports.map(\.act) == [.putBack])
        }

        /// A newer act abandons the one still waiting, so a result is never credited to the
        /// act before it.
        @Test func aNewerActAbandonsThePendingOne() {
            let monitor = MainRunLoopStallMonitor()
            var reports: [ActResultReport] = []
            monitor.onActResult = { reports.append($0) }
            let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Generated"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
            monitor.beginActToResult(.moveToTrash, ids: [id])
            monitor.beginActToResult(.choice(.disliked), ids: [id])
            #expect(!monitor.completeMembershipToResult(committed: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: [])))
            #expect(monitor.completeChoiceToResult(rendered: id))
            #expect(reports.map(\.act) == [.choice(.disliked)])
            #expect(!monitor.completeChoiceToResult(rendered: id))
        }
    }
}
