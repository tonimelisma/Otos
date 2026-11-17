import Darwin
import Foundation
@testable import OtosKit
import Testing

/// Freed memory the footprint keeps (ADR 0056): on macOS 27 a freed malloc block of 4 KB or
/// more stays dirty in the process until malloc reuses it
/// (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). On the owner's library
/// the app held 460 MB of dirty malloc regions at idle against a live heap of 324 MB. These
/// run the launch and the tour's scope visits on a catalog of the owner's shape, with every
/// background owner running, and measure malloc's dirty bytes less its live bytes (vmmap's
/// `FRAG SIZE` total) after each step, record which call stacks made and freed the blocks of
/// 4 KB and up (`MallocSiteProbe`), and write both to `build/transient-memory/`.
///
/// On demand only (`OTOS_SCALE_TEST=1`), and run alone: the probe hooks every allocation in the
/// process and `vmmap` suspends it at each step, so beside other tests it would slow every one
/// of them and count their allocations as the tour's. What always runs for the same rule is
/// deterministic and process-local: the builder's own tests (`MappedArrayBuilderTests`) and the
/// lint that keeps a grouping from growing its groups (`grouping_grows_arrays`).
@Suite(.testScope, .serialized, .enabled(if: StallReproductionTests.ownerSize))
struct TransientMemoryTests {
    @Test func theTourSequenceOnASmallCatalog() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 0.02)
        let (run, sites, overflowed) = try await MallocSiteProbe.record {
            try await TourSequence.run(catalog, in: directory)
        }
        #expect(!overflowed)
        #expect(!sites.isEmpty)
        try TourSequence.write(run, sites: sites, overflowed: overflowed, named: "small")
        // An owner-scale read builds in mapped regions (`MappedArrayBuilder`) or at its length:
        // none of them outgrows a buffer bigger than a bounded page's, here at 2 % of the
        // owner's size.
        let grown = sites.filter { site in
            site.growsAnArrayInADatabaseAccess && site.largest > Self.boundedPageBlock
                && Self.ownerScaleReads.contains { name in site.frames.contains { $0.contains(name) } }
                // The process's identity table is held and grows by design (ARC-070).
                && !site.frames.contains { $0.contains("MediaAssetIdentityTable") }
        }
        #expect(grown.isEmpty, "\(grown.map { "largestKB=\($0.largest / 1024) " + $0.frames.filter { $0.contains("OtosKit") }.prefix(3).joined(separator: " < ") })")
    }

    /// The largest buffer a bounded read's array may outgrow at 2 % of the owner's size: a page
    /// of a walk is at most a few hundred rows, whatever the library's size.
    static let boundedPageBlock = 16 * 1024

    /// The reads and builds whose results grow with the library, by the names their frames
    /// carry: the order and its stacks, the filter options, the duplicates candidates, the
    /// People snapshot, a root's rows and the derived folder's walk.
    static let ownerScaleReads = [
        "fetchOrderedAssetIDRows", "orderedAssets", "fetchCandidates", "PhotoStackRule", "tallyFilterOptionRows",
        "fetchSamePhotoCandidates", "candidatePairs", "peopleSnapshot", "PeopleFaces", "fetchExistingAssetRows", "namedRows",
    ]

    @Test func theTourSequenceAtTheOwnersSize() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let (run, sites, overflowed) = try await MallocSiteProbe.record {
            try await TourSequence.run(catalog, in: directory)
        }
        try TourSequence.write(run, sites: sites, overflowed: overflowed, named: "owner")
        try? FileManager.default.removeItem(at: directory)
        // After the sequence's last step, malloc holds at most this much freed (dirty less live):
        // 82 and 92 MB before the reads built in mapped regions, 27 and 51 MB after
        // (`docs/research/2026-11-16-freed-memory-after-the-tour.md`).
        let last = try #require(run.steps.first { $0.label == "sortName" })
        #expect(last.malloc.fragmentBytes <= Self.freedAfterTheSequence, "\(run.lines.joined(separator: "\n"))")
    }

    /// The bound on malloc's freed-but-held bytes after the owner-size sequence.
    static let freedAfterTheSequence = 64 * 1_048_576
}

/// The launch and the tour's scope visits, as the window makes them, over every background
/// owner (`RunningBackgroundOwners`): the first grid, a library, People, a person, Places with
/// its clusters, On This Day, Duplicates, All Media again, a filter and a sort. The test bundle
/// holds no search model, so no search is made.
enum TourSequence {
    struct Step {
        let label: String
        let malloc: MallocRegions
        let footprintMB: UInt64
        let liveHeapMB: Int
    }

    struct Run {
        var steps: [Step] = []
        var lines: [String] {
            steps.map {
                "step=\($0.label) mallocDirtyMB=\($0.malloc.dirtyBytes / 1_048_576) mallocAllocatedMB=\($0.malloc.allocatedBytes / 1_048_576) freedRetainedMB=\($0.malloc.fragmentBytes / 1_048_576) liveHeapMB=\($0.liveHeapMB) footprintMB=\($0.footprintMB)"
            }
        }
    }

