import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ENR-034, ADR 0009 §12: a cloud-only original is downloaded for whatever its row owes, its
/// digest alone included (owner, 2026-11-21: "yes, download them"), so every photo is checked
/// for duplicates. A row that owes more is downloaded once and its digest taken from that copy.
@Suite(.testScope)
struct DigestDownloadsTests {
    private static let name = "a.jpg"
    private static let digest = ContentDigest(data: Data(repeating: 7, count: ContentDigest.byteCount))!

    /// One library of one photo, on a store whose file events the test emits, its file
    /// dataless or local as `local` says.
    private struct Library {
        let store: CatalogStore
        let root: URL
        let id: MediaAssetID
        let emit: @Sendable (FilesystemEvent) -> Void
        let local: Shared<Bool>
        let size: Shared<Int64>

        func coordinator(_ requests: DownloadCounter, _ reads: ScopeLog) -> EnrichmentCoordinator {
            EnrichmentCoordinator(
                store: store,
                enricher: DigestDownloadsTests.enricher(reads),
                materialize: { [local] _ in
                    await requests.count()
                    local.set(true)
                    return .testMaterialized
                },
                originalStatus: { [local] _ in local.value ? .materialized : .dataless }
            )
        }

        func asset() async throws -> MediaAsset? {
            try await store.windowReads.mediaAssets(for: [id])[id]
        }
    }

    private static func library() async throws -> Library {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let size = Shared<Int64>(100)
        // The one file, at its current size: what a walk of the root or of any folder lists,
        // and what an event on the file observes. Nothing is on disk.
        let rel = MediaRelativePath(rawValue: name)
        let file = { @Sendable [size] in
            ScannedMediaFile(
                relativePath: rel, name: name, contentTypeIdentifier: "public.jpeg",
                byteSize: size.value, createdAt: nil,
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            )
        }
        let scanner = CatalogScanner(
            scanRoot: { _, _, batchHandler in
                try await batchHandler([file()])
                return .mediaOnly([rel])
            },
            scanSubtree: { _, _, _, batchHandler in
                try await batchHandler([file()])
                return .mediaOnly([rel])
            },
            observeFile: { _, _ in .present(.media(file())) }
        )
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = makeTestStore(location: .inMemory, scanner: scanner, filesystemWatcher: watcher)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)
        return Library(store: store, root: root, id: id, emit: emit, local: Shared(false), size: size)
    }

    /// Writes every product of the library's row but its digest, from local bytes: what a
    /// library holds whose digests were never taken.
    private static func owingOnlyItsDigest() async throws -> Library {
        let library = try await library()
        let outcome = await library.store.applyEnrichmentBatch([
            EnrichmentResult(
                id: library.id,
                metadata: EnrichedMetadata(metadata: AssetMetadata(), kind: nil, format: nil),
                rendering: EnrichedRendering(thumbnailPath: "t.jpg"),
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: nil
            ),
        ])
        #expect(outcome == .applied(count: 1))
        let asset = try await library.asset()
        #expect(asset?.metadataStale == false && asset?.renderingStale == false && asset?.hashStale == true)
        return library
    }

    private static func enricher(_ reads: ScopeLog) -> MediaEnricher {
        MediaEnricher { id, _, size, mtime, scope, _ in
            await reads.record(scope)
            if scope == .hash {
                return .hashed(ContentHashResult(id: id, contentHash: DigestDownloadsTests.digest, sourceSize: size, sourceMTimeSeconds: mtime))
            }
            return .complete(EnrichmentResult(
                id: id,
                metadata: scope.contains(.metadata) ? EnrichedMetadata(metadata: AssetMetadata(), kind: nil, format: nil) : nil,
                rendering: scope.contains(.rendering) ? EnrichedRendering(thumbnailPath: "t.jpg") : nil,
                sourceSize: size,
                sourceMTimeSeconds: mtime,
                contentHash: scope.contains(.hash) ? DigestDownloadsTests.digest : nil
            ))
        }
    }

    /// A row whose original is not local and whose only owed product is its digest is
    /// downloaded, and its digest read from that copy.
    @Test func aDatalessRowOwingOnlyItsDigestIsDownloadedAndHashed() async throws {
        let library = try await Self.owingOnlyItsDigest()
        let requests = DownloadCounter()
        let reads = ScopeLog()
        let coordinator = library.coordinator(requests, reads)
        await coordinator.start()
        try await waitUntil { try await library.asset()?.hashStale == false }
        _ = try await coordinator.untilQuiescent()

        #expect(await requests.total == 1, "one download, for the digest")
        #expect(await reads.scopes == [.hash], "the digest alone, from the downloaded copy")
        #expect(try await library.asset()?.contentHash == Self.digest)
        #expect(await coordinator.heldRows() == [OwnerHeldRows(waitingFor: .pacing, count: 0)], "nothing is held")
        await coordinator.shutdown()
        await library.store.shutdown()
    }

    /// A row that owes a rendering is downloaded once, and its digest is taken in the same read.
    @Test func aDatalessRowOwingARenderingIsDownloadedOnceAndHashedFromThatCopy() async throws {
        let library = try await Self.library()
        let requests = DownloadCounter()
        let reads = ScopeLog()
        let coordinator = library.coordinator(requests, reads)
        await coordinator.start()
        try await waitUntil { try await library.asset()?.needsEnrichment(.library) == false }
        _ = try await coordinator.untilQuiescent()

        #expect(await requests.total == 1)
        #expect(await reads.scopes == [[.metadata, .rendering, .hash]])
        #expect(try await library.asset()?.contentHash == Self.digest)
        await coordinator.shutdown()
        await library.store.shutdown()
    }
}

private actor DownloadCounter {
    private(set) var total = 0

    func count() {
        total += 1
    }
}

/// The scopes the enricher was asked to read, in order.
private actor ScopeLog {
    private(set) var scopes: [EnrichmentScope] = []

    func record(_ scope: EnrichmentScope) {
        scopes.append(scope)
    }
}

/// A value the test changes and a synchronous closure reads.
private final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) {
        state = Mutex(value)
    }

    var value: Value {
        state.withLock { $0 }
    }

    func set(_ value: Value) {
        state.withLock { $0 = value }
    }
}
