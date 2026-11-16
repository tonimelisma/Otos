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
