import Foundation
import GRDB
import Synchronization

// Catalog read lanes guide
//
// Every Store read runs in one of two lanes (plan 0116 bet 5, ADR 0002). A window read is one
// the window shows as its answer: a scope's order, the filter's options, the visible tiles,
// the Info pane, a user's act. A background read is an owner's work: a candidate walk, a
// People or duplicates build, the search index's load. Both use the one pool of
// `CatalogStore.readerCount` readers; a background read first takes one of
// `CatalogReadAdmission.backgroundReaders` turns (`CatalogReadAdmission`), so background
// reads never hold more than that many readers and a window read always finds one free.
//
// The caller's handle picks the lane, never the Store function: an owner holds `WindowReads`
// or `BackgroundReads` (`CatalogStore.windowReads`, `.backgroundReads`) and reads through it.
// A Store read takes the handle's `CatalogReadLane`, which only a handle can make, and reaches
// a connection only through `CatalogStore.reader(for:)` (lint `read_outside_lane`). A read
// both lanes need is on both handles.

/// Which lane a read runs in: made only by a handle (`CatalogReads.lane`).
nonisolated struct CatalogReadLane: Equatable, Sendable {
    enum Kind: String, Sendable {
        case window
        case background
    }

    let kind: Kind

    fileprivate init(_ kind: Kind) {
        self.kind = kind
    }
}

nonisolated protocol CatalogReadLaneKind: Sendable {
    static var kind: CatalogReadLane.Kind { get }
}

/// The window's lane: reads whose answer the window shows.
nonisolated enum WindowLane: CatalogReadLaneKind {
    static let kind = CatalogReadLane.Kind.window
}

/// The background owners' lane: admitted a few at a time.
nonisolated enum BackgroundLane: CatalogReadLaneKind {
    static let kind = CatalogReadLane.Kind.background
}

/// The Store's reads in one lane. Made only here, from the Store it wraps.
nonisolated struct CatalogReads<Lane: CatalogReadLaneKind>: Sendable {
    let store: CatalogStore

    fileprivate init(store: CatalogStore) {
        self.store = store
    }

    var lane: CatalogReadLane {
        CatalogReadLane(Lane.kind)
    }
}

typealias WindowReads = CatalogReads<WindowLane>
typealias BackgroundReads = CatalogReads<BackgroundLane>

extension CatalogStore {
    /// The window's reads: for the projection's window build, the view models, the tile
    /// detail reader and the user's acts.
    nonisolated var windowReads: WindowReads {
        WindowReads(store: self)
    }

    /// The background owners' reads.
    nonisolated var backgroundReads: BackgroundReads {
        BackgroundReads(store: self)
    }

    /// The pool's readers. Four serve background reads at most, so four are always there for
    /// the window: on a generated owner-size catalog with every owner running, window reads
    /// waited up to 1.9 s (p95) for one of four shared readers and under 30 ms with lanes
    /// (`docs/research/2026-11-16-window-read-lanes.md`).
    static let readerCount = 8
}

// MARK: - The background admission

/// Background reads: at most `capacity` run at once, the rest wait in the order asked. A
/// waiter that stops waiting is dropped; a read that ends passes its turn to the next.
nonisolated struct ReadAdmissionMachine: AdmissionMachine, Equatable {
    enum Event: Equatable, Sendable {
        case request(AdmissionRequest)
        case withdraw(AdmissionRequest)
        case release(AdmissionRequest)
    }

    enum Effect: Equatable, Sendable {
        case grant(AdmissionRequest)
        case refuse(AdmissionRequest)
    }

    let capacity: Int
    private(set) var running: Set<AdmissionRequest> = []
    private(set) var waiting: [AdmissionRequest] = []

    static func requested(_ request: AdmissionRequest, _: Void) -> Event {
        .request(request)
    }

    static func withdrawn(_ request: AdmissionRequest) -> Event {
        .withdraw(request)
    }

    static func released(_ request: AdmissionRequest) -> Event {
        .release(request)
    }

    static func resolution(of effect: Effect) -> (request: AdmissionRequest, granted: Bool) {
        switch effect {
        case let .grant(request): (request, true)
        case let .refuse(request): (request, false)
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .request(request):
            waiting.append(request)
        case let .withdraw(request):
            guard let index = waiting.firstIndex(of: request) else { return [] }
            waiting.remove(at: index)
            return [.refuse(request)]
        case let .release(request):
            guard running.remove(request) != nil else { return [] }
        }
        var granted: [Effect] = []
        while running.count < capacity, !waiting.isEmpty {
            let next = waiting.removeFirst()
            running.insert(next)
            granted.append(.grant(next))
        }
        return granted
    }
}

