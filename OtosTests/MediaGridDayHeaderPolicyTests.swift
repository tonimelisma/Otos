import Foundation
@testable import OtosKit
import Testing

/// DES-069: every day section draws its own in-flow header except the first, whose
/// header the bar already covers and which rubber-band scrolling would otherwise slide
/// out from under the bar as a duplicate.
struct MediaGridDayHeaderPolicyTests {
    private let structure: MediaGridStructure = {
        let buckets: [Date?] = Array(repeating: Date(timeIntervalSince1970: 86400 * 2), count: 3)
            + Array(repeating: Date(timeIntervalSince1970: 86400), count: 5)
            + [nil]
        let ids = buckets.indices.map {
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "\($0).jpg")
            )
        }
        return MediaGridStructure(orderedIDs: ids, dayBuckets: buckets)
    }()

    @Test func theFirstSectionDoesNotDrawItsOwnHeader() {
        #expect(MediaGridDayHeaderPolicy.presentation(section: 0, in: structure) == nil)
    }

    @Test func everyOtherSectionDrawsItsDayAndCount() {
        #expect(
            MediaGridDayHeaderPolicy.presentation(section: 1, in: structure)
                == .map(date: Date(timeIntervalSince1970: 86400), itemCount: 5)
        )
        #expect(
            MediaGridDayHeaderPolicy.presentation(section: 2, in: structure)
                == .map(date: nil, itemCount: 1)
        )
    }

    @Test func anUngroupedSectionDrawsNothing() {
        let ungrouped = MediaGridStructure(orderedIDs: structure.orderedIDs)
        #expect(MediaGridDayHeaderPolicy.presentation(section: 0, in: ungrouped) == nil)
        #expect(MediaGridDayHeaderPolicy.presentation(section: 1, in: ungrouped) == nil)
    }
}
