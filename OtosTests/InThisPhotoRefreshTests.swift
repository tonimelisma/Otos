import Foundation
@testable import OtosKit
import Testing

/// The Info pane's In This Photo section follows what search reads (APP-041, ADR 0050): the
/// view model's refresh re-reads the shown item's labels whenever its doorbell rings, which
/// search's index does as it reads and every Info read does as it lands. This window has no
/// index, so the test rings it as the index would.
@Suite(.testDirectory)
@MainActor
struct InThisPhotoRefreshTests {
    @Test func inThisPhotoReadsTheShownItemAgainWhenItsDoorbellRings() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let asset = try #require(try await library.store.mediaAssets(for: [id])[id])
            _ = await library.store.applyEnrichmentBatch([EnrichmentResult(
                id: id, metadata: AssetMetadata(), enrichedKind: .image, thumbnailPath: "pool-thumb.jpg",
                sourceSize: asset.byteSize ?? 0, sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: nil
            )])
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.startRecognizedRefresh()
            defer { model.recognizedRefreshTask?.cancel() }

            model.openLoupe(id: id)
            model.toggleInspector(.info)
            try await waitUntil { model.photoInfo?.id == id }
            #expect(model.photoInfo?.recognized == PhotoInfo.Recognized(labels: nil, text: nil))

            let candidate = try #require(try await library.store.searchEmbeddingCandidates(limit: 10).first)
            _ = try await library.store.applySearchEmbeddings([SearchEmbeddingResult(
                id: id, source: candidate.source, embedding: [Float](repeating: 1, count: SearchEmbedding.dimensions),
                labels: ["pool": 0.88], confidentLabels: ["pool"]
            )])
            let named = try await model.sceneLabelNames.names(of: ["pool"], in: Locale.current.language)
            model.recognizedDoorbell?.yield()
            try await waitUntil { model.photoInfo?.recognized?.labels == named }
            #expect(model.photoInfo?.id == id)
        }
    }
}
