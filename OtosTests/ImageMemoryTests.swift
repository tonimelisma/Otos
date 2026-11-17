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
                catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            let start = ImageMemoryFixture.footprintMB()
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
            let painted = ImageMemoryFixture.footprintMB()
            let tiles = keys.compactMap { model.faceTileImages.image(for: $0) }
            ImageMemoryFixture.record(
                "op=imageMemory step=peopleGallery startMB=\(start) paintedMB=\(painted) tiles=\(tiles.count) "
                    + "tile=\(tiles.first.map { "\($0.width)x\($0.height)" } ?? "-")"
            )
            // A tile is 256 px at most on a Retina display, 256 KB; a screenful a few MB, with
            // the window, its views and the decodes' transients well inside the bound.
            #expect(tiles.allSatisfy { $0.width <= 256 && $0.height <= 256 && $0.bytesPerRow == $0.width * 4 })
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
            // preview is 12 MB, so the walk stays well inside the bound; two copies of each
            // (a display copy beside the decode) would exceed it.
            #expect(highest - before <= Self.photoStepsBoundMB, "photo steps: \(before) MB → peak \(highest) MB")
            // Leaving lets go of every photo Otos holds. One decode's IOSurface (15 MB here)
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

        private enum ImageMemoryError: Error {
            case noImage
        }
    }
}
