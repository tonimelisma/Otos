import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing

/// A library of real JPEGs cataloged by a store with an on-disk database, so it has a
/// thumbnail directory edit renders can be promoted into. Needs the `.testDirectory` trait.
struct EditableLibrary {
    let store: CatalogStore
    let root: URL
    let ids: [MediaAssetID]
    let thumbnailDirectory: URL
    let databaseURL: URL
    let models: EditModels

    /// A view model over the library's store whose grid holds `ids` (the library's own when
    /// none are given), with its edit lanes started, ended with the test (`EditModels`).
    @MainActor
    func makeEditModel(ids: [MediaAssetID]? = nil) -> CatalogWindowViewModel {
        models.make(store: store, ids: ids ?? self.ids)
    }
}

/// The edit view models a test makes over one store, ended before the store shuts down. A
/// cancelled lane still finishes the step it is awaiting — a save, a render, an analysis —
/// and holds the store while it does, so `finish` waits for each lane to end: a write that
/// lands after the test's directory removal began leaves a file behind.
@MainActor
final class EditModels {
    private var started: [CatalogWindowViewModel] = []
    /// The one analyzer every test's edit view models read with: the app has one per window,
    /// and a window per test loading Auto crop's and Auto straighten's 79 MB of weights side by
    /// side took the test host from 220 MB to 1.39 GB within two seconds.
    private static let analyzer = EditAnalyzer()

    /// A view model over `store` whose grid holds `ids`, with its edit lanes started.
    func make(store: CatalogStore, ids: [MediaAssetID]) -> CatalogWindowViewModel {
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
            title: "Edit",
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil
        ))
        model.startEditing(store: store, analyzer: Self.analyzer)
        started.append(model)
        return model
    }

    func finish() async {
        for model in started {
            for lane in [model.editRenderTask, model.editCommandTask, model.editAnalysisTask] {
                lane?.cancel()
                await lane?.value
            }
        }
        started.removeAll()
    }
}

func withEditableLibrary(
    fileCount: Int,
    fileExtension: String = "jpg",
    write: (URL) throws -> Void = writeGradientJPEG,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (EditableLibrary) async throws -> Void
) async throws {
    let temp = try makeTestDirectory()
    let root = temp.appending(path: "Photos", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let names = (0 ..< fileCount).map { "edit-\($0).\(fileExtension)" }
    for name in names {
        try write(root.appending(path: name))
    }
    let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
    let ids = names.map { MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: $0)) }
    let databaseURL = temp.appending(path: "Catalog/catalog.sqlite")
    try FileManager.default.createDirectory(
        at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(5))
    let models = EditModels()
    let thumbnailDirectory = try #require(store.thumbnailDirectory)
    try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
    do {
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try #require(Set(scanned.testAssets.map(\.id)) == Set(ids))
        try await body(EditableLibrary(
            store: store, root: root, ids: ids, thumbnailDirectory: thumbnailDirectory, databaseURL: databaseURL,
            models: models
        ))
    } catch {
        await models.finish()
        await store.shutdown()
        throw error
    }
    await models.finish()
    await store.shutdown()
}

/// A volume with a terabyte free, for tests that write: the free-space floor (ADR 0027)
/// reads this instead of the disk the tests run on, which parallel checks fill and drain.
nonisolated let ampleVolumeCapacity: @Sendable (URL) -> Int64? = { _ in 1 << 40 }

/// A 96×64 left-to-right gray gradient, so exposure and contrast visibly move its pixels.
func writeGradientJPEG(to url: URL) throws {
    let image = try #require(gradientImage(width: 96, height: 64))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
}

/// The 96×64 gradient stored as a HEIC turned a quarter clockwise by its `irot` property
/// (ImageIO writes the property for orientation 6), so it shows upright as 64×96.
func writeRotatedHEIC(to url: URL) throws {
    let image = try #require(gradientImage(width: 96, height: 64))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
}

