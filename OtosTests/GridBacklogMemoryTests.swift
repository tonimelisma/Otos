import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// What the window holds while enrichment works a new library's backlog (ADR 0006, "What the
/// tile store keeps"): every publication is a read that moved a photo to another day, published
/// as an edit of the last; the grid applies some of them and holds one through a scroll; and it
/// is scrolled from place to place, decoding the visible tiles and the look-ahead either way.
/// Counted, never timed: the orders still alive, the edit each index holds, the tiles the store
/// keeps. Over a backlog of publications none of them may grow with the number of publications.
/// At the reference size (`OTOS_SCALE_TEST=1`, run alone) the process footprint is bounded too.
@MainActor
@Suite(.testScope, .serialized)
struct GridBacklogMemoryTests {
    private nonisolated static let photosPerDay = 32

    /// A library's order under Date sort, newest day first, and the reads a backlog publishes:
    /// each gives one photo another day, which moves it to the end of that day.
    private nonisolated struct Backlog {
        private(set) var ids: [MediaAssetID]
        private(set) var days: [Date?]
        private var generator = SplitMix64(seed: 61)
        private let dayCount: Int

        init(photos: Int) {
            let dayCount = photos / GridBacklogMemoryTests.photosPerDay
            self.dayCount = dayCount
            ids = (0 ..< photos).map(GridBacklogMemoryTests.id)
            days = (0 ..< photos).map { GridBacklogMemoryTests.day(dayCount - $0 / GridBacklogMemoryTests.photosPerDay) }
        }

        /// The order after one photo's capture date arrived.
        mutating func readMovingOnePhoto() -> CatalogMediaGridState {
            let from = Int.random(in: 0 ..< ids.count, using: &generator)
            let day = GridBacklogMemoryTests.day(Int.random(in: 1 ... dayCount, using: &generator))
            let id = ids.remove(at: from)
            days.remove(at: from)
            // Days run newest first: the photo goes after the last one of its day.
            var low = 0
            var high = days.count
            while low < high {
                let middle = (low + high) / 2
                if let other = days[middle], other >= day {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            ids.insert(id, at: low)
            days.insert(day, at: low)
            return CatalogMediaGridState(descriptor: .default, orderedAssetIDs: ids, dayBuckets: days)
        }
    }

    private nonisolated static func id(_ index: Int) -> MediaAssetID {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Backlog"),
            relativePath: MediaRelativePath(rawValue: "b\(index).jpg")
        )
    }

    private nonisolated static func day(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 86400 * Double(index))
    }

    private static func detail(of id: MediaAssetID) -> MediaTileDetail {
        MediaTileDetail(
            libraryRootPath: id.libraryRootPath,
            relativePath: id.relativePath,
            thumbnailPath: "t-\(id.relativePath.rawValue)",
            bestKind: .image,
            renderedSourceSize: 100,
            renderedSourceMTimeSeconds: 1
        )
    }

    /// A 64 × 64 thumbnail of its own, as the small generated library's tiles decode.
    private static func thumbnail() -> DisplayImage {
        DisplayImage.fixture(width: 64)
    }

    private final class WeakContent {
        weak var content: CatalogGridContent?

        init(_ content: CatalogGridContent) {
            self.content = content
        }
    }

    /// What one run held at its end.
    private struct Census: CustomStringConvertible {
        var publications = 0
        var contentsAlive = 0
        var largestIndexEdit = 0
        var editFromShown = 0
        var tiles = 0
        var tileImageBytes = 0
        var offscreenLimit = 0
        var visible = 0
        var settledFootprint: UInt64 = 0
        var footprint: UInt64 = 0

        var description: String {
            "publications=\(publications) contentsAlive=\(contentsAlive) largestIndexEdit=\(largestIndexEdit) "
                + "editFromShown=\(editFromShown) tiles=\(tiles) tileImageMB=\(tileImageBytes / 1_048_576) "
                + "offscreenLimit=\(offscreenLimit) visible=\(visible) "
                + "settledFootprintMB=\(settledFootprint / 1_048_576) footprintMB=\(footprint / 1_048_576)"
        }
    }

