import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

/// The fixtures are local files, so nothing is ever fetched.
private let localOriginals = ClosureMaterializationRequester { _ in .cancelled }

/// ADR 0038: File ▸ Export… writes one new file per photo into the
/// chosen folder, never overwriting, in the chosen format and size, with or without location.
@Suite(.testScope)
@MainActor
struct ExportTests {
    // Validates: APP-052
    /// Several photos, one edited, exported as JPEG into a folder that already holds a file
    /// with one of their names: every photo arrives, the taken name gets `_001`, the file
    /// that was there is untouched, and nothing else is left in the folder.
    @Test func aSelectionExportsOneFilePerPhotoWithoutOverwriting() async throws {
        try await withEditableLibrary(fileCount: 3) { library in
            let ids = library.ids
            _ = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: ids[1])
            let folder = try makeTestDirectory().appending(path: "Exports", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = folder.appending(path: "edit-0.jpg")
            try Data("keep".utf8).write(to: existing)
            let model = library.makeEditModel(ids: ids)
            model.startExport()
            defer { model.exportTask?.cancel() }
            var settings = model.exportSettings
            settings.format = .jpeg
            settings.destination = folder
            model.setExportSettings(settings)
            model.selectAll()

            model.beginExport()
            #expect(model.exportSheet?.title == "Export 3 Photos")
            model.confirmExport()
            #expect(model.exportSheet == nil)
            try await waitUntil { model.hasSettledExports }

            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            #expect(names == ["edit-0.jpg", "edit-0_001.jpg", "edit-1.jpg", "edit-2.jpg"])
            #expect(try Data(contentsOf: existing) == Data("keep".utf8))
            let edited = try #require(CGImageSourceCreateWithURL(folder.appending(path: "edit-1.jpg") as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(edited, 0, nil))
            #expect(image.width == 96 && image.height == 64)
            #expect(model.exportProgress == nil)
            #expect(model.exportReport == nil)
        }
    }

    // Validates: APP-052
    @Test func aLongEdgeScalesDownButNeverUp() async throws {
        let (item, folder) = try makePhoto(named: "wide.jpg")
        var settings = ExportSettings.default
        settings.limitsSize = true
        settings.longEdge = 48

        let small = try await exportedImage(MediaExporter.export(item, settings: settings, to: folder, materialization: localOriginals,
                                                                 volumeCapacity: ampleVolumeCapacity))
        #expect(small.width == 48 && small.height == 32)

        settings.longEdge = 4000
        let full = try await exportedImage(MediaExporter.export(item, settings: settings, to: folder, materialization: localOriginals,
                                                                volumeCapacity: ampleVolumeCapacity))
        #expect(full.width == 96 && full.height == 64)
    }

