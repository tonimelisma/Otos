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
    let thumbnailDirectory = try #require(store.thumbnailDirectory)
    try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
    do {
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try #require(Set(scanned.testAssets.map(\.id)) == Set(ids))
        try await body(EditableLibrary(
            store: store, root: root, ids: ids, thumbnailDirectory: thumbnailDirectory, databaseURL: databaseURL
        ))
    } catch {
        await store.shutdown()
        throw error
    }
    await store.shutdown()
}

/// A view model over `store` whose grid holds `ids`, with its edit lanes started.
@MainActor
func makeEditModel(store: CatalogStore, ids: [MediaAssetID]) -> CatalogWindowViewModel {
    let model = CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
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
    model.startEditing(store: store)
    return model
}

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
