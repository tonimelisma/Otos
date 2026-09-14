import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// The loupe info overlay's facts (APP-041): known values are formatted, unknown ones
/// say so instead of vanishing.
struct LoupeInfoModelTests {
    @Test func unknownFactsReadUnknown() {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "Trip/IMG_0001.ARW")
        )

        let model = LoupeInfoModel.make(id: id, asset: nil, kind: nil, nativePixelSize: nil)

        #expect(model.fileName == "IMG_0001.ARW")
        #expect(model.captureDate == LoupeInfoModel.unknown)
        #expect(model.dimensions == LoupeInfoModel.unknown)
        #expect(model.kind == "ARW")
        #expect(model.fileSize == LoupeInfoModel.unknown)
    }

    @Test func knownFactsAreFormatted() {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "clip.mov")
        )
        let asset = MediaAsset(
            libraryRootPath: id.libraryRootPath,
            relativePath: id.relativePath,
            name: "clip.mov",
            contentTypeIdentifier: "com.apple.quicktime-movie",
            byteSize: 52_400_000,
            createdAt: nil,
            contentModifiedAt: nil
        )

        let model = LoupeInfoModel.make(id: id, asset: asset, kind: .video, nativePixelSize: CGSize(width: 3840, height: 2160))

        #expect(model.fileName == "clip.mov")
        #expect(model.dimensions == "3840 × 2160")
        #expect(model.kind == "Video · MOV")
        #expect(model.fileSize == "52 MB")
        #expect(model.captureDate == LoupeInfoModel.unknown)
    }
}
