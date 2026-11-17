import AppKit
@testable import OtosKit
import SwiftUI
import Testing

extension AppKitWindowTests {
    /// The tour's choice acts in a window nothing presents: the main window's content in an
    /// off-screen window, which AppKit reports occluded, as a covered window or one on a
    /// sleeping display is. Each act is still timed, to the main-actor render of its tile with
    /// the choice, and says the window could not present it; none is skipped.
    @MainActor
    struct SmokeTourActWindowTests {
        @Test func aChoiceActInAnOccludedWindowIsTimedToItsTilesRender() async throws {
            try await withCatalogedLibrary(fileCount: 6, fileNamePrefix: "act") { library in
                let model = CatalogWindowViewModel(
                    catalogStore: library.store,
                    startsStallMonitor: false,
                    startsEnrichment: false,
                    startsSourceMonitoring: false,
                    preferencesDomain: .suite(UUID().uuidString),
                    volumeCapacity: ampleVolumeCapacity,
                    trashFiles: .refusing
                )
                model.applyState(CatalogWindowState(
                    title: "Acts",
                    libraries: [],
                    removableSources: [],
                    mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: library.ids),
                    filterOptions: .empty,
                    resolvedSidebarSelection: .allMedia,
                    mediaEmptyState: nil,
                    deviceConnectionBanner: nil
                ))
                model.startMediaChoiceForwarding(writer: .store(library.store))
                defer { model.mediaChoiceForwardingTask?.cancel() }
                let window = Self.offScreenWindow(showing: model)
                defer { window.close() }
                try #require(!window.occlusionState.contains(.visible), "an off-screen window is occluded")

                let configuration = try #require(SmokeTour.Configuration(environment: [
                    SmokeTour.tourVariable: "1",
                    SmokeTour.deadlineVariable: "60",
                ]))
                let runner = SmokeTourRunner(viewModel: model, configuration: configuration, environment: [:], quit: {})
                var acted: [String] = []
                for index in 0 ..< 3 {
                    let (kind, label, outcome) = await runner.choiceAct(index)
                    #expect(kind == "act")
                    #expect(outcome.result == "reported", "act \(index) \(label): \(outcome.result) \(outcome.fields)")
                    #expect(outcome.fields["window"] == "occluded")
                    #expect(outcome.fields["surface"] == "grid")
                    #expect(Int(outcome.fields["resultMs"] ?? "") != nil)
                    acted.append(label)
                }
                // Each choice in turn after the tile's own, the last putting it back.
                #expect(acted == SmokeTour.choiceCycle(after: .notRated).map { WindowAct.choice($0).name })
                #expect(model.lastActResult?.window == .occluded)
                try await waitUntil { model.hasSettledMediaChoices }
                let reads = try await library.store.windowReads.mediaAssets(for: library.ids)
                #expect(library.ids.allSatisfy { reads[$0]?.mediaChoice == .notRated }, "every choice is as it was")
            }
        }

        /// The main window's content in a titled window off screen.
        private static func offScreenWindow(showing model: CatalogWindowViewModel) -> NSWindow {
            let controller = NSHostingController(rootView: ContentView(viewModel: model))
            controller.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .resizable]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.setFrame(NSRect(x: -4000, y: -4000, width: 1100, height: 700), display: true)
            window.makeKeyAndOrderFront(nil)
            return window
        }
    }
}
