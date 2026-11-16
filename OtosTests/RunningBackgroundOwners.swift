import Foundation
@testable import OtosKit
import Testing

/// Every background owner the app runs over one Store, as the app starts them, with models
/// and downloads that answer nothing: originals stay dataless and unreachable, no search or
/// description model loads, no face is read and no place is named. Duplicates and People run
/// under the projection, which also reads All Media's order. The stall reproduction and the
/// idle guard both run them.
actor RunningBackgroundOwners {
    let materializer: MaterializationCoordinator
    let enrichment: EnrichmentCoordinator
    let renderSignatures: RenderSignatureRefresher
    let previewFaces: PreviewFaceReader
    let placeNames: PlaceNameReader
    let searchIndex: PhotoSearchIndex
    let descriptions: PhotoDescriptionWriter
    let metadata: MetadataRefresher
    let projection: CatalogProjection
    private var projectionTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?

    init(store: CatalogStore, thumbnails: URL) throws {
        materializer = MaterializationCoordinator(
            store: store,
            executor: { _ in MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0) },
            volumeCapacity: ampleVolumeCapacity,
            status: { _ in .dataless }
        )
        enrichment = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .notMaterialized },
            materializationRequester: materializer
        )
        renderSignatures = RenderSignatureRefresher(store: store, thumbnailDirectory: thumbnails)
        previewFaces = PreviewFaceReader(store: store, thumbnailDirectory: thumbnails) { _ in throw CocoaError(.featureUnsupported) }
        placeNames = PlaceNameReader(store: store, namer: PlaceNameReader.Namer { _, _ in .none })
        // The test bundle holds no search model, so no embedding is made, as on a Mac whose
        // model is still loading; every read before the model runs as in the app.
        searchIndex = try PhotoSearchIndex(
            store: store,
            thumbnailDirectory: thumbnails,
            vectorDirectory: #require(store.searchIndexDirectory),
            bundle: Bundle(for: BundleMarker.self),
            textReader: SearchTextReader { RecognizingSession { _ in [] } }
        )
        descriptions = PhotoDescriptionWriter(store: store, thumbnailDirectory: thumbnails) { _, _ in
            throw CocoaError(.featureUnsupported)
        }
        metadata = MetadataRefresher(store: store) { _ in .unreachable }
        projection = CatalogProjection()
    }

    /// Starts every owner, the projection's loop and Duplicates and People under it included,
    /// and the metadata refresher's pass.
    func start(store: CatalogStore) async {
        let states = await projection.states(store: store, initialDescriptor: .default)
        projectionTask = Task {
            for await _ in states {}
        }
        await materializer.start()
        await enrichment.start()
        await renderSignatures.start()
        await previewFaces.start()
        await placeNames.start()
        await searchIndex.start()
        await descriptions.start()
        let metadata = metadata
        metadataTask = Task { await metadata.refresh() }
    }

    func shutdown() async {
        await enrichment.shutdown()
        await materializer.shutdown()
        await renderSignatures.shutdown()
        await previewFaces.shutdown()
        await placeNames.shutdown()
        await searchIndex.shutdown()
        await descriptions.shutdown()
        await metadata.shutdown()
        await metadataTask?.value
        projectionTask?.cancel()
        await projectionTask?.value
    }
}

/// A class whose bundle is the test bundle, which holds no search model.
private final class BundleMarker {}