/// The rotated HEIC with its Exif Orientation entry renamed to tag 0, so only the HEIF
/// `irot` property records the rotation, as Sony cameras write it. MediaMetadata 0.6.0
/// read such a file as unrotated; ImageIO and 0.6.1 read orientation 6.
func writeIrotOnlyHEIC(to url: URL) throws {
    try writeRotatedHEIC(to: url)
    var data = try Data(contentsOf: url)
    let littleEndian = data.range(of: Data([0x49, 0x49, 0x2A, 0x00]))
    let bigEndian = data.range(of: Data([0x4D, 0x4D, 0x00, 0x2A]))
    let header = try #require(littleEndian ?? bigEndian).lowerBound
    let isLittle = littleEndian != nil
    func read(_ offset: Int, _ count: Int) -> Int {
        let bytes = data[offset ..< offset + count]
        return (isLittle ? bytes.reversed() : Array(bytes)).reduce(0) { $0 << 8 | Int($1) }
    }
    let ifd = header + read(header + 4, 4)
    var renamed = false
    for index in 0 ..< read(ifd, 2) {
        let entry = ifd + 2 + 12 * index
        if read(entry, 2) == 0x0112 {
            data[entry] = 0
            data[entry + 1] = 0
            renamed = true
        }
    }
    try #require(renamed)
    try data.write(to: url)
}

func gradientImage(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    for column in 0 ..< width {
        let level = CGFloat(column) / CGFloat(width - 1) * 0.8 + 0.1
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        context.fill(CGRect(x: column, y: 0, width: 1, height: height))
    }
    return context.makeImage()
}

/// The image's mean luminance, 0…1, read back through an 8-bit sRGB context.
func meanLuminance(_ image: CGImage) -> Double {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return 0 }
    var total = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        total += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
    }
    return Double(total) / Double(width * height * 3 * 255)
}

/// A 64×48 JPEG of one color — a warm-cast gray when the defaults are used — for white
/// balance tests.
func writeSolidJPEG(to url: URL, red: CGFloat = 0.62, green: CGFloat = 0.5, blue: CGFloat = 0.38) throws {
    let context = try #require(CGContext(
        data: nil,
        width: 64,
        height: 48,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
}

struct MeanColor {
    let red: Double
    let green: Double
    let blue: Double
}

/// Mean red, green and blue, 0…1, read back through an 8-bit sRGB context.
func meanColor(_ image: CGImage) -> MeanColor {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return MeanColor(red: 0, green: 0, blue: 0) }
    var totals = (0, 0, 0)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        totals.0 += Int(pixels[index])
        totals.1 += Int(pixels[index + 1])
        totals.2 += Int(pixels[index + 2])
    }
    let count = Double(width * height * 255)
    return MeanColor(red: Double(totals.0) / count, green: Double(totals.1) / count, blue: Double(totals.2) / count)
}

/// A 96×64 JPEG whose left half is `left` and right half `right` (sRGB), so a turn,
/// flip or crop shows where each half went. Red and blue by default.
func writeSplitJPEG(
    to url: URL,
    left: CGColor = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1),
    right: CGColor = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1)
) throws {
    let context = try #require(CGContext(
        data: nil,
        width: 96,
        height: 64,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(left)
    context.fill(CGRect(x: 0, y: 0, width: 48, height: 64))
    context.setFillColor(right)
    context.fill(CGRect(x: 48, y: 0, width: 48, height: 64))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
}

