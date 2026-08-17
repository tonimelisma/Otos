import Foundation
@testable import Otos
import Testing

/// DES-069 grouping is a pure linear pass over an already date-sorted list — these
/// tests exercise `MediaGridSectionGroupingPolicy` directly, with no live
/// `NSCollectionView` involved.
@MainActor
struct MediaGridSectionGroupingPolicyTests {
    @Test func emptyDayBucketsProducesOneUngroupedRun() {
        let ids = ["a.jpg", "b.jpg", "c.jpg"].map(makeGroupingAssetID)

        let runs = MediaGridSectionGroupingPolicy.sectionRuns(orderedIDs: ids, dayBuckets: [])

        #expect(runs.count == 1)
        #expect(runs[0].section == .ungrouped)
        #expect(runs[0].ids == ids)
    }

    @Test func mismatchedBucketCountFallsBackToUngrouped() {
        let ids = ["a.jpg", "b.jpg"].map(makeGroupingAssetID)

        let runs = MediaGridSectionGroupingPolicy.sectionRuns(
            orderedIDs: ids,
            dayBuckets: [Date(timeIntervalSince1970: 0)]
        )

        #expect(runs.count == 1)
        #expect(runs[0].section == .ungrouped)
        #expect(runs[0].ids == ids)
    }

    /// Matches pre-day-header behavior: an empty grid still produces one empty
    /// `.ungrouped` section rather than zero sections.
    @Test func emptyOrderedIDsProducesOneEmptyUngroupedRun() {
        let runs = MediaGridSectionGroupingPolicy.sectionRuns(orderedIDs: [], dayBuckets: [])
        #expect(runs.count == 1)
        #expect(runs[0].section == .ungrouped)
        #expect(runs[0].ids.isEmpty)
    }

    @Test func contiguousSameDayRunsBecomeOneSectionEach() {
        let dayOne = Date(timeIntervalSince1970: 0)
        let dayTwo = Date(timeIntervalSince1970: 86400)
        let ids = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].map(makeGroupingAssetID)

        let runs = MediaGridSectionGroupingPolicy.sectionRuns(
            orderedIDs: ids,
            dayBuckets: [dayOne, dayOne, dayTwo, dayTwo]
        )

        #expect(runs.count == 2)
        #expect(runs[0].section == .day(dayOne))
        #expect(runs[0].ids == Array(ids[0 ... 1]))
        #expect(runs[1].section == .day(dayTwo))
        #expect(runs[1].ids == Array(ids[2 ... 3]))
    }

    @Test func nilBucketGetsItsOwnRunRatherThanBeingDropped() {
        let dayOne = Date(timeIntervalSince1970: 0)
        let ids = ["a.jpg", "b.jpg", "c.jpg"].map(makeGroupingAssetID)

        let runs = MediaGridSectionGroupingPolicy.sectionRuns(
            orderedIDs: ids,
            dayBuckets: [dayOne, nil, nil]
        )

        #expect(runs.count == 2)
        #expect(runs[0].section == .day(dayOne))
        #expect(runs[0].ids == [ids[0]])
        #expect(runs[1].section == .day(nil))
        #expect(runs[1].ids == Array(ids[1 ... 2]))
    }

    /// The pass is linear, not a group-by: a day bucket that reappears after a
    /// different bucket interrupts it produces a second, separate run rather than
    /// being merged with the first (correct because the list is presumed already
    /// date-sorted, so a non-contiguous repeat should not happen in practice, but
    /// the policy must not silently coalesce it if it does).
    @Test func nonContiguousSameDayProducesSeparateRuns() {
        let dayOne = Date(timeIntervalSince1970: 0)
        let dayTwo = Date(timeIntervalSince1970: 86400)
        let ids = ["a.jpg", "b.jpg", "c.jpg"].map(makeGroupingAssetID)

        let runs = MediaGridSectionGroupingPolicy.sectionRuns(
            orderedIDs: ids,
            dayBuckets: [dayOne, dayTwo, dayOne]
        )

        #expect(runs.count == 3)
        #expect(runs[0].section == .day(dayOne))
        #expect(runs[1].section == .day(dayTwo))
        #expect(runs[2].section == .day(dayOne))
    }
}

@MainActor
private func makeGroupingAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}
