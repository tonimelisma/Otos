@testable import OtosKit
import Testing

struct CatalogFilterOptionsTests {
    @Test func availableKindsIncludeKindsWithNoFormats() {
        let options = CatalogFilterOptions(formatsByKind: [
            .image: [],
            .video: [MediaFormatToken(rawValue: "MOV")],
        ])

        #expect(options.availableKinds == [.image, .video])
        #expect(options.formats(for: .image).isEmpty)
    }

    /// File types carry MediaMetadata's names (ADR 0039): every spelling of one type is one
    /// token, so it is one filter row, and a token restored from an older build is renamed.
    @Test func fileTypesTakeTheLibrarysNames() {
        #expect(["heic", "HEIF", "hif"].map { MediaFormatToken.normalize(extension: $0)?.rawValue } == ["HEIF", "HEIF", "HEIF"])
        #expect(["jpg", "JPE", "jpeg"].map { MediaFormatToken.normalize(extension: $0)?.rawValue } == ["JPEG", "JPEG", "JPEG"])
        #expect(MediaFormatToken.normalize(extension: "tif")?.rawValue == "TIFF")
        #expect(MediaFormatToken.normalize(extension: "arw")?.rawValue == "ARW")
        #expect(MediaFormatToken.normalize(extension: "xyz")?.rawValue == "XYZ")
        let options = CatalogFilterOptions(formatsByKind: [
            .image: [MediaFormatToken(rawValue: "JPEG"), MediaFormatToken(rawValue: "HEIF")],
        ])
        #expect(options.formats(for: .image) == [MediaFormatToken(rawValue: "HEIF"), MediaFormatToken(rawValue: "JPEG")])
    }

    @Test func selectingAWholeKindReplacesItsChildFileTypes() {
        let options = filterOptions()
        let jpeg = MediaFormatToken(rawValue: "JPEG")
        let formatOnly = MediaFilter.all.settingFileType(jpeg, kind: .image, included: true, options: options)

        #expect(formatOnly.kinds.isEmpty)
        #expect(formatOnly.formats == [jpeg])

        let allImages = formatOnly.settingKind(.image, included: true, options: options)
        #expect(allImages.kinds == [.image])
        #expect(allImages.formats.isEmpty)
    }

    @Test func removingOneFileTypeFromAWholeKindProducesTheExpectedMixedSubset() {
        let options = filterOptions()
        let allImages = MediaFilter(kinds: [.image])

        let withoutJPEG = allImages.settingFileType(
            MediaFormatToken(rawValue: "JPEG"),
            kind: .image,
            included: false,
            options: options
        )

        #expect(withoutJPEG.kinds.isEmpty)
        #expect(withoutJPEG.formats == [MediaFormatToken(rawValue: "ARW"), MediaFormatToken(rawValue: "HEIF")])
    }

    @Test func selectingEveryAvailableKindCanonicalizesToAllItems() {
        let options = filterOptions()
        let images = MediaFilter.all.settingKind(.image, included: true, options: options)
        let everything = images.settingKind(.video, included: true, options: options)

        #expect(everything == .all)
        #expect(!everything.isActive)
    }

    private func filterOptions() -> CatalogFilterOptions {
        CatalogFilterOptions(formatsByKind: [
            .image: [
                MediaFormatToken(rawValue: "ARW"),
                MediaFormatToken(rawValue: "HEIF"),
                MediaFormatToken(rawValue: "JPEG"),
            ],
            .video: [MediaFormatToken(rawValue: "MOV")],
        ])
    }
}
