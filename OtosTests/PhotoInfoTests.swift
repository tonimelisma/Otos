import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// The Info pane's facts (APP-041): known values are formatted, unknown ones say so
/// instead of vanishing.
struct PhotoInfoTests {
    @Test func unknownFactsReadUnknown() {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "Trip/IMG_0001.ARW")
        )

        let model = PhotoInfo.make(id: id, asset: nil, kind: nil, nativePixelSize: nil)

        #expect(model.fileName == "IMG_0001.ARW")
        #expect(model.captureDate == PhotoInfo.unknown)
        #expect(model.dimensions == PhotoInfo.unknown)
        #expect(model.kind == "ARW")
        #expect(model.fileSize == PhotoInfo.unknown)
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

        let model = PhotoInfo.make(
            id: id,
            asset: asset,
            kind: .video,
            nativePixelSize: CGSize(width: 3840, height: 2160)
        )

        #expect(model.fileName == "clip.mov")
        #expect(model.dimensions == "3840 × 2160")
        #expect(model.kind == "Video · MOV")
        #expect(model.fileSize == "52 MB")
        #expect(model.captureDate == PhotoInfo.unknown)
    }
}
