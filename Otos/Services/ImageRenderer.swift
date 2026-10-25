import CoreImage
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Image renderer guide
///
/// The one place a still photo's pixels are made from its original (ADR 0035). A RAW
/// file is developed by `CIRAWFilter` with the newest decoder the file supports — RAW9
/// where Apple offers it, otherwise RAW8 — so the grid, the loupe and every product
/// derived from them show the same rendering; any other still is decoded by Image I/O
/// with its orientation applied. The result is an 8-bit Display P3 bitmap.
///
/// Rendering is blocking CPU and GPU work, so it leaves every actor on a named serial
/// queue (ADR 0032 rule 6). There are two lanes, each rendering one image at a time:
/// `background` for enrichment and `interactive` for what the user is looking at, so a
/// backlog of enrichment renders never queues in front of the photo on screen, and at
/// most two RAW developments — 160–340 MB each, measured — are in memory at once.
///
/// The caller has already checked that the original's bytes are local; reading a
/// dataless file here would block on its download.
final nonisolated class ImageRenderer: Sendable {
    /// Which decoder produced a rendering — recorded so a product can say how it was made.
    enum Decoder: String, Sendable {
        case raw9
        case raw8
        /// A RAW file whose camera only an older decoder supports.
        case rawOther
        case imageIO
    }

    struct Rendered: Sendable {
        /// An immutable 8-bit Display P3 bitmap.
        let image: CGImage
        let decoder: Decoder
        /// The original's oriented full-resolution size, for the loupe's 100% document.
        let nativePixelSize: CGSize
    }

    enum RenderError: Error {
        case unreadable
        case renderFailed
    }

    static let background = ImageRenderer(lane: "background")
    static let interactive = ImageRenderer(lane: "interactive")

    private let lane: String
    private let queue: DispatchQueue

    private init(lane: String) {
        self.lane = lane
        queue = DispatchQueue(label: "net.melisma.Otos.render.\(lane)", qos: lane == "interactive" ? .userInitiated : .utility)
    }

    /// Renders `url` so its long edge is at most `longEdge`, or at full size when nil.
    func render(_ url: URL, longEdge: Int?) async throws -> Rendered {
        let lane = lane
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let start = ContinuousClock.now
                let signpost = OtosSignpost.rendering.beginInterval("ImageRender")
                defer { OtosSignpost.rendering.endInterval("ImageRender", signpost) }
                do {
                    let rendered = try Self.renderNow(url, longEdge: longEdge)
                    OtosLog.rendering.noticeOperation("render.still", phase: "finish", fields: [
                        "lane": lane,
                        "decoder": rendered.decoder.rawValue,
                        "width": "\(rendered.image.width)",
                        "height": "\(rendered.image.height)",
                        "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
                        "path": url.path(percentEncoded: false),
                    ])
                    continuation.resume(returning: rendered)
                } catch {
                    OtosLog.rendering.errorOperation("render.still", phase: "failed", fields: [
                        "lane": lane,
                        "path": url.path(percentEncoded: false),
                        "error": String(describing: error),
                    ])
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func isRAW(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
    }

    private static func renderNow(_ url: URL, longEdge: Int?) throws -> Rendered {
        if isRAW(url) {
            return try developRAW(url, longEdge: longEdge)
        }
        return try decodeImage(url, longEdge: longEdge)
    }

    private static func developRAW(_ url: URL, longEdge: Int?) throws -> Rendered {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RenderError.unreadable
        }
        let decoder: Decoder
        if filter.supportedDecoderVersions.contains(.version9) {
            filter.decoderVersion = .version9
            decoder = .raw9
        } else if filter.supportedDecoderVersions.contains(.version8) {
            filter.decoderVersion = .version8
            decoder = .raw8
        } else {
            decoder = .rawOther
        }
        let nativeLongEdge = max(filter.nativeSize.width, filter.nativeSize.height)
        var scale = 1.0
        if let longEdge, nativeLongEdge > 0 {
            scale = min(1, Double(longEdge) / Double(nativeLongEdge))
            filter.scaleFactor = Float(scale)
        }
        // Read once per configuration: under RAW9 below a 0.5 scale factor a second read
        // returns an image at half the requested size (research 2026-10-24).
        guard let image = filter.outputImage else {
            throw RenderError.renderFailed
        }
        // The output is oriented; its aspect says whether the native size is rotated.
        let isPortrait = image.extent.height > image.extent.width
        let native = filter.nativeSize
        let oriented = (native.height > native.width) == isPortrait
            ? native : CGSize(width: native.height, height: native.width)
        return try Rendered(image: bitmap(image), decoder: decoder, nativePixelSize: oriented)
    }

    private static func decodeImage(_ url: URL, longEdge: Int?) throws -> Rendered {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw RenderError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let nativeLongEdge = max(width, height)
        guard nativeLongEdge > 0 else {
            throw RenderError.unreadable
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge ?? nativeLongEdge, nativeLongEdge),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw RenderError.renderFailed
        }
        let native = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return Rendered(image: image, decoder: .imageIO, nativePixelSize: native)
    }

    /// Renders every pixel into an 8-bit Display P3 bitmap. `createCGImage` may return an
    /// image that renders lazily on first draw; the bitmap makes the work happen here, on
    /// the lane, rather than wherever the image is first drawn.
    private static func bitmap(_ image: CIImage) throws -> CGImage {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw RenderError.renderFailed
        }
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        let context = CIContext(options: [.cacheIntermediates: false])
        data.withUnsafeMutableBytes { buffer in
            context.render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: rowBytes,
                bounds: extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: rowBytes,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            throw RenderError.renderFailed
        }
        return cgImage
    }
}
