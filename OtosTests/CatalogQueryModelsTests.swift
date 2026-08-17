@testable import OtosKit
import Testing

struct CatalogQueryModelsTests {
    @Test func canonicalExtensionUsesApplePreferenceForKnownAliases() {
        #expect(CanonicalMediaExtension.forDateTimeName(
            contentTypeIdentifier: "public.heif",
            sourceExtension: "HIF"
        ) == "heif")
        #expect(CanonicalMediaExtension.forDateTimeName(
            contentTypeIdentifier: "public.heic",
            sourceExtension: "HEIC"
        ) == "heic")
        #expect(CanonicalMediaExtension.forDateTimeName(
            contentTypeIdentifier: "public.jpeg",
            sourceExtension: "JPG"
        ) == "jpeg")
        #expect(CanonicalMediaExtension.forDateTimeName(
            contentTypeIdentifier: "public.tiff",
            sourceExtension: "TIF"
        ) == "tiff")
    }

    @Test func canonicalExtensionPreservesUnknownSourceSpelling() {
        #expect(CanonicalMediaExtension.forDateTimeName(
            contentTypeIdentifier: nil,
            sourceExtension: "Odd"
        ) == "Odd")
        #expect(CanonicalMediaExtension.forDateTimeName(
            contentTypeIdentifier: "dyn.unknown",
            sourceExtension: "Odd"
        ) == "Odd")
    }

    @Test func sortOrdersExposeSixCompleteUserFacingChoices() {
        #expect(MediaSortOrder.allCases.map(\.label) == [
            "Date — Newest First",
            "Date — Oldest First",
            "Filename — A to Z",
            "Filename — Z to A",
            "Size — Largest First",
            "Size — Smallest First",
        ])
        #expect(MediaSortOrder.defaultOrder == .dateNewest)
    }
}
