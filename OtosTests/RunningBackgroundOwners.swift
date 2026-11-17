import Foundation
@testable import OtosKit
import Testing

/// Every background owner the app runs over one Store, started as the app starts them
/// (`BackgroundOwnerSet`): under one closed `LoadAdmission` that opens at the window's first
/// grid, with the search's first query readied over that grid. Models and downloads answer
/// nothing: originals stay dataless and unreachable, no search or description model loads, no
/// face is read and no place is named. Duplicates and People run under the projection, which
/// also reads All Media's order. An account's sync runs as `ImmichAccounts` runs one, against a
/// server with nothing new: its stream lists no line and it has no image to give. The stall
/// reproduction and the idle guard both run them.
///
/// `backoffs` sets how long an owner waits after a failure before it tries again: the app's
/// own waits, or a day, so that no backoff an owner arms while a test runs comes due before
/// the test ends, however slowly a loaded Mac runs it.
actor RunningBackgroundOwners {
    enum Backoffs {
        case production
        case beyondTheRun

        static let day: Duration = .seconds(86400)

        var enrichment: EnrichmentRetrySchedule {
            switch self {
            case .production:
                .production
            case .beyondTheRun:
                EnrichmentRetrySchedule(
                    backgroundDownloadDelays: [Self.day], ledgerPacing: Self.day, readinessRecheck: Self.day,
                    spaceRecheck: Self.day, deviceFailureBackoff: Self.day, deviceAttemptLimit: 1,
                    writeFailureBackoff: Self.day, faceModelBackoff: Self.day
                )
            }
        }

        var searchIndex: (first: Duration, last: Duration) {
            switch self {
            case .production: (.seconds(30), .seconds(900))
            case .beyondTheRun: (Self.day, Self.day)
            }
        }

        var descriptions: (retry: Duration, busy: Duration) {
            switch self {
            case .production: (PhotoDescriptionWriter.retryPacing, PhotoDescriptionWriter.busyPacing)
            case .beyondTheRun: (Self.day, Self.day)
            }
        }
    }

    let admission: LoadAdmission
    let materializer: MaterializationCoordinator
    let enrichment: EnrichmentCoordinator
    let renderSignatures: RenderSignatureRefresher
    let previewFaces: PreviewFaceReader
    let placeNames: PlaceNameReader
    let searchIndex: PhotoSearchIndex
    let descriptions: PhotoDescriptionWriter
    let metadata: MetadataRefresher
    let derivedFolder: DerivedFolderLoad
    let projection: CatalogProjection
    /// The account's sync, when the catalog has an account.
    let accountSync: ImmichCatalogSync?
    private let owners: BackgroundOwnerSet
    private var projectionTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var syncTasks: [Task<Void, Never>] = []

    init(store: CatalogStore, thumbnails: URL, account: LibraryRootPath? = nil, backoffs: Backoffs = .production) throws {
        let admission = LoadAdmission()
        self.admission = admission
        materializer = MaterializationCoordinator(
            store: store,
            executor: { _ in MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0) },
            volumeCapacity: ampleVolumeCapacity,
            status: { _ in .dataless }
        )
        enrichment = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .notMaterialized },
            materializationRequester: materializer,
            schedule: EnrichmentSchedule(retrySchedule: backoffs.enrichment)
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
            backoff: backoffs.searchIndex,
            textReader: SearchTextReader { RecognizingSession { _ in [] } },
            admission: admission
        )
        descriptions = PhotoDescriptionWriter(
            store: store, thumbnailDirectory: thumbnails,
            describe: { _, _ in throw CocoaError(.featureUnsupported) },
            retryPacing: backoffs.descriptions.retry, busyPacing: backoffs.descriptions.busy
        )
        metadata = MetadataRefresher(store: store) { _ in .unreachable }
        derivedFolder = DerivedFolderLoad(store: store, admission: admission)
        projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, admission: admission)
        accountSync = account.map { account in
            ImmichCatalogSync(
                rootPath: account, source: QuietServer(), store: store, volumeCapacity: ampleVolumeCapacity, admission: admission
            )
        }
        owners = BackgroundOwnerSet(
            store: store,
            projection: projection,
            materialization: materializer,
            enrichment: enrichment,
            immich: nil,
            renderSignatures: renderSignatures,
            previewFaces: previewFaces,
            placeNames: placeNames,
            searchIndex: searchIndex,
            descriptions: descriptions,
            metadata: metadata,
            derivedFolder: derivedFolder,
            starts: .all
        )
    }

    /// Subscribes the projection as the window does, and at its first grid opens the admission,
    /// readies the first search, starts the account's sync and starts every
    /// owner (`BackgroundOwnerSet.start`), as `CatalogWindowViewModel` does at
    /// `op=launch.firstGrid`. Returns once they are started; the metadata pass runs on.
    func start(store: CatalogStore) async {
        let states = await projection.states(store: store, initialDescriptor: .default)
        let (firstGrid, gridPainted) = AsyncStream<Void>.makeStream()
        projectionTask = Task {
            for await state in states where state.mediaEmptyState != .loadingCatalog {
                gridPainted.yield()
                gridPainted.finish()
            }
        }
        for await _ in firstGrid {}
        admission.open()
        searchIndex.prepareWhenAdmitted()
        if let accountSync {
            syncTasks = [
                Task { await accountSync.run() },
                Task { await accountSync.runVisible() },
            ]
            accountSync.requestSync()
        }
        let owners = owners
        startTask = Task(priority: .backgroundOwner) {
            await owners.start()
        }
    }

    /// Every owner that reports quiescence, the account's sync included.
    func quiescentOwners() async -> [any QuiescentOwner] {
        let started: [any QuiescentOwner] = await owners.quiescentOwners()
        return started + (accountSync.map { [$0] } ?? [])
    }

    /// Returns every owner's fact once the owners have started, the metadata pass has ended and
    /// every owner owes nothing at one instant (`BackgroundOwnerQuiescence.untilQuiescent`).
    func untilQuiescent(store: CatalogStore) async throws -> [OwnerQuiescence] {
        await startTask?.value
        return try await BackgroundOwnerQuiescence.untilQuiescent(quiescentOwners(), store: store)
    }

    func shutdown() async {
        admission.shutdown()
        await derivedFolder.shutdown()
        await enrichment.shutdown()
        await materializer.shutdown()
        await renderSignatures.shutdown()
        await previewFaces.shutdown()
        await placeNames.shutdown()
        await searchIndex.shutdown()
        await descriptions.shutdown()
        await metadata.shutdown()
        await startTask?.value
        accountSync?.finish()
        for task in syncTasks {
            task.cancel()
            await task.value
        }
        projectionTask?.cancel()
        await projectionTask?.value
    }
}

/// An Immich server with nothing new: each stream is complete and lists no line, and it gives
/// no image or asset (404), as a server whose assets are all listed already.
private nonisolated struct QuietServer: ImmichSyncSource {
    func events(fromZero _: Bool) async throws -> any AsyncSequence<ImmichSyncEvent, any Error> {
        AsyncThrowingStream<ImmichSyncEvent, any Error> { continuation in
            continuation.yield(.complete(ack: "complete"))
            continuation.finish()
        }
    }

    func acknowledge(_: [String]) async throws {}

    func preview(assetID _: String) async throws -> Data {
        throw ImmichClientError.refused(status: 404)
    }

    func asset(id _: String) async throws -> ImmichAssetDetail {
        throw ImmichClientError.refused(status: 404)
    }
}

/// A class whose bundle is the test bundle, which holds no search model.
private final class BundleMarker {}
