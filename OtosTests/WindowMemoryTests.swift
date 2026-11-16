import Darwin
import Foundation
@testable import OtosKit
import Testing

/// The window's memory across scope changes and re-reads (plan 0116; ADR 0005, "One copy of
/// an order"): on a catalog of the owner's shape with every background owner off, the
/// projection's held orders, collapses, stacks and window are measured after All Media's first
/// publication and again after 20 scope changes, each followed by a whole re-read of the shown
/// order: the distinct path strings they reference, those strings' bytes per path, and the
/// process footprint (`phys_footprint`, reported, not judged: it moves with the allocator).
/// The held strings must not climb: an order read again that came back as held is held once.
/// At the owner's size (`OTOS_SCALE_TEST=1`, run alone) each checkpoint is written to
/// `build/window-memory/run.txt`, and each step as it ends to `run.progress`.
@Suite(.testScope, .serialized)
struct WindowMemoryTests {
    /// The path storages the held structures may reference per distinct path: one copy of the
    /// order, and the stacks' own read of the members they hold (about 7 % of the paths on the
    /// owner's shape). An order held twice is two.
    static let storagesPerPathLimit = 1.15

    @Test func heldPathStringsDoNotClimbAcrossScopeChanges() async throws {
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
        let projection = CatalogProjection(
            cadence: .milliseconds(25),
            backgroundOwners: BackgroundOwners(off: Set(BackgroundOwner.allCases))
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
        let first = try await Self.census(projection)
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
        let after = try await Self.census(projection)
        await store.shutdown()

        let lines = ["scale=\(ownerSize ? 1 : 0.02)"] + first.lines("after=1") + after.lines("after=20")
        if ownerSize {
            let url = SourceTree.root.appending(path: "build/window-memory/run.txt")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        }
        let report = lines.joined(separator: "\n")
        // Every held structure together references about one string per path it holds, and
        // no more after the 20 than after the first.
        #expect(after.all.storages.count <= first.all.storages.count + first.all.storages.count / 20, "\(report)")
        #expect(Double(after.all.storages.count) <= Double(after.distinctPaths) * Self.storagesPerPathLimit, "\(report)")
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
        var structures: [(String, PathStorageCensus)] = []
        var all = PathStorageCensus()
        /// The distinct paths (by text) every structure together holds.
        var distinctPaths = 0
        var footprint: UInt64 = 0

        func lines(_ checkpoint: String) -> [String] {
            let separately = structures.reduce(0) { $0 + $1.1.storages.count }
            return structures.map { "\(checkpoint) structure=\($0.0) \($0.1.summary)" } + [
                "\(checkpoint) structure=all \(all.summary) distinctPaths=\(distinctPaths) storagesCountedSeparately=\(separately) bytesPerPath=\(distinctPaths == 0 ? 0 : all.bytes / distinctPaths)",
                "\(checkpoint) footprintMB=\(footprint / 1_048_576)",
            ]
        }
    }

    private static func census(_ projection: CatalogProjection) async throws -> Census {
        let reads = await projection.reads
        let changeLog = await projection.changeLog
        let window = try #require(await projection.lastPublishedState)
        var census = Census()
        // Read before the census builds its own sets.
        census.footprint = ProcessResourceSample.current().footprintBytes
        func count(_ name: String, _ fill: (inout PathStorageCensus) -> Void) {
            var structure = PathStorageCensus()
            fill(&structure)
            census.structures.append((name, structure))
        }
        count("window") { $0.add(window.mediaGrid.orderedAssetIDs) }
        for slot in [CatalogProjectionReads.Slot.allMedia, .other] {
            count("order.\(slot)") { $0.add(reads.orders[slot]?.answer.ids ?? []) }
            for searched in [false, true] {
                count("collapse.\(slot)\(searched ? ".searched" : "")") { structure in
                    guard let collapse = reads.collapses.first(where: { $0.key.slot == slot && $0.key.searched == searched })?.value
                    else {
                        return
                    }
                    structure.add(collapse.ids)
                    structure.add(collapse.result.ids)
                    structure.add(collapse.result.stackedPositions.keys)
                }
            }
        }
        count("stacks") { structure in
            for stack in reads.stacks?.built.stacks.stacks.values ?? [:].values {
                structure.add(stack.members)
            }
        }
        count("changeLog") { structure in
            for entry in changeLog.entries {
                if case let .named(named) = entry.rows {
                    structure.add(named.ids)
                }
            }
        }
        var texts = Set<String>()
        for (_, structure) in census.structures {
            census.all.formUnion(structure)
            texts.formUnion(structure.texts)
        }
        census.distinctPaths = texts.count
        return census
    }
}

/// The distinct heap storages a set of path strings references, by the address of each one's
/// contiguous UTF-8. A path short enough to live inside its `String` has no storage and is
/// counted apart (`inline`).
struct PathStorageCensus {
    /// The longest UTF-8 a 64-bit `String` holds inline.
    static let inlineCapacity = 15

    /// Each storage's address and its UTF-8 count.
    private(set) var storages: [UInt: Int] = [:]
    /// The texts of the paths with a storage.
    private(set) var texts: Set<String> = []
    private(set) var references = 0
    private(set) var inline = 0

    mutating func add(_ ids: some Sequence<MediaAssetID>) {
        for id in ids {
            add(id.relativePath.rawValue)
        }
    }

    mutating func add(_ text: String) {
        references += 1
        let count = text.utf8.count
        guard count > Self.inlineCapacity,
              let address = text.utf8.withContiguousStorageIfAvailable({ UInt(bitPattern: $0.baseAddress) })
        else {
            inline += 1
            return
        }
        storages[address] = count
        texts.insert(text)
    }

    mutating func formUnion(_ other: PathStorageCensus) {
        storages.merge(other.storages) { first, _ in first }
        texts.formUnion(other.texts)
        references += other.references
        inline += other.inline
    }

    /// What the storages occupy: a native string's 32-byte header, its UTF-8 and a NUL, as
    /// malloc rounds it.
    var bytes: Int {
        storages.values.reduce(0) { $0 + malloc_good_size(32 + $1 + 1) }
    }

    var summary: String {
        "references=\(references) storages=\(storages.count) storageKB=\(bytes / 1024) inline=\(inline)"
    }
}
