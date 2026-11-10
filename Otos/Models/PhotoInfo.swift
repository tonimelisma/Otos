import CoreGraphics
import Foundation

/// Photo info guide
///
/// The read-only facts the inspector's Info pane shows for the current target (APP-041):
/// file name, capture date, pixel dimensions, kind and format, and file size. Every value
/// is a catalog fact the app already holds — `MediaAsset` plus the upright size the
/// catalog's metadata reports — and nothing is fetched for the pane. A fact the catalog
/// does not have reads `Unknown` rather than disappearing (APP-001, DES-053).
nonisolated struct PhotoInfo: Equatable, Sendable {
    static let unknown = "Unknown"

    /// The asset these facts describe.
    let id: MediaAssetID
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
    ) -> PhotoInfo {
        let fileName = asset?.name ?? id.relativePath.fileName
        // Written as the clock where it was taken read it, whatever zone this Mac is in.
        let captureDate: String = if let local = asset?.captureLocalTime {
            local.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar))
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
        let format = id.relativePath.fileExtension.uppercased()
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
        return PhotoInfo(
            id: id,
            fileName: fileName,
            captureDate: captureDate,
            dimensions: dimensions,
            kind: kindText,
            fileSize: fileSize
        )
    }
}
