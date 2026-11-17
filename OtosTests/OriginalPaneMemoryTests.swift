import AppKit
import Foundation
import ImageIO
@testable import OtosKit
import SwiftUI
import Testing

extension AppKitWindowTests {
    /// The full-size view on a new library: originals from a person's cameras with no stored
    /// preview yet, so every pane decodes an original, while the first enrichment renders the
    /// same files on the background lane. On demand and alone
    /// (`OTOS_SCALE_TEST=1 script/check.sh --only AppKitWindowTests/OriginalPaneMemoryTests`).
    @MainActor
    @Suite(.testScope, .serialized, .enabled(if: ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"))
    struct OriginalPaneMemoryTests {
        /// One pane decode of each camera's original, alone: its peak above its start.
        @Test func eachCamerasOriginalDecodedForThePane() async throws {
            let directory = try makeTestDirectory()
            let root = LibraryRootPath(rawValue: directory.path(percentEncoded: false))
            for (index, camera) in FirstLaunchFootprintTests.cameras.enumerated() {
                let name = "alone-\(index).\(camera.ext)"
                try FirstLaunchFootprintTests.writePhoto(
                    to: directory.appending(path: name), width: camera.width, height: camera.height, type: camera.type, seed: index
                )
                for edge in [CatalogWindowViewModel.previewTargetLongEdge(), ThumbnailStore.previewMaxPixelSize] {
                    let loader = Self.loader(directory)
                    let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: name))
                    let detail = Self.detail(id, camera)
                    var shown = "-"
                    let start = ContinuousClock.now
                    let peak = try await FirstLaunchFootprintTests.peakMB {
                        if case let .image(image, _) = await loader.preview(for: .init(id: id, detail: detail, targetLongEdge: edge)) {
                            shown = "\(image.width)x\(image.height)"
                        }
                    }
                    ImageMemoryFixture.record(
                        "op=paneMemory step=originalAlone camera=\(camera.width)x\(camera.height).\(camera.ext) edge=\(edge) "
                            + "shown=\(shown) ms=\(DiagnosticsTiming.milliseconds(since: start)) peakAboveStartMB=\(peak)"
                    )
                }
            }
        }

        /// What runs in a phase of the tour test.
        enum Phase: String {
            /// The first enrichment alone: every photo's preview rendered and staged.
            case enrichment
            /// The tour's photo steps with the first enrichment beside them.
            case both
            /// The tour's photo steps alone.
            case steps
        }

        /// The tour's photo steps on a new library's originals (open, next ×3, previous ×3,
        /// Compare of the first two), measured three ways on fresh libraries: the first
        /// enrichment alone, the steps with it, and the steps alone. Viewing never stacks on
        /// enrichment: the steps beside it add no more than the steps alone may.
        @Test func thePhotoStepsOnANewLibraryNeverStackOnEnrichment() async throws {
            let enrichment = try await Self.measure(.enrichment)
            let both = try await Self.measure(.both)
            let steps = try await Self.measure(.steps)
            ImageMemoryFixture.record(
                "op=paneMemory step=tour.summary enrichmentMB=\(enrichment) bothMB=\(both) stepsMB=\(steps)"
            )
            #expect(steps <= Self.photoStepsBoundMB, "photo steps alone: +\(steps) MB")
            #expect(both <= enrichment + Self.photoStepsBoundMB, "photo steps with enrichment: +\(both) MB, enrichment alone +\(enrichment) MB")
        }

        /// What the tour's photo steps on a new library's originals may add at their peak: the
        /// three photos held to return to and the one shown, about 20 MB each at 2,560 pixels,
        /// and the decode of the next, at most a 12 MP JPEG's, which decodes whole (110 MB).
        static let photoStepsBoundMB = 200

        /// The peak above the footprint before `phase` began, in MB.
        private static func measure(_ phase: Phase) async throws -> Int {
            let directory = try makeTestDirectory()
            let root = LibraryRootPath(rawValue: directory.path(percentEncoded: false))
            var ids: [MediaAssetID] = []
            var details: [MediaAssetID: MediaTileDetail] = [:]
            for index in 0 ..< 28 {
                let camera = FirstLaunchFootprintTests.cameras[index % FirstLaunchFootprintTests.cameras.count]
                let name = "photo-\(index).\(camera.ext)"
                try FirstLaunchFootprintTests.writePhoto(
                    to: directory.appending(path: name), width: camera.width, height: camera.height, type: camera.type, seed: index
                )
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: name))
                ids.append(id)
                details[id] = detail(id, camera)
            }
            let model = CatalogWindowViewModel(
                catalogStore: makeTestStore(location: .inMemory),
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                previewLoader: StoredPreviewLoader(loader: loader(directory), details: details),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            model.applyState(CatalogWindowState(
                title: "Test", libraries: [], removableSources: [],
                mediaGrid: CatalogMediaGridState(
                    descriptor: CatalogQueryDescriptor(scope: .allMedia), orderedAssetIDs: ids, dayBuckets: [],
                    stacks: .empty, detailRefreshGeneration: 1
                ),
                filterOptions: .empty, resolvedSidebarSelection: .allMedia, mediaEmptyState: nil,
                deviceConnectionBanner: nil, queryGeneration: 0
            ).sharingUnchanged(with: nil))
            let controller = NSHostingController(rootView: ContentView(viewModel: model))
            controller.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .resizable]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.setFrame(NSRect(x: -4000, y: -4000, width: 1512, height: 945), display: true)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            func settle() async {
                await drainMainQueue()
                window.displayIfNeeded()
                CATransaction.flush()
                await drainMainQueue()
            }
            let peak = FootprintPeak()
            peak.start()
            defer { peak.stop() }
            var highest = 0
            func sample(_ step: String, ms: Int) async {
                await settle()
                let now = ImageMemoryFixture.footprintMB()
                let stepPeak = peak.takeMB()
                highest = max(highest, stepPeak, now)
                let held = model.panePreviews.values.map { "\($0.image.width)x\($0.image.height)" }.joined(separator: ",")
                ImageMemoryFixture.record(
                    "op=paneMemory step=tour.\(phase.rawValue).\(step) ms=\(ms) footprintMB=\(now) peakMB=\(stepPeak) "
                        + "scale=\(window.backingScaleFactor) panes=\(held)\n" + ImageMemoryFixture.regions()
                )
            }
            func shows(_ slot: PaneSlot, _ id: MediaAssetID) async throws -> Int {
                let asked = ContinuousClock.now
                try await waitUntil(every: .milliseconds(1)) { model.panePreviews[slot]?.id == id }
                return DiagnosticsTiming.milliseconds(ContinuousClock.now - asked)
            }
            // One visit first, so the footprint compared against has paid what the first one
            // pays once (the views, the decoder).
            await settle()
            model.openLoupe(id: ids[27])
            _ = try await shows(.loupe, ids[27])
            model.exitToGrid()
            await settle()
            // time: measurement — writing the originals leaves encoder memory that is let go
            // shortly after; the footprint compared against is read once it has gone.
            try await Task.sleep(for: .seconds(1))
            let before = ImageMemoryFixture.footprintMB()
            _ = peak.takeMB()
            ImageMemoryFixture.record("op=paneMemory step=tour.\(phase.rawValue).start footprintMB=\(before)")
            let staging = directory.appending(path: "Staging", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let urls = ids.map(\.fileURL)
            let lane = Task.detached {
                if phase != .steps {
                    await Self.renderPreviews(urls, staging: staging)
                }
            }
            if phase != .enrichment {
                model.openLoupe(id: ids[0])
                try await sample("open", ms: shows(.loupe, ids[0]))
                for index in 1 ... 3 {
                    model.focusNext()
                    try await sample("next\(index)", ms: shows(.loupe, ids[index]))
                }
                for index in stride(from: 2, through: 0, by: -1) {
                    model.focusPrevious()
                    try await sample("previous\(index)", ms: shows(.loupe, ids[index]))
                }
                model.exitToGrid()
                model.selectAssets([ids[0], ids[1]])
                model.enterCompare()
                let left = try await shows(.compareLeft, ids[0])
                let right = try await shows(.compareRight, ids[1])
                await sample("compare", ms: max(left, right))
                model.exitToGrid()
            }
            await lane.value
            await sample("end", ms: 0)
            return highest - before
        }

        /// Every still's preview rendered and staged on the background lane, as many at once as
        /// it admits, as a new library's first enrichment asks.
        nonisolated static func renderPreviews(_ urls: [URL], staging: URL) async {
            await withTaskGroup(of: Void.self) { group in
                for (index, url) in urls.enumerated() {
                    group.addTask {
                        _ = try? await ImageRenderer.background.render(url, longEdge: ThumbnailStore.previewMaxPixelSize) { rendered in
                            (try? ThumbnailStore.stagePreview(rendered.image, finalRelativeName: "\(index).heic", in: staging)) != nil
                        }
                    }
                }
            }
        }

        nonisolated static func loader(_ directory: URL) -> PreviewImageLoader {
            PreviewImageLoader(
                status: { _ in .materialized },
                derivedImageDirectory: directory,
                materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in .testMaterialized }
            )
        }

        nonisolated static func detail(_ id: MediaAssetID, _ camera: FirstLaunchFootprintTests.Camera) -> MediaTileDetail {
            MediaTileDetail(
                libraryRootPath: id.libraryRootPath, relativePath: id.relativePath, previewPath: nil,
                nativePixelWidth: camera.width, nativePixelHeight: camera.height, bestKind: .image
            )
        }
    }
}