/// The mean color of `rect` (top-left origin, pixels) of `image`.
func meanColor(_ image: CGImage, in rect: CGRect) throws -> MeanColor {
    try meanColor(#require(image.cropping(to: rect)))
}

/// A 1200 × 800 landscape: sky over sea, split by a horizon through the center that rises
/// to the right by `degrees` as the photo is shown.
func writeHorizonJPEG(to url: URL, risingBy degrees: Double) throws {
    let width = 1200.0, height = 800.0
    let context = try #require(CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.55, green: 0.72, blue: 0.92, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Core Graphics is y-up, so a line rising to the right has a positive slope here too.
    let slope = tan(degrees * .pi / 180)
    let left = height / 2 - slope * width / 2, right = height / 2 + slope * width / 2
    context.setFillColor(CGColor(srgbRed: 0.08, green: 0.22, blue: 0.36, alpha: 1))
    context.beginPath()
    context.move(to: CGPoint(x: 0, y: 0))
    context.addLine(to: CGPoint(x: 0, y: left))
    context.addLine(to: CGPoint(x: width, y: right))
    context.addLine(to: CGPoint(x: width, y: 0))
    context.closePath()
    context.fillPath()
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
}

/// `writeHorizonJPEG`'s photo as an iPhone writes it: an Exif segment naming the lens and
/// carrying the Apple MakerNote's gravity reading at capture (`AccelerationVector`, tag
/// `0x0008`, in g in the device's frame), placed straight after the JPEG's start marker.
func writeLeveledJPEG(
    to url: URL,
    risingBy degrees: Double,
    gravity: (x: Double, y: Double, z: Double),
    lensModel: String
) throws {
    try writeHorizonJPEG(to: url, risingBy: degrees)
    let jpeg = try Data(contentsOf: url)
    try #require(jpeg.prefix(2) == Data([0xFF, 0xD8]))
    let segment = appleGravityExifSegment(gravity: gravity, lensModel: lensModel)
    try (jpeg.prefix(2) + segment + jpeg.dropFirst(2)).write(to: url)
}

/// A big-endian APP1 Exif segment: IFD0 points at an Exif IFD holding `LensModel` and an
/// Apple MakerNote, whose own IFD holds the gravity reading as three signed rationals, its
/// offset counted from the MakerNote's start.
private func appleGravityExifSegment(gravity: (x: Double, y: Double, z: Double), lensModel: String) -> Data {
    func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }
    func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    var vector = Data()
    for component in [gravity.x, gravity.y, gravity.z] {
        vector += be32(UInt32(bitPattern: Int32((component * 1_000_000).rounded()))) + be32(1_000_000)
    }
    let noteHeaderLength = 14, noteIFDLength = 2 + 12 + 4
    var note = Data("Apple iOS".utf8) + Data([0, 0, 1]) + Data("MM".utf8)
    note += be16(1) + be16(0x0008) + be16(10) + be32(3) + be32(UInt32(noteHeaderLength + noteIFDLength))
    note += be32(0) + vector

    let lens = Data(lensModel.utf8) + Data([0])
    let exifIFDOffset: UInt32 = 8 + 2 + 12 + 4
    let exifIFDLength: UInt32 = 2 + 2 * 12 + 4
    let lensOffset = exifIFDOffset + exifIFDLength
    let noteOffset = lensOffset + UInt32(lens.count)
    var tiff = Data("MM".utf8) + be16(42) + be32(8)
    tiff += be16(1) + be16(0x8769) + be16(4) + be32(1) + be32(exifIFDOffset) + be32(0)
    tiff += be16(2)
    tiff += be16(0x927C) + be16(7) + be32(UInt32(note.count)) + be32(noteOffset)
    tiff += be16(0xA434) + be16(2) + be32(UInt32(lens.count)) + be32(lensOffset)
    tiff += be32(0) + lens + note
    let app1 = Data("Exif".utf8) + Data([0, 0]) + tiff
    return Data([0xFF, 0xE1]) + be16(UInt16(app1.count + 2)) + app1
}

/// A 1200 × 800 photo of one subject: a red disk a fifth of the height across, centered at
/// `center` (fractions from the top-left corner), on a plain gray ground.
func writeSubjectJPEG(to url: URL, center: CGPoint) throws {
    let width = 1200.0, height = 800.0
    let context = try #require(CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let diameter = height / 5
    context.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
    // Core Graphics is y-up.
    context.fillEllipse(in: CGRect(
        x: center.x * width - diameter / 2,
        y: (1 - center.y) * height - diameter / 2,
        width: diameter,
        height: diameter
    ))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
}
