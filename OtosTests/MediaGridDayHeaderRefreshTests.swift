import AppKit
@testable import OtosKit
import Testing

extension AppKitWindowTests {
    /// DES-069 / APP-030: a day header on screen draws the day of the section it is in
    /// now, not the one it was made for. A diffable apply keeps the header view of every
    /// section whose day survives, however far that section moves, so these drive real
    /// applies through the controller and read the header AppKit actually shows.
    @MainActor
    struct MediaGridDayHeaderRefreshTests {
        /// The import case: the oldest day lands first, as the top section, so its
        /// header is drawn blank; a newer day then lands above it.
        @Test func aHeaderThatWasTheFirstSectionDrawsItsDayOnceANewerDayLandsAbove() async throws {
            let harness = DayHeaderHarness()
            let older = harness.ids(prefix: "older", count: 4)
            let newer = harness.ids(prefix: "newer", count: 2)

            try await harness.apply(older.map { ($0, DayHeaderHarness.olderDay) })
            try await harness.apply(
                newer.map { ($0, DayHeaderHarness.newerDay) }
                    + older.map { ($0, DayHeaderHarness.olderDay) }
            )

            #expect(harness.header(section: 0) == nil)
            #expect(harness.header(section: 1) == .map(date: DayHeaderHarness.olderDay, itemCount: 4))
        }

        @Test func aHeaderOnScreenDrawsTheCountItsDayHasNow() async throws {
            let harness = DayHeaderHarness()
            let newer = harness.ids(prefix: "newer", count: 2)
            let older = harness.ids(prefix: "older", count: 4)

            try await harness.apply(
                newer.map { ($0, DayHeaderHarness.newerDay) }
                    + older.prefix(2).map { ($0, DayHeaderHarness.olderDay) }
            )
            #expect(harness.header(section: 1) == .map(date: DayHeaderHarness.olderDay, itemCount: 2))

            try await harness.apply(
                newer.map { ($0, DayHeaderHarness.newerDay) }
                    + older.map { ($0, DayHeaderHarness.olderDay) }
            )
            #expect(harness.header(section: 1) == .map(date: DayHeaderHarness.olderDay, itemCount: 4))
        }

        /// DES-069: the header and the bar are one label drawn twice, identical in height,
        /// and the blank first header still reserves that height, so no row moves.
        @Test func everyHeaderIsTheBarsHeight() async throws {
            let harness = DayHeaderHarness()
            let newer = harness.ids(prefix: "newer", count: 2)
            let older = harness.ids(prefix: "older", count: 4)
            try await harness.apply(
                newer.map { ($0, DayHeaderHarness.newerDay) } + older.map { ($0, DayHeaderHarness.olderDay) }
            )
            let layout = try #require(harness.controller.collectionView.collectionViewLayout)
            let heights = (0 ..< 2).compactMap {
                layout.layoutAttributesForSupplementaryView(
                    ofKind: MediaGridDayHeaderView.elementKind,
                    at: IndexPath(item: 0, section: $0)
                )?.frame.height
            }
            let barHeight = harness.controller.dayBar.frame.height
            #expect(barHeight > 0)
            #expect(heights == [barHeight, barHeight])
        }

        /// ARC-023: the structure is built off the main actor inside the one in-flight slot.
        /// Until the build lands nothing on screen changes, and a grid arriving meanwhile
        /// parks and is applied after it, never instead of it or alongside it.
        @Test func aGridArrivingWhileTheStructureBuildsIsAppliedAfterIt() async throws {
            let harness = DayHeaderHarness()
            let older = harness.ids(prefix: "older", count: 4)
            let newer = harness.ids(prefix: "newer", count: 2)
            let first = older.map { ($0, DayHeaderHarness.olderDay) }
            let second = newer.map { ($0, DayHeaderHarness.newerDay) } + first

            harness.receive(first)
            #expect(harness.controller.mutationGate.inFlight == .structuralApply)
            #expect(harness.controller.collectionView.numberOfSections == 0)
            let secondGrid = harness.receive(second)
            #expect(harness.controller.mutationGate.stallDiagnosticFields["pendingGrid"] == "true")

            try await awaitGridShows(harness.controller, secondGrid)
            let applied = harness.controller.structure
            #expect(applied.orderedIDs == second.map(\.0))
            #expect(harness.controller.collectionView.numberOfSections == 2)
            #expect(applied.sections.map(\.day) == [
                MediaGridDayBarPolicy.Day(date: DayHeaderHarness.newerDay, itemCount: 2),
                MediaGridDayBarPolicy.Day(date: DayHeaderHarness.olderDay, itemCount: 4),
            ])
        }
    }
}

@MainActor
private final class DayHeaderHarness {
    static let newerDay = Date(timeIntervalSince1970: 86400 * 10)
    static let olderDay = Date(timeIntervalSince1970: 86400 * 3)

    let controller: MediaGridViewController
    let window: NSWindow

    init() {
        controller = MediaGridViewController()
        _ = controller.view
        window = orderedInTestWindow(width: 800, height: 600, contentView: controller.view)
        controller.view.layoutSubtreeIfNeeded()
    }

    /// Closes the window deterministically; see `PaintInvariantHarness`.
    isolated deinit {
        window.close()
    }

    func ids(prefix: String, count: Int) -> [MediaAssetID] {
        (0 ..< count).map { index in
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "\(prefix)-\(index).jpg")
            )
        }
    }

    /// Hands the controller a grid of `entries` in order, each with its day bucket, as the
    /// view model does.
    @discardableResult
    func receive(_ entries: [(MediaAssetID, Date)]) -> CatalogMediaGridState {
        let grid = CatalogMediaGridState(
            scope: .allMedia,
            orderedAssetIDs: entries.map(\.0),
            dayBuckets: entries.map(\.1)
        )
        controller.receive(grid)
        return grid
    }

    /// One structural apply of `entries` through the controller's gate, then the layout
    /// pass that puts the result on screen.
    func apply(_ entries: [(MediaAssetID, Date)]) async throws {
        try await awaitGridShows(controller, receive(entries))
        controller.view.layoutSubtreeIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
    }

    /// What the header AppKit shows for `section` draws; `nil` is a blank header.
    func header(section: Int) -> MediaGridDayLabelPresentation? {
        let header = controller.collectionView.supplementaryView(
            forElementKind: MediaGridDayHeaderView.elementKind,
            at: IndexPath(item: 0, section: section)
        ) as? MediaGridDayHeaderView
        #expect(header != nil, "no header on screen for section \(section)")
        return header?.presentation
    }
}
