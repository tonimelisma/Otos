@testable import OtosKit
import Testing

struct CatalogFilterOptionsTests {
    private let jpeg = MediaFormatToken(rawValue: "JPEG")
    private let arw = MediaFormatToken(rawValue: "ARW")

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
        #expect(options.formats(for: .image, holding: .all) == [MediaFormatToken(rawValue: "HEIF"), jpeg])
    }

    /// The reported case: a RAW filter chosen in one library, then a scope — or a whole
    /// catalog — with no ARW in it. The filter still names ARW, so ARW still has a row
    /// under RAW, ticked, where it can be cleared.
    @Test func everyHeldFileTypeHasARowEvenWhereNothingHasIt() {
        let heldARW = MediaFilter(fileTypes: [FilterFileType(kind: .raw, format: arw)])
        let noRAW = CatalogFilterOptions(formatsByKind: [.image: [jpeg]])

        #expect(noRAW.formats(for: .raw, holding: heldARW) == [arw])
        #expect(noRAW.formats(for: .raw, holding: .all).isEmpty)
        #expect(noRAW.formats(for: .image, holding: heldARW) == [jpeg])

        let cleared = heldARW.settingFileType(arw, kind: .raw, included: false, options: noRAW)
        #expect(cleared == .all)
    }

    @Test func selectingAWholeKindReplacesItsChildFileTypes() {
        let options = filterOptions()
        let formatOnly = MediaFilter.all.settingFileType(jpeg, kind: .image, included: true, options: options)

        #expect(formatOnly.kinds.isEmpty)
        #expect(formatOnly.fileTypes == [FilterFileType(kind: .image, format: jpeg)])

        let allImages = formatOnly.settingKind(.image, included: true)
        #expect(allImages.kinds == [.image])
        #expect(allImages.fileTypes.isEmpty)
    }

    @Test func removingOneFileTypeFromAWholeKindProducesTheExpectedMixedSubset() {
        let allImages = MediaFilter(kinds: [.image])

        let withoutJPEG = allImages.settingFileType(jpeg, kind: .image, included: false, options: filterOptions())

        #expect(withoutJPEG.kinds.isEmpty)
        #expect(withoutJPEG.fileTypes == [
            FilterFileType(kind: .image, format: MediaFormatToken(rawValue: "HEIF")),
            FilterFileType(kind: .image, format: MediaFormatToken(rawValue: "PNG")),
        ])
    }

    @Test func selectingEveryFileTypeOfAKindSelectsTheKind() {
        let options = filterOptions()
        let filter = ["HEIF", "JPEG", "PNG"].reduce(MediaFilter.all) { filter, name in
            filter.settingFileType(MediaFormatToken(rawValue: name), kind: .image, included: true, options: options)
        }

        #expect(filter == MediaFilter(kinds: [.image]))
    }

    /// Every kind is one choice, present or not, so "all of them" is the same everywhere.
    @Test func selectingEveryKindCanonicalizesToAllItems() {
        let twoKinds = MediaFilter.all.settingKind(.image, included: true).settingKind(.video, included: true)
        #expect(twoKinds.isActive)

        let everything = twoKinds.settingKind(.raw, included: true)
        #expect(everything == .all)
        #expect(!everything.isActive)
    }

    private func filterOptions() -> CatalogFilterOptions {
        CatalogFilterOptions(formatsByKind: [
            .image: [
                MediaFormatToken(rawValue: "HEIF"),
                MediaFormatToken(rawValue: "JPEG"),
                MediaFormatToken(rawValue: "PNG"),
            ],
            .raw: [arw],
            .video: [MediaFormatToken(rawValue: "MOV")],
        ])
    }

    /// People and Places show their head: the first five rows, any checked row past them,
    /// and the whole list once expanded; Show All is offered only past five rows.
    @Test func aLongListShowsItsHeadAndEveryCheckedRow() {
        let rows = Array(1 ... 8)
        let collapsed = FilterListHead.rows(rows, isChecked: { $0 == 7 }, isExpanded: false)
        #expect(collapsed.shown == [1, 2, 3, 4, 5, 7])
        #expect(collapsed.isLong)
        #expect(FilterListHead.rows(rows, isChecked: { _ in false }, isExpanded: true).shown == rows)
        #expect(!FilterListHead.rows(Array(1 ... 5), isChecked: { _ in false }, isExpanded: false).isLong)
    }
}
