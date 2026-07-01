import CoreGraphics
import Foundation
import ImageIO
@testable import Otos
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

    @Test func writeNormalizesToLoadableJPEG() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let image = try makeThumbnailTestImage()

        let relativeName = try ThumbnailStore.write(image, named: "thumb.jpg", in: directory)
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
