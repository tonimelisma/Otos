import Foundation
import ImageIO
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

/// What one face tile's decode costs while it runs (`FaceCrop.decode`), for each format a
/// tile is cut from: a stored preview (HEIC, ADR 0035) and a JPEG of the same picture. The
/// transient is the footprint's peak above where the decode found it, sampled every
/// millisecond (`FootprintPeak`), against what the whole preview costs decoded. On demand and
/// alone (`OTOS_SCALE_TEST=1 script/check.sh --only FaceTileDecodeMemoryTests`): a footprint
/// is the whole process's. Each line goes to `build/measurements/image-memory.log`.
@Suite(.testScope, .serialized, .enabled(if: ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"))
struct FaceTileDecodeMemoryTests {
    /// A small face, as in a group photo: 4 % of the preview's width.
    static let face = CGRect(x: 0.48, y: 0.4, width: 0.04, height: 0.053)
    static let decodes = 12

    @Test(arguments: ["heic", "jpeg"])
    func whatAFaceTileDecodeCostsByFormat(format: String) async throws {
        let directory = try makeTestDirectory()
        let heic = try #require(ImageMemoryFixture.writePreviews(count: 1, in: directory).first)
        let name = format == "heic" ? heic : try Self.reencodeAsJPEG(heic, in: directory)
        let preview = FacePreview(name: name, recipe: .neutral)
        let wholeMB = ImageMemoryFixture.width * ImageMemoryFixture.height * 4 / 1_048_576
        // One decode first, so what the decoder pays once (its own setup) is not counted.
        _ = try #require(await FaceCrop.decode(Self.face, from: preview, in: directory, pixelEdge: 256))
        let peak = FootprintPeak()
        peak.start()
        defer { peak.stop() }
        var transients: [Int] = []
        for _ in 0 ..< Self.decodes {
            let before = ImageMemoryFixture.footprintMB()
            _ = peak.takeMB()
            let tile = try #require(await FaceCrop.decode(Self.face, from: preview, in: directory, pixelEdge: 256))
            #expect(tile.width <= 256)
            transients.append(max(0, peak.takeMB() - before))
        }
        let worst = transients.max() ?? 0
        // The control: the whole preview decoded and drawn, through the same sampler, so a
        // small tile transient is the decode's and not a sampler that missed it.
        let before = ImageMemoryFixture.footprintMB()
        _ = peak.takeMB()
        try Self.decodeWhole(name, in: directory)
        let wholeTransient = max(0, peak.takeMB() - before)
        ImageMemoryFixture.record(
            "op=imageMemory step=faceTileDecode format=\(format) wholeDecodeMB=\(wholeMB) wholeTransientMB=\(wholeTransient) "
                + "transientMB=\(transients.map(String.init).joined(separator: ",")) worstMB=\(worst)"
        )
        #expect(wholeTransient >= wholeMB / 2, "the sampler sees a whole decode: \(wholeTransient) MB")
        #expect(worst <= Self.transientBoundMB[format] ?? 0, "\(format): \(transients) MB, whole decode \(wholeMB) MB")
    }

    /// What one tile's decode may add at its peak, by format (measured; see the research note
    /// `2026-11-16-image-memory-while-used.md`).
    static let transientBoundMB = ["heic": 32, "jpeg": 8]

    /// Decodes the whole preview at its own size, as a full-size decode of it does.
    private static func decodeWhole(_ name: String, in directory: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(directory.appending(path: name) as CFURL, nil))
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: ImageMemoryFixture.width,
        ] as CFDictionary))
        // Reading a pixel makes the decode happen, as painting it does.
        _ = image.dataProvider?.data.map(CFDataGetLength)
    }

    private static func reencodeAsJPEG(_ name: String, in directory: URL) throws -> String {
        let source = try #require(CGImageSourceCreateWithURL(directory.appending(path: name) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let jpeg = "preview-0.jpg"
        let destination = try #require(CGImageDestinationCreateWithURL(
            directory.appending(path: jpeg) as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return jpeg
    }
}
