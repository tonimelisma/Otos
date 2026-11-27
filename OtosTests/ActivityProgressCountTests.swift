import Foundation
@testable import OtosKit
import Testing

/// ADR 0058: the counts behind the Activity popover's progress are the backlog each owner's
/// walk reads, exactly: a COUNT over the walk's own predicate, not an estimate.
@Suite(.testScope)
struct ActivityProgressCountTests {
    /// Three stills in a library, enriched with thumbnails but no digest.
    private func catalogOfThreeStills() async throws -> (CatalogStore, [MediaAssetID], [MediaAsset]) {
        let temp = try makeTestDirectory()
        let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try writeCatalogStoreFile(library.appending(path: name), contents: "jpeg \(name)")
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: library)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }
        return (store, scanned.testAssets.map(\.id), scanned.testAssets)
    }

    @Test func enrichmentsCountIsEveryRowItsWalkOwes() async throws {
        let (store, ids, _) = try await catalogOfThreeStills()
        #expect(
            try await store.backgroundReads.enrichmentLeft(videoFaces: .admitted)
                == EnrichmentLeft(byPurpose: [.thumbnail: ids.count]),
            "every new row owes its products, filed under the thumbnail it still needs"
        )
    }

    @Test func eachCountEqualsWhatItsWalkReadsAndFallsAsWorkIsWritten() async throws {
        let (store, ids, assets) = try await catalogOfThreeStills()
        _ = await store.applyEnrichmentBatch(assets.map { asset in
            EnrichmentResult(
                id: asset.id,
                metadata: AssetMetadata(),
                enrichedKind: .image,
                thumbnailPath: "\(asset.id.relativePath.rawValue)-thumb.jpg",
                sourceSize: asset.byteSize ?? 0,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: nil
            )
        })

        let written = try await store.backgroundReads.enrichmentLeft(videoFaces: .admitted)
        #expect(written[.thumbnail] == 0, "a row with its rendering owes no thumbnail")
        #expect(written[.copies] == ids.count, "each still owes its digest, filed under the copies duplicates are told by")

        let signatures = try await store.backgroundReads.renderSignatureCandidates(limit: 100).candidates
        #expect(signatures.count == ids.count)
        #expect(try await store.backgroundReads.renderSignaturesLeft() == signatures.count)

        let embeddings = try await store.backgroundReads.searchEmbeddingCandidates(limit: 100).candidates
        #expect(try await store.backgroundReads.searchEmbeddingsLeft() == embeddings.count)

        let first = try #require(signatures.first)
        let gray = [UInt8](repeating: 9, count: RenderSignature.grayEdge * RenderSignature.grayEdge)
        let signature = try #require(RenderSignature(differenceHash: 1, gray: gray))
        #expect(try await store.applyRenderSignatures([
            RenderSignatureResult(id: first.id, source: first.source, signature: signature),
        ]) == 1)
        #expect(try await store.backgroundReads.renderSignaturesLeft() == signatures.count - 1, "a written signature is done")
    }

    /// What an owner reports done is what the catalog accepted from it, counted as it writes,
    /// beside what its walk still owes: after signing three stills, 3 finished and none left.
    @Test func anOwnersProgressCountsTheItemsItWrote() async throws {
        let (store, ids, assets) = try await catalogOfThreeStills()
        _ = await store.applyEnrichmentBatch(assets.map { asset in
            EnrichmentResult(
                id: asset.id,
                metadata: AssetMetadata(),
                enrichedKind: .image,
                thumbnailPath: "\(asset.id.relativePath.rawValue)-thumb.jpg",
                sourceSize: asset.byteSize ?? 0,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: nil
            )
        })
        let refresher = RenderSignatureRefresher(store: store, thumbnailDirectory: nil)
        #expect(await refresher.progress(for: .findingDuplicates) == .counted(completed: 0, left: ids.count), "nothing written yet")
        await refresher.start()
        _ = try await refresher.untilQuiescent()
        #expect(await refresher.progress(for: .findingDuplicates) == .counted(completed: ids.count, left: 0))
        await refresher.shutdown()
        await store.shutdown()
    }
}