/// The admission every background read takes before it enters the pool, and what it cost
/// since launch, for `op=catalog.store.use`.
final nonisolated class CatalogReadAdmission: Sendable {
    /// Background reads at once: half the pool (`CatalogStore.readerCount`).
    static let backgroundReaders = 4

    struct Use: Equatable, Sendable {
        var admitted = 0
        /// Reads that found every turn taken.
        var waited = 0
        var totalWait: Duration = .zero
        var longestWait: Duration = .zero
    }

    private let admission: Admission<ReadAdmissionMachine>
    private let counted = Mutex(Use())

    init(capacity: Int = CatalogReadAdmission.backgroundReaders) {
        admission = Admission(ReadAdmissionMachine(capacity: capacity))
    }

    var machine: ReadAdmissionMachine {
        admission.machine
    }

    func use() -> Use {
        counted.withLock { $0 }
    }

    /// Waits for a turn; throws `CancellationError` when the caller's task is cancelled first.
    func admit() async throws -> AdmissionRequest {
        let asked = ContinuousClock.now
        let request = try await admission.admit(())
        let waited = asked.duration(to: .now)
        counted.withLock { use in
            use.admitted += 1
            // A turn free at once still crosses the shell's continuation; a wait under a
            // millisecond is not a wait for another read.
            if waited >= .milliseconds(1) {
                use.waited += 1
                use.totalWait += waited
                use.longestWait = max(use.longestWait, waited)
            }
        }
        return request
    }

    func release(_ request: AdmissionRequest) {
        admission.release(request)
    }
}

/// The pool, entered in one lane (`CatalogStore.reader(for:)`).
nonisolated struct CatalogLaneReader: Sendable {
    let pool: any DatabaseReader
    let lane: CatalogReadLane
    let admission: CatalogReadAdmission

    /// `readFreeingConnection` in this lane. A background read takes its turn before it asks
    /// the pool for a connection, and gives it back on the connection's queue as the
    /// connection goes back, on every exit. `askedAt` of a background read is when its turn
    /// came, so a stall line names a wait for a connection, never the turn a read is meant to
    /// wait for.
    func readFreeingConnection<T: Sendable>(
        operation: String = #function,
        askedAt: ContinuousClock.Instant = .now,
        _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        switch lane.kind {
        case .window:
            return try await pool.readFreeingConnection(operation: operation, askedAt: askedAt, body)
        case .background:
            let request = try await admission.admit()
            return try await pool.readFreeingConnection(
                operation: operation, askedAt: max(askedAt, .now), freed: { admission.release(request) }, body
            )
        }
    }
}

// MARK: - The reads, by the lanes that ask for them

/// Reads both lanes ask for.
extension CatalogReads {
    func holdRead(_ hold: @escaping @Sendable () -> Void) async throws {
        try await store.holdRead(hold, lane: lane)
    }

    func planningMedia(for rootPath: LibraryRootPath) async -> [PlanningFileFacts]? {
        await store.planningMedia(for: rootPath, lane: lane)
    }

    func faces(of id: MediaAssetID) async throws -> [DetectedFace] {
        try await store.faces(of: id, lane: lane)
    }

    func editRecipe(for id: MediaAssetID) async throws -> StoredEditRecipe? {
        try await store.editRecipe(for: id, lane: lane)
    }

