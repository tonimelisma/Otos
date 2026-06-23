import Foundation
@testable import Otos
import Testing

/// The precomputed sort key replaces localized collation per comparison. These
/// tests pin the order-preserving properties the cheap key must keep: numeric-aware
/// ordering, case insensitivity, and library-then-path grouping.
struct MediaSortKeyTests {
    private func key(_ string: String) -> String {
        MediaSortKey.naturalKey(string)
    }

    @Test func numbersOrderNumericallyNotLexically() {
        // "2" sorts before "10" even though "10" is lexically smaller.
        #expect(key("img2.jpg") < key("img10.jpg"))
        #expect(key("img10.jpg") < key("img100.jpg"))
    }

    @Test func keyIsCaseInsensitive() {
        #expect(key("Photo.JPG") == key("photo.jpg"))
    }

    @Test func timestampNamesKeepChronologicalOrder() {
        #expect(key("20260601_085532.heif") < key("20260621_170223.heif"))
    }

    @Test func assetSortKeyGroupsByLibraryThenPath() {
        let inLibraryA = MediaAsset(
            libraryRootPath: LibraryRootPath(rawValue: "/A"),
            relativePath: MediaRelativePath(rawValue: "z.jpg"),
            name: nil,
            contentTypeIdentifier: nil,
            byteSize: nil,
            createdAt: nil,
            contentModifiedAt: nil
        )
        let inLibraryB = MediaAsset(
            libraryRootPath: LibraryRootPath(rawValue: "/B"),
            relativePath: MediaRelativePath(rawValue: "a.jpg"),
            name: nil,
            contentTypeIdentifier: nil,
            byteSize: nil,
            createdAt: nil,
            contentModifiedAt: nil
        )

        // Library /A precedes /B regardless of the within-library filename.
        #expect(inLibraryA.sortKey < inLibraryB.sortKey)
    }
}
