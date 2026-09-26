# Develop.swift

Native full-resolution RAW boundary for the saved model. Extract to compile with the evaluator. Call `encodedRGBA(try developNeutral(url))`, then `MetalLook.apply`. Tag the resulting encoded pixels as sRGB for display/export. This synchronous reference holds whole images in memory; app scheduling and memory management are separate implementation work.

```swift
import CoreImage
import Darwin
import Foundation

enum DevelopmentError: Error { case unavailableOriginal, unsupportedRAW, decoderUnavailable, renderFailed }

/// Synchronous reference: run off the main actor. Never request cloud materialization.
func developNeutral(_ url: URL) throws -> CGImage {
    var info = stat()
    guard lstat(url.path, &info) == 0,
          info.st_mode & S_IFMT == S_IFREG,
          info.st_flags & 0x4000_0000 == 0
    else {
        throw DevelopmentError.unavailableOriginal
    }
    let bytes = try Data(contentsOf: url)
    guard let raw = CIRAWFilter(imageData: bytes, identifierHint: "com.sony.arw-raw-image") else {
        throw DevelopmentError.unsupportedRAW
    }
    let decoder = CIRAWDecoderVersion(rawValue: "8")
    guard raw.supportedDecoderVersions.contains(decoder) else {
        throw DevelopmentError.decoderUnavailable
    }
    raw.decoderVersion = decoder
    raw.scaleFactor = 1
    raw.boostAmount = 0
    raw.localToneMapAmount = 0
    raw.contrastAmount = 0
    raw.sharpnessAmount = 0
    raw.detailAmount = 0
    // Retain per-file native white balance, exposure, noise, lens, gamut and highlight defaults.
    guard let output = raw.outputImage else { throw DevelopmentError.renderFailed }
    let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    ])
    guard let encoded = context.createCGImage(output, from: output.extent,
                                              format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
    else {
        throw DevelopmentError.renderFailed
    }
    return encoded
}

/// Interpret the encoded samples numerically. Do not linearize them before the learned look.
func encodedRGBA(_ image: CGImage) -> [Float] {
    let input = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
    var pixels = [Float](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes {
        context.render(input, toBitmap: $0.baseAddress!, rowBytes: image.width * 16,
                       bounds: input.extent, format: .RGBAf, colorSpace: nil)
    }
    return pixels
}
```
