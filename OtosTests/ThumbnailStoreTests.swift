import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

@Suite(.testDirectory)
struct ThumbnailStoreTests {
    /// ADR 0035: the preview is an 8-bit Display P3 HEIC under the asset's `.heic` name, and
    /// `scaled` never enlarges.
    @Test func previewStagesAsDisplayP3HEICAndScalingNeverEnlarges() throws {
        let temp = try makeTestDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        #expect(ThumbnailStore.previewRelativeName(for: id).hasSuffix(".heic"))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())

        let staged = try ThumbnailStore.stagePreview(
            image, finalRelativeName: ThumbnailStore.previewRelativeName(for: id), in: directory
        )
        let name = try ThumbnailStore.promote(staged, in: directory)
        let source = try #require(CGImageSourceCreateWithURL(ThumbnailStore.url(for: name, in: directory) as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.heic.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyDepth] as? Int == 8)
        #expect((properties[kCGImagePropertyProfileName] as? String)?.contains("P3") == true)

        #expect(try ThumbnailStore.scaled(image, toLongEdge: 100).width == 100)
        #expect(try ThumbnailStore.scaled(image, toLongEdge: 1000).width == 400)
    }

    @Test func stageAndPromoteNormalizeToLoadableJPEG() throws {
        let temp = try makeTestDirectory()
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
        let temp = try makeTestDirectory()
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
        let temp = try makeTestDirectory()
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

        let source = try ThumbnailStore.stage(
            image,
            finalRelativeName: ThumbnailStore.relativeName(for: sourceID),
            in: directory
        )
        let sourceName = try ThumbnailStore.promote(source, in: directory)
        let copied = try ThumbnailStore.stageCopy(
            sourceRelativeName: sourceName,
            destinationRelativeName: ThumbnailStore.relativeName(for: destinationID),
            in: directory
        )
        let destinationName = try ThumbnailStore.promote(copied, in: directory)

        #expect(destinationName != sourceName)
        #expect(try Data(contentsOf: ThumbnailStore.url(for: sourceName, in: directory))
            == Data(contentsOf: ThumbnailStore.url(for: destinationName, in: directory)))
    }

    @Test func deleteAllPurgesOnlyThumbnailDirectoryContents() throws {
        let temp = try makeTestDirectory()
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

    /// Staging has its own subdirectory, so the startup sweep lists only what was staged —
    /// never the finished images beside it, which number in the tens of thousands.
    @Test func startupClearsOnlyTheStagingSubdirectory() throws {
        let temp = try makeTestDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let image = try makeThumbnailTestImage()
        let promoted = try ThumbnailStore.stage(image, finalRelativeName: "kept.jpg", in: directory)
        try ThumbnailStore.promote(promoted, in: directory)
        let abandoned = try ThumbnailStore.stage(image, finalRelativeName: "abandoned.jpg", in: directory)
        let hiddenBeside = directory.appending(path: ".beside.tmp", directoryHint: .notDirectory)
        try Data("not staged".utf8).write(to: hiddenBeside)

        #expect(abandoned.stagedRelativePath.hasPrefix(ThumbnailStore.stagingDirectoryName + "/"))
        #expect(ThumbnailStore.clearStaging(in: directory) == 1)

        let staged = ThumbnailStore.url(for: abandoned.stagedRelativePath, in: directory)
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(ThumbnailStore.load("kept.jpg", in: directory) != nil)
        #expect(FileManager.default.fileExists(atPath: hiddenBeside.path(percentEncoded: false)))
        #expect(ThumbnailStore.clearStaging(in: temp.appending(path: "Missing", directoryHint: .isDirectory)) == 0)
    }

    /// A missing folder is a missing file whichever call finds it: a listing reports
    /// `NSFileReadNoSuchFileError`, a removal `NSFileNoSuchFileError`.
    @Test func aMissingFileIsRecognizedFromAReadAndARemoval() throws {
        let missing = try makeTestDirectory().appending(path: "Missing", directoryHint: .isDirectory)
        #expect(throws: (any Error).self) {
            do {
                _ = try FileManager.default.contentsOfDirectory(at: missing, includingPropertiesForKeys: nil)
            } catch {
                #expect(ErrorDiagnostics.isMissingFile(error))
                throw error
            }
        }
        #expect(throws: (any Error).self) {
            do {
                try FileManager.default.removeItem(at: missing)
            } catch {
                #expect(ErrorDiagnostics.isMissingFile(error))
                throw error
            }
        }
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
