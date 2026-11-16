import Foundation
@testable import OtosKit
import Testing

/// What enrichment costs the footprint when it starts, on a catalog of the owner's shape
/// (plan 0116: peak footprint ≤ 700 MB). Measured by the kernel's own footprint
/// (`ProcessResourceSample`).
///
/// - **Claims.** Enrichment runs alone over the generated catalog for `passes` passes, where
///   every original is dataless and no download returns, as on a cloud-only library. What it
///   holds is its claim window and the hand-off (32 + 16 rows), not the backlog, so its passes
///   may add at most `startBoundMB`. Once its claims are given back, the footprint stays within
///   that bound.
/// - **Bytes.** The products of an original whose bytes are local stream through
///   `FileBytes`. Hashing a file of a few hundred MB in a task-group child, as the coordinator
///   runs it, adds at most `bytesBoundMB`. So does reading a still's original whole and
///   letting it go. Before `FileBytes`, each 1 MiB chunk was an autoreleased `NSData` kept until
///   the job ended, and a 300 MB hash left 300 MB in the footprint.
///
/// At the owner's size only on demand
/// (`OTOS_SCALE_TEST=1 script/check.sh --only EnrichmentLaunchMemoryTests`), alone, because the
/// footprint is the whole process's. Writes `build/enrichment-launch-memory/owner.txt`. A
/// measurement, not a benchmark.
@Suite(.testScope, .serialized)
struct EnrichmentLaunchMemoryTests {
    static let startBoundMB: Int64 = 40
    static let bytesBoundMB: Int64 = 8
    static let hashedFileMB = 300
    static let wholeFileMB = 64
    /// Passes enough to walk far past the window: each claims up to four batches of 32.
    static let passes = 200

