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

    @Test func heicAndHeifRemainExactFactsButShareOneFileTypeChoice() {
        let heic = MediaFormatToken(rawValue: "HEIC")
        let heif = MediaFormatToken(rawValue: "HEIF")
        let options = CatalogFilterOptions(formatsByKind: [
            .image: [heic, heif, MediaFormatToken(rawValue: "JPEG")],
        ])

        #expect(options.formats(for: .image) == [heic, heif, MediaFormatToken(rawValue: "JPEG")])
        #expect(options.fileTypes(for: .image) == [
            MediaFileTypeOption(format: heic),
            MediaFileTypeOption(format: MediaFormatToken(rawValue: "JPEG")),
        ])
        #expect(options.fileTypes(for: .image).first?.label == "HEIF / HEIC")
        #expect(Set(options.fileTypes(for: .image).first?.formats ?? []) == [heic, heif])
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
        #expect(formatOnly.formats == [MediaFormatToken(rawValue: "JPEG")])

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
