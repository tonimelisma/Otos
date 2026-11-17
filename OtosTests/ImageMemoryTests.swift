import AppKit
import Foundation
import ImageIO
@testable import OtosKit
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers

/// Stored previews shaped like the owner's (ADR 0035): 2560 × 1920 8-bit Display P3 HEICs a
/// few hundred kilobytes each, about 20 MB each decoded, drawn here as overlapping ellipses so
/// they encode like photographs rather than flat colour.
nonisolated enum ImageMemoryFixture {
    static let width = 2560
    static let height = 1920

    /// Writes `count` previews into `directory` and returns their names.
    static func writePreviews(count: Int, width: Int = Self.width, height: Int = Self.height, in directory: URL) throws -> [String] {
        var generator = SplitMix64(seed: 11)
        func unit() -> CGFloat {
            CGFloat(generator.next() % 10000) / 10000
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        return try (0 ..< count).map { index in
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.setFillColor(red: unit(), green: unit(), blue: unit(), alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for _ in 0 ..< 400 {
                context.setFillColor(red: unit(), green: unit(), blue: unit(), alpha: 0.6)
                let edge = 40 + unit() * 500
                context.fillEllipse(in: CGRect(x: unit() * CGFloat(width), y: unit() * CGFloat(height), width: edge, height: edge * (0.5 + unit())))
            }
            let image = try #require(context.makeImage())
            let name = "preview-\(index).heic"
            let destination = try #require(CGImageDestinationCreateWithURL(
                directory.appending(path: name) as CFURL, UTType.heic.identifier as CFString, 1, nil
            ))
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            return name
        }
    }

    /// `count` people, each covered by a small face (3 to 8 % of the photo's width, as in the
    /// owner's group photos) on one of `previews`.
    static func people(count: Int, previews: [String]) -> CatalogPeopleState {
        let people = (0 ..< count).map { index in
            let photo = PeopleGalleryFixture.asset(index)
            let side = 0.03 + Double(index % 6) * 0.01
            let cover = FaceTile(
                id: FaceID(asset: photo, index: 0),
                box: CGRect(x: 0.2 + Double(index % 5) * 0.12, y: 0.3, width: side, height: side * 4 / 3),
                preview: FacePreview(name: previews[index % previews.count], recipe: .neutral),
                captureSeconds: nil
            )
            return PersonSummary(
                id: PersonID(rawValue: Int64(index + 1)), name: "Person \(index)", birthday: nil, isHidden: false,
                isFavorite: false, media: MediaCount(photos: count - index), cover: cover, userFaces: [], anchorMedia: [:]
            )
        }
        return CatalogPeopleState(people: people.sorted(by: CatalogPeopleState.galleryOrder), unchecked: MediaCount(photos: 0), hasFaces: true)
    }

    static func footprintMB() -> Int {
        Int(ProcessResourceSample.current().footprintBytes / 1_048_576)
    }

    /// The image-bearing rows of `vmmap --summary` of this process: which regions hold the
    /// footprint, by name, dirty and swapped size.
    static func regions() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["--summary", "\(getpid())"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "  vmmap unavailable: \(error)"
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let names = ["CG ", "CoreAnimation", "IOSurface", "IOAccelerator", "ImageIO", "MALLOC", "VM_ALLOCATE", "TOTAL", "Physical footprint"]
        return String(decoding: output, as: UTF8.self).split(separator: "\n")
            .filter { line in names.contains { line.hasPrefix($0) } }
            .map { "  " + $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// The dirty size in MB of the `vmmap --summary` row named `name` in `regions`, 0 when the
    /// process has no such region.
    static func dirtyMB(_ name: String, in regions: String) -> Double {
        guard let line = regions.split(separator: "\n").first(where: { $0.hasPrefix("  " + name + " ") }) else {
            return 0
        }
        // Virtual, resident, then dirty: the third size after the name.
        let sizes = line.dropFirst(2 + name.count).split(separator: " ")
        guard sizes.count >= 3, let unit = sizes[2].last, let value = Double(sizes[2].dropLast()) else {
            return 0
        }
        switch unit {
        case "K": return value / 1024
        case "M": return value
        case "G": return value * 1024
        default: return value / 1_048_576
        }
    }

    /// Appends `line` to `build/measurements/image-memory.log` in the checkout: the test host's
    /// standard output reaches no log.
    static func record(_ line: String) {
        let file = SourceTree.root.appending(path: "build/measurements/image-memory.log")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}

/// The loader the window uses, handed each photo's catalog row as a catalog would join it: the
/// test's in-memory store has no rows, and the stored preview is what the tour's photos show.
nonisolated struct StoredPreviewLoader: PreviewLoading {
    let loader: PreviewImageLoader
    let details: [MediaAssetID: MediaTileDetail]

    func preview(for request: PreviewImageLoader.Request) async -> PreviewImageLoader.Outcome {
        await loader.preview(for: .init(id: request.id, detail: details[request.id], targetLongEdge: request.targetLongEdge))
    }

    func quiesce(under root: LibraryRootPath) async {
        await loader.quiesce(under: root)
    }

    func resume(under root: LibraryRootPath) async {
        await loader.resume(under: root)
    }

    func releaseHeldPhotos() {
        loader.releaseHeldPhotos()
    }
}

/// The highest footprint between two reads, sampled every millisecond on a thread of its own:
/// a decode's transient lives for tens of milliseconds, between the steps' own samples.
final nonisolated class FootprintPeak: Sendable {
    private let state = Mutex<(running: Bool, peak: UInt64)>((false, 0))

    func start() {
        state.withLock { $0.running = true }
        Thread.detachNewThread { [self] in
            while state.withLock({ $0.running }) {
                let now = ProcessResourceSample.current().footprintBytes
                state.withLock { $0.peak = max($0.peak, now) }
                // time: measurement — a footprint sample's cadence; nothing reports a peak
                usleep(1000)
            }
        }
    }

    func stop() {
        state.withLock { $0.running = false }
    }

    /// The peak since the last read, in MB; the next read starts from now.
    func takeMB() -> Int {
        state.withLock { value in
            defer { value.peak = 0 }
            return Int(value.peak / 1_048_576)
        }
    }
}

extension AppKitWindowTests {
    /// What the window's image surfaces hold while they are used, measured as the kernel
    /// charges the process (`phys_footprint`). On demand and alone
    /// (`OTOS_SCALE_TEST=1 script/check.sh --only AppKitWindowTests/ImageMemoryTests`): a footprint is the whole
    /// process's, so a test running beside it would be counted too.
    @MainActor
    @Suite(.testScope, .enabled(if: ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"))
    struct ImageMemoryTests {
        /// The People gallery's tiles in a Retina window: what a screenful costs, and that a
        /// tile holds only its own pixels however small its face is on the preview.
        @Test func thePeopleGalleryHoldsOnlyItsTiles() async throws {
            let directory = try makeTestDirectory()
            let previews = try ImageMemoryFixture.writePreviews(count: 24, in: directory)
            let people = ImageMemoryFixture.people(count: 200, previews: previews)
            let model = CatalogWindowViewModel(
                catalogStore: makeTestStore(
                    location: .databaseFile(directory.appending(path: "Catalog.sqlite")),
                    stagingContainers: StagingContainers(base: directory)
                ),
                catalogProjection: CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10)),
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            let start = ImageMemoryFixture.footprintMB()
            let startRegions = ImageMemoryFixture.regions()
            ImageMemoryFixture.record("op=imageMemory step=peopleGallery.start footprintMB=\(start)\n" + startRegions)
            PeopleGalleryFixture.show(people, in: model)
            let host = NSHostingView(rootView: PeopleView(
                people: people, session: model.peopleSession, librariesState: nil, images: model.faceTileImages,
                derivedImageDirectory: directory, actions: model.peopleActions
            ).environment(\.displayScale, 2))
            let window = orderedInTestWindow(width: 1200, height: 800, contentView: host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            // The first rows of the gallery: every cell a 1200 × 800 window shows.
            let shown = people.visiblePeople.prefix(24).compactMap(\.cover)
            let keys = shown.compactMap { tile in tile.preview.map { FaceTileImages.Key(face: tile.id, box: tile.box, preview: $0) } }
            try await waitUntil {
                keys.allSatisfy { model.faceTileImages.image(for: $0) != nil }
            }
            host.displayIfNeeded()
            CATransaction.flush()
            await drainMainQueue()
            let painted = ImageMemoryFixture.footprintMB()
            let paintedRegions = ImageMemoryFixture.regions()
            let tiles = keys.compactMap { model.faceTileImages.image(for: $0) }
            ImageMemoryFixture.record(
                "op=imageMemory step=peopleGallery startMB=\(start) paintedMB=\(painted) tiles=\(tiles.count) "
                    + "tile=\(tiles.first.map { "\($0.width)x\($0.height)" } ?? "-")\n" + paintedRegions
            )
            // A tile is 256 px at most on a Retina display, 256 KB, its rows padded to the
            // surface's 64-byte alignment at most; a screenful a few MB, with the window, its
            // views and the decodes' transients well inside the bound.
            #expect(tiles.allSatisfy { tile in
                tile.width <= 256 && tile.height <= 256 && tile.bytesPerRow <= (tile.width * 4 + 63) / 64 * 64
            })
            // Shown without a display copy: Core Animation's region does not grow by the tiles.
            let copies = ImageMemoryFixture.dirtyMB("CoreAnimation", in: paintedRegions) - ImageMemoryFixture.dirtyMB("CoreAnimation", in: startRegions)
            #expect(copies <= Self.displayCopiesBoundMB, "Core Animation grew \(copies) MB")
            #expect(painted - start <= Self.galleryBoundMB, "People gallery: \(start) MB → \(painted) MB")
        }

        /// What a screenful of the People gallery may add to the footprint.
        static let galleryBoundMB = 64

        /// The full-size view walked as the owner walks it: ten photos opened one after the
        /// other, then a step back. The pane holds the photo it shows and the loader what a
        /// pane can return to, so the footprint holds a few previews however many were seen.
        @Test func theFullSizeViewHoldsOnlyWhatItCanReturnTo() async throws {
            let directory = try makeTestDirectory()
            let previews = try ImageMemoryFixture.writePreviews(count: 10, in: directory)
            let root = LibraryRootPath(rawValue: directory.path(percentEncoded: false))
            let loader = PreviewImageLoader(
                status: { _ in .dataless },
                derivedImageDirectory: directory,
                materializationRequester: ClosureMaterializationRequester(status: { _ in .dataless }) { _ in
                    MaterializationResult(outcome: .timedOut, rerequestCount: 0, elapsedMs: 0)
                }
            )
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let probe = try #require(CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ))
            func show(_ index: Int) async throws -> CGImage {
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "photo-\(index).heic"))
                let detail = MediaTileDetail(
                    libraryRootPath: root, relativePath: id.relativePath, previewPath: previews[index],
                    nativePixelWidth: 6000, nativePixelHeight: 4500, bestKind: .image
                )
                guard case let .image(image, _) = await loader.preview(for: .init(id: id, detail: detail, targetLongEdge: 2560)) else {
                    throw ImageMemoryError.noImage
                }
                // Painting reads every pixel, as the pane's layer does.
                probe.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 48))
                return image
            }
            let start = ImageMemoryFixture.footprintMB()
            var shown = try await show(0)
            for index in 1 ..< previews.count {
                shown = try await show(index)
            }
            shown = try await show(previews.count - 2)
            let walked = ImageMemoryFixture.footprintMB()
            let previewMB = shown.bytesPerRow * shown.height / 1_048_576
            ImageMemoryFixture.record(
                "op=imageMemory step=fullSizeView startMB=\(start) walkedMB=\(walked) previewMB=\(previewMB) photos=\(previews.count)"
            )
            // The photo shown and the ones the loader holds to return to, and a margin for
            // the decodes' transients; ten held previews would be twice the bound.
            let bound = (PreviewImageLoader.retainedPhotos + 1) * previewMB + 16
            #expect(walked - start <= bound, "Full-size view: \(start) MB → \(walked) MB, bound \(bound) MB")
        }

        /// The tour's photo steps in the main window at the owner's screen size: open, next ×3,
        /// previous ×3, Compare of the first two, back to the grid. Each step waits until the
        /// pane holds its photo and the window has drawn it, as the tour does.
        @Test func theTourPhotoStepsInTheWindow() async throws {
            let directory = try makeTestDirectory()
            let previews = try ImageMemoryFixture.writePreviews(count: 8, width: 2160, height: 1440, in: directory)
            let root = LibraryRootPath(rawValue: directory.path(percentEncoded: false))
            let ids = previews.indices.map {
                MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "photo-\($0).heic"))
            }
            var details: [MediaAssetID: MediaTileDetail] = [:]
            for (index, id) in ids.enumerated() {
                details[id] = MediaTileDetail(
                    libraryRootPath: root, relativePath: id.relativePath, previewPath: previews[index],
                    nativePixelWidth: 6000, nativePixelHeight: 4500, bestKind: .image
                )
            }
            let loader = StoredPreviewLoader(
                loader: PreviewImageLoader(
                    status: { _ in .dataless },
                    derivedImageDirectory: directory,
                    materializationRequester: ClosureMaterializationRequester(status: { _ in .dataless }) { _ in
                        MaterializationResult(outcome: .timedOut, rerequestCount: 0, elapsedMs: 0)
                    }
                ),
                details: details
            )
            let model = CatalogWindowViewModel(
                catalogStore: makeTestStore(location: .inMemory),
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                previewLoader: loader,
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
            let peak = FootprintPeak()
            func settle() async {
                await drainMainQueue()
                window.displayIfNeeded()
                CATransaction.flush()
                await drainMainQueue()
            }
            var highest = 0
            func sample(_ step: String) async -> Int {
                await settle()
                let now = ImageMemoryFixture.footprintMB()
                let stepPeak = peak.takeMB()
                highest = max(highest, stepPeak, now)
                let held = model.panePreviews.values.map { "\($0.image.width)x\($0.image.height)" }.joined(separator: ",")
                ImageMemoryFixture.record(
                    "op=imageMemory step=tour.\(step) footprintMB=\(now) peakMB=\(stepPeak) scale=\(window.backingScaleFactor) "
                        + "panes=\(held)\n" + ImageMemoryFixture.regions()
                )
                return now
            }
            func shows(_ slot: PaneSlot, _ id: MediaAssetID) async throws {
                let asked = ContinuousClock.now
                try await waitUntil(every: .milliseconds(1)) { model.panePreviews[slot]?.id == id }
                ImageMemoryFixture.record("op=imageMemory step=tour.shown slot=\(slot) ms=\(DiagnosticsTiming.milliseconds(ContinuousClock.now - asked))")
            }
            // One visit first, so the footprint compared against has paid what the first one
            // pays once (the views, the decoder) and the previews' encoder has let go: the
            // measure is what this walk holds, and what leaving it gives back.
            model.openLoupe(id: ids[7])
            try await shows(.loupe, ids[7])
            model.exitToGrid()
            await settle()
            // time: measurement — writing the previews leaves encoder memory that is let go
            // shortly after; the footprint compared against is read once it has gone.
            try await Task.sleep(for: .seconds(1))
            peak.start()
            defer { peak.stop() }
            let before = await sample("start")
            highest = before
            model.openLoupe(id: ids[0])
            try await shows(.loupe, ids[0])
            _ = await sample("open")
            for index in 1 ... 3 {
                model.focusNext()
                try await shows(.loupe, ids[index])
                _ = await sample("next\(index)")
            }
            for index in stride(from: 2, through: 0, by: -1) {
                model.focusPrevious()
                try await shows(.loupe, ids[index])
                _ = await sample("previous\(index)")
            }
            model.exitToGrid()
            model.selectAssets([ids[0], ids[1]])
            model.enterCompare()
            try await shows(.compareLeft, ids[0])
            try await shows(.compareRight, ids[1])
            _ = await sample("compare")
            model.exitToGrid()
            let left = await sample("grid")
            ImageMemoryFixture.record(
                "op=imageMemory step=tour.summary beforeMB=\(before) peakAddedMB=\(highest - before) leftAddedMB=\(left - before) "
                    + "held=\(loader.loader.heldPhotos.count)"
            )
            // Three photos held to return to and one decode in flight, each once: a 2160 × 1440
            // preview is about 6 MB as Image I/O decodes it whole, so the walk stays well inside
            // the bound; a display copy beside each would not.
            #expect(highest - before <= Self.photoStepsBoundMB, "photo steps: \(before) MB → peak \(highest) MB")
            // Leaving lets go of every photo Otos holds. One decode's IOSurface (6 MB here)
            // outlives the panes in this off-screen window although no image Otos made is
            // left (`2026-11-16-full-size-view-memory.md` §3); three held photos would be
            // three times the bound.
            #expect(left - before <= Self.leftBoundMB, "after leaving: \(before) MB → \(left) MB")
            #expect(loader.loader.heldPhotos == (0, 0))
        }

        /// What the tour's photo steps may add at their peak, and what may stay once the
        /// full-size view is left.
        static let photoStepsBoundMB = 100
        static let leftBoundMB = 20

        /// The grid at the owner's window size, as the tour shows it: All Media of a generated
        /// catalog of the owner's shape, its stored thumbnails 256 px JPEGs, first a screenful,
        /// then scrolled 900 tiles down in three steps, each step waiting until every visible
        /// tile shows its thumbnail. Each tile's image is held once: the tile store holds it,
        /// the tile's layer shows that same image, and Core Animation keeps no copy of it.
        @Test func theGridHoldsEachThumbnailOnce() async throws {
            let directory = try makeTestDirectory()
            let catalog = try OwnerShapedCatalog.make(in: directory, scale: 0.02)
            let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
            try await store.start(scansSavedLibraries: false)
            let thumbnails = try #require(store.thumbnailDirectory)
            let projection = CatalogProjection(
                volumeCapacity: ampleVolumeCapacity,
                cadence: .milliseconds(25), backgroundOwners: BackgroundOwners(off: Set(BackgroundOwner.allCases))
            )
            let stream = await projection.states(store: store, initialDescriptor: .default)
            let draining = Task {
                for await _ in stream {}
            }
            try await waitUntil {
                guard await projection.isQuiescent, let state = await projection.lastPublishedState else { return false }
                return state.resolvedSidebarSelection == .allMedia && !state.mediaGrid.orderedAssetIDs.isEmpty
            }
            let published = try #require(await projection.lastPublishedState)
            draining.cancel()
            let order = published.mediaGrid.orderedAssetIDs
            let written = try await Self.writeThumbnails(for: Array(order.prefix(1300)), store: store, in: thumbnails)

            let model = CatalogWindowViewModel(
                catalogStore: store,
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            model.applyState(CatalogWindowState(
                title: "Test", libraries: [], removableSources: [],
                mediaGrid: CatalogMediaGridState(
                    descriptor: CatalogQueryDescriptor(scope: .allMedia), orderedAssetIDs: [], dayBuckets: [],
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
            await settle()
            // time: measurement — writing the thumbnails leaves encoder memory that is let go
            // shortly after; the footprint compared against is read once it has gone.
            try await Task.sleep(for: .seconds(1))
            await settle()
            let empty = ImageMemoryFixture.footprintMB()
            let emptyRegions = ImageMemoryFixture.regions()
            ImageMemoryFixture.record("op=imageMemory step=grid.empty footprintMB=\(empty) scale=\(window.backingScaleFactor)\n" + emptyRegions)

            model.applyState(published.sharingUnchanged(with: model.state))
            func shown(_ step: String, target: MediaAssetID?) async throws -> (footprint: Int, regions: String) {
                if let target {
                    let before = model.lastVisibleThumbnails?.revision ?? 0
                    model.setFocus(target)
                    try await waitUntil {
                        guard let report = model.lastVisibleThumbnails, report.ids.contains(target) else { return false }
                        return report.revision > before || model.tileContentStore.settledVisible == report
                    }
                } else {
                    try await waitUntil { model.lastVisibleThumbnails.map { $0.visible > 0 } ?? false }
                }
                await settle()
                let report = try #require(model.lastVisibleThumbnails)
                let footprint = ImageMemoryFixture.footprintMB()
                let regions = ImageMemoryFixture.regions()
                let tiles = try Self.shownTiles(in: window)
                let held = tiles.compactMap { model.tileContentStore.content(for: $0.id)?.image }
                ImageMemoryFixture.record(
                    "op=imageMemory step=grid.\(step) footprintMB=\(footprint) visible=\(report.visible) "
                        + "withoutThumbnail=\(report.withoutThumbnail) thumbnailsMs=\(report.milliseconds) "
                        + "shownTiles=\(tiles.count) storeImages=\(model.tileContentStore.count) "
                        + "storeImageMB=\(model.tileContentStore.imageBytes / 1_048_576) "
                        + "tile=\(tiles.first.map { "\(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))" } ?? "-") "
                        + "image=\(held.first.map { "\($0.width)x\($0.height)" } ?? "-")\n" + regions
                )
                #expect(report.withoutThumbnail == 0, "\(step): \(report.withoutThumbnail) tiles without a thumbnail")
                // One image a tile: the layer shows the very image the tile store holds, and it is
                // the stored thumbnail at its own size, no larger than the tile shows it.
                for tile in tiles {
                    let image = try #require(tile.image, "\(step): a shown tile has no image")
                    #expect(image === model.tileContentStore.content(for: tile.id)?.image, "\(step): the layer shows another image")
                    #expect(max(image.width, image.height) <= ThumbnailStore.maxPixelSize)
                }
                return (footprint, regions)
            }
            let screenful = try await shown("screenful", target: nil)
            for step in 1 ... 3 {
                _ = try await shown("scrolled\(step * 300)", target: order[min(step * 300, written - 1)])
            }
            let scrolled = try await shown("scrolled900.settled", target: order[min(900, written - 1)])
            ImageMemoryFixture.record(
                "op=imageMemory step=grid.summary emptyMB=\(empty) screenfulAddedMB=\(screenful.footprint - empty) "
                    + "scrolledAddedMB=\(scrolled.footprint - empty)"
            )
            // Core Animation keeps no display copy of a tile: its region does not grow by a
            // tile's worth however many tiles were shown (a copy each was 56 MB for 300 tiles).
            let copies = ImageMemoryFixture.dirtyMB("CoreAnimation", in: scrolled.regions) - ImageMemoryFixture.dirtyMB("CoreAnimation", in: emptyRegions)
            #expect(copies <= Self.displayCopiesBoundMB, "Core Animation grew \(copies) MB")
            #expect(screenful.footprint - empty <= Self.gridScreenfulBoundMB, "grid screenful: \(empty) MB → \(screenful.footprint) MB")
            #expect(scrolled.footprint - empty <= Self.gridScrolledBoundMB, "grid scrolled: \(empty) MB → \(scrolled.footprint) MB")
            await store.shutdown()
        }

        /// What a screenful of the grid may add above the empty window, what 900 tiles scrolled
        /// may, and how much Core Animation's own region may grow across them.
        static let gridScreenfulBoundMB = 24
        static let gridScrolledBoundMB = 48
        static let displayCopiesBoundMB = 8.0

        /// Writes a 256 px JPEG, as `ThumbnailStore` stores one, at each of `ids`' thumbnail
        /// names, and returns how many it wrote.
        private static func writeThumbnails(for ids: [MediaAssetID], store: CatalogStore, in directory: URL) async throws -> Int {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let details = try await store.windowReads.mediaTileDetails(for: ids)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            var generator = SplitMix64(seed: 5)
            var written = 0
            for id in ids {
                guard let name = details[id]?.thumbnailPath else { continue }
                let portrait = generator.next() % 4 == 0
                let (width, height) = portrait ? (192, 256) : (256, 192)
                let context = try #require(CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ))
                func unit() -> CGFloat {
                    CGFloat(generator.next() % 10000) / 10000
                }
                context.setFillColor(red: unit(), green: unit(), blue: unit(), alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                for _ in 0 ..< 40 {
                    context.setFillColor(red: unit(), green: unit(), blue: unit(), alpha: 0.6)
                    let edge = 8 + unit() * 80
                    context.fillEllipse(in: CGRect(x: unit() * CGFloat(width), y: unit() * CGFloat(height), width: edge, height: edge))
                }
                let image = try #require(context.makeImage())
                let destination = try #require(CGImageDestinationCreateWithURL(
                    ThumbnailStore.url(for: name, in: directory) as CFURL, UTType.jpeg.identifier as CFString, 1, nil
                ))
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                #expect(CGImageDestinationFinalize(destination))
                written += 1
            }
            return written
        }

        /// The grid's tiles in `window` whose frames are on screen, each with the image its
        /// thumbnail layer shows and its size in backing pixels.
        private static func shownTiles(in window: NSWindow) throws -> [(id: MediaAssetID, image: CGImage?, pixelSize: CGSize)] {
            let content = try #require(window.contentView)
            let collection = try #require(Self.collectionView(in: content))
            let controller = try #require(collection.dataSource as? MediaGridViewController)
            let visible = collection.visibleRect
            let scale = window.backingScaleFactor
            return collection.visibleItems().compactMap { item in
                guard let indexPath = collection.indexPath(for: item), let id = controller.structure.id(at: indexPath),
                      let tile = item.view as? MediaAssetTileView, item.view.frame.intersects(visible)
                else { return nil }
                let size = item.view.frame.size
                return (id, tile.displayedThumbnail, CGSize(width: size.width * scale, height: size.height * scale))
            }
        }

        private static func collectionView(in view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView {
                return collection
            }
            for subview in view.subviews {
                if let found = collectionView(in: subview) {
                    return found
                }
            }
            return nil
        }

        private enum ImageMemoryError: Error {
            case noImage
        }
    }
}
