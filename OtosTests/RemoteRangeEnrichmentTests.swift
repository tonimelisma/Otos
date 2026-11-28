import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0046 §5: an Immich account's metadata is read from its server in byte ranges, and
/// only while the server answers. The server here is a fixture file served from memory.
@Suite(.testScope)
struct RemoteRangeEnrichmentTests {
    /// How many ranges the server was asked for.
    private final class RequestCount: Sendable {
        private let count = Mutex(0)

        var value: Int {
            count.withLock { $0 }
        }

        func increment() {
            count.withLock { $0 += 1 }
        }
    }

    private static func reader(serving data: Data, requests: RequestCount? = nil) -> RemoteRangeReader {
        RemoteRangeReader(size: UInt64(data.count)) { offset, length, completion in
            requests?.increment()
            let start = Int(offset)
            completion(.success(data.subdata(in: start ..< min(data.count, start + length))))
            return .settled
        }
    }

    // MARK: - The byte source

    // Validates: APP-066
    @Test func aRangeOutsideTheFileIsNilAndAskedOfNoServer() throws {
        let requests = RequestCount()
        let source = RemoteByteSource(reader: Self.reader(serving: Data(repeating: 7, count: 10), requests: requests))
        #expect(try source.data(offset: 8, length: 5) == nil)
        #expect(try source.data(offset: 11, length: 0) == nil)
        #expect(try source.data(offset: 4, length: 0) == Data())
        #expect(requests.value == 0)
        #expect(try source.data(offset: 2, length: 3) == Data(repeating: 7, count: 3))
        #expect(requests.value == 1)
    }

    // Validates: APP-066
    /// A short, failed or unanswered read throws: never a definitive absence.
    @Test func aReadTheServerDoesNotAnswerInFullThrows() {
        let short = RemoteByteSource(reader: RemoteRangeReader(size: 10) { _, _, completion in
            completion(.success(Data(count: 2)))
            return .settled
        })
        #expect(throws: RemoteByteSourceError.shortRead(expected: 5, received: 2)) {
            try short.data(offset: 0, length: 5)
        }
        let failing = RemoteByteSource(reader: RemoteRangeReader(size: 10) { _, _, completion in
            completion(.failure(ImmichClientError.unreachable(.timedOut)))
            return .settled
        })
        #expect(throws: ImmichClientError.unreachable(.timedOut)) {
            try failing.data(offset: 0, length: 5)
        }
        // An unanswered read is cancelled at its deadline, so its transfer stops.
        let cancelled = Mutex(false)
        let silent = RemoteByteSource(
            reader: RemoteRangeReader(size: 10) { _, _, _ in
                RemoteRangeRead { cancelled.withLock { $0 = true } }
            },
            readDeadline: .milliseconds(10)
        )
        #expect(throws: RemoteByteSourceError.timedOut) {
            try silent.data(offset: 0, length: 5)
        }
        #expect(cancelled.withLock { $0 })
    }

    // MARK: - The Store's answering fact

    // Validates: APP-066
    /// An account is not claimed until its owner says its server answers, and stops being
    /// claimed when it says the server does not.
    @Test func anAccountIsEnrichableOnlyWhileItsServerAnswers() async throws {
        let store = try makeTestStore(
            location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: makeTestDirectory())
        )
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "u1", displayName: "Family"
        )
        #expect(await !store.enrichableRootPaths().contains(rootPath))
        await store.setSourceAnswering(true, for: rootPath)
        #expect(await store.enrichableRootPaths().contains(rootPath))
        await store.setSourceAnswering(false, for: rootPath)
        #expect(await !store.enrichableRootPaths().contains(rootPath))
        await store.shutdown()
    }

    // MARK: - Enrichment over ranges

    // Validates: APP-066
    /// A listed account row gets its metadata from ranged reads of its original: the
    /// capture date the file holds, stamped, with no download and no rendering.
    @Test func anAccountRowsMetadataIsReadInRanges() async throws {
        let data = try Data(contentsOf: SourceTree.mediaFixtures.appending(path: "jpeg-exif-offset-date.jpg"))
        let temp = try makeTestDirectory()
        let store = makeTestStore(location: .databaseFile(temp.appending(path: "Catalog.sqlite")), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "u1", displayName: "Family"
        )
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        let path = MediaRelativePath(rawValue: "asset-1/IMG_1.JPG")
        try await store.applySourceListingChanges(SourceListingChanges(listed: [SourceListedItem(
            file: ScannedMediaFile(
                relativePath: path, name: "IMG_1.JPG", contentTypeIdentifier: "public.jpeg",
                byteSize: Int64(data.count), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            sourceItemID: "asset-1",
            isInSourceTrash: false,
            sourceHasProducts: true
        )]), scan: scan)
        await store.endSourceListing(scan: scan)
        await store.setSourceAnswering(true, for: rootPath)

        let requests = RequestCount()
        let reader = Self.reader(serving: data, requests: requests)
        let access = RemoteRangeAccess(
            serves: { $0 == rootPath },
            resolve: { id, _ in id.libraryRootPath == rootPath ? reader : nil }
        )
        let coordinator = try EnrichmentCoordinator(
            store: store,
            enricher: .live(thumbnailDirectory: #require(store.thumbnailDirectory)),
            remoteRangeAccess: access
        )
        await coordinator.start()
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: path)
        try await waitUntil {
            await (try? store.windowReads.mediaAssets(for: [id])[id]?.metadataSourceSize) == Int64(data.count)
        }
        let asset = try #require(try await store.windowReads.mediaAssets(for: [id])[id])
        #expect(asset.captureLocalTime != nil)
        #expect(asset.renderedSourceSize == nil)
        // A few ranges, not the file: the read-through cache's chunks.
        #expect(requests.value <= 4)
        await coordinator.shutdown()
        await store.shutdown()
    }

    // Validates: APP-066
    /// A row the server did not answer for waits out the pacing ledger before it is
    /// claimed again.
    @Test func anUnansweredRowIsPacedBeforeItIsClaimedAgain() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/RemoteStaging/account"),
            relativePath: MediaRelativePath(rawValue: "asset-1/IMG_1.JPG")
        )
        let now = ContinuousClock.now
        schedule.pace(id, sourceSize: 42, cause: .serverDidNotAnswer, now: now)
        let admittedAtOnce = schedule.ledgerAdmits(id, sourceSize: 42, now: now)
        let admittedLater = schedule.ledgerAdmits(id, sourceSize: 42, now: now.advanced(by: .seconds(901)))
        #expect(!admittedAtOnce)
        #expect(admittedLater)
    }
}
