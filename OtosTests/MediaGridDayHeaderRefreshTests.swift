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
        @Test func aHeaderThatWasTheFirstSectionDrawsItsDayOnceANewerDayLandsAbove() {
            let harness = DayHeaderHarness()
            let older = harness.ids(prefix: "older", count: 4)
            let newer = harness.ids(prefix: "newer", count: 2)

            harness.apply(older.map { ($0, DayHeaderHarness.olderDay) })
            harness.apply(
                newer.map { ($0, DayHeaderHarness.newerDay) }
                    + older.map { ($0, DayHeaderHarness.olderDay) }
            )

            #expect(harness.header(section: 0) == nil)
            #expect(harness.header(section: 1) == .map(date: DayHeaderHarness.olderDay, itemCount: 4))
        }

        @Test func aHeaderOnScreenDrawsTheCountItsDayHasNow() {
            let harness = DayHeaderHarness()
            let newer = harness.ids(prefix: "newer", count: 2)
            let older = harness.ids(prefix: "older", count: 4)

            harness.apply(
                newer.map { ($0, DayHeaderHarness.newerDay) }
                    + older.prefix(2).map { ($0, DayHeaderHarness.olderDay) }
            )
            #expect(harness.header(section: 1) == .map(date: DayHeaderHarness.olderDay, itemCount: 2))

            harness.apply(
                newer.map { ($0, DayHeaderHarness.newerDay) }
                    + older.map { ($0, DayHeaderHarness.olderDay) }
            )
            #expect(harness.header(section: 1) == .map(date: DayHeaderHarness.olderDay, itemCount: 4))
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

    /// One structural apply of `entries` in order, each with its day bucket, then the
    /// layout pass that puts the result on screen.
    func apply(_ entries: [(MediaAssetID, Date)]) {
        controller.applyStructure(
            CatalogMediaGridState(
                scope: .allMedia,
                orderedAssetIDs: entries.map(\.0),
                dayBuckets: entries.map(\.1)
            ),
            change: .unchanged
        )
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
