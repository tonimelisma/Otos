import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Immich accounts' faces, read from the previews stored on sync (ADR 0047): which rows owe
/// them, how a new Immich version is read again, and the reader end to end.
@Suite(.testDirectory)
struct PreviewFaceReaderTests {
    /// How many previews the stand-in analyser was handed.
    private final class Calls: Sendable {
        private let count = Mutex(0)

        func record() {
            count.withLock { $0 += 1 }
        }

        var value: Int {
            count.withLock { $0 }
        }
    }

    private static let server = URL(string: "https://photos.example.com")!

    /// An Immich still with a stored preview owes faces once; a new version of the asset,
    /// with its new preview, owes them again. A video never does.
    @Test func anImmichStillOwesFacesFromEachPreview() async throws {
        let account = try await ImmichAccount.make(in: makeTestDirectory())
        try await account.list([("IMG_1.JPG", "public.jpeg", 42), ("CLIP.MOV", "com.apple.quicktime-movie", 42)])
        await account.applySourceImages(for: "IMG_1.JPG", size: 42)
        await account.applySourceImages(for: "CLIP.MOV", size: 42)

        let first = try await account.store.previewFaceCandidates(limit: 10)
        #expect(first.map(\.id) == [account.id("IMG_1.JPG")])
        #expect(try await account.store.applyPreviewFaces(first.map {
            PreviewFaceResult(candidate: $0, faces: EnrichedFaces(faces: [FaceEnrichmentTests.face(seed: 1)], analysisRevision: 1))
        }) == 1)
        #expect(try await account.store.previewFaceCandidates(limit: 10).isEmpty)
        #expect(try await account.store.faces(of: account.id("IMG_1.JPG")) == [FaceEnrichmentTests.face(seed: 1)])

        try await account.list([("IMG_1.JPG", "public.jpeg", 43)])
        await account.applySourceImages(for: "IMG_1.JPG", size: 43)
        #expect(try await account.store.previewFaceCandidates(limit: 10).map(\.id) == [account.id("IMG_1.JPG")])
        await account.store.shutdown()
    }

    /// A reading of a preview the row no longer has is not written.
    @Test func aReadingOfAnOlderPreviewIsNotWritten() async throws {
        let account = try await ImmichAccount.make(in: makeTestDirectory())
        try await account.list([("IMG_1.JPG", "public.jpeg", 42)])
        await account.applySourceImages(for: "IMG_1.JPG", size: 42)
        let stale = try await account.store.previewFaceCandidates(limit: 10)

        try await account.list([("IMG_1.JPG", "public.jpeg", 43)])
        await account.applySourceImages(for: "IMG_1.JPG", size: 43)

        #expect(try await account.store.applyPreviewFaces(stale.map { PreviewFaceResult(candidate: $0, faces: .noneFound) }) == 0)
        await account.store.shutdown()
    }

    /// The reader reads the stored preview, hands it upright to the analyser, and stores the
    /// faces; a fixed library's rows are never its work.
    @Test func theReaderStoresThePreviewsFaces() async throws {
        let account = try await ImmichAccount.make(in: makeTestDirectory())
        try await account.list([("IMG_1.JPG", "public.jpeg", 42)])
        let directory = try #require(account.store.thumbnailDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeSubjectJPEG(to: directory.appending(path: "preview.jpg"), center: CGPoint(x: 0.5, y: 0.5))
        await account.applySourceImages(for: "IMG_1.JPG", size: 42)
        let face = FaceEnrichmentTests.face(seed: 2)
        let analysed = Calls()
        let reader = PreviewFaceReader(
            store: account.store,
            thumbnailDirectory: directory,
            analyzeFaces: { _ in
                analysed.record()
                return FaceAnalysis(faces: [face], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            }
        )

        await reader.start()
        try await waitUntil { try await account.store.faces(of: account.id("IMG_1.JPG")) == [face] }
        await reader.shutdown()

        #expect(try await account.store.previewFaceCandidates(limit: 10).isEmpty)
        #expect(analysed.value == 1)
        await account.store.shutdown()
    }

    /// An Immich account in a file-backed catalog, whose listing the test drives by hand.
    struct ImmichAccount {
        let store: CatalogStore
        let rootPath: LibraryRootPath

        static func make(in directory: URL) async throws -> ImmichAccount {
            let store = CatalogStore(
                location: .databaseFile(directory.appending(path: "db/catalog.sqlite")), scanCadence: .milliseconds(10)
            )
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(
                server: PreviewFaceReaderTests.server, userID: "user-1", displayName: "Family",
                stagingContainer: directory.appending(path: "RemoteStaging", directoryHint: .isDirectory)
            )
            return ImmichAccount(store: store, rootPath: rootPath)
        }

        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "asset-\(name)/\(name)"))
        }

        /// Lists `files` as the server would, each under its own asset folder.
        func list(_ files: [(name: String, type: String, size: Int64)]) async throws {
            let scan = try await store.beginSourceListing(rootPath: rootPath)
            let scanned = files.map { file in
                ScannedMediaFile(
                    relativePath: id(file.name).relativePath,
                    name: file.name,
                    contentTypeIdentifier: file.type,
                    byteSize: file.size,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            }
            try await store.recordSourceListingBatch(scanned, scan: scan)
            try await store.completeSourceListing(scan: scan, observedPaths: Set(scanned.map(\.relativePath)))
        }

        /// Immich's thumbnail and preview for `name`, as sync stores them.
        func applySourceImages(for name: String, size: Int64) async {
            _ = await store.applyEnrichmentBatch([EnrichmentResult(
                id: id(name),
                metadata: nil,
                rendering: EnrichedRendering(thumbnailPath: "thumb.jpg", previewPath: "preview.jpg", origin: .source),
                sourceSize: size,
                sourceMTimeSeconds: 1_700_000_000,
                contentHash: nil
            )])
        }
    }
}
