import Darwin
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The window's memory across scope changes and re-reads (ADR 0005, "One copy of
/// an order"): on a catalog of the owner's shape with every background owner off, the
/// projection's held orders, collapses, stacks and window are measured after All Media's first
/// publication and again after 20 scope changes, each followed by a whole re-read of the shown
/// order: the distinct ID arrays they reference, the IDs those hold per distinct asset, their
/// bytes per asset, and the process footprint (`phys_footprint`, reported, not judged: it
/// moves with the allocator). The held IDs must not climb: an order read again that came back
/// as held is held once, and an ID holds no string of its own (`MediaAssetIdentityTable`).
/// At the owner's size (`OTOS_SCALE_TEST=1`, run alone) each checkpoint is written to
/// `build/window-memory/run.txt`, and each step as it ends to `run.progress`.
@Suite(.testScope, .serialized)
struct WindowMemoryTests {
    /// The IDs the held arrays may hold per distinct asset they name: All Media's order, its
    /// collapse (the order less the stacks' hidden files) and the stacks' own member arrays,
    /// about 7 % of the files on the owner's shape. An order held twice is about three.
    static let idsPerAssetLimit = 2.2

    /// What the held arrays may hold per distinct asset, in bytes: their IDs at
    /// `idsPerAssetLimit`, each a 4-byte place in the identity table.
    static let bytesPerAssetLimit = 10

    /// The test process's footprint after the 20 steps at the owner's size, run alone: 144 MB
    /// measured with 4-byte IDs, 212–220 MB with IDs that hold their path strings
    /// (`docs/research/2026-11-17-asset-identity-memory.md`).
    static let ownerSizeFootprintLimit: UInt64 = 180 * 1_048_576

    @Test func heldIDsDoNotClimbAcrossScopeChanges() async throws {
        let ownerSize = StallReproductionTests.ownerSize
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: ownerSize ? 1 : 0.02)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let batch = try #require(try await store.windowReads.importBatches(counting: .newest(1, and: nil)).first)
        let scopes: [SidebarSelection] = [
            .library(catalog.pictures), .library(catalog.account), .library(catalog.archive),
            .importBatch(batch.batchID), .allMedia,
        ]
        let held = HeldIDs()
        let projection = CatalogProjection(
            volumeCapacity: ampleVolumeCapacity,
            cadence: .milliseconds(25),
            backgroundOwners: BackgroundOwners(off: Set(BackgroundOwner.allCases)),
            heldIDsReport: { held.report($0) }
        )
        // Drained without keeping what it delivers: a recorder of every state would hold every
        // published order.
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let draining = Task {
            for await _ in stream {}
        }
        defer { draining.cancel() }

        // Each step as it ends, so a run that stops says where.
        let progress = Progress(enabled: ownerSize)
        progress.append("catalog rows=\(catalog.shape.assets)")
        try await Self.settle(projection, on: .allMedia)
        let first = try Self.census(held)
        progress.append("first \(Self.sample())")
        for step in 1 ... 20 {
            let scope = scopes[(step - 1) % scopes.count]
            await projection.updateSidebarSelection(scope)
            try await Self.settle(projection, on: scope)
            // A choice changed on a shown row: the shown order and its stacks are read again
            // whole (`CatalogChangedFacts.orderInputs`, `stackInputs`).
            let state = try #require(await projection.lastPublishedState, "step \(step) \(scope)")
            let shown = try #require(state.mediaGrid.orderedAssetIDs.first, "step \(step) \(scope)")
            let changed = try await store.setMediaChoice(step.isMultiple(of: 2) ? .disliked : .liked, for: [shown]).changedCount
            try await waitUntil {
                guard await projection.isQuiescent, let published = await projection.lastPublishedState else { return false }
                return changed == 0 || published.mediaGrid.detailRefreshGeneration > state.mediaGrid.detailRefreshGeneration
            }
            await progress.append(
                "step=\(step) scope=\(scope.diagnosticDescription) changed=\(changed) orderReads=\(projection.orderQueryCount) stackReads=\(projection.stackReadCount) \(Self.sample())"
            )
        }
        let after = try Self.census(held)
        await store.shutdown()

