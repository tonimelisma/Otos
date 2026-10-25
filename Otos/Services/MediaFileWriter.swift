import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a photo as Otos shows it, or a video's edited range, to a file for a hand-off
/// (ADR 0037) or an export (ADR 0038). One owner, so both write the same file for the same
/// photo:
/// - a rendered image as JPEG or HEIC, carrying the original's Exif, GPS, TIFF and IPTC
///   metadata except what rendering made untrue: the pixels are upright and may be
///   cropped or scaled, so orientation and pixel size are reset rather than copied;
/// - a video's range, copied without re-encoding, its metadata kept.
///
/// Location can be removed from either.
nonisolated enum MediaFileWriter {
    enum WriteError: Error {
        case unsupportedType
        case encodeFailed
        case exportUnavailable
    }

    @concurrent
    static func writeImage(
        _ image: CGImage,
        as type: UTType,
        quality: Double,
        metadataOf original: URL,
        removingLocation: Bool,
        to url: URL
    ) async throws {
        guard type == .jpeg || type == .heic else {
            throw WriteError.unsupportedType
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let source = CGImageSourceCreateWithURL(original as CFURL, nil),
           let originalProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            var keys = [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
            if !removingLocation {
                keys.append(kCGImagePropertyGPSDictionary)
            }
            for key in keys {
                properties[key] = originalProperties[key]
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw WriteError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WriteError.encodeFailed
        }
    }

    /// The recipe's range of a video (the whole video when it is untrimmed) as a QuickTime
    /// movie, copied without re-encoding. Removing location applies AVFoundation's sharing
    /// filter, which drops location and other identifying metadata.
    @concurrent
    static func writeVideo(_ original: URL, recipe: EditRecipe, removingLocation: Bool, to url: URL) async throws {
        let asset = AVURLAsset(url: original)
        let duration = try await asset.load(.duration)
        let start = recipe.trimStart.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .zero
        let end = recipe.trimEnd.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? duration
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw WriteError.exportUnavailable
        }
        session.timeRange = CMTimeRange(start: start, end: end)
        if removingLocation {
            session.metadataItemFilter = .forSharing()
        }
        try await session.export(to: url, as: .mov)
    }
}
