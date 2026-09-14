import CoreGraphics
import Foundation

/// Loupe info overlay model guide
///
/// The read-only facts the loupe shows on I (APP-041): file name, capture date,
/// pixel dimensions, kind and format, and file size. Every value comes from a catalog
/// fact the app already holds — `MediaAsset` plus the native size the preview decode
/// reported — and nothing is fetched for the overlay. A fact the catalog does not have
/// reads `Unknown` rather than disappearing (APP-001, DES-053).
nonisolated struct LoupeInfoModel: Equatable, Sendable {
    static let unknown = "Unknown"

    let fileName: String
    let captureDate: String
    let dimensions: String
    let kind: String
    let fileSize: String

    static func make(
        id: MediaAssetID,
        asset: MediaAsset?,
        kind: MediaKind?,
        nativePixelSize: CGSize?,
        calendar: Calendar = .current
    ) -> LoupeInfoModel {
        let fileName = asset?.name ?? URL(fileURLWithPath: id.relativePath.rawValue).lastPathComponent
        let captureDate: String = if let date = asset?.bestCaptureDate {
            date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar))
        } else {
            unknown
        }
        let dimensions: String = if let size = nativePixelSize, size.width > 0, size.height > 0 {
            "\(Int(size.width)) × \(Int(size.height))"
        } else {
            unknown
        }
        let resolvedKind = kind ?? asset?.bestKind
        let kindLabel: String? = switch resolvedKind {
        case .image: "Image"
        case .raw: "RAW image"
        case .video: "Video"
        case .none: nil
        }
        let format = URL(fileURLWithPath: id.relativePath.rawValue).pathExtension.uppercased()
        let kindText: String = switch (kindLabel, format.isEmpty) {
        case let (label?, false): "\(label) · \(format)"
        case let (label?, true): label
        case (nil, false): format
        case (nil, true): unknown
        }
        let fileSize: String = if let bytes = asset?.byteSize {
            ImportBarByteFormat.string(bytes: bytes)
        } else {
            unknown
        }
        return LoupeInfoModel(
            fileName: fileName,
            captureDate: captureDate,
            dimensions: dimensions,
            kind: kindText,
            fileSize: fileSize
        )
    }
}
