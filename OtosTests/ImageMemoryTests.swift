import AppKit
import Foundation
import ImageIO
@testable import OtosKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Stored previews shaped like the owner's (ADR 0035): 2560 × 1920 8-bit Display P3 HEICs a
/// few hundred kilobytes each, about 20 MB each decoded, drawn here as overlapping ellipses so
/// they encode like photographs rather than flat colour.
nonisolated enum ImageMemoryFixture {
    static let width = 2560
    static let height = 1920

    /// Writes `count` previews into `directory` and returns their names.
    static func writePreviews(count: Int, in directory: URL) throws -> [String] {
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

        private enum ImageMemoryError: Error {
            case noImage
        }
    }
}
