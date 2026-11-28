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

    // Validates: ARC-070
    /// The usage line carries page-ins as a plain count beside CPU and disk, and a counter the
    /// kernel did not report reads `unknown`, never zero.
    @Test func theUsageLineCarriesPageInsAndSaysUnknownForAMissingCounter() {
        func sample(pageIns: UInt64?) -> ProcessResourceSample {
            ProcessResourceSample(
                footprintBytes: 1, peakFootprintBytes: nil, residentBytes: 1, sqliteBytes: nil,
                systemFreeBytes: nil, systemCompressorBytes: nil, swapUsedBytes: nil,
                cpuMilliseconds: 451, diskBytesRead: 23 * 1_048_576, diskBytesWritten: nil, pageIns: pageIns,
                assetIdentities: 165_000, assetIdentityBytes: 18 * 1_048_576, assetIdentityLargestRebuild: 4096
            )
        }
        #expect(sample(pageIns: 1480).usageFields == [
            "cpuMs": "451", "diskReadMB": "23", "diskWrittenMB": "unknown", "pageIns": "1480",
        ])
        #expect(sample(pageIns: nil).usageFields["pageIns"] == "unknown")
        // The identity table never frees, so the memory line carries its pairs and bytes.
        #expect(sample(pageIns: nil).memoryFields["assetIdentities"] == "165000")
        #expect(sample(pageIns: nil).memoryFields["assetIdentityMB"] == "18")
        #expect(sample(pageIns: nil).memoryFields["assetIdentityLargestRebuild"] == "4096")
    }

    /// The pressure line's level comes from the kernel's own numbers, and a value the kernel
    /// does not define is unknown, never normal.
    @Test func theKernelPressureLevelIsNamedAsTheSourceNamesItAndReadsAsANumber() throws {
        #expect(SystemPressure.memory(kernelValue: 1) == .normal)
        #expect(SystemPressure.memory(kernelValue: 2) == .warning)
        #expect(SystemPressure.memory(kernelValue: 4) == .critical)
        #expect(SystemPressure.memory(kernelValue: 0) == nil)
        #expect(SystemPressure.memory(kernelValue: 3) == nil)
        for level in [MachineConditions.Memory.normal, .warning, .critical] {
            #expect(SystemPressure.memory(kernelValue: SystemPressure.kernelValue(level)) == level)
        }
        let kernel = try #require(SystemPressure.kernelMemory())
        let fields = kernel.logFields
        let level = try #require(fields["systemLevel"].flatMap(Int.init))
        #expect([1, 2, 4].contains(level))
        let available = try #require(kernel.availablePercent)
        #expect((0 ... 100).contains(available))
    }

    /// A helper's usage is the kernel's for that process: readable while it runs, gone once
    /// it has exited and been reaped.
    @Test func aHelperProcessUsageIsReadWhileItRunsAndNotAfter() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/cat")
        let input = Pipe()
        process.standardInput = input
        let exited = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.continuation.finish() }
        try process.run()
        let usage = try #require(ProcessResourceSample.rusage(of: process.processIdentifier))
        #expect(usage.peakFootprint > 0)
        try input.fileHandleForWriting.close()
        for await _ in exited.stream {}
        process.waitUntilExit()
        #expect(ProcessResourceSample.rusage(of: process.processIdentifier) == nil)
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
