@testable import Otos
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

    @Test func heicHeifAndHifRemainExactFactsButShareOneFileTypeChoice() {
        let heic = MediaFormatToken(rawValue: "HEIC")
        let heif = MediaFormatToken(rawValue: "HEIF")
        let hif = MediaFormatToken(rawValue: "HIF")
        let options = CatalogFilterOptions(formatsByKind: [
            .image: [heic, heif, hif, MediaFormatToken(rawValue: "JPEG")],
        ])

        #expect(options.formats(for: .image) == [heic, heif, hif, MediaFormatToken(rawValue: "JPEG")])
        #expect(options.fileTypes(for: .image) == [
            MediaFileTypeOption(format: heic),
            MediaFileTypeOption(format: MediaFormatToken(rawValue: "JPEG")),
        ])
        #expect(options.fileTypes(for: .image).first?.label == "HEIF")
        #expect(Set(options.fileTypes(for: .image).first?.formats ?? []) == [heic, heif, hif])
    }

    @Test func selectingAWholeKindReplacesItsChildFileTypes() {
        let options = filterOptions()
        let jpeg = MediaFileTypeOption(format: MediaFormatToken(rawValue: "JPEG"))
        let formatOnly = MediaFilter.all.settingFileType(
            jpeg,
            kind: .image,
            included: true,
            options: options
        )

        #expect(formatOnly.kinds.isEmpty)
        #expect(formatOnly.formats == [
            MediaFormatToken(rawValue: "JPE"),
            MediaFormatToken(rawValue: "JPEG"),
            MediaFormatToken(rawValue: "JPG"),
        ])

        let allImages = formatOnly.settingKind(.image, included: true, options: options)
        #expect(allImages.kinds == [.image])
        #expect(allImages.formats.isEmpty)
    }

    @Test func removingOneFileTypeFromAWholeKindProducesTheExpectedMixedSubset() {
        let options = filterOptions()
        let jpeg = MediaFileTypeOption(format: MediaFormatToken(rawValue: "JPEG"))
        let allImages = MediaFilter(kinds: [.image])

        let withoutJPEG = allImages.settingFileType(
            jpeg,
            kind: .image,
            included: false,
            options: options
        )

        #expect(withoutJPEG.kinds.isEmpty)
        #expect(withoutJPEG.formats == [
            MediaFormatToken(rawValue: "HEIC"),
            MediaFormatToken(rawValue: "HEIF"),
            MediaFormatToken(rawValue: "HIF"),
        ])
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
                MediaFormatToken(rawValue: "HEIC"),
                MediaFormatToken(rawValue: "HEIF"),
                MediaFormatToken(rawValue: "JPEG"),
            ],
            .video: [MediaFormatToken(rawValue: "MOV")],
        ])
    }
}
