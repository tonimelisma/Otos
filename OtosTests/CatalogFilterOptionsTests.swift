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
}
