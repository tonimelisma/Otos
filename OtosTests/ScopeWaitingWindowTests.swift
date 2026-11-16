import AppKit
@testable import OtosKit
import SwiftUI
import Testing

extension AppKitWindowTests {
    /// DES-118 in a real window: a sidebar click draws the selected surface waiting, its bar at
    /// the loaded bar's height, and the one centered indicator only once a frame has been
    /// presented without the scope's state. Each state is drawn in light and dark into
    /// `build/DesignEvidence/scope-waiting/` of the checkout that ran the test (DES-022), as the
    /// design check's screenshots: AppKit draws the spinner, which an `ImageRenderer` cannot.
    /// Beside each, the window's Tab stops (DES-080).
    @MainActor
    struct ScopeWaitingWindowTests {
        private nonisolated static let today = CalendarDay(year: 2026, month: 11, day: 15)

        private static func evidenceDirectory() -> URL {
            SourceTree.root.appending(path: "build/DesignEvidence/scope-waiting", directoryHint: .isDirectory)
        }

        @Test(arguments: [
            ("places", SidebarSelection.places),
            ("people", .people),
            ("duplicates", .duplicates),
            ("on-this-day", .onThisDay(Self.today)),
        ])
        func aClickedScopeWaitsWithOneIndicator(name: String, scope: SidebarSelection) async throws {
            let directory = Self.evidenceDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let model = Self.model()
                let window = Self.window(showing: model, appearance: appearance)
                defer { window.close() }
                let suffix = appearance == .darkAqua ? "dark" : "light"

                model.selectSidebar(scope)
                #expect(model.detailPane.content == .waiting(showsIndicator: false))
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(Self.indicators(in: window).isEmpty, "no indicator before a frame without the state")
                try Self.draw(window, to: directory.appending(path: "\(name)-waiting-\(suffix).png"))
                try Self.tabStops(in: window).joined(separator: "\n").write(
                    to: directory.appending(path: "\(name)-tab-\(suffix).txt"), atomically: true, encoding: .utf8
                )

                model.waitingFramePresented()
                let indicators = try await waitForValue {
                    window.contentView?.layoutSubtreeIfNeeded()
                    let found = Self.indicators(in: window)
                    return found.isEmpty ? nil : found
                }
                #expect(indicators.count == 1)
                #expect(indicators.allSatisfy { $0.style == .spinning && $0.isIndeterminate })
                try Self.draw(window, to: directory.appending(path: "\(name)-indicator-\(suffix).png"))
            }
        }

        /// DES-053 and DES-018 across waiting and loaded: each bar is one height, and On This
        /// Day's day title holds its place whether or not its summary has arrived.
        @Test func everyWaitingBarHoldsTheLoadedBarsHeightAndTitle() throws {
            func fitted(_ view: some View) -> NSHostingView<AnyView> {
                let host = NSHostingView(rootView: AnyView(view.frame(width: 900)))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                return host
            }
            #expect(fitted(PlacesMapBar(locatedCount: nil)).fittingSize.height == 52)
            #expect(fitted(PlacesMapBar(locatedCount: 100)).fittingSize.height == 52)
            #expect(fitted(PeopleBar(people: nil)).fittingSize.height == 52)
            let waitingDay = fitted(OnThisDayBar(day: Self.today, summary: ""))
            let loadedDay = fitted(OnThisDayBar(day: Self.today, summary: "24 photos and videos from 8 years"))
            #expect(waitingDay.fittingSize.height == 52)
            #expect(loadedDay.fittingSize.height == 52)
            #expect(
                try Self.firstInkRow(waitingDay) == Self.firstInkRow(loadedDay),
                "the day title moves when its summary arrives"
            )

