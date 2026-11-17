import Foundation
@testable import OtosKit
import Testing

/// The resource checkpoints read what the kernel and the Store hold; these pin the parts a
/// scorecard depends on.
struct ProcessResourcesTests {
    /// The footprint is the kernel's charge for this process, never zero for a live one, and
    /// its lifetime peak is at least what it is now.
    @Test func aSampleReadsThisProcessFootprintAndItsPeak() throws {
        let sample = ProcessResourceSample.current()
        #expect(sample.footprintBytes > 0)
        let peak = try #require(sample.peakFootprintBytes)
        #expect(peak >= sample.footprintBytes / 2)
        #expect(sample.memoryFields["footprintMB"] != nil)
        #expect(sample.usageFields["cpuMs"] != "unknown")
        #expect(sample.pageIns != nil)
    }

    /// The usage line carries page-ins as a plain count beside CPU and disk, and a counter the
    /// kernel did not report reads `unknown`, never zero.
    @Test func theUsageLineCarriesPageInsAndSaysUnknownForAMissingCounter() {
        func sample(pageIns: UInt64?) -> ProcessResourceSample {
            ProcessResourceSample(
                footprintBytes: 1, peakFootprintBytes: nil, residentBytes: 1, sqliteBytes: nil,
                systemFreeBytes: nil, systemCompressorBytes: nil, swapUsedBytes: nil,
                cpuMilliseconds: 451, diskBytesRead: 23 * 1_048_576, diskBytesWritten: nil, pageIns: pageIns,
                assetIdentities: 165_000, assetIdentityBytes: 18 * 1_048_576
            )
        }
        #expect(sample(pageIns: 1480).usageFields == [
            "cpuMs": "451", "diskReadMB": "23", "diskWrittenMB": "unknown", "pageIns": "1480",
        ])
        #expect(sample(pageIns: nil).usageFields["pageIns"] == "unknown")
        // The identity table never frees, so the memory line carries its pairs and bytes.
        #expect(sample(pageIns: nil).memoryFields["assetIdentities"] == "165000")
        #expect(sample(pageIns: nil).memoryFields["assetIdentityMB"] == "18")
    }

    /// Each notification counts once, and once for each kind of fact it names.
    @Test func theChangeTallyCountsNotificationsByKindOfFact() {
        let tally = CatalogChangeTally()
        tally.record(.changed([.detail, .images]))
        tally.record(.changed(.detail))
        tally.record(.assetsAdded)

        let counts = tally.current
        #expect(counts.notifications == 3)
        #expect(counts.byFact["detail"] == 2)
        #expect(counts.byFact["images"] == 1)
        #expect(counts.byFact["membership"] == 1)
        let fields = CatalogStoreUse(connections: CatalogConnectionActivity.Use(holds: []), changes: counts).fields
        #expect(fields["changes"] == "3")
        #expect(fields["changeFacts"] == "detail:2,images:1,membership:1")
    }
}
