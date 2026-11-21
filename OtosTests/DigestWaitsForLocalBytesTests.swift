import CoreServices
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ENR-034, ADR 0009 §12: a cloud-only original is never downloaded only to take its digest.
/// A row whose only owed product is its digest and whose original is not local is held by the
/// Store, out of every claim and no work of the coordinator's, until the fact that ends the
/// wait: an event on its file, Otos downloading it for other work, or its facts moving. A row
/// that owes anything else is downloaded once and its digest taken from that copy.
@Suite(.testScope)
struct DigestWaitsForLocalBytesTests {
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
                enricher: DigestWaitsForLocalBytesTests.enricher(reads),
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

        /// The event a provider's download delivers on the file: the measured hydration shape
        /// (`0x1d400`: inode meta, modified, owner and xattr changes of a regular file).
        func fileEvent() {
            let flags = kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod
                | kFSEventStreamEventFlagItemIsFile
            emit(FilesystemEvent(
                path: root.appending(path: DigestWaitsForLocalBytesTests.name).path(percentEncoded: false),
                flags: UInt32(flags)
            ))
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
                return .hashed(ContentHashResult(id: id, contentHash: DigestWaitsForLocalBytesTests.digest, sourceSize: size, sourceMTimeSeconds: mtime))
            }
            return .complete(EnrichmentResult(
                id: id,
                metadata: scope.contains(.metadata) ? EnrichedMetadata(metadata: AssetMetadata(), kind: nil, format: nil) : nil,
                rendering: scope.contains(.rendering) ? EnrichedRendering(thumbnailPath: "t.jpg") : nil,
                sourceSize: size,
                sourceMTimeSeconds: mtime,
                contentHash: scope.contains(.hash) ? DigestWaitsForLocalBytesTests.digest : nil
            ))
        }
    }

    private static func heldCount(_ coordinator: EnrichmentCoordinator) async -> Int? {
        await coordinator.heldRows().first { $0.waitingFor == .digestAwaitsLocalBytes }?.count
    }

    @Test func aDatalessRowOwingOnlyItsDigestIsNeverDownloaded() async throws {
        let library = try await Self.owingOnlyItsDigest()
        let requests = DownloadCounter()
        let reads = ScopeLog()
        let coordinator = library.coordinator(requests, reads)
        await coordinator.start()
        _ = try await coordinator.untilQuiescent()
        // Woken again with nothing new, it asks for nothing either.
        await coordinator.ringIdle()
        _ = try await coordinator.untilQuiescent()

        #expect(await requests.total == 0, "no download is made for a digest alone")
        #expect(await reads.scopes.isEmpty, "nothing reads a file that is not local")
        #expect(await Self.heldCount(coordinator) == 1)
        #expect(try await library.asset()?.hashStale == true)
        await coordinator.shutdown()
        await library.store.shutdown()
    }

    /// The provider makes the file local (Finder, "Keep Downloaded"): its file event ends the
    /// hold, and the digest is read from the local bytes with nothing downloaded.
    @Test func aHeldRowIsHashedWithoutADownloadOnceAnEventSaysItsBytesAreLocal() async throws {
        let library = try await Self.owingOnlyItsDigest()
        let requests = DownloadCounter()
        let reads = ScopeLog()
        let coordinator = library.coordinator(requests, reads)
        await coordinator.start()
        _ = try await coordinator.untilQuiescent()
        #expect(await Self.heldCount(coordinator) == 1)

        library.local.set(true)
        library.fileEvent()
        try await waitUntil { try await library.asset()?.hashStale == false }
        _ = try await coordinator.untilQuiescent()

        #expect(await requests.total == 0)
        #expect(await reads.scopes == [.hash], "the digest alone, from the local file")
        #expect(await Self.heldCount(coordinator) == 0)
        #expect(try await library.asset()?.contentHash == Self.digest)
        await coordinator.shutdown()
        await library.store.shutdown()
    }

    /// The user opens the photo in the full-size view (or exports it): the download made for
    /// that work ends the hold, and the digest is taken from that copy.
    @Test func aHeldRowIsHashedFromTheCopyADownloadForTheUsersWorkLanded() async throws {
        let library = try await Self.owingOnlyItsDigest()
        let requests = DownloadCounter()
        let reads = ScopeLog()
        let coordinator = library.coordinator(requests, reads)
        await coordinator.start()
        _ = try await coordinator.untilQuiescent()
        #expect(await Self.heldCount(coordinator) == 1)

        // What `MaterializationCoordinator` reports when an interactive download lands.
        library.local.set(true)
        await library.store.endKnownMaterialization(for: library.id, success: true)
        try await waitUntil { try await library.asset()?.hashStale == false }
        _ = try await coordinator.untilQuiescent()

        #expect(await requests.total == 0, "enrichment downloads nothing of its own")
        #expect(await reads.scopes == [.hash])
        #expect(await Self.heldCount(coordinator) == 0)
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
        #expect(await Self.heldCount(coordinator) == 0)
        await coordinator.shutdown()
        await library.store.shutdown()
    }

    /// Held rows take no place in the claim window: a walk that holds more rows than one pass
    /// claims goes on until it reaches the row behind them that owes a rendering, which is
    /// downloaded, with nothing else asked for.
    @Test func theWalkGoesOnPastHeldRowsToTheRowsThatOweMore() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Newest first in the claim order: 300 rows owing only their digest, then the oldest,
        // owing everything.
        let heldNames = (0 ..< 300).map { "held-\($0).jpg" }
        let files = heldNames.map { ScannedMediaFile(
            relativePath: MediaRelativePath(rawValue: $0), name: $0, contentTypeIdentifier: "public.jpeg",
            byteSize: 100, createdAt: nil, contentModifiedAt: Date(timeIntervalSince1970: 2000)
        ) } + [ScannedMediaFile(
            relativePath: MediaRelativePath(rawValue: "old.jpg"), name: "old.jpg", contentTypeIdentifier: "public.jpeg",
            byteSize: 100, createdAt: nil, contentModifiedAt: Date(timeIntervalSince1970: 1000)
        )]
        let scanner = CatalogScanner { _, _, batchHandler in
            try await batchHandler(files)
            return .mediaOnly(Set(files.map(\.relativePath)))
        }
        let store = makeTestStore(location: .inMemory, scanner: scanner)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == files.count }
        let held = scanned.testAssets.filter { $0.relativePath.rawValue.hasPrefix("held-") }
        let old = try #require(scanned.testAssets.first { $0.relativePath.rawValue == "old.jpg" }?.id)
        #expect(await store.applyEnrichmentBatch(held.map { asset in
            EnrichmentResult(
                id: asset.id,
                metadata: EnrichedMetadata(metadata: AssetMetadata(), kind: nil, format: nil),
                rendering: EnrichedRendering(thumbnailPath: "t.jpg"),
                sourceSize: 100, sourceMTimeSeconds: 2000, contentHash: nil
            )
        }) == .applied(count: held.count))

        let requests = DownloadCounter()
        let reads = ScopeLog()
        let dataless = Shared(Set(files.map { root.appending(path: $0.relativePath.rawValue).lastPathComponent }))
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: Self.enricher(reads),
            materialize: { [dataless] url in
                await requests.count()
                dataless.set(dataless.value.subtracting([url.lastPathComponent]))
                return .testMaterialized
            },
            originalStatus: { [dataless] url in dataless.value.contains(url.lastPathComponent) ? .dataless : .materialized }
        )
        await coordinator.start()
        try await waitUntil { try await store.windowReads.mediaAssets(for: [old])[old]?.needsEnrichment(.library) == false }
        _ = try await coordinator.untilQuiescent()

        #expect(await requests.total == 1, "only the row that owes a rendering is downloaded")
        #expect(await reads.scopes == [[.metadata, .rendering, .hash]])
        #expect(await Self.heldCount(coordinator) == held.count)
        await coordinator.shutdown()
        await store.shutdown()
    }

    /// A held file replaced in the cloud (new size, still not local), found by a walk rather
    /// than an event on the file: the scan's write ends the hold, and the row is downloaded
    /// once for the products it owes again, its digest among them.
    @Test func aHeldRowWhoseFactsAWalkFindsMovedIsClaimedForItsNewProducts() async throws {
        let library = try await Self.owingOnlyItsDigest()
        let requests = DownloadCounter()
        let reads = ScopeLog()
        let coordinator = library.coordinator(requests, reads)
        await coordinator.start()
        _ = try await coordinator.untilQuiescent()
        #expect(await Self.heldCount(coordinator) == 1)

        library.size.set(250)
        library.emit(FilesystemEvent(
            path: library.root.path(percentEncoded: false),
            flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir)
        ))
        try await waitUntil {
            let asset = try await library.asset()
            return asset?.byteSize == 250 && asset?.needsEnrichment(.library) == false
        }
        _ = try await coordinator.untilQuiescent()

        #expect(await requests.total == 1)
        #expect(await reads.scopes == [[.metadata, .rendering, .hash]])
        #expect(await Self.heldCount(coordinator) == 0)
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
