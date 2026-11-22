import Foundation
import OSLog

/// Background owner set guide (ADR 0055, ADR 0032 rule 8)
///
/// The background owners a window starts once its first grid has painted, and the one place
/// that starts them: the window's start path and the idle guard both run `start()`, so the
/// owners a test measures start exactly as the app's do, in the app's order. The heavy loads
/// among them wait for the window's `LoadAdmission`, which the window opens at the same grid.
///
/// The order: the derived folder's once-a-launch load (it waits behind every admitted load),
/// enrichment and the materializer it feeds (the visible tiles' thumbnails), the Immich
/// accounts' sync, the walks that read stored thumbnails, the search index, descriptions, and
/// the metadata re-read last, which `start()` runs to its end. Every owner's tasks run below
/// the window's priority (`TaskPriority.backgroundOwner`), inherited from the caller.
///
/// `quiescentOwners()` lists every owner that reports quiescence (`QuiescentOwner`), the
/// projection's own owners included, for `BackgroundOwnerQuiescence.untilQuiescent`.
nonisolated struct BackgroundOwnerSet: Sendable {
    let store: CatalogStore
    let projection: CatalogProjection
    let materialization: MaterializationCoordinator
    let enrichment: EnrichmentCoordinator?
    let immich: ImmichAccounts?
    let renderSignatures: RenderSignatureRefresher?
    let previewFaces: PreviewFaceReader?
    let placeNames: PlaceNameReader?
    let searchIndex: PhotoSearchIndex?
    let descriptions: PhotoDescriptionWriter?
    let metadata: MetadataRefresher?
    let derivedFolder: DerivedFolderLoad?
    /// Which owners this session starts (`BackgroundOwners`).
    let starts: BackgroundOwners

    /// Starts every owner `starts` names, in order, and returns when the metadata pass ends.
    func start() async {
        await derivedFolder?.start()
        if starts.starts(.enrichment), let enrichment {
            await materialization.start()
            await enrichment.start()
        }
        if starts.starts(.immich) {
            await immich?.start()
        }
        if starts.starts(.renderSignatures) {
            await renderSignatures?.start()
        }
        if starts.starts(.previewFaces) {
            await previewFaces?.start()
        }
        if starts.starts(.placeNames) {
            await placeNames?.start()
        }
        if starts.starts(.searchIndex) {
            await searchIndex?.start()
        }
        if starts.starts(.descriptions) {
            await descriptions?.start()
        }
        if starts.starts(.metadataRefresh) {
            await metadata?.refresh()
        }
    }

    /// Returns once the duplicate groups the launch owed are built and published
    /// (`LaunchSettlement.duplicatesBuilt`), at once when no duplicates owner runs.
    func untilLaunchDuplicatesBuilt() async throws {
        try await projection.untilLaunchDuplicatesBuilt()
    }

    /// Every owner `start()` started that reports quiescence, the projection and the owners
    /// it runs included. An owner a tour leaves out is not listed: it owes nothing it was asked.
    /// Which of them works a backlog each says itself (`QuiescentOwner.worksBacklog`).
    func quiescentOwners() async -> [any QuiescentOwner] {
        var owners: [any QuiescentOwner] = await projection.quiescentOwners()
        if let derivedFolder {
            owners.append(derivedFolder)
        }
        if starts.starts(.enrichment), let enrichment {
            owners += [materialization, enrichment]
        }
        if starts.starts(.immich), let immich {
            owners += await immich.quiescentOwners()
        }
        let walkers: [(BackgroundOwner, (any QuiescentOwner)?)] = [
            (.renderSignatures, renderSignatures), (.previewFaces, previewFaces), (.placeNames, placeNames),
            (.searchIndex, searchIndex), (.descriptions, descriptions), (.metadataRefresh, metadata),
        ]
        return owners + walkers.compactMap { owner, running in starts.starts(owner) ? running : nil }
    }
}

extension BackgroundOwnerSet {
    /// Every started owner whose work the Activity surface names, with the outcome it serves
    /// (ADR 0058, DES-035). Immich accounts report their own status; the derived folder's tidy
    /// and the projection's publications are machinery and are not named.
    func activityOwners() async -> [ActivityBoard.Watched] {
        var owners = await projection.activityOwners()
        if starts.starts(.enrichment), let enrichment {
            owners += [
                .init(kind: .readingPhotos, owner: enrichment),
                .init(kind: .downloadingOriginals, owner: materialization),
            ]
        }
        let named: [(BackgroundOwner, ActivityKind, (any QuiescentOwner)?)] = [
            (.renderSignatures, .findingDuplicates, renderSignatures), (.previewFaces, .findingPeople, previewFaces),
            (.placeNames, .namingPlaces, placeNames), (.searchIndex, .preparingSearch, searchIndex),
            (.descriptions, .describingPhotos, descriptions), (.metadataRefresh, .readingPhotos, metadata),
        ]
        for (owner, kind, running) in named where starts.starts(owner) {
            if let running {
                owners.append(.init(kind: kind, owner: running))
            }
        }
        return owners
    }
}

/// The derived folder's once-a-launch load: its counters, and a reconciliation only when a
/// fact says leftovers can exist (`CatalogStore.reconcileDerivedFilesIfOwed`), as a heavy load
/// behind every other admitted one (`BackgroundLoad.derivedFolder`). One pass, its one
/// request covered when it ends, however it ended but torn down: a failure is logged and the
/// next launch looks again. Nothing rings it again (`QuiescentOwner`).
///
/// Its task runs at the priority of the task that starts it, `TaskPriority.backgroundOwner`,
/// like every owner's (ADR 0055): while it runs it holds the admission's one turn, so a lower
/// priority would hold People, duplicates and the search index behind work the system
/// throttles hardest under load.
actor DerivedFolderLoad: QuiescentOwner {
    private let admission: LoadAdmission
    /// The look the load runs once admitted.
    private let look: @Sendable () async throws -> Void
    private var task: Task<Void, Never>?
    let activity = OwnerActivity(owner: "derivedFolder")

    init(store: CatalogStore, admission: LoadAdmission) {
        self.init(admission: admission) {
            _ = try await store.backgroundReads.reconcileDerivedFilesIfOwed()
        }
    }

    init(admission: LoadAdmission, look: @escaping @Sendable () async throws -> Void) {
        self.admission = admission
        self.look = look
    }

    /// Starts the launch's load, once, at the caller's priority.
    func start() {
        guard task == nil else { return }
        let answering = activity.request()
        activity.beginPass()
        task = Task { [admission, look] in
            var answered: UInt64?
            do {
                try await admission.run(.derivedFolder) {
                    try await look()
                }
                answered = answering
            } catch is CancellationError {
                // Refused at teardown: the next launch looks again.
            } catch {
                // This launch's one look ended: the next launch looks again.
                OtosLog.thumbnails.errorOperation("derived.reconcile", phase: "failed", fields: [
                    "error": String(describing: error),
                ])
                answered = answering
            }
            await self.ended(covering: answered)
        }
    }

    private func ended(covering answered: UInt64?) {
        activity.read(rows: 0)
        activity.endPass(covering: answered)
        settleQuiescence()
    }

    /// One load a launch: nothing rings it again.
    func ringIdle() {}

    func shutdown() {
        task?.cancel()
    }
}
