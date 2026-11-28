import Foundation
@testable import OtosKit
import Testing

/// Every thumbnail outside the grid answers one of three facts (`ThumbnailLoad`): a stored
/// thumbnail that does not decode is unavailable and draws DES-063's slash glyph, one not
/// stored yet leaves the answer open, and a picture already painted is never replaced by
/// anything but a newer picture.
@Suite(.testScope)
@MainActor
struct ThumbnailLoadTests {
    // Validates: APP-095
    @Test func aStoredThumbnailThatDoesNotDecodeIsUnavailableAndDrawsTheSlashGlyph() async throws {
        let directory = try makeTestDirectory()
        try Data("not an image".utf8).write(to: ThumbnailStore.url(for: "broken.jpg", in: directory))
        let video = makeDetail(thumbnailPath: "broken.jpg", kind: .video)
        let photo = makeDetail(thumbnailPath: "broken.jpg", kind: .image)

        let videoLoad = await ThumbnailLoad.decoding(video, thumbnailDirectory: directory)
        let photoLoad = await ThumbnailLoad.decoding(photo, thumbnailDirectory: directory)

        guard case .unavailable(kind: .video) = videoLoad else {
            Issue.record("expected unavailable, got \(videoLoad)")
            return
        }
        #expect(videoLoad.image == nil)
        // The detail's kind names the glyph, so a pane that knows no kind draws the right one.
        #expect(videoLoad.placeholderSystemName(for: nil) == "video.slash")
        #expect(photoLoad.placeholderSystemName(for: nil) == "photo.slash")
    }

    @Test func aThumbnailNotStoredYetLeavesTheAnswerOpen() async throws {
        let directory = try makeTestDirectory()
        let load = await ThumbnailLoad.decoding(makeDetail(thumbnailPath: nil, kind: .raw), thumbnailDirectory: directory)

        guard case .notYet = load else {
            Issue.record("expected notYet, got \(load)")
            return
        }
        #expect(load.placeholderSystemName(for: .raw) == "r.square")
    }

    // Validates: APP-095
    @Test func aPaintedPictureIsReplacedOnlyByANewerPicture() {
        let painted = DisplayImage.fixture(width: 8)
        let newer = DisplayImage.fixture(width: 12)
        let shown = ThumbnailLoad.decoded(painted)

        #expect(shown.updated(by: .unavailable(kind: .image)).image?.width == 8)
        #expect(shown.updated(by: .notYet).image?.width == 8)
        #expect(shown.updated(by: .decoded(newer)).image?.width == 12)
        // An open answer never takes back a known failure.
        let failed = ThumbnailLoad.notYet.updated(by: .unavailable(kind: .image))
        #expect(failed.updated(by: .notYet).placeholderSystemName(for: .image) == "photo.slash")
    }
}

private func makeDetail(thumbnailPath: String?, kind: MediaKind) -> MediaTileDetail {
    MediaTileDetail(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: "a.mov"),
        thumbnailPath: thumbnailPath,
        bestKind: kind,
        renderedSourceSize: thumbnailPath == nil ? nil : 100,
        renderedSourceMTimeSeconds: thumbnailPath == nil ? nil : 1
    )
}