        let lines = ["scale=\(ownerSize ? 1 : 0.02)"] + first.lines("after=1") + after.lines("after=20")
        if ownerSize {
            let url = SourceTree.root.appending(path: "build/window-memory/run.txt")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        }
        let report = lines.joined(separator: "\n")
        // Every held structure together holds about one copy of each order it names, no more
        // after the 20 than after the first, in a few bytes per asset.
        #expect(after.all.elements <= first.all.elements + first.all.elements / 20, "\(report)")
        #expect(Double(after.all.elements) <= Double(after.distinctAssets) * Self.idsPerAssetLimit, "\(report)")
        #expect(after.all.bytes <= after.distinctAssets * Self.bytesPerAssetLimit, "\(report)")
        if ownerSize {
            #expect(after.footprint <= Self.ownerSizeFootprintLimit, "\(report)")
        }
    }

    /// The footprint and SQLite's own allocations now, for a progress line.
    private static func sample() -> String {
        let sample = ProcessResourceSample.current()
        return "footprintMB=\(sample.footprintBytes / 1_048_576) sqliteMB=\((sample.sqliteBytes ?? 0) / 1_048_576)"
    }

    private static func settle(_ projection: CatalogProjection, on scope: SidebarSelection) async throws {
        try await waitUntil {
            guard await projection.isQuiescent, let state = await projection.lastPublishedState else {
                return false
            }
            return state.resolvedSidebarSelection == scope && !state.mediaGrid.orderedAssetIDs.isEmpty
        }
    }

    /// Appends a line to `build/window-memory/run.progress` at the owner's size.
    private struct Progress {
        let url: URL?

        init(enabled: Bool) {
            url = enabled ? SourceTree.root.appending(path: "build/window-memory/run.progress") : nil
            if let url {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: url)
            }
        }

        func append(_ line: String) {
            guard let url, let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// One checkpoint: each held structure's census, all of them together, and the footprint.
    private struct Census {
        var structures: [(String, IDStorageCensus)] = []
        var all = IDStorageCensus()
        /// The distinct assets every structure together names.
        var distinctAssets = 0
        var footprint: UInt64 = 0
        /// The process's identity table, reported: other suites in the process add to it too.
        var identityTableEntries = 0

        func lines(_ checkpoint: String) -> [String] {
            let separately = structures.reduce(0) { $0 + $1.1.elements }
            let perAsset = distinctAssets == 0 ? 0 : Double(all.bytes) / Double(distinctAssets)
            return structures.map { "\(checkpoint) structure=\($0.0) \($0.1.summary)" } + [
                "\(checkpoint) structure=all \(all.summary) distinctAssets=\(distinctAssets) elementsCountedSeparately=\(separately) bytesPerAsset=\(perAsset)",
                "\(checkpoint) footprintMB=\(footprint / 1_048_576) identityTableEntries=\(identityTableEntries)",
            ]
        }
    }

    /// The IDs the projection last reported holding, as its last pass ended.
    private final class HeldIDs: Sendable {
        private let last = Mutex<CatalogProjectionHeldIDs?>(nil)

        func report(_ held: CatalogProjectionHeldIDs) {
            last.withLock { $0 = held }
        }

        var reported: CatalogProjectionHeldIDs? {
            last.withLock { $0 }
        }
    }

    private static func census(_ reported: HeldIDs) throws -> Census {
        let held = try #require(reported.reported, "the projection reported no pass")
        var census = Census()
        // Read before the census builds its own sets.
        census.footprint = ProcessResourceSample.current().footprintBytes
        census.identityTableEntries = MediaAssetIdentityTable.shared.count
        for structure in held.structures {
            var counted = IDStorageCensus()
            structure.arrays.forEach { counted.add($0) }
            structure.sets.forEach { counted.add($0) }
            census.structures.append((structure.name, counted))
        }
        var assets = Set<MediaAssetID>()
        for (_, structure) in census.structures {
            census.all.formUnion(structure)
            assets.formUnion(structure.ids)
        }
        census.distinctAssets = assets.count
        return census
    }
}

/// The distinct ID arrays a set of held structures references, by the address of each one's
/// contiguous storage: an array shared by two structures is counted once.
struct IDStorageCensus {
    /// Each storage's address and its element count.
    private(set) var storages: [UInt: Int] = [:]
    /// The IDs the storages hold.
    private(set) var ids: Set<MediaAssetID> = []
    private(set) var references = 0

    mutating func add(_ array: [MediaAssetID]) {
        references += array.count
        guard !array.isEmpty,
              let address = array.withUnsafeBufferPointer({ $0.baseAddress.map { UInt(bitPattern: $0) } })
        else {
            return
        }
        if storages[address] == nil {
            storages[address] = array.count
            ids.formUnion(array)
        }
    }

    /// A set's own storage, counted as one more (a set exposes no storage address).
    mutating func add(_ set: Set<MediaAssetID>) {
        references += set.count
        guard !set.isEmpty else { return }
        storages[UInt.max - UInt(storages.count)] = set.count
        ids.formUnion(set)
    }

    mutating func formUnion(_ other: IDStorageCensus) {
        storages.merge(other.storages) { first, _ in first }
        ids.formUnion(other.ids)
        references += other.references
    }

    var elements: Int {
        storages.values.reduce(0, +)
    }

    /// What the storages' elements occupy.
    var bytes: Int {
        elements * MemoryLayout<MediaAssetID>.stride
    }

    var summary: String {
        "references=\(references) storages=\(storages.count) elements=\(elements) kilobytes=\(bytes / 1024)"
    }
}
