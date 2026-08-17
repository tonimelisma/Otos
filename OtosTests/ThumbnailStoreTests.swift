import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

struct ThumbnailStoreTests {
    @Test func relativeNameUsesJPEGExtension() {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "movie.mp4")
        )

        let name = ThumbnailStore.relativeName(for: id)
        #expect(name.hasSuffix(".jpg"))
        #expect(!name.hasSuffix(".heic"))
    }

    @Test func stageAndPromoteNormalizeToLoadableJPEG() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let image = try makeThumbnailTestImage()

        let generated = try ThumbnailStore.stage(image, finalRelativeName: "thumb.jpg", in: directory)
        let relativeName = try ThumbnailStore.promote(generated, in: directory)
        let thumbnailURL = ThumbnailStore.url(for: relativeName, in: directory)
        let data = try Data(contentsOf: thumbnailURL)
        #expect(Array(data.prefix(2)) == [0xFF, 0xD8])

        let source = try #require(CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil))
        let typeIdentifier = try #require(CGImageSourceGetType(source))
        #expect(typeIdentifier as String == UTType.jpeg.identifier)

        let loaded = try #require(ThumbnailStore.load(relativeName, in: directory))
        #expect(loaded.width == image.width)
        #expect(loaded.height == image.height)
    }

    @Test func stageDoesNotPublishUntilPromoted() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let image = try makeThumbnailTestImage()

        let generated = try ThumbnailStore.stage(image, finalRelativeName: "thumb.jpg", in: directory)
        let finalURL = ThumbnailStore.url(for: generated.finalRelativePath, in: directory)
        let stagedURL = ThumbnailStore.url(for: generated.stagedRelativePath, in: directory)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: stagedURL.path(percentEncoded: false)))

        let promotedName = try ThumbnailStore.promote(generated, in: directory)
        #expect(promotedName == "thumb.jpg")
        #expect(FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path(percentEncoded: false)))
    }

    @Test func stageCopyUsesIndependentDestinationIdentity() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let image = try makeThumbnailTestImage()
        let sourceID = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Card"),
            relativePath: MediaRelativePath(rawValue: "source.jpg")
        )
        let destinationID = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "2026/destination.jpg")
        )

        let source = try ThumbnailStore.stage(image, finalRelativeName: ThumbnailStore.relativeName(for: sourceID), in: directory)
        let sourceName = try ThumbnailStore.promote(source, in: directory)
        let copied = try ThumbnailStore.stageCopy(sourceRelativeName: sourceName, destinationID: destinationID, in: directory)
        let destinationName = try ThumbnailStore.promote(copied, in: directory)

        #expect(destinationName != sourceName)
        #expect(try Data(contentsOf: ThumbnailStore.url(for: sourceName, in: directory))
            == Data(contentsOf: ThumbnailStore.url(for: destinationName, in: directory)))
    }

    @Test func deleteAllPurgesOnlyThumbnailDirectoryContents() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nested = directory.appending(path: "thumb.jpg", directoryHint: .notDirectory)
        let outside = temp.appending(path: "original.jpg", directoryHint: .notDirectory)
        try Data("thumb".utf8).write(to: nested)
        try Data("original".utf8).write(to: outside)

        ThumbnailStore.deleteAll(in: directory)

        #expect(!FileManager.default.fileExists(atPath: nested.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
    }

    @Test func deleteRemovesThumbnailFile() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "thumb.jpg"
        let thumbnailURL = ThumbnailStore.url(for: name, in: directory)
        try Data("thumb".utf8).write(to: thumbnailURL)

        ThumbnailStore.delete(name, in: directory)

        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))
    }

    @Test func startupCleanupDeletesOnlyHiddenTemporaryThumbnailFiles() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let outside = temp.appending(path: ".outside.tmp", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appending(path: ".thumb.jpg.tmp", directoryHint: .notDirectory)
        let visibleTemporary = directory.appending(path: "thumb.jpg.tmp", directoryHint: .notDirectory)
        let hiddenNonTemporary = directory.appending(path: ".thumb.jpg", directoryHint: .notDirectory)
        let hiddenTemporaryDirectory = directory.appending(path: ".nested.tmp", directoryHint: .isDirectory)
        try Data("staged".utf8).write(to: staged)
        try Data("visible".utf8).write(to: visibleTemporary)
        try Data("hidden".utf8).write(to: hiddenNonTemporary)
        try FileManager.default.createDirectory(at: hiddenTemporaryDirectory, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: outside)

        let deletedCount = try ThumbnailStore.deleteStagedTemporaryFiles(in: directory)

        #expect(deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: visibleTemporary.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: hiddenNonTemporary.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: hiddenTemporaryDirectory.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
    }
}

private func makeThumbnailTestImage() throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try #require(CGContext(
        data: nil,
        width: 4,
        height: 3,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ))

    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 0.7))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
    return try #require(context.makeImage())
}
