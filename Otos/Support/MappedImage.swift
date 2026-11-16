import CoreGraphics
import Darwin

/// Mapped image guide
///
/// **The rule: an image Otos draws for itself and holds past the call that made it keeps its
/// pixels in a `ScratchBuffer`, never in the malloc heap or inside a larger decode.** Its pixels
/// are one mapped region, unmapped when the last reference to the image goes, so holding it
/// costs its own pixels and dropping it gives them back (`ScratchBuffer`'s rule; on macOS 27
/// what `malloc` frees stays in the footprint,
/// `docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`).
///
/// Why not `CGImage.cropping(to:)`: a crop keeps a reference to the whole image it was cut
/// from. A face tile cut that way from a preview decoded at a few megapixels held all of it:
/// 48 tiles of 164 px held 563 MB, the same tiles drawn here 24 MB
/// (`docs/research/2026-11-16-image-memory-while-used.md`).
///
/// - **Format:** 8-bit premultiplied BGRA, little-endian, the layout Core Animation takes
///   without converting; the color space the caller names.
/// - **Use:** `draw` hands a context over the new pixels to `body` and returns the image once
///   `body` has drawn; nothing else ever writes the pixels.
nonisolated enum MappedImage {
    static func draw(width: Int, height: Int, colorSpace: CGColorSpace, _ body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0, colorSpace.model == .rgb else { return nil }
        let bytesPerRow = width * 4
        let pixels = ScratchBuffer<UInt8>(count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: pixels.base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        body(context)
        // The provider holds the buffer until Core Graphics lets the image go, on whichever
        // thread that is; nothing else holds or writes it by then.
        let owner = Unmanaged.passRetained(pixels)
        guard let provider = CGDataProvider(
            dataInfo: owner.toOpaque(), data: pixels.base, size: bytesPerRow * height,
            releaseData: { info, _, _ in
                info.map { Unmanaged<ScratchBuffer<UInt8>>.fromOpaque($0).release() }
            }
        ) else {
            owner.release()
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