    @Test(.enabled(if: StallReproductionTests.ownerSize))
    func enrichmentAddsItsWindowNotItsBacklog() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)

        let floor = ProcessResourceSample.current()
        let materializer = MaterializationCoordinator(
            store: store,
            executor: { _ in MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0) },
            volumeCapacity: ampleVolumeCapacity,
            status: { _ in .dataless }
        )
        let enrichment = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .notMaterialized },
            materializationRequester: materializer
        )
        await materializer.start()
        // The run loop's passes, driven one at a time so their count is the test's. Each claims
        // and routes as the loop does; the transfers it hands off are never run, so they stay in
        // flight, as a cloud-only library's downloads do for seconds each.
        for _ in 0 ..< Self.passes {
            _ = await enrichment.dequeueEnrichmentWork()
            _ = await enrichment.dequeueMaterializationSubmissions()
        }
        let started = ProcessResourceSample.current()
        let schedule = await enrichment.schedule
        let demands = schedule.materializations.count
        let kept = "parked=\(schedule.parked.count) ledger=\(schedule.retryLedger.count) rechecks=\(schedule.readinessRechecks.count)"
        let claims = store.use().connections.holds.filter { $0.operation == "claimedEnrichmentCandidates" }.reduce(0) { $0 + $1.count }
        let demandBound = await enrichment.claimWindowLimit + enrichment.handoffPolicy.globalOutstandingLimit
        let vmmap = Self.vmmapSummary()
        await enrichment.shutdown()
        await materializer.shutdown()
        let released = ProcessResourceSample.current()
        await store.shutdown()

        let hashed = try await Self.hashMeasurement(in: directory)
        let whole = try await Self.wholeReadMeasurement(in: directory)

        let startMB = Self.megabytes(started.footprintBytes, minus: floor.footprintBytes)
        let releasedMB = Self.megabytes(released.footprintBytes, minus: floor.footprintBytes)
        let line = """
        op=enrichmentLaunchMemory assets=\(catalog.shape.assets) passes=\(Self.passes) claims=\(claims) \
        demands=\(demands) demandBound=\(demandBound) \(kept) \
        floorMB=\(floor.footprintBytes / 1_048_576) startedMB=\(started.footprintBytes / 1_048_576) \
        releasedMB=\(released.footprintBytes / 1_048_576) startAddedMB=\(startMB) releasedAddedMB=\(releasedMB) \
        hashFileMB=\(Self.hashedFileMB) hashAddedMB=\(hashed) wholeFileMB=\(Self.wholeFileMB) wholeAddedMB=\(whole)

        \(vmmap)
        """
        let url = SourceTree.root.appending(path: "build/enrichment-launch-memory/owner.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(line.utf8).write(to: url)

        #expect(demands <= demandBound, "enrichment holds \(demands) demands, more than its window and hand-off")
        #expect(startMB <= Self.startBoundMB, "starting enrichment added \(startMB) MB")
        #expect(releasedMB <= Self.startBoundMB, "after its claims were given back the footprint was \(releasedMB) MB over the floor")
        #expect(hashed <= Self.bytesBoundMB, "hashing \(Self.hashedFileMB) MB added \(hashed) MB")
        #expect(whole <= Self.bytesBoundMB, "reading \(Self.wholeFileMB) MB whole and letting it go added \(whole) MB")
    }

    /// The footprint a hash-only enrichment of a local file adds, run in a task-group child as
    /// the coordinator runs it.
    private static func hashMeasurement(in directory: URL) async throws -> Int64 {
        let url = try writeFile(megabytes: hashedFileMB, in: directory, name: "hashed.bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let enricher = MediaEnricher.live(thumbnailDirectory: directory.appending(path: "Thumbnails", directoryHint: .isDirectory))
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path(percentEncoded: false)),
            relativePath: MediaRelativePath(rawValue: "hashed.bin")
        )
        let before = ProcessResourceSample.current()
        let outcome = await withTaskGroup(of: EnrichmentOutcome.self) { group in
            group.addTask {
                await enricher.enrich(id, .localFile(url), Int64(hashedFileMB) * 1_048_576, 0, .hash, nil)
            }
            return await group.next()!
        }
        let after = ProcessResourceSample.current()
        guard case .hashed = outcome else {
            Issue.record("expected a digest, got \(outcome)")
            return .max
        }
        return megabytes(after.footprintBytes, minus: before.footprintBytes)
    }

    /// The footprint a still's whole read leaves once its bytes are let go.
    private static func wholeReadMeasurement(in directory: URL) async throws -> Int64 {
        let url = try writeFile(megabytes: wholeFileMB, in: directory, name: "whole.bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = ProcessResourceSample.current()
        let count = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { try FileBytes.whole(url).count }
            return try await group.next()!
        }
        let after = ProcessResourceSample.current()
        #expect(count == wholeFileMB * 1_048_576)
        return megabytes(after.footprintBytes, minus: before.footprintBytes)
    }

    private static func writeFile(megabytes: Int, in directory: URL, name: String) throws -> URL {
        let url = directory.appending(path: name)
        #expect(FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data((0 ..< 1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) })
        for _ in 0 ..< megabytes {
            try handle.write(contentsOf: chunk)
        }
        return url
    }

    private static func megabytes(_ value: UInt64, minus base: UInt64) -> Int64 {
        (Int64(value) - Int64(base)) / 1_048_576
    }

    /// `vmmap --summary` of this process at the measured point, so a failure names the regions.
    private static func vmmapSummary() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["--summary", "\(getpid())"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "vmmap unavailable: \(error)"
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}

@Suite(.testScope)
struct FileBytesTests {
    @Test func aWholeReadIsTheFileAndOutlivesItsRead() throws {
        let url = try makeTestDirectory().appending(path: "bytes")
        let contents = Data((0 ..< (FileBytes.chunkSize + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try contents.write(to: url)
        let read = try FileBytes.whole(url)
        let copy = read
        #expect(copy == contents)
    }

    @Test func anEmptyFileIsEmptyAndAMissingOneIsAnOpenFailure() throws {
        let directory = try makeTestDirectory()
        let empty = directory.appending(path: "empty")
        try Data().write(to: empty)
        #expect(try FileBytes.whole(empty).isEmpty)
        #expect(try FileBytes.forEachChunk(of: empty) { _ in Issue.record("an empty file has no chunk") })
        #expect(throws: FileBytes.ReadError.self) { try FileBytes.whole(directory.appending(path: "missing")) }
    }

    @Test func chunksArriveInOrderInOneBuffer() throws {
        let url = try makeTestDirectory().appending(path: "bytes")
        let contents = Data((0 ..< 10000).map { UInt8(truncatingIfNeeded: $0) })
        try contents.write(to: url)
        var joined = Data()
        var bases: Set<UInt> = []
        let finished = try FileBytes.forEachChunk(of: url, chunkSize: 4096) { chunk in
            joined.append(contentsOf: chunk)
            bases.insert(UInt(bitPattern: chunk.baseAddress))
        }
        #expect(finished)
        #expect(joined == contents)
        #expect(bases.count == 1)
    }
}