    // Validates: APP-052
    @Test func heicKeepsOrRemovesLocationAsAsked() async throws {
        let (item, folder) = try makePhoto(named: "placed.jpg", withLocation: true)
        var settings = ExportSettings.default
        settings.format = .heic

        let kept = try #require(await exportedURL(MediaExporter.export(item, settings: settings, to: folder, materialization: localOriginals,
                                                                       volumeCapacity: ampleVolumeCapacity)))
        #expect(kept.lastPathComponent == "placed.heic")
        #expect(try properties(of: kept)[kCGImagePropertyGPSDictionary] != nil)
        let source = try #require(CGImageSourceCreateWithURL(kept as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.heic.identifier)

        settings.removesLocation = true
        let removed = try #require(await exportedURL(MediaExporter.export(item, settings: settings, to: folder, materialization: localOriginals,
                                                                          volumeCapacity: ampleVolumeCapacity)))
        #expect(removed.lastPathComponent == "placed_001.heic")
        #expect(try properties(of: removed)[kCGImagePropertyGPSDictionary] == nil)
        #expect(try properties(of: removed)[kCGImagePropertyExifDictionary] != nil)
    }

    /// An export that would take the destination's volume below the floor writes nothing
    /// and stops, whatever the machine running the test has free.
    @Test func anExportThatWouldCrossTheFloorWritesNothing() async throws {
        let (photo, folder) = try makePhoto(named: "tight.jpg")
        let item = EditedMediaItem(id: photo.id, isVideo: false, recipe: .neutral, sourceSize: nil)
        var settings = ExportSettings.default
        settings.format = .original
        let atTheFloor: @Sendable (URL) -> Int64? = { _ in FreeSpaceFloor.bytes }

        let outcome = await MediaExporter.export(
            item, settings: settings, to: folder, materialization: localOriginals, volumeCapacity: atTheFloor
        )
        #expect(outcome == .belowFloor)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
    }

    // Validates: APP-052
    @Test func originalExportsTheFileAsItIsOnDisk() async throws {
        let (photo, folder) = try makePhoto(named: "as-is.jpg")
        let item = EditedMediaItem(id: photo.id, isVideo: false, recipe: EditRecipe(exposure: 1), sourceSize: nil)
        var settings = ExportSettings.default
        settings.format = .original

        let url = try #require(await exportedURL(MediaExporter.export(item, settings: settings, to: folder, materialization: localOriginals,
                                                                      volumeCapacity: ampleVolumeCapacity)))
        #expect(url.lastPathComponent == "as-is.jpg")
        #expect(try Data(contentsOf: url) == Data(contentsOf: item.id.fileURL))
    }

    // Validates: APP-052
    /// A trimmed video exports its range; removing location drops the location the
    /// original carries, and keeping it keeps it.
    @Test func aVideoExportsItsTrimAndCanDropLocation() async throws {
        let directory = try makeTestDirectory()
        let fixture = SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov")
        let placed = directory.appending(path: "clip.mov")
        try await writeLocatedCopy(of: fixture, to: placed)
        #expect(try await hasLocation(placed))
        let id = try MediaAssetID(
            libraryRootPath: CatalogPath.normalizedExistingDirectoryPath(for: directory),
            relativePath: MediaRelativePath(rawValue: "clip.mov")
        )
        let item = EditedMediaItem(id: id, isVideo: true, recipe: EditRecipe(trimStart: 0.2, trimEnd: 0.6), sourceSize: nil)
        let folder = directory.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var settings = ExportSettings.default

        let kept = try #require(await exportedURL(MediaExporter.export(item, settings: settings, to: folder, materialization: localOriginals,
                                                                       volumeCapacity: ampleVolumeCapacity)))
        #expect(try await abs(AVURLAsset(url: kept).load(.duration).seconds - 0.4) < 0.15)
        #expect(try await hasLocation(kept))

        settings.removesLocation = true
        let removed = try #require(await exportedURL(MediaExporter.export(item, settings: settings, to: folder, materialization: localOriginals,
                                                                          volumeCapacity: ampleVolumeCapacity)))
        #expect(removed.lastPathComponent == "clip_001.mov")
        #expect(try await !hasLocation(removed))
    }

    // Validates: APP-052
    @Test func aMissingFolderStopsTheExportWithAReport() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let model = library.makeEditModel()
            model.startExport()
            defer { model.exportTask?.cancel() }
            var settings = model.exportSettings
            settings.destination = try makeTestDirectory().appending(path: "Gone", directoryHint: .isDirectory)
            model.setExportSettings(settings)
            model.selectAll()

            model.beginExport()
            model.confirmExport()
            try await waitUntil { model.hasSettledExports }

            #expect(model.exportReport?.title == "Couldn’t Export")
            #expect(model.exportReport?.message.contains("“Gone”") == true)
        }
    }

    // Validates: APP-052
    @Test func theFloorAFullDiskAndFailuresAreReportedAndACancelIsNot() {
        let folder = URL(fileURLWithPath: "/Exports", isDirectory: true)
        let one = [folder.appending(path: "a.jpg")]
        let floor = CatalogWindowViewModel.exportReport(requested: 3, exported: one, failed: 0, stop: .belowFloor, folder: folder)
        #expect(floor?.title == "Exported 1 of 3 Photos")
        #expect(floor?.message == "Export stopped to keep 5 GB free on the disk.")
        let failed = CatalogWindowViewModel.exportReport(requested: 3, exported: one, failed: 2, stop: nil, folder: folder)
        #expect(failed?.message == "2 photos couldn’t be exported. Their originals may be unavailable.")
        let full = CatalogWindowViewModel.exportReport(requested: 3, exported: one, failed: 0, stop: .outOfSpace, folder: folder)
        #expect(full?.title == "Exported 1 of 3 Photos")
        #expect(full?.message == "Export stopped because the disk is full. Free up space and export again.")
        #expect(CatalogWindowViewModel.exportReport(requested: 3, exported: one, failed: 0, stop: .cancelled, folder: folder) == nil)
        #expect(CatalogWindowViewModel.exportReport(requested: 1, exported: one, failed: 0, stop: nil, folder: folder) == nil)
    }

    // Validates: APP-052
    @Test func settingsAreRememberedAndKeptInRange() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: domain,
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        #expect(model.exportSettings == .default)
        let settings = ExportSettings(
            format: .heic,
            limitsSize: true,
            longEdge: 10,
            quality: 1.4,
            removesLocation: true,
            destination: URL(fileURLWithPath: "/Exports", isDirectory: true)
        )
        model.setExportSettings(settings)
        #expect(model.exportSettings.longEdge == ExportSettings.longEdgeRange.lowerBound)
        #expect(model.exportSettings.quality == 1)

        let reloaded = ExportSettingsStore.load(defaults: domain.makeDefaults())
        #expect(reloaded == model.exportSettings)
        #expect(reloaded.destination == URL(fileURLWithPath: "/Exports", isDirectory: true))
    }

    // MARK: - Support

    private func makePhoto(named name: String, withLocation: Bool = false) throws -> (EditedMediaItem, URL) {
        let directory = try makeTestDirectory()
        let url = directory.appending(path: name)
        if withLocation {
            let image = try #require(gradientImage(width: 96, height: 64))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 60.17, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 24.94, kCGImagePropertyGPSLongitudeRef: "E",
                ],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"],
            ] as CFDictionary)
            try #require(CGImageDestinationFinalize(destination))
        } else {
            try writeGradientJPEG(to: url)
        }
        let id = try MediaAssetID(
            libraryRootPath: CatalogPath.normalizedExistingDirectoryPath(for: directory),
            relativePath: MediaRelativePath(rawValue: name)
        )
        let folder = directory.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (EditedMediaItem(id: id, isVideo: false, recipe: .neutral, sourceSize: nil), folder)
    }

    private func exportedURL(_ outcome: ExportOutcome) -> URL? {
        if case let .exported(url) = outcome {
            return url
        }
        return nil
    }

    private func exportedImage(_ outcome: ExportOutcome) throws -> CGImage {
        let url = try #require(exportedURL(outcome))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func writeLocatedCopy(of fixture: URL, to url: URL) async throws {
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: fixture), presetName: AVAssetExportPresetPassthrough))
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+60.1700+024.9400/" as NSString
        location.dataType = kCMMetadataBaseDataType_UTF8 as String
        session.metadata = [location]
        try await session.export(to: url, as: .mov)
    }

    private func hasLocation(_ url: URL) async throws -> Bool {
        try await AVURLAsset(url: url).load(.metadata).contains { $0.identifier == .quickTimeMetadataLocationISO6709 }
    }
}