            let loaded = DuplicatesBarPresentation(
                primaryLine: "10 copies go to the Trash · 203 KB",
                secondaryLine: "10 photos with duplicates",
                middle: .legend(DuplicatesBarPresentation.legend),
                actionTitle: "Move 10 Copies to Trash",
                actionEnabled: true
            )
            let actions = Self.duplicatesActions()
            let shown = fitted(DuplicatesStatusBar(presentation: loaded, actions: actions))
            let waiting = fitted(DuplicatesStatusBar(presentation: loaded.waiting, actions: actions).disabled(true))
            #expect(shown.fittingSize.height == waiting.fittingSize.height)
            #expect(loaded.waiting.actionTitle == loaded.actionTitle, "a disabled act keeps its title (DES-053)")
        }

        // MARK: - Support

        private static func model() -> CatalogWindowViewModel {
            let model = CatalogWindowViewModel(
                catalogStore: CatalogStore(location: .inMemory),
                enrichmentCoordinator: nil,
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            let pictures = LibraryRootPath(rawValue: "/Users/example/Pictures")
            let ids = (0 ..< 3).map {
                MediaAssetID(libraryRootPath: pictures, relativePath: MediaRelativePath(rawValue: "asset-\($0).jpg"))
            }
            model.applyState(CatalogWindowState(
                title: "Test",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(
                    descriptor: CatalogQueryDescriptor(scope: .allMedia),
                    orderedAssetIDs: ids,
                    dayBuckets: [],
                    stacks: .empty,
                    detailRefreshGeneration: 1
                ),
                filterOptions: .empty,
                resolvedSidebarSelection: .allMedia,
                mediaEmptyState: nil,
                deviceConnectionBanner: nil,
                queryGeneration: 0
            ).sharingUnchanged(with: nil))
            return model
        }

        /// The main window's content in a titled window with its toolbar, off screen.
        private static func window(showing model: CatalogWindowViewModel, appearance: NSAppearance.Name) -> NSWindow {
            let controller = NSHostingController(rootView: ContentView(viewModel: model))
            controller.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .resizable]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.setFrame(NSRect(x: -4000, y: -4000, width: 1100, height: 700), display: true)
            window.makeKeyAndOrderFront(nil)
            return window
        }

        private static func duplicatesActions() -> DuplicatesActions {
            DuplicatesActions(
                select: { _, _, _ in },
                keep: { _ in },
                setRule: { _, _ in },
                keepAll: { _ in },
                reviewAgain: { _ in },
                openGroup: {},
                openGroupContaining: { _ in },
                moveToTrashNow: { _ in },
                moveAll: {},
                undoMove: {},
                revealNeedingChoice: {}
            )
        }

        /// The progress indicators AppKit draws in the window.
        private static func indicators(in window: NSWindow) -> [NSProgressIndicator] {
            func collect(_ view: NSView) -> [NSProgressIndicator] {
                [view as? NSProgressIndicator].compactMap(\.self) + view.subviews.flatMap(collect)
            }
            return window.contentView.map(collect) ?? []
        }

        /// The responders Tab reaches from the window's first, until one comes round again.
        private static func tabStops(in window: NSWindow) -> [String] {
            var stops: [String] = []
            var seen = Set<ObjectIdentifier>()
            for _ in 0 ..< 40 {
                window.selectNextKeyView(nil)
                guard let responder = window.firstResponder else {
                    break
                }
                stops.append(String(describing: type(of: responder)))
                if !seen.insert(ObjectIdentifier(responder)).inserted {
                    break
                }
            }
            return stops
        }

        /// The window as it composes itself, title bar and toolbar included.
        private static func draw(_ window: NSWindow, to url: URL) throws {
            let view = try #require(window.contentView?.superview ?? window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }

        /// The first pixel row, from the top, in the bar's leading pixels that differs from its
        /// top-left pixel: where the title's ink starts.
        private static func firstInkRow(_ host: NSView) throws -> Int {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let background = try #require(bitmap.colorAt(x: 0, y: 0))
            for row in 0 ..< bitmap.pixelsHigh {
                for column in 0 ..< min(bitmap.pixelsWide, 600) {
                    if let color = bitmap.colorAt(x: column, y: row), color != background {
                        return row
                    }
                }
            }
            return -1
        }
    }
}