    func importBatchAssetCount(_ batch: ImportBatchID) async throws -> Int {
        try await store.importBatchAssetCount(batch, lane: lane)
    }
}

/// Reads only the window asks for.
extension CatalogReads where Lane == WindowLane {
    /// The owed rows among those on screen: their images are what the window paints next.
    func sourceProductCandidates(rootPath: LibraryRootPath, among ids: [MediaAssetID]) async throws -> [SourceProductCandidate] {
        try await store.sourceProductCandidates(rootPath: rootPath, among: ids, lane: lane)
    }

    func peopleGallery(availableLibraryPaths: Set<LibraryRootPath>) async throws -> PeopleGalleryRead? {
        try await store.peopleGallery(availableLibraryPaths: availableLibraryPaths, lane: lane)
    }

    func photoFaces(of files: [MediaAssetID], landedThrough: UInt64) async throws -> PhotoFaces {
        try await store.photoFaces(of: files, landedThrough: landedThrough, lane: lane)
    }

    func newestFaces(of person: PersonID, limit: Int) async throws -> [FaceTile] {
        try await store.newestFaces(of: person, limit: limit, lane: lane)
    }

    func filterOptionTally(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>,
        placeNameLanguages: Set<PlaceNameLanguage>,
        capacity: Int
    ) async throws -> CatalogFilterOptionTally {
        try await store.filterOptionTally(
            for: selection, availableLibraryPaths: availableLibraryPaths, placeNameLanguages: placeNameLanguages,
            capacity: capacity, lane: lane
        )
    }