    /// `publications` reads of a backlog over `photos` photos, published as the projection
    /// publishes them (`sharingContent(of:)`, each read's index the last one's carried through its edit). The
    /// grid applies every seventh and holds one order through the middle fifth of the run, as a
    /// scroll holds reorders; every `scrollEvery` publications it is scrolled a screen and a half
    /// on, pinning `visible` tiles and decoding them and two screens either way, a thumbnail of
    /// its own each, as the look-ahead does.
    private static func run(photos: Int, publications: Int, visible: Int, scrollEvery: Int) -> Census {
        var backlog = Backlog(photos: photos)
        let tiles = TileContentStore()
        var published = CatalogMediaGridState(descriptor: .default, orderedAssetIDs: backlog.ids, dayBuckets: backlog.days)
        published.content.prepareIndex()
        var shown = published
        let held = (publications * 2 / 5) ..< (publications * 3 / 5)
        var made: [WeakContent] = []
        var census = Census(publications: publications, visible: visible)
        var top = 0

        func scroll() {
            let order = published.orderedAssetIDs
            let visibleRange = top ..< min(order.count, top + visible)
            tiles.pinVisible(Set(order[visibleRange]))
            let lookahead = max(0, top - 2 * visible) ..< min(order.count, top + 3 * visible)
            for position in lookahead {
                let id = order[position]
                let detail = detail(of: id)
                tiles.mergeDetail(detail)
                if tiles.content(for: id)?.image == nil {
                    tiles.applyDecoded(thumbnail(), key: MediaAssetTilePresentation.imageContentKey(detail), for: id)
                }
            }
            top = (top + visible * 3 / 2) % max(1, order.count - visible)
        }

        scroll()
        for publication in 1 ... publications {
            published = backlog.readMovingOnePhoto().sharingContent(of: published)
            made.append(WeakContent(published.content))
            census.largestIndexEdit = max(census.largestIndexEdit, published.content.indexEditSize)
            if publication.isMultiple(of: 7), !held.contains(publication) {
                shown = published
            }
            if publication.isMultiple(of: scrollEvery) {
                scroll()
            }
            if publication == publications / 10 {
                census.settledFootprint = ProcessResourceSample.current().footprintBytes
            }
        }
        census.footprint = ProcessResourceSample.current().footprintBytes
        census.editFromShown = published.content.edit(from: shown.content)?.size ?? -1
        census.contentsAlive = made.count { $0.content != nil }
        census.tiles = tiles.count
        census.tileImageBytes = tiles.imageBytes
        census.offscreenLimit = tiles.offscreenLimit
        return census
    }

    // Validates: APP-015
    /// After a thousand backlog publications, scrolled to many places: the window holds the
    /// published order and the one the grid shows, an index's edit stays smaller than its order, and the
    /// tile store keeps the visible tiles and its off-screen limit, whatever the run's length.
    @Test func aBacklogOfPublicationsHoldsWhatTheWindowShows() {
        let census = Self.run(photos: 8000, publications: 1000, visible: 60, scrollEvery: 5)
        #expect(census.contentsAlive <= 3, "\(census)")
        #expect(census.largestIndexEdit < 8000, "an index's edit never outgrows its order: \(census)")
        #expect(census.editFromShown >= 0, "the grid follows from the order it shows: \(census)")
        #expect(census.tiles <= census.visible + census.offscreenLimit * 5 / 4, "\(census)")
        #expect(census.tiles >= census.visible + census.offscreenLimit, "the store keeps what it is designed to keep: \(census)")
    }

    /// The process footprint at the reference size: a 160,000-photo library, 1,500 backlog
    /// publications, scrolled to a hundred places, grows at most `footprintGrowthLimit` past the
    /// window it settled to.
    static let footprintGrowthLimit: UInt64 = 150 * 1_048_576

    @Test(.enabled(if: StallReproductionTests.referenceSize))
    func aBacklogAtTheReferenceSizeStaysWithinItsFootprint() throws {
        let census = Self.run(photos: 160_000, publications: 1500, visible: 90, scrollEvery: 15)
        let url = SourceTree.root.appending(path: "build/grid-backlog-memory/run.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((census.description + "\n").utf8).write(to: url)
        #expect(census.contentsAlive <= 3, "\(census)")
        #expect(census.tiles <= census.visible + census.offscreenLimit * 5 / 4, "\(census)")
        #expect(census.footprint <= census.settledFootprint + Self.footprintGrowthLimit, "\(census)")
    }
}