    /// The steps and the 40 sites that freed the most, to `build/transient-memory/<name>.txt`.
    static func write(_ run: Run, sites: [MallocSiteProbe.Report], overflowed: Bool, named name: String) throws {
        var lines = run.lines
        lines.append("probe overflowed=\(overflowed) sites=\(sites.count)")
        for site in sites.prefix(40) {
            lines.append(
                "site freedKB=\(site.freedBytes / 1024) allocatedKB=\(site.allocatedBytes / 1024) blocks=\(site.allocations) largestKB=\(site.largest / 1024)"
            )
            lines += site.frames.prefix(30).map { "    \($0)" }
        }
        let growing = sites.filter(\.growsAnArrayInADatabaseAccess)
        lines.append("growing sites=\(growing.count)")
        for site in growing {
            lines.append("grow freedKB=\(site.freedBytes / 1024) blocks=\(site.allocations) largestKB=\(site.largest / 1024)")
            lines += site.frames.prefix(30).map { "    \($0)" }
        }
        let url = SourceTree.root.appending(path: "build/transient-memory/\(name).txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    static func run(_ catalog: OwnerShapedCatalog, in directory: URL) async throws -> Run {
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let thumbnails = directory.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let owners = try RunningBackgroundOwners(store: store, thumbnails: thumbnails)
        var run = Run()
        func step(_ label: String) throws {
            try run.steps.append(Step(
                label: label, malloc: MallocRegions.current(),
                footprintMB: ProcessResourceSample.current().footprintBytes / 1_048_576,
                liveHeapMB: liveHeapBytes() / 1_048_576
            ))
        }
        try step("start")
        await owners.start(store: store)
        let projection = owners.projection
        try await settle(projection, on: .allMedia)
        try step("firstGrid")
        let person = PersonID(rawValue: 1)
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let scopes: [(String, SidebarSelection)] = [
            ("library", .library(catalog.pictures)),
            ("people", .people),
            ("person", .person(person)),
            ("places", .places),
            ("onThisDay", .onThisDay(CalendarDay(year: today.year!, month: today.month!, day: today.day!))),
            ("duplicates", .duplicates),
            ("allMedia", .allMedia),
        ]
        for (label, scope) in scopes {
            await projection.updateSidebarSelection(scope)
            try await settle(projection, on: scope)
            if scope == .places, let map = await projection.lastPublishedState?.map {
                let viewport = MapViewport(originX: 0, originY: 0, width: 1, height: 1, viewWidth: 1200, viewHeight: 800)
                _ = await MapClusterLane.clusters(located: map.located, viewport: viewport)
            }
            try step(label)
        }
        var descriptor = CatalogQueryDescriptor(scope: .allMedia)
        descriptor.filter.kinds = [.video]
        await projection.updateQueryDescriptor(descriptor)
        try await settle(projection, on: .allMedia)
        try step("filterVideo")
        descriptor.sort = .filenameAscending
        await projection.updateQueryDescriptor(descriptor)
        try await settle(projection, on: .allMedia)
        try step("sortName")
        await owners.shutdown()
        await store.shutdown()
        try step("shutdown")
        return run
    }

    private static func settle(_ projection: CatalogProjection, on scope: SidebarSelection) async throws {
        try await waitUntil {
            guard await projection.isQuiescent, let state = await projection.lastPublishedState else { return false }
            return state.resolvedSidebarSelection == scope && state.mediaEmptyState != .loadingCatalog
        }
    }
}

/// The process's malloc regions as vmmap reports them: dirty and swapped bytes, the bytes
/// allocated in them, and the difference (`FRAG SIZE`), which is what the footprint holds of
/// freed blocks.
struct MallocRegions {
    let dirtyBytes: Int
    let allocatedBytes: Int
    let fragmentBytes: Int

    struct Unreadable: Error {
        let output: String
    }

    static func current() throws -> MallocRegions {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["--summary", "\(getpid())"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        var inZones = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("MALLOC ZONE") {
                inZones = true
            } else if inZones, line.hasPrefix("TOTAL") {
                // TOTAL virtual resident dirty swapped count allocated frag %frag regions
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 9, let dirty = bytes(parts[3]), let swapped = bytes(parts[4]),
                      let allocated = bytes(parts[6]), let fragment = bytes(parts[7])
                else { break }
                return MallocRegions(dirtyBytes: dirty + swapped, allocatedBytes: allocated, fragmentBytes: fragment)
            }
        }
        throw Unreadable(output: String(output.suffix(2000)))
    }

    /// vmmap's sizes: `512`, `640K`, `21.1M`, `1.2G`.
    static func bytes(_ text: String) -> Int? {
        let units: [Character: Double] = ["K": 1024, "M": 1_048_576, "G": 1_073_741_824]
        if let last = text.last, let unit = units[last], let value = Double(text.dropLast()) {
            return Int(value * unit)
        }
        return Int(text)
    }
}