    func filterOptionsOfRows(
        _ changed: Set<MediaAssetID>,
        names language: PlaceNameLanguage?,
        for row: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> CatalogFilterOptionRows? {
        try await store.filterOptionsOfRows(
            changed, names: language, for: row, availableLibraryPaths: availableLibraryPaths, lane: lane
        )
    }

    func importPlanningSnapshot(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        policy: ImportPolicy,
        generation: UInt64,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) async throws -> ImportPlanningSnapshot? {
        try await store.importPlanningSnapshot(
            source: source,
            destination: destination,
            policy: policy,
            generation: generation,
            calendar: calendar,
            timeZone: timeZone,
            lane: lane
        )
    }

    func importBatches(counting: ImportBatchCounting) async throws -> [ImportBatchSummary] {
        try await store.importBatches(counting: counting, lane: lane)
    }

    func assetIDs(inImportBatch batchID: ImportBatchID) async throws -> [MediaAssetID] {
        try await store.assetIDs(inImportBatch: batchID, lane: lane)
    }

    func assetsMissingBestDateFacts() async throws -> [MediaAssetID] {
        try await store.assetsMissingBestDateFacts(lane: lane)
    }

    func captureWall(for id: MediaAssetID) async throws -> CaptureWallClock.Selection? {
        try await store.captureWall(for: id, lane: lane)
    }

    func companions(in rootPath: LibraryRootPath) async throws -> [MediaCompanion] {
        try await store.companions(in: rootPath, lane: lane)
    }

    func facesRead(for id: MediaAssetID) async throws -> PhotoFacesRead? {
        try await store.facesRead(for: id, lane: lane)
    }

    func photoInfoOverlay(for id: MediaAssetID) async throws -> PhotoInfoOverlay? {
        try await store.photoInfoOverlay(for: id, lane: lane)
    }

    func orderedAssetIDs(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>,
        heldStacks: PhotoStackSQL.Built? = nil
    ) async throws -> CatalogOrderedAssets {
        try await store.orderedAssetIDs(for: descriptor, availableLibraryPaths: availableLibraryPaths, heldStacks: heldStacks, lane: lane)
    }

    func orderedAssetIDs(
        ofRows changed: Set<MediaAssetID>,
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> CatalogOrderedAssets? {
        try await store.orderedAssetIDs(ofRows: changed, for: descriptor, availableLibraryPaths: availableLibraryPaths, lane: lane)
    }

    func orderedAssetIDs(for selection: SidebarSelection, availableLibraryPaths: Set<LibraryRootPath>) async throws -> [MediaAssetID] {
        try await store.orderedAssetIDs(for: selection, availableLibraryPaths: availableLibraryPaths, lane: lane)
    }

    func catalogedAssetCount(for selection: SidebarSelection) async throws -> Int {
        try await store.catalogedAssetCount(for: selection, lane: lane)
    }

    func visibleAssetCount(for selection: SidebarSelection, filter: MediaFilter = .all, availableLibraryPaths: Set<LibraryRootPath>) async throws -> Int {
        try await store.visibleAssetCount(for: selection, filter: filter, availableLibraryPaths: availableLibraryPaths, lane: lane)
    }

    func filterOptions(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>,
        placeNameLanguages: Set<PlaceNameLanguage>
    ) async throws -> CatalogFilterOptions {
        try await store.filterOptions(for: selection, availableLibraryPaths: availableLibraryPaths, placeNameLanguages: placeNameLanguages, lane: lane)
    }

    func placeNameLanguages() async throws -> Set<PlaceNameLanguage> {
        try await store.placeNameLanguages(lane: lane)
    }

    func mediaAssets(for ids: [MediaAssetID], askedAt: ContinuousClock.Instant = .now) async throws -> [MediaAssetID: MediaAsset] {
        try await store.mediaAssets(for: ids, askedAt: askedAt, lane: lane)
    }

    func mediaTileDetails(for ids: [MediaAssetID], askedAt: ContinuousClock.Instant = .now) async throws -> [MediaAssetID: MediaTileDetail] {
        try await store.mediaTileDetails(for: ids, askedAt: askedAt, lane: lane)
    }

    func mediaTrashItems(for ids: [MediaAssetID]) async throws -> [MediaTrashItem] {
        try await store.mediaTrashItems(for: ids, lane: lane)
    }

    func livePhotoMotion(of id: MediaAssetID) async throws -> MediaAssetID? {
        try await store.livePhotoMotion(of: id, lane: lane)
    }

    func restoreTrashedItem(_ trashed: TrashedItem) async -> Bool {
        await store.restoreTrashedItem(trashed, lane: lane)
    }

    func pendingTrashItems() async throws -> [PendingTrashItem] {
        try await store.pendingTrashItems(lane: lane)
    }

    func metadata(for id: MediaAssetID) async throws -> AssetMetadata? {
        try await store.metadata(for: id, lane: lane)
    }

    func searchEmbeddingPendingCount() async throws -> Int {
        try await store.searchEmbeddingPendingCount(lane: lane)
    }

    func namedPeople() async throws -> [SearchPerson] {
        try await store.namedPeople(lane: lane)
    }

    func searchTextMatches(_ queries: [SearchTextQuery]) async throws -> SearchTextMatches {
        try await store.searchTextMatches(queries, lane: lane)
    }

    func searchFactMatches(_ facts: SearchFactFilter) async throws -> Set<MediaAssetID> {
        try await store.searchFactMatches(facts, lane: lane)
    }
}

/// Reads only the background owners ask for.
extension CatalogReads where Lane == BackgroundLane {
    func enrichmentDemandSources(_ ids: [MediaAssetID]) async throws -> [MediaAssetID: Int64?] {
        try await store.enrichmentDemandSources(ids, lane: lane)
    }

    func librariesHoldContent(_ digests: Set<ContentDigest>) async throws -> Set<ContentDigest> {
        try await store.librariesHoldContent(digests, lane: lane)
    }

    func uncheckedForFaces(availableLibraryPaths: Set<LibraryRootPath>) async throws -> MediaCount {
        try await store.uncheckedForFaces(availableLibraryPaths: availableLibraryPaths, lane: lane)
    }

    func peopleSnapshot(of photos: Set<MediaAssetID>? = nil) async throws -> PeopleSnapshot {
        try await store.peopleSnapshot(of: photos, lane: lane)
    }

    func faceEmbeddings(after vector: Int64, limit: Int) async throws -> [FaceVectorStore.Read] {
        try await store.faceEmbeddings(after: vector, limit: limit, lane: lane)
    }

    func settledPeopleAssignment() async throws -> Data? {
        try await store.settledPeopleAssignment(lane: lane)
    }

    func previewFaceCandidates(after cursor: PreviewFaceCursor? = nil, limit: Int) async throws -> PreviewFacePage {
        try await store.previewFaceCandidates(after: cursor, limit: limit, lane: lane)
    }

    func previewFaceCandidates(among ids: Set<MediaAssetID>) async throws -> [PreviewFaceCandidate] {
        try await store.previewFaceCandidates(among: ids, lane: lane)
    }

    func unnamedPlaceCells(language: PlaceNameLanguage, after: PlaceCell? = nil, limit: Int) async throws -> [PlaceCell] {
        try await store.unnamedPlaceCells(language: language, after: after, limit: limit, lane: lane)
    }

    func unnamedPlaceCells(language: PlaceNameLanguage, of ids: Set<MediaAssetID>) async throws -> [PlaceCell] {
        try await store.unnamedPlaceCells(language: language, of: ids, lane: lane)
    }

    func metadataRefreshCandidates(after cursor: MediaAssetID?, limit: Int) async throws -> [MetadataRefreshCandidate] {
        try await store.metadataRefreshCandidates(after: cursor, limit: limit, lane: lane)
    }

    func sourceLastSynced(rootPath: LibraryRootPath) async throws -> Date? {
        try await store.sourceLastSynced(rootPath: rootPath, lane: lane)
    }

    func sourceResyncOwed(rootPath: LibraryRootPath) async throws -> SourceResyncDebt? {
        try await store.sourceResyncOwed(rootPath: rootPath, lane: lane)
    }

    func sourceItemID(for id: MediaAssetID) async throws -> String? {
        try await store.sourceItemID(for: id, lane: lane)
    }

    func sourceItemRows(_ sourceItemIDs: Set<String>, in rootPath: LibraryRootPath) async throws -> [String: SourceItemRow] {
        try await store.sourceItemRows(sourceItemIDs, in: rootPath, lane: lane)
    }

    func sourceProductCandidates(rootPath: LibraryRootPath, after cursor: MediaRelativePath?, limit: Int) async throws -> [SourceProductCandidate] {
        try await store.sourceProductCandidates(rootPath: rootPath, after: cursor, limit: limit, lane: lane)
    }

    func reconcileDerivedFilesIfOwed() async throws -> CatalogStore.DerivedFolderOutcome? {
        try await store.reconcileDerivedFilesIfOwed(lane: lane)
    }

    func derivedFolderCounters() async throws -> DerivedFileReconciliation.Census? {
        try await store.derivedFolderCounters(lane: lane)
    }

    func activeImportOperations() async throws -> [ActiveFileOperation] {
        try await store.activeImportOperations(lane: lane)
    }

    func activeSourceEraseOperations() async throws -> [ActiveSourceEraseOperation] {
        try await store.activeSourceEraseOperations(lane: lane)
    }

    func settleImportedAsset(
        operation: ActiveFileOperation,
        byteSize: Int64,
        contentModifiedAt: Date,
        companions: [MediaCompanion]
    ) async throws -> ImportProductsResult {
        try await store.settleImportedAsset(operation: operation, byteSize: byteSize, contentModifiedAt: contentModifiedAt, companions: companions, lane: lane)
    }

    func activeReorganizationComponents() async throws -> [ActiveReorganizationComponent] {
        try await store.activeReorganizationComponents(lane: lane)
    }

    func settleReorganizationComponent(key: ReorganizationComponentKey) async throws {
        try await store.settleReorganizationComponent(key: key, lane: lane)
    }

    func duplicateCopies(
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> (copies: [DuplicateCopyFacts], keptPairs: Set<DuplicateKeptPair>, reach: DuplicatesReach) {
        try await store.duplicateCopies(availableLibraryPaths: availableLibraryPaths, lane: lane)
    }

    func mirrorProbes(account: LibraryRootPath) async throws -> [MirrorGateway.Probe] {
        try await store.mirrorProbes(account: account, lane: lane)
    }

    func pairMirroredCopies(account: LibraryRootPath) async throws -> Int {
        try await store.pairMirroredCopies(account: account, lane: lane)
    }

    func renderSignatureCandidates(after cursor: AssetKeyCursor? = nil, limit: Int) async throws -> CandidatePage<RenderSignatureCandidate, AssetKeyCursor> {
        try await store.renderSignatureCandidates(after: cursor, limit: limit, lane: lane)
    }

    func searchEmbeddingCandidates(
        after cursor: CaptureOrderCursor? = nil,
        limit: Int
    ) async throws -> CandidatePage<SearchEmbeddingCandidate, CaptureOrderCursor> {
        try await store.searchEmbeddingCandidates(after: cursor, limit: limit, lane: lane)
    }

    func searchEmbeddingCandidates(for ids: Set<MediaAssetID>) async throws -> [SearchEmbeddingCandidate] {
        try await store.searchEmbeddingCandidates(for: ids, lane: lane)
    }

    func searchTextCandidates(for ids: Set<MediaAssetID>) async throws -> [SearchTextCandidate] {
        try await store.searchTextCandidates(for: ids, lane: lane)
    }

    func factsRead(by statements: [String]) async throws -> CatalogChangedFacts {
        try await store.factsRead(by: statements, lane: lane)
    }

    func currentSearchEmbeddingIDs() async throws -> CurrentSearchKeys {
        try await store.currentSearchEmbeddingIDs(lane: lane)
    }

    func searchEmbeddingRows(after cursor: AssetKeyCursor? = nil, limit: Int) async throws -> CandidatePage<StoredSearchEmbeddingRow, AssetKeyCursor> {
        try await store.searchEmbeddingRows(after: cursor, limit: limit, lane: lane)
    }

    func currentSearchEmbeddings(for ids: Set<MediaAssetID>) async throws -> [StoredSearchEmbeddingRow] {
        try await store.currentSearchEmbeddings(for: ids, lane: lane)
    }

    func searchVectorFileState() async throws -> SearchVectorFileState? {
        try await store.searchVectorFileState(lane: lane)
    }

    func searchTextCandidates(after cursor: CaptureOrderCursor? = nil, limit: Int) async throws -> CandidatePage<SearchTextCandidate, CaptureOrderCursor> {
        try await store.searchTextCandidates(after: cursor, limit: limit, lane: lane)
    }

    func photoDescriptionCandidates(
        after cursor: CaptureOrderCursor? = nil,
        limit: Int,
        excluding: some Collection<MediaAssetID> & Sendable = Set<MediaAssetID>()
    ) async throws -> CandidatePage<PhotoDescriptionCandidate, CaptureOrderCursor> {
        try await store.photoDescriptionCandidates(after: cursor, limit: limit, excluding: excluding, lane: lane)
    }

    func currentPhotoDescriptions(for ids: [MediaAssetID]) async throws -> [MediaAssetID: String] {
        try await store.currentPhotoDescriptions(for: ids, lane: lane)
    }

    func samePhotoCandidates(availableLibraryPaths: Set<LibraryRootPath>) async throws -> [SamePhotoCandidate] {
        try await store.samePhotoCandidates(availableLibraryPaths: availableLibraryPaths, lane: lane)
    }

    func samePhotoEvidence(for ids: [MediaAssetID]) async throws -> [MediaAssetID: SamePhotoEvidence] {
        try await store.samePhotoEvidence(for: ids, lane: lane)
    }

    func samePhotoCopies(for ids: [MediaAssetID]) async throws -> [MediaAssetID: DuplicateCopy] {
        try await store.samePhotoCopies(for: ids, lane: lane)
    }
}
