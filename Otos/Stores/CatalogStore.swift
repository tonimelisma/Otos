import Foundation
import GRDB
import OSLog

/// Store notifications remain cheap invalidation signals. Most changes carry no
/// payload; root removal carries its typed path because a remove followed by a
/// same-path add can otherwise coalesce into a queried state where Projection cannot
/// observe that the selected library instance disappeared.
nonisolated enum CatalogStoreChange: Equatable {
    case catalogChanged
    case assetsDetailChanged
    case libraryRemoved(LibraryRootPath)
}

/// Catalog Store guide
///
/// This actor is the only runtime owner of catalog truth. SQLite provides durable
/// overlay storage and the per-asset working set; the actor keeps only root identity,
/// source metadata, root availability, scan/enumeration lifecycle, and notification
/// state resident. Fixed libraries, removable volumes, and MTP cameras share the root
/// table because the current filesystem or staging path remains the asset identity
/// boundary, while `LibraryRootKind` controls lifecycle rules such as All Media
/// membership, launch scans, detach, and Forget. Filesystem scans and device catalog
/// batches write SQLite and notify consumers only when those writes actually inserted,
/// updated, or deleted rows. While the app runs, `CatalogFilesystemWatcher` forwards
/// macOS events to per-root debounced reconciliation: safe single-file events update
/// one row and unsafe events fall back to the full scan pipeline. Views never access
/// persistence directly.
///
/// Why an actor: the database handle, root runtime state, scan lifecycle, and
/// background scans all touch the same catalog authority, and a scan streams in
/// thousands of files concurrently with user actions. Actor isolation serializes every access to that state
/// automatically, so the catalog cannot be corrupted by two operations at once and
/// we never reach for a lock. The cost is that `await` is a yield point — the actor
/// can run another message mid-operation — which is exactly why scans carry the
/// ownership lease described below.
///
/// Store notifications are intentionally lightweight. Ordinary events only mark
/// Projection dirty; successful root removal additionally carries its typed path
/// so same-path replacement cannot hide selection invalidation. Projection pulls
/// cheap root state and descriptor-ordered asset IDs on its background cadence
/// and owns presentation.
/// Initial loading is represented by one finite task so every concurrent caller
/// observes the same load instead of applying competing root sets. Awaited GRDB calls
/// make this actor reentrant, so active scans carry the root path, private root-row
/// instance, and in-memory lease generation they own and revalidate them after each
/// database await. Completed scans reconcile missing paths; failed, cancelled, or
/// stale scans preserve prior rows because incomplete observation cannot prove
/// removal. Device enumerations use the same process-local lease before they may
/// reconcile missing rows, so a stale camera flow cannot delete rows written by a
/// newer attach. A single regular-file remove
/// event proves deletion only after Store checks that exact path is absent under an
/// armed available root.
actor CatalogStore {
    private nonisolated static let slowQueryDiagnosticThresholdMs = 50

    enum Location {
        case application(bundleIdentifier: String)
        case databaseFile(URL)
        case inMemory
    }

    struct StoredRoot {
        let id: Int64
        let path: LibraryRootPath
        let kind: LibraryRootKind
        let deviceIdentity: String?
        let displayName: String?
        let lastSeenAt: Date?
    }

    struct StoredAsset {
        let libraryRootID: Int64
        let relativePath: MediaRelativePath
        let name: String?
        let contentTypeIdentifier: String?
        let byteSize: Int64?
        let createdAt: Date?
        let contentModifiedAt: Date?
        var thumbnailPath: String?
        var bestCaptureDate: Date?
        var bestKind: MediaKind?
        var bestFormat: MediaFormatToken?
        var durationSeconds: Double?
        var enrichedSourceSize: Int64?
        var enrichedSourceMTimeSeconds: Int?
    }

    struct StoredTileDetail {
        let libraryRootID: Int64
        let relativePath: MediaRelativePath
        var thumbnailPath: String?
        var bestKind: MediaKind?
        var durationSeconds: Double?
        var enrichedSourceSize: Int64?
        var enrichedSourceMTimeSeconds: Int?
    }

    struct ThumbnailPathMigration {
        let oldRelativeName: String
        let newRelativeName: String
    }

    /// This value is a process-local ownership lease, not durable scan identity.
    /// The normalized path identifies the domain root, the private row ID
    /// distinguishes a removed root from a later root added at the same path, and
    /// the in-memory generation distinguishes overlapping callbacks for the same
    /// root instance.
    struct ActiveScan: Equatable {
        let rootPath: LibraryRootPath
        let rootRowID: Int64
        let leaseGeneration: UInt64
    }

    private struct RemovableRootAttachment {
        let kind: LibraryRootKind
        let path: LibraryRootPath
        let identity: String
        let displayName: String
        let isEjectable: Bool
        let activity: CatalogLibraryActivity
        let enqueuesScan: Bool

        func root(lastSeenAt: Date) -> LibraryRoot {
            LibraryRoot(
                path: path,
                kind: kind,
                deviceIdentity: identity,
                displayName: displayName,
                lastSeenAt: lastSeenAt
            )
        }
    }

    private enum ScanQueuePriority {
        case normal
        case front
    }

    private struct EnrichmentBatchWriteOutcome {
        var appliedCount = 0
        var promotionFailed = false
        var discardedThumbnails: [GeneratedThumbnail] = []
        var waitMs = 0
        var execMs = 0

        mutating func discard(_ thumbnail: GeneratedThumbnail?) {
            guard let thumbnail else {
                return
            }
            discardedThumbnails.append(thumbnail)
        }

        mutating func failPromotion(_ thumbnail: GeneratedThumbnail?) {
            promotionFailed = true
            discard(thumbnail)
        }
    }

    private struct DatabaseTimedValue<Value: Sendable> {
        let value: Value
        let waitMs: Int
        let execMs: Int

        var totalMs: Int {
            waitMs + execMs
        }
    }

    private let location: Location
    private let scanner: CatalogScanner
    private let filesystemWatcher: CatalogFilesystemWatcher
    private let scanCadence: Duration
    private let filesystemEventDebounce: Duration
    private let filesystemEventSleep: @Sendable (Duration) async -> Void
    private let initialLoadDidRead: (@Sendable () async -> Void)?
    private var dbWriter: (any DatabaseWriter)?
    private var databaseFileURL: URL?
    private var started = false
    private var startupTask: Task<Void, Error>?
    private var unrequestedLoadedRootPaths: [LibraryRootPath] = []
    private var rootsByPath: [LibraryRootPath: LibraryRoot] = [:]
    private var rootRowIDsByPath: [LibraryRootPath: Int64] = [:]
    private var rootPathsByRowID: [Int64: LibraryRootPath] = [:]
    private var availabilityByRootPath: [LibraryRootPath: LibraryAvailability] = [:]
    private var activityByRootPath: [LibraryRootPath: CatalogLibraryActivity] = [:]
    private var isEjectableByRootPath: [LibraryRootPath: Bool] = [:]
    private var changeContinuations: [UUID: AsyncStream<CatalogStoreChange>.Continuation] = [:]
    private var pendingScanPaths: [LibraryRootPath] = []
    private var activeScan: ActiveScan?
    private var activeDeviceScans: [LibraryRootPath: ActiveScan] = [:]
    private var nextActiveScanLeaseGeneration: UInt64 = 0
    private var currentScanTask: Task<Void, Never>?
    private var filesystemWatchingStarted = false
    private var filesystemWatchingArmed: Set<LibraryRootPath> = []
    private var rescanAfterCurrentScan: Set<LibraryRootPath> = []
    private var filesystemDebounceTasks: [LibraryRootPath: Task<Void, Never>] = [:]
    private var filesystemEventBatches: [LibraryRootPath: [FilesystemEvent]] = [:]

    private static let enrichmentClaimLease: TimeInterval = 300

    init(
        location: Location = .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos"),
        scanner: CatalogScanner = .live,
        filesystemWatcher: CatalogFilesystemWatcher = .live,
        scanCadence: Duration = .seconds(1),
        filesystemEventDebounce: Duration = .seconds(1),
        filesystemEventSleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        initialLoadDidRead: (@Sendable () async -> Void)? = nil
    ) {
        self.location = location
        self.scanner = scanner
        self.filesystemWatcher = filesystemWatcher
        self.scanCadence = scanCadence
        self.filesystemEventDebounce = filesystemEventDebounce
        self.filesystemEventSleep = filesystemEventSleep
        self.initialLoadDidRead = initialLoadDidRead
    }
}

extension CatalogStore {
    func changeNotifications() -> AsyncStream<CatalogStoreChange> {
        let (stream, continuation) = AsyncStream<CatalogStoreChange>.makeStream(
            // Root-removal signals cannot be dropped: a same-path add may follow
            // before Projection gets another executor turn. Events are tiny and
            // Projection coalesces their expensive work on its existing cadence.
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        changeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            // AsyncStream termination is synchronous, while the continuations
            // dictionary is actor state. This short task is the required actor
            // hop that removes the observer after the stream goes away.
            Task {
                await self?.removeChangeContinuation(id)
            }
        }
        return stream
    }

    func currentLibraries() -> [CatalogLibraryState] {
        rootsByPath.values.map { root in
            CatalogLibraryState(
                root: root,
                availability: availabilityByRootPath[root.path] ?? .unknown,
                activity: activity(for: root.path),
                isEjectable: isEjectableByRootPath[root.path] ?? false
            )
        }
    }

    func orderedAssetIDs(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> [MediaAssetID] {
        let rootIDs = rootIDsForQuery(selection: descriptor.scope, availableLibraryPaths: availableLibraryPaths)
        guard !rootIDs.isEmpty else {
            return []
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreOrderedAssetIDQuery")
        let dbWriter = try database()
        let timedRows = try await timedRead(dbWriter) { db in
            try Self.fetchOrderedAssetIDRows(descriptor: descriptor, rootIDs: rootIDs, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreOrderedAssetIDQuery", signpost)

        let validRootPathsByRowID = rootPathsByRowID.filter { rowID, path in
            rootIDs.contains(rowID) && availableLibraryPaths.contains(path)
        }
        let ids = timedRows.value.compactMap { rootRowID, relativePath -> MediaAssetID? in
            guard let rootPath = validRootPathsByRowID[rootRowID] else {
                return nil
            }
            return MediaAssetID(libraryRootPath: rootPath, relativePath: relativePath)
        }
        let queryMs = timedRows.totalMs
        OtosLog.catalog.debug(
            """
            Catalog ordered asset IDs queried descriptor=\(descriptor.diagnosticDescription, privacy: .public) \
            roots=\(rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) \
            waitMs=\(timedRows.waitMs, privacy: .public) \
            execMs=\(timedRows.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.order phase=finish descriptor=\(descriptor.diagnosticDescription, privacy: .public) rootCount=\(rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) waitMs=\(timedRows.waitMs, privacy: .public) execMs=\(timedRows.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)"
        )
        return ids
    }

    func orderedAssetIDs(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> [MediaAssetID] {
        try await orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: selection),
            availableLibraryPaths: availableLibraryPaths
        )
    }

    func catalogedAssetCount(for selection: SidebarSelection) async throws -> Int {
        let rootIDs = rootIDsForQuery(selection: selection, availableLibraryPaths: Set(rootsByPath.keys))
        guard !rootIDs.isEmpty else {
            return 0
        }
        let dbWriter = try database()
        let timedCount = try await timedRead(dbWriter) { db in
            try Self.countAssets(rootIDs: rootIDs, db: db)
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.catalogedCount phase=finish selection=\(selection.diagnosticDescription, privacy: .public) rootCount=\(rootIDs.count, privacy: .public) count=\(timedCount.value, privacy: .public) waitMs=\(timedCount.waitMs, privacy: .public) execMs=\(timedCount.execMs, privacy: .public) queryMs=\(timedCount.totalMs, privacy: .public)"
        )
        return timedCount.value
    }

    func visibleAssetCount(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> Int {
        let rootIDs = rootIDsForQuery(selection: selection, availableLibraryPaths: availableLibraryPaths)
        guard !rootIDs.isEmpty else {
            return 0
        }
        let dbWriter = try database()
        let timedCount = try await timedRead(dbWriter) { db in
            try Self.countAssets(rootIDs: rootIDs, db: db)
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.visibleCount phase=finish selection=\(selection.diagnosticDescription, privacy: .public) rootCount=\(rootIDs.count, privacy: .public) count=\(timedCount.value, privacy: .public) waitMs=\(timedCount.waitMs, privacy: .public) execMs=\(timedCount.execMs, privacy: .public) queryMs=\(timedCount.totalMs, privacy: .public)"
        )
        return timedCount.value
    }

    func filterOptions(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> CatalogFilterOptions {
        let rootIDs = rootIDsForQuery(selection: selection, availableLibraryPaths: availableLibraryPaths)
        guard !rootIDs.isEmpty else {
            return .empty
        }
        let dbWriter = try database()
        let timedOptions = try await timedRead(dbWriter) { db in
            try Self.filterOptions(rootIDs: rootIDs, db: db)
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.filterOptions phase=finish selection=\(selection.diagnosticDescription, privacy: .public) rootCount=\(rootIDs.count, privacy: .public) kindCount=\(timedOptions.value.availableKinds.count, privacy: .public) formatCount=\(timedOptions.value.formatsByKind.values.reduce(0) { $0 + $1.count }, privacy: .public) waitMs=\(timedOptions.waitMs, privacy: .public) execMs=\(timedOptions.execMs, privacy: .public) queryMs=\(timedOptions.totalMs, privacy: .public)"
        )
        return timedOptions.value
    }

    func mediaAssets(for ids: [MediaAssetID]) async throws -> [MediaAssetID: MediaAsset] {
        guard !ids.isEmpty else {
            return [:]
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreTileDetailQuery")
        let rootIDsBeforeRead = rootRowIDsByPath
        let dbWriter = try database()
        let timedAssets = try await timedRead(dbWriter) { db in
            try Self.fetchStoredAssets(ids: ids, rootIDsByPath: rootIDsBeforeRead, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreTileDetailQuery", signpost)

        var assetsByID: [MediaAssetID: MediaAsset] = [:]
        assetsByID.reserveCapacity(timedAssets.value.count)
        for storedAsset in timedAssets.value {
            guard let rootPath = rootPathsByRowID[storedAsset.libraryRootID],
                  rootRowIDsByPath[rootPath] == storedAsset.libraryRootID
            else {
                continue
            }
            let asset = mediaAsset(from: storedAsset, rootPath: rootPath)
            assetsByID[asset.id] = asset
        }

        let queryMs = timedAssets.totalMs
        if queryMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowTileDetailQuery(
                requestedCount: ids.count,
                returnedCount: assetsByID.count,
                timing: timedAssets
            )
        }
        return assetsByID
    }

    func mediaTileDetails(for ids: [MediaAssetID]) async throws -> [MediaAssetID: MediaTileDetail] {
        guard !ids.isEmpty else {
            return [:]
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreTileDetailQuery")
        let rootIDsBeforeRead = rootRowIDsByPath
        let dbWriter = try database()
        let timedDetails = try await timedRead(dbWriter) { db in
            try Self.fetchStoredTileDetails(ids: ids, rootIDsByPath: rootIDsBeforeRead, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreTileDetailQuery", signpost)

        var detailsByID: [MediaAssetID: MediaTileDetail] = [:]
        detailsByID.reserveCapacity(timedDetails.value.count)
        for storedDetail in timedDetails.value {
            guard let rootPath = rootPathsByRowID[storedDetail.libraryRootID],
                  rootRowIDsByPath[rootPath] == storedDetail.libraryRootID
            else {
                continue
            }
            let detail = mediaTileDetail(from: storedDetail, rootPath: rootPath)
            detailsByID[detail.id] = detail
        }

        let queryMs = timedDetails.totalMs
        if queryMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowTileDetailQuery(
                requestedCount: ids.count,
                returnedCount: detailsByID.count,
                timing: timedDetails
            )
        }
        return detailsByID
    }

    private func recordSlowTileDetailQuery(
        requestedCount: Int,
        returnedCount: Int,
        timing: DatabaseTimedValue<some Any>
    ) async {
        OtosLog.catalog.debug(
            """
            Catalog slow tile details query requested=\(requestedCount, privacy: .public) \
            returned=\(returnedCount, privacy: .public) \
            waitMs=\(timing.waitMs, privacy: .public) \
            execMs=\(timing.execMs, privacy: .public) queryMs=\(timing.totalMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.tileDetail phase=finish requested=\(requestedCount, privacy: .public) returned=\(returnedCount, privacy: .public) waitMs=\(timing.waitMs, privacy: .public) execMs=\(timing.execMs, privacy: .public) queryMs=\(timing.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    /// On-demand metadata read retained for the future tile/inspector metadata surface
    /// owned by ADR 0009. It is test-exercised today but stays out of the hot grid path.
    func metadata(for id: MediaAssetID) async throws -> AssetMetadata? {
        guard let rootID = rootRowIDsByPath[id.libraryRootPath] else {
            return nil
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreMetadataQuery")
        let dbWriter = try database()
        let timedMetadata = try await timedRead(dbWriter) { db in
            try Self.metadataExtra(libraryRootID: rootID, relativePath: id.relativePath, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreMetadataQuery", signpost)

        guard rootRowIDsByPath[id.libraryRootPath] == rootID else {
            return nil
        }
        let queryMs = timedMetadata.totalMs
        OtosLog.catalog.debug(
            """
            Catalog metadata queried returned=\(timedMetadata.value == nil ? 0 : 1, privacy: .public) \
            waitMs=\(timedMetadata.waitMs, privacy: .public) \
            execMs=\(timedMetadata.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)
            """
        )
        OtosLog.metadata.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.metadata phase=finish 0=1 returned=\(timedMetadata.value == nil ? "0" : "1", privacy: .public) waitMs=\(timedMetadata.waitMs, privacy: .public) execMs=\(timedMetadata.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)"
        )
        return timedMetadata.value
    }

    func enrichmentCandidates(
        prioritizing priorityIDs: [MediaAssetID],
        limit: Int
    ) async throws -> [MediaAsset] {
        guard limit > 0 else {
            return []
        }

        let queryStart = Date()
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreEnrichmentCandidateQuery")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStoreEnrichmentCandidateQuery", signpost)
        }

        var candidates: [MediaAsset] = []
        candidates.reserveCapacity(limit)
        var claimedIDs = Set<MediaAssetID>()
        let uniquePriorityIDs = unclaimedPriorityIDs(priorityIDs, claimedIDs: &claimedIDs)
        var waitMs = 0
        var execMs = 0

        if !uniquePriorityIDs.isEmpty {
            let priorityClaims = try await priorityEnrichmentCandidates(
                ids: uniquePriorityIDs,
                limit: limit
            )
            candidates.append(contentsOf: priorityClaims.value)
            waitMs += priorityClaims.waitMs
            execMs += priorityClaims.execMs
            for asset in candidates {
                claimedIDs.insert(asset.id)
            }
        }

        if candidates.count < limit {
            let remaining = limit - candidates.count
            let queriedClaims = try await claimedEnrichmentCandidates(limit: remaining)
            waitMs += queriedClaims.waitMs
            execMs += queriedClaims.execMs
            for asset in queriedClaims.value where candidates.count < limit && !claimedIDs.contains(asset.id) {
                claimedIDs.insert(asset.id)
                candidates.append(asset)
            }
        }

        let queryMs = waitMs + execMs
        let wallMs = DiagnosticsTiming.milliseconds(since: queryStart)
        if queryMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowEnrichmentCandidateQuery(
                priorityCount: priorityIDs.count,
                returnedCount: candidates.count,
                waitMs: waitMs,
                execMs: execMs,
                wallMs: wallMs
            )
        }
        return candidates
    }

    private func recordSlowEnrichmentCandidateQuery(
        priorityCount: Int,
        returnedCount: Int,
        waitMs: Int,
        execMs: Int,
        wallMs: Int
    ) async {
        let queryMs = waitMs + execMs
        OtosLog.catalog.debug(
            """
            Catalog slow enrichment candidates query priority=\(priorityCount, privacy: .public) \
            returned=\(returnedCount, privacy: .public) \
            waitMs=\(waitMs, privacy: .public) execMs=\(execMs, privacy: .public) \
            queryMs=\(queryMs, privacy: .public) wallMs=\(wallMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.enrichment phase=finish priority=\(priorityCount, privacy: .public) returned=\(returnedCount, privacy: .public) waitMs=\(waitMs, privacy: .public) execMs=\(execMs, privacy: .public) queryMs=\(queryMs, privacy: .public) wallMs=\(wallMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    func releaseEnrichmentClaims(_ ids: [MediaAssetID]) async throws {
        guard !ids.isEmpty else {
            return
        }
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
        let dbWriter = try database()
        try await dbWriter.write { db in
            try Self.releaseEnrichmentClaims(ids: ids, rootIDsByPath: rootIDsByPathBeforeWrite, db: db)
        }
    }

    @discardableResult
    func refreshEnrichmentClaims(_ ids: [MediaAssetID]) async throws -> Date? {
        guard !ids.isEmpty else {
            return nil
        }
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
        let claimedUntil = Date().timeIntervalSince1970 + Self.enrichmentClaimLease
        let dbWriter = try database()
        try await dbWriter.write { db in
            try Self.refreshEnrichmentClaims(
                ids: ids,
                rootIDsByPath: rootIDsByPathBeforeWrite,
                claimedUntil: claimedUntil,
                db: db
            )
        }
        return Date(timeIntervalSince1970: claimedUntil)
    }

    private func unclaimedPriorityIDs(
        _ priorityIDs: [MediaAssetID],
        claimedIDs: inout Set<MediaAssetID>
    ) -> [MediaAssetID] {
        priorityIDs.reduce(into: [MediaAssetID]()) { result, id in
            guard !claimedIDs.contains(id) else {
                return
            }
            claimedIDs.insert(id)
            result.append(id)
        }
    }

    private func priorityEnrichmentCandidates(
        ids: [MediaAssetID],
        limit: Int
    ) async throws -> DatabaseTimedValue<[MediaAsset]> {
        let priorityAssetsByID = try await mediaAssets(for: ids)
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
        let claimedUntil = Date().timeIntervalSince1970 + Self.enrichmentClaimLease
        let dbWriter = try database()
        let eligibleClaims = priorityEnrichmentClaimInputs(
            ids: ids,
            assetsByID: priorityAssetsByID,
            rootIDsByPath: rootIDsByPathBeforeWrite
        )
        guard !eligibleClaims.isEmpty else {
            return DatabaseTimedValue(value: [], waitMs: 0, execMs: 0)
        }
        let timedClaim = try await timedWrite(dbWriter) { db in
            var candidates: [MediaAsset] = []
            candidates.reserveCapacity(min(limit, eligibleClaims.count))
            for (asset, rootID) in eligibleClaims {
                guard candidates.count < limit else {
                    break
                }
                guard try Self.claimEnrichmentAsset(
                    libraryRootID: rootID,
                    relativePath: asset.relativePath,
                    claimedUntil: claimedUntil,
                    db: db
                ) else {
                    continue
                }
                candidates.append(asset)
            }
            return candidates
        }
        let result = timedClaim
        if result.totalMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowPriorityEnrichmentClaim(
                priorityCount: ids.count,
                eligibleCount: eligibleClaims.count,
                result: result
            )
        }
        return result
    }

    private func priorityEnrichmentClaimInputs(
        ids: [MediaAssetID],
        assetsByID: [MediaAssetID: MediaAsset],
        rootIDsByPath: [LibraryRootPath: Int64]
    ) -> [(asset: MediaAsset, rootID: Int64)] {
        var eligibleClaims: [(asset: MediaAsset, rootID: Int64)] = []
        eligibleClaims.reserveCapacity(ids.count)
        for id in ids {
            guard let asset = assetsByID[id],
                  asset.needsEnrichment,
                  availabilityByRootPath[asset.libraryRootPath] == .available,
                  let rootID = rootIDsByPath[asset.libraryRootPath]
            else {
                continue
            }
            eligibleClaims.append((asset, rootID))
        }
        return eligibleClaims
    }

    private func recordSlowPriorityEnrichmentClaim(
        priorityCount: Int,
        eligibleCount: Int,
        result: DatabaseTimedValue<[MediaAsset]>
    ) async {
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.enrichment.priorityClaim phase=finish priority=\(priorityCount, privacy: .public) eligible=\(eligibleCount, privacy: .public) returned=\(result.value.count, privacy: .public) waitMs=\(result.waitMs, privacy: .public) execMs=\(result.execMs, privacy: .public) queryMs=\(result.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    private func claimedEnrichmentCandidates(limit: Int) async throws -> DatabaseTimedValue<[MediaAsset]> {
        let claimedUntil = Date().timeIntervalSince1970 + Self.enrichmentClaimLease
        let prioritizedRootIDs = availableRootIDsByRemovablePriority()
        let dbWriter = try database()
        let timedStoredAssets = try await timedWrite(dbWriter) { db in
            var storedAssets: [StoredAsset] = []
            if !prioritizedRootIDs.removable.isEmpty {
                storedAssets = try Self.fetchStoredAssetsNeedingEnrichment(
                    rootIDs: prioritizedRootIDs.removable,
                    claimNotAfter: claimedUntil,
                    limit: limit,
                    db: db
                )
            }
            if storedAssets.count < limit, !prioritizedRootIDs.fixed.isEmpty {
                let fixedAssets = try Self.fetchStoredAssetsNeedingEnrichment(
                    rootIDs: prioritizedRootIDs.fixed,
                    claimNotAfter: claimedUntil,
                    limit: limit - storedAssets.count,
                    db: db
                )
                storedAssets.append(contentsOf: fixedAssets)
            }
            return storedAssets
        }
        let candidates: [MediaAsset] = timedStoredAssets.value.compactMap { storedAsset -> MediaAsset? in
            guard let rootPath = rootPathsByRowID[storedAsset.libraryRootID],
                  rootRowIDsByPath[rootPath] == storedAsset.libraryRootID,
                  availabilityByRootPath[rootPath] == .available
            else {
                return nil
            }
            return mediaAsset(from: storedAsset, rootPath: rootPath)
        }
        let result = DatabaseTimedValue(
            value: candidates,
            waitMs: timedStoredAssets.waitMs,
            execMs: timedStoredAssets.execMs
        )
        if result.totalMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowFallbackEnrichmentClaim(
                limit: limit,
                removableRootCount: prioritizedRootIDs.removable.count,
                fixedRootCount: prioritizedRootIDs.fixed.count,
                result: result
            )
        }
        return result
    }

    private func recordSlowFallbackEnrichmentClaim(
        limit: Int,
        removableRootCount: Int,
        fixedRootCount: Int,
        result: DatabaseTimedValue<[MediaAsset]>
    ) async {
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.enrichment.claim phase=finish limit=\(limit, privacy: .public) availableRootCount=\(removableRootCount + fixedRootCount, privacy: .public) removableRootCount=\(removableRootCount, privacy: .public) returned=\(result.value.count, privacy: .public) waitMs=\(result.waitMs, privacy: .public) execMs=\(result.execMs, privacy: .public) queryMs=\(result.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    func start(scansSavedLibraries: Bool = true) async throws {
        try await loadIfNeeded()
        if scansSavedLibraries {
            requestLoadedRootScansIfNeeded()
        }
        startFilesystemWatchingIfNeeded()
    }

    /// Every entry point that needs catalog truth awaits the same finite load.
    /// The task is installed before its first suspension, which closes the actor
    /// reentrancy window where two callers could read and later apply competing
    /// database loads.
    private func loadIfNeeded() async throws {
        if started {
            return
        }
        if let startupTask {
            OtosLog.persistence.debug("Catalog startup joined existing load")
            OtosLog.catalog.noticeOperation("catalog.start", phase: "coalesced")
            try await startupTask.value
            return
        }

        let task = Task {
            try await self.performInitialLoad()
        }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func performInitialLoad() async throws {
        let state = OtosSignpost.persistence.beginInterval("CatalogStart")
        OtosLog.catalog.noticeOperation("catalog.start", phase: "start")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStart", state)
        }

        let dbQueue = try database()
        let loaded = try await dbQueue.read { db in
            try Self.fetchCatalog(db)
        }
        try await clearAbandonedEnrichmentClaims(dbQueue)
        // Tests pause precisely at this real suspension boundary to prove that
        // concurrent mutation callers join this load. Production leaves the
        // hook nil and performs no additional work.
        await initialLoadDidRead?()
        let normalizedRoots = await normalizeLoadedRoots(loaded.roots, dbWriter: dbQueue)
        let applyState = OtosSignpost.catalog.beginInterval("CatalogApplyLoadedCatalog")
        applyLoadedCatalog(roots: normalizedRoots)
        unrequestedLoadedRootPaths = normalizedRoots
            .filter { $0.kind == .library }
            .map(\.path)
        OtosSignpost.catalog.endInterval("CatalogApplyLoadedCatalog", applyState)
        started = true
        OtosLog.persistence.info(
            """
            Catalog loaded roots=\(normalizedRoots.count, privacy: .public) \
            assets=\(loaded.assetCount, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.start phase=finish roots=\(normalizedRoots.count, privacy: .public) assets=\(loaded.assetCount, privacy: .public)"
        )
        notifyCatalogChanged()
    }

    private func clearAbandonedEnrichmentClaims(_ dbQueue: any DatabaseWriter) async throws {
        let clearedCount = try await dbQueue.write { db in
            try Self.clearEnrichmentClaims(db: db)
        }
        guard clearedCount > 0 else {
            return
        }
        OtosLog.metadata.info(
            "Cleared abandoned enrichment claims count=\(clearedCount, privacy: .public)"
        )
        OtosLog.metadata.notice(
            "op=catalog.enrichment.claims phase=startupClear count=\(clearedCount, privacy: .public)"
        )
    }

    /// Applies a batch of completed enrichments in one transaction and one notification.
    /// Batching mirrors `recordScannedBatch`: a per-asset transaction across a whole
    /// library would crawl, and a notification per asset would re-sort the catalog in
    /// Projection per completion. Enrichment writes only enrichment columns/fields,
    /// disjoint from facts; a row that was proven-deleted or whose source facts changed
    /// between extraction and this write is skipped, so a removed or edited asset is never
    /// stamped current by stale work. Generated thumbnails are staged by the enricher and
    /// promoted here only for accepted rows, keeping derived files subordinate to Store's
    /// current SQLite truth.
    /// Applies a batch and reports the outcome so the coordinator can react correctly.
    /// `.applied(count:)` with `count < results.count` means some results were *validated*
    /// drops — proven-deleted, or stale because a scan observed newer bytes — which the
    /// coordinator should re-wake to retry. `.writeFailed` means the SQLite write or
    /// thumbnail promotion failed (disk full, corruption, permissions, missing staged file);
    /// the coordinator must *not* re-wake into a tight read/generate/fail loop and instead
    /// lets the recorded error back it off.
    @discardableResult
    func applyEnrichmentBatch(_ results: [EnrichmentResult]) async -> EnrichmentApplyOutcome {
        guard !results.isEmpty else {
            return .applied(count: 0)
        }
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
        guard results.contains(where: { rootIDsByPathBeforeWrite[$0.id.libraryRootPath] != nil }) else {
            discardGeneratedThumbnails(results.compactMap(\.generatedThumbnail))
            return .applied(count: 0)
        }
        let resultIDs = results.map(\.id)

        let state = OtosSignpost.persistence.beginInterval("CatalogEnrichmentBatchWrite")
        let writeOutcome: EnrichmentBatchWriteOutcome
        let thumbnailDirectory = thumbnailDirectory
        do {
            let dbQueue = try database()
            writeOutcome = try await writeEnrichmentBatch(
                results,
                rootIDsByPath: rootIDsByPathBeforeWrite,
                thumbnailDirectory: thumbnailDirectory,
                dbWriter: dbQueue
            )
        } catch {
            OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)
            discardGeneratedThumbnails(results.compactMap(\.generatedThumbnail))
            await recordEnrichmentBatchError(error, count: results.count)
            await releaseEnrichmentClaimsAfterBatch(resultIDs)
            return .writeFailed
        }
        OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)
        discardGeneratedThumbnails(writeOutcome.discardedThumbnails)

        await recordEnrichmentBatchWrite(resultsCount: results.count, writeOutcome: writeOutcome)
        await recordWALDiagnostics(reason: "enrichmentBatch")
        if writeOutcome.appliedCount > 0 {
            notifyCatalogChanged(.assetsDetailChanged)
        }
        await releaseEnrichmentClaimsAfterBatch(resultIDs)
        if writeOutcome.promotionFailed {
            return .writeFailed
        }
        return .applied(count: writeOutcome.appliedCount)
    }

    private func recordEnrichmentBatchWrite(
        resultsCount: Int,
        writeOutcome: EnrichmentBatchWriteOutcome
    ) async {
        OtosLog.metadata.notice(
            // swiftlint:disable:next line_length
            "op=catalog.enrichment.batch phase=finish attempted=\(resultsCount, privacy: .public) count=\(writeOutcome.appliedCount, privacy: .public) discardedThumbnails=\(writeOutcome.discardedThumbnails.count, privacy: .public) promotionFailed=\(writeOutcome.promotionFailed, privacy: .public) waitMs=\(writeOutcome.waitMs, privacy: .public) execMs=\(writeOutcome.execMs, privacy: .public) writeMs=\(writeOutcome.waitMs + writeOutcome.execMs, privacy: .public)"
        )
    }

    private func releaseEnrichmentClaimsAfterBatch(_ resultIDs: [MediaAssetID]) async {
        do {
            try await releaseEnrichmentClaims(resultIDs)
        } catch {
            OtosLog.metadata.error(
                """
                Enrichment claim release failed count=\(resultIDs.count, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func writeEnrichmentBatch(
        _ results: [EnrichmentResult],
        rootIDsByPath: [LibraryRootPath: Int64],
        thumbnailDirectory: URL?,
        dbWriter: any DatabaseWriter
    ) async throws -> EnrichmentBatchWriteOutcome {
        let timedOutcome = try await timedWrite(dbWriter) { db in
            var outcome = EnrichmentBatchWriteOutcome()
            for result in results {
                try Self.applyEnrichmentResult(
                    result,
                    rootIDsByPath: rootIDsByPath,
                    thumbnailDirectory: thumbnailDirectory,
                    outcome: &outcome,
                    db: db
                )
            }
            return outcome
        }
        var outcome = timedOutcome.value
        outcome.waitMs = timedOutcome.waitMs
        outcome.execMs = timedOutcome.execMs
        return outcome
    }

    private static func applyEnrichmentResult(
        _ result: EnrichmentResult,
        rootIDsByPath: [LibraryRootPath: Int64],
        thumbnailDirectory: URL?,
        outcome: inout EnrichmentBatchWriteOutcome,
        db: Database
    ) throws {
        guard let rootID = rootIDsByPath[result.id.libraryRootPath] else {
            outcome.discard(result.generatedThumbnail)
            return
        }
        guard result.generatedThumbnail == nil || thumbnailDirectory != nil else {
            outcome.failPromotion(result.generatedThumbnail)
            return
        }
        guard try enrichmentResultMatchesCurrentRow(result, libraryRootID: rootID, db: db) else {
            outcome.discard(result.generatedThumbnail)
            return
        }
        if let generatedThumbnail = result.generatedThumbnail, let thumbnailDirectory {
            do {
                try ThumbnailStore.promote(generatedThumbnail, in: thumbnailDirectory)
            } catch {
                outcome.failPromotion(generatedThumbnail)
                return
            }
        }
        try writeEnrichmentOverlay(result, libraryRootID: rootID, db: db)
        outcome.appliedCount += 1
    }

    private func discardGeneratedThumbnails(_ thumbnails: [GeneratedThumbnail]) {
        guard let thumbnailDirectory else {
            return
        }
        for thumbnail in thumbnails {
            ThumbnailStore.discard(thumbnail, in: thumbnailDirectory)
        }
    }

    private func recordEnrichmentBatchError(_ error: Error, count: Int) async {
        OtosLog.metadata.error(
            """
            Enrichment batch persist failed count=\(count, privacy: .public) \
            error=\(String(describing: error), privacy: .public)
            """
        )
        OtosLog.metadata.error(
            "op=catalog.enrichment.batch phase=error count=\(count, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    func addLibrary(url: URL) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: url)
        try await ensureStartedForMutation()
        try validateNoOverlap(path)
        try await insertLibraryRootAndStartScan(path, operation: "catalog.library.add")
    }

    func ensureLibrary(url: URL) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: url)
        try await ensureStartedForMutation()
        OtosLog.catalog.notice(
            "op=catalog.library.ensure phase=start rootPath=\(path.rawValue, privacy: .public)"
        )
        if rootsByPath[path] != nil {
            OtosLog.catalog.info("Smoke library root already saved path=\(path.rawValue, privacy: .public)")
            OtosLog.catalog.notice(
                "op=catalog.library.ensure phase=exists rootPath=\(path.rawValue, privacy: .public)"
            )
            return
        }
        try validateNoOverlap(path)
        try await insertLibraryRootAndStartScan(
            path,
            operation: "catalog.library.ensure",
            recordsStart: false
        )
    }

    func removeLibrary(path: LibraryRootPath) async throws {
        try await ensureStartedForMutation()
        guard let root = rootsByPath[path],
              let rootRowID = rootRowIDsByPath[path]
        else {
            return
        }

        cancelRuntimeWork(for: path)
        filesystemWatcher.removeRoot(path)
        filesystemWatchingArmed.remove(path)

        let dbQueue = try database()
        guard let purgedThumbnails = try await thumbnailPathsForLibraryRemoval(
            path: path,
            root: root,
            rootRowID: rootRowID,
            dbWriter: dbQueue
        ) else {
            return
        }

        let state = OtosSignpost.persistence.beginInterval("CatalogRemoveRoot")
        OtosLog.catalog.notice(
            "op=catalog.library.remove phase=start rootPath=\(path.rawValue, privacy: .public)"
        )
        try await dbQueue.write { db in
            try Self.deleteLibraryRoot(rootRowID: rootRowID, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogRemoveRoot", state)

        removeRootRuntimeState(path: path, rootRowID: rootRowID)
        if let thumbnailDirectory {
            for name in purgedThumbnails {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        deleteDeviceStagingIfNeeded(root)
        OtosLog.catalog.info("Library root removed path=\(root.path.rawValue, privacy: .public)")
        OtosLog.catalog.notice(
            "op=catalog.library.remove phase=finish rootPath=\(path.rawValue, privacy: .public)"
        )
        notifyCatalogChanged(.libraryRemoved(path))
        startNextScanIfNeeded()
    }

    private func thumbnailPathsForLibraryRemoval(
        path: LibraryRootPath,
        root: LibraryRoot,
        rootRowID: Int64,
        dbWriter: any DatabaseWriter
    ) async throws -> [String]? {
        do {
            let deletionFacts = try await dbWriter.read { db in
                try Self.fetchExistingAssetRows(libraryRootID: rootRowID, db: db)
            }
            guard rootsByPath[path] == root,
                  rootRowIDsByPath[path] == rootRowID
            else {
                return nil
            }
            return deletionFacts.compactMap(\.thumbnailPath)
        } catch {
            OtosLog.persistence.error(
                "Catalog remove root thumbnail lookup failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func removeRootRuntimeState(path: LibraryRootPath, rootRowID: Int64) {
        rootsByPath.removeValue(forKey: path)
        availabilityByRootPath.removeValue(forKey: path)
        activityByRootPath.removeValue(forKey: path)
        isEjectableByRootPath.removeValue(forKey: path)
        activeDeviceScans.removeValue(forKey: path)
        rootRowIDsByPath.removeValue(forKey: path)
        rootPathsByRowID.removeValue(forKey: rootRowID)
    }

    private func rootForDeviceIdentity(_ identity: String) -> LibraryRoot? {
        rootsByPath.values.first { $0.deviceIdentity == identity }
    }

    private func isTransientDeviceIdentity(_ identity: String) -> Bool {
        identity.hasPrefix("volume:path:")
            || identity.contains("#path:")
            || identity.hasPrefix("camera:transient:")
    }

    private func cancelRuntimeWork(for path: LibraryRootPath) {
        unrequestedLoadedRootPaths.removeAll { $0 == path }
        cancelFilesystemDebounce(for: path)
        rescanAfterCurrentScan.remove(path)
        pendingScanPaths.removeAll { $0 == path }
        activeDeviceScans.removeValue(forKey: path)
        if activeScan?.rootPath == path {
            currentScanTask?.cancel()
            currentScanTask = nil
            activeScan = nil
        }
    }

    private func releaseEnrichmentClaimsForRoot(_ rootRowID: Int64) async {
        guard let dbWriter else {
            return
        }
        do {
            try await dbWriter.write { db in
                try Self.releaseEnrichmentClaims(rootID: rootRowID, db: db)
            }
        } catch {
            OtosLog.metadata.error(
                "Root enrichment claim release failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func deleteDeviceStagingIfNeeded(_ root: LibraryRoot) {
        guard root.kind == .deviceMTP else {
            return
        }
        try? FileManager.default.removeItem(at: root.path.url)
    }

    private func attachRemovableRoot(_ attachment: RemovableRootAttachment) async throws {
        let lastSeenAt = Date()
        let dbQueue = try database()
        if let existingRoot = rootForDeviceIdentity(attachment.identity),
           let rootRowID = rootRowIDsByPath[existingRoot.path]
        { // swiftlint:disable:this opening_brace
            try await updateExistingRemovableRoot(
                attachment,
                existingRoot: existingRoot,
                rootRowID: rootRowID,
                lastSeenAt: lastSeenAt,
                dbWriter: dbQueue
            )
        } else {
            try await insertRemovableRoot(attachment, lastSeenAt: lastSeenAt, dbWriter: dbQueue)
        }
        await finishRemovableRootAttachment(attachment)
    }

    private func updateExistingRemovableRoot(
        _ attachment: RemovableRootAttachment,
        existingRoot: LibraryRoot,
        rootRowID: Int64,
        lastSeenAt: Date,
        dbWriter: any DatabaseWriter
    ) async throws {
        try validateNoOverlap(attachment.path, ignoring: rootRowID)
        var thumbnailMigrations: [ThumbnailPathMigration] = []
        if existingRoot.path != attachment.path {
            thumbnailMigrations = try await dbWriter.write { db in
                try Self.updateLibraryRootPath(rootRowID: rootRowID, path: attachment.path, db: db)
            }
        }
        try await dbWriter.write { db in
            try Self.updateLibraryRootSourceFacts(
                rootRowID: rootRowID,
                path: attachment.path,
                displayName: attachment.displayName,
                lastSeenAt: lastSeenAt,
                db: db
            )
        }
        migrateNormalizedRootThumbnails(thumbnailMigrations)
        moveRootRuntimeState(
            oldPath: existingRoot.path,
            newRoot: attachment.root(lastSeenAt: lastSeenAt),
            rootRowID: rootRowID
        )
    }

    private func insertRemovableRoot(
        _ attachment: RemovableRootAttachment,
        lastSeenAt: Date,
        dbWriter: any DatabaseWriter
    ) async throws {
        try validateNoOverlap(attachment.path)
        let storedRoot = try await dbWriter.write { db in
            try Self.insertLibraryRoot(
                path: attachment.path,
                kind: attachment.kind,
                deviceIdentity: attachment.identity,
                displayName: attachment.displayName,
                lastSeenAt: lastSeenAt,
                db: db
            )
        }
        let root = libraryRoot(from: storedRoot)
        rootsByPath[root.path] = root
        rootRowIDsByPath[root.path] = storedRoot.id
        rootPathsByRowID[storedRoot.id] = root.path
    }

    private func finishRemovableRootAttachment(_ attachment: RemovableRootAttachment) async {
        availabilityByRootPath[attachment.path] = .available
        activityByRootPath[attachment.path] = attachment.activity
        isEjectableByRootPath[attachment.path] = attachment.isEjectable
        if attachment.kind == .removableVolume {
            filesystemWatcher.addRoot(attachment.path)
        }
        OtosLog.catalog.info(
            """
            Removable source attached kind=\(attachment.kind.rawValue, privacy: .public) \
            identity=\(attachment.identity, privacy: .public) path=\(attachment.path.rawValue, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.removable.attach phase=finish kind=\(attachment.kind.rawValue, privacy: .public) identity=\(attachment.identity, privacy: .public) rootPath=\(attachment.path.rawValue, privacy: .public) displayName=\(attachment.displayName, privacy: .public)"
        )
        notifyCatalogChanged()
        if attachment.enqueuesScan {
            enqueueScans([attachment.path], priority: .front)
        }
    }

    private func moveRootRuntimeState(oldPath: LibraryRootPath, newRoot: LibraryRoot, rootRowID: Int64) {
        let previousAvailability = availabilityByRootPath.removeValue(forKey: oldPath)
        let previousActivity = activityByRootPath.removeValue(forKey: oldPath)
        let previousEjectable = isEjectableByRootPath.removeValue(forKey: oldPath)
        rootsByPath.removeValue(forKey: oldPath)
        rootRowIDsByPath.removeValue(forKey: oldPath)
        filesystemWatchingArmed.remove(oldPath)
        rescanAfterCurrentScan.remove(oldPath)
        filesystemEventBatches.removeValue(forKey: oldPath)
        rootsByPath[newRoot.path] = newRoot
        rootRowIDsByPath[newRoot.path] = rootRowID
        rootPathsByRowID[rootRowID] = newRoot.path
        availabilityByRootPath[newRoot.path] = previousAvailability
        activityByRootPath[newRoot.path] = previousActivity
        isEjectableByRootPath[newRoot.path] = previousEjectable
    }

    private func insertLibraryRootAndStartScan(
        _ path: LibraryRootPath,
        operation: String,
        recordsStart: Bool = true
    ) async throws {
        let dbQueue = try database()

        let state = OtosSignpost.persistence.beginInterval("CatalogAddRoot")
        defer {
            OtosSignpost.persistence.endInterval("CatalogAddRoot", state)
        }
        if recordsStart {
            OtosLog.catalog.notice(
                "op=\(operation, privacy: .public) phase=start rootPath=\(path.rawValue, privacy: .public)"
            )
        }
        let storedRoot = try await dbQueue.write { db in
            try Self.insertLibraryRoot(path: path, db: db)
        }

        let root = libraryRoot(from: storedRoot)
        rootsByPath[root.path] = root
        availabilityByRootPath[root.path] = .available
        rootRowIDsByPath[root.path] = storedRoot.id
        rootPathsByRowID[storedRoot.id] = root.path
        OtosLog.catalog.info("Library root added path=\(root.path.rawValue, privacy: .public)")
        OtosLog.catalog.notice(
            "op=\(operation, privacy: .public) phase=finish rootPath=\(root.path.rawValue, privacy: .public)"
        )
        notifyCatalogChanged()
        filesystemWatcher.addRoot(root.path)
        enqueueScans([root.path])
    }

    func attachRemovableVolume(
        mountURL: URL,
        identity: String,
        displayName: String,
        isEjectable: Bool
    ) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: mountURL)
        try await ensureStartedForMutation()
        try await attachRemovableRoot(RemovableRootAttachment(
            kind: .removableVolume,
            path: path,
            identity: identity,
            displayName: displayName,
            isEjectable: isEjectable,
            activity: .idle,
            enqueuesScan: true
        ))
    }

    @discardableResult
    func attachDeviceMTP(
        stagingRootURL: URL,
        identity: String,
        displayName: String
    ) async throws -> LibraryRootPath {
        let path = try CatalogPath.normalizedDirectoryPath(for: stagingRootURL)
        try FileManager.default.createDirectory(at: path.url, withIntermediateDirectories: true)
        try await ensureStartedForMutation()
        try await attachRemovableRoot(RemovableRootAttachment(
            kind: .deviceMTP,
            path: path,
            identity: identity,
            displayName: displayName,
            isEjectable: false,
            activity: .enumerating,
            enqueuesScan: false
        ))
        return path
    }

    func detachRemovableSource(identity: String, reason: RemovableSourceDetachReason) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind != .library,
              let rootRowID = rootRowIDsByPath[root.path]
        else {
            return
        }
        if isTransientDeviceIdentity(identity) {
            try await removeLibrary(path: root.path)
            return
        }

        cancelRuntimeWork(for: root.path)
        filesystemWatcher.removeRoot(root.path)
        filesystemWatchingArmed.remove(root.path)
        isEjectableByRootPath[root.path] = false
        activityByRootPath[root.path] = .idle
        await releaseEnrichmentClaimsForRoot(rootRowID)
        setAvailability(.unavailable, for: root.path)
        if root.kind == .deviceMTP {
            deleteDeviceStagingIfNeeded(root)
        }
        OtosLog.catalog.info(
            """
            Removable source detached identity=\(identity, privacy: .public) \
            reason=\(reason.rawValue, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.removable.detach phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        notifyCatalogChanged()
        startNextScanIfNeeded()
    }

    func quiesceRemovableSource(identity: String) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind != .library,
              let rootRowID = rootRowIDsByPath[root.path]
        else {
            return
        }
        cancelRuntimeWork(for: root.path)
        activityByRootPath[root.path] = .idle
        await releaseEnrichmentClaimsForRoot(rootRowID)
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.removable.quiesce phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public)"
        )
    }

    func resumeRemovableSource(identity: String) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind != .library
        else {
            return
        }
        let changed = setAvailability(.available, for: root.path)
        if changed {
            notifyCatalogChanged()
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.removable.resume phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public)"
        )
    }

    func beginDeviceCatalogEnumeration(rootPath: LibraryRootPath) async throws -> ActiveScan {
        guard rootsByPath[rootPath]?.kind == .deviceMTP,
              availabilityByRootPath[rootPath] == .available,
              let rootRowID = rootRowIDsByPath[rootPath]
        else {
            throw CancellationError()
        }
        let scan = makeActiveScan(rootPath: rootPath, rootRowID: rootRowID)
        activeDeviceScans[rootPath] = scan
        activityByRootPath[rootPath] = .enumerating
        notifyCatalogChanged()
        return scan
    }

    func recordDeviceCatalogBatch(_ batch: [ScannedMediaFile], scan: ActiveScan) async throws {
        try await ensureStartedForMutation()
        guard owns(scan),
              rootsByPath[scan.rootPath]?.kind == .deviceMTP,
              availabilityByRootPath[scan.rootPath] == .available
        else {
            throw CancellationError()
        }
        let dbQueue = try database()
        let timedChangedCount = try await timedWrite(dbQueue) { db in
            var count = 0
            for file in batch {
                let changed = try Self.upsertScannedFile(
                    file,
                    libraryRootPath: scan.rootPath,
                    libraryRootID: scan.rootRowID,
                    db: db
                )
                if changed {
                    count += 1
                }
            }
            return count
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        if timedChangedCount.value > 0 {
            notifyCatalogChanged()
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.device.scan.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(batch.count, privacy: .public) changedCount=\(timedChangedCount.value, privacy: .public) waitMs=\(timedChangedCount.waitMs, privacy: .public) execMs=\(timedChangedCount.execMs, privacy: .public)"
        )
    }

    func completeDeviceCatalogEnumeration(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>
    ) async throws {
        guard owns(scan),
              rootsByPath[scan.rootPath]?.kind == .deviceMTP,
              availabilityByRootPath[scan.rootPath] == .available
        else {
            throw CancellationError()
        }
        do {
            _ = try await reconcileMissingAssets(
                scan: scan,
                observedPaths: observedPaths
            )
        } catch {
            OtosLog.catalog.error(
                "Device catalog reconciliation failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
        await endDeviceCatalogEnumeration(scan: scan)
    }

    func endDeviceCatalogEnumeration(scan: ActiveScan) async {
        guard activeDeviceScans[scan.rootPath] == scan else {
            return
        }
        activeDeviceScans.removeValue(forKey: scan.rootPath)
        if rootsByPath[scan.rootPath]?.kind == .deviceMTP {
            activityByRootPath[scan.rootPath] = .idle
            notifyCatalogChanged()
        }
    }

    func applyProvisionalThumbnails(_ thumbnailsByID: [MediaAssetID: String]) async throws {
        guard !thumbnailsByID.isEmpty else {
            return
        }
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
        let dbQueue = try database()
        let changed = try await timedWrite(dbQueue) { db in
            var count = 0
            for (id, thumbnailPath) in thumbnailsByID {
                guard let rootID = rootIDsByPathBeforeWrite[id.libraryRootPath] else {
                    continue
                }
                try Self.updateThumbnailPath(
                    thumbnailPath,
                    libraryRootID: rootID,
                    relativePath: id.relativePath,
                    onlyWhenMissing: true,
                    db: db
                )
                count += db.changesCount
            }
            return count
        }
        if changed.value > 0 {
            notifyCatalogChanged(.assetsDetailChanged)
        }
    }

    func shutdown() {
        currentScanTask?.cancel()
        currentScanTask = nil
        activeScan = nil
        activeDeviceScans.removeAll()
        pendingScanPaths.removeAll()
        cancelAllFilesystemDebounces()
        filesystemWatcher.stop()
        filesystemWatchingStarted = false
        filesystemWatchingArmed.removeAll()
        rescanAfterCurrentScan.removeAll()
        notifyCatalogChanged()
    }
}

extension CatalogStore {
    /// Where thumbnail files live, derived from the catalog location: beside the
    /// catalog in Application Support, or beside an explicit database file. In-memory
    /// catalogs have no thumbnail directory (nothing to purge).
    ///
    /// `nonisolated` because it reads only the immutable `location`: the ViewModel needs
    /// it synchronously to build the enricher, and tiles need it to resolve thumbnails.
    /// It lives in an internal (not `private`) extension so those owners can read it.
    nonisolated var thumbnailDirectory: URL? {
        switch location {
        case let .application(bundleIdentifier):
            try? Self.applicationThumbnailDirectory(bundleIdentifier: bundleIdentifier)
        case let .databaseFile(url):
            url.deletingLastPathComponent().appending(path: "Thumbnails", directoryHint: .isDirectory)
        case .inMemory:
            nil
        }
    }
}

private extension CatalogStore {
    private func timedRead<Value: Sendable>(
        _ dbWriter: any DatabaseWriter,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let start = Date()
        return try await dbWriter.read { db in
            let entered = Date()
            let value = try body(db)
            return DatabaseTimedValue(
                value: value,
                waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                execMs: DiagnosticsTiming.milliseconds(since: entered)
            )
        }
    }

    private func timedWrite<Value: Sendable>(
        _ dbWriter: any DatabaseWriter,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let start = Date()
        return try await dbWriter.write { db in
            let entered = Date()
            let value = try body(db)
            return DatabaseTimedValue(
                value: value,
                waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                execMs: DiagnosticsTiming.milliseconds(since: entered)
            )
        }
    }

    private func ensureStartedForMutation() async throws {
        try await loadIfNeeded()
    }

    private func database() throws -> any DatabaseWriter {
        if let dbWriter {
            return dbWriter
        }

        let state = OtosSignpost.persistence.beginInterval("CatalogOpenDatabase")
        defer {
            OtosSignpost.persistence.endInterval("CatalogOpenDatabase", state)
        }

        let openResult = try openDatabaseWriter()
        let dbWriter = openResult.dbWriter
        let needsCleanReset = try dbWriter.read { db in
            try Self.databaseNeedsCleanSchemaReset(db)
        }
        if needsCleanReset {
            try dbWriter.erase()
        }
        try Self.migrator.migrate(dbWriter)
        performThumbnailStoreStartupMaintenance(needsCleanReset: needsCleanReset)
        self.dbWriter = dbWriter
        databaseFileURL = openResult.openedFileURL
        recordDatabaseOpenDiagnostics(dbWriter: dbWriter, storageKind: openResult.storageKind)
        OtosLog.persistence.info(
            "Catalog database opened storage=\(openResult.storageKind, privacy: .public)"
        )
        return dbWriter
    }

    private struct DatabaseOpenResult {
        let dbWriter: any DatabaseWriter
        let storageKind: String
        let openedFileURL: URL?
    }

    private func openDatabaseWriter() throws -> DatabaseOpenResult {
        switch location {
        case let .application(bundleIdentifier):
            let databaseURL = try Self.applicationDatabaseURL(bundleIdentifier: bundleIdentifier)
            return try DatabaseOpenResult(
                dbWriter: DatabasePool(
                    path: databaseURL.path(percentEncoded: false),
                    configuration: Self.fileBackedDatabaseConfiguration()
                ),
                storageKind: "application",
                openedFileURL: databaseURL
            )
        case let .databaseFile(url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try DatabaseOpenResult(
                dbWriter: DatabasePool(
                    path: url.path(percentEncoded: false),
                    configuration: Self.fileBackedDatabaseConfiguration()
                ),
                storageKind: "file",
                openedFileURL: url
            )
        case .inMemory:
            return try DatabaseOpenResult(
                dbWriter: DatabaseQueue(),
                storageKind: "memory",
                openedFileURL: nil
            )
        }
    }

    private func performThumbnailStoreStartupMaintenance(needsCleanReset: Bool) {
        guard let thumbnailDirectory else {
            return
        }
        if needsCleanReset {
            ThumbnailStore.deleteAll(in: thumbnailDirectory)
            OtosLog.thumbnails.info("Thumbnail directory purged after clean catalog schema reset")
        }
        let removedTemps = ThumbnailStore.deleteStagedTemporaryFiles(in: thumbnailDirectory)
        guard removedTemps > 0 else {
            return
        }
        OtosLog.thumbnails.info(
            "Staged thumbnail temp cleanup removed count=\(removedTemps, privacy: .public)"
        )
        recordDiagnostic(
            operation: "catalog.thumbnails.stagedTempCleanup",
            phase: "finish",
            fields: ["count": "\(removedTemps)"]
        )
    }

    private func recordDatabaseOpenDiagnostics(dbWriter: any DatabaseWriter, storageKind: String) {
        let synchronousValue = (try? dbWriter.read { db in
            try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
        }) ?? -1
        let synchronousLabel = Self.sqliteSynchronousLabel(synchronousValue)
        OtosLog.persistence.info(
            """
            Catalog database pragmas storage=\(storageKind, privacy: .public) \
            synchronous=\(synchronousLabel, privacy: .public)(\(synchronousValue, privacy: .public))
            """
        )
        recordDiagnostic(
            operation: "catalog.database.open",
            phase: "finish",
            fields: [
                "storage": storageKind,
                "synchronous": synchronousLabel,
                "synchronousValue": "\(synchronousValue)",
            ]
        )
    }

    private static func sqliteSynchronousLabel(_ value: Int) -> String {
        switch value {
        case 0:
            "OFF"
        case 1:
            "NORMAL"
        case 2:
            "FULL"
        case 3:
            "EXTRA"
        default:
            "unknown"
        }
    }

    private func applyLoadedCatalog(roots: [StoredRoot]) {
        rootsByPath = [:]
        rootRowIDsByPath = [:]
        rootPathsByRowID = [:]
        availabilityByRootPath = [:]
        activityByRootPath = [:]
        isEjectableByRootPath = [:]

        for storedRoot in roots {
            let root = libraryRoot(from: storedRoot)
            rootsByPath[root.path] = root
            // SQLite proves that a root was saved, not that it is reachable now.
            // Fixed libraries are checked by launch scans; removable roots are
            // event-driven and start unavailable until a monitor re-attaches them.
            availabilityByRootPath[root.path] = root.kind == .library ? .unknown : .unavailable
            rootRowIDsByPath[root.path] = storedRoot.id
            rootPathsByRowID[storedRoot.id] = root.path
        }
    }

    private func normalizeLoadedRoots(
        _ roots: [StoredRoot],
        dbWriter: any DatabaseWriter
    ) async -> [StoredRoot] {
        var normalizedRoots: [StoredRoot] = []
        for storedRoot in roots {
            let normalizedRoot = await normalizedLoadedRoot(storedRoot, dbWriter: dbWriter)
            normalizedRoots.append(normalizedRoot)
        }
        return normalizedRoots
    }

    private func normalizedLoadedRoot(
        _ storedRoot: StoredRoot,
        dbWriter: any DatabaseWriter
    ) async -> StoredRoot {
        guard storedRoot.kind == .library else {
            return storedRoot
        }
        guard let normalizedPath = try? CatalogPath.normalizedExistingDirectoryPath(for: storedRoot.path.url),
              normalizedPath != storedRoot.path
        else {
            return storedRoot
        }
        do {
            let thumbnailMigrations = try await dbWriter.write { db in
                try Self.updateLibraryRootPath(rootRowID: storedRoot.id, path: normalizedPath, db: db)
            }
            migrateNormalizedRootThumbnails(thumbnailMigrations)
            OtosLog.persistence.info(
                """
                Library root normalized oldPath=\(storedRoot.path.rawValue, privacy: .public) \
                path=\(normalizedPath.rawValue, privacy: .public) \
                thumbnailMigrations=\(thumbnailMigrations.count, privacy: .public)
                """
            )
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=catalog.library.normalize phase=finish oldRootPath=\(storedRoot.path.rawValue, privacy: .public) rootPath=\(normalizedPath.rawValue, privacy: .public) thumbnailMigrations=\(thumbnailMigrations.count, privacy: .public)"
            )
            return StoredRoot(
                id: storedRoot.id,
                path: normalizedPath,
                kind: storedRoot.kind,
                deviceIdentity: storedRoot.deviceIdentity,
                displayName: storedRoot.displayName,
                lastSeenAt: storedRoot.lastSeenAt
            )
        } catch {
            await recordRootNormalizationFailure(storedRoot, normalizedPath: normalizedPath, error: error)
            return storedRoot
        }
    }

    private func recordRootNormalizationFailure(
        _ storedRoot: StoredRoot,
        normalizedPath: LibraryRootPath,
        error: Error
    ) async {
        OtosLog.persistence.error(
            """
            Library root normalization failed oldPath=\(storedRoot.path.rawValue, privacy: .public) \
            path=\(normalizedPath.rawValue, privacy: .public) \
            error=\(String(describing: error), privacy: .public)
            """
        )
        OtosLog.catalog.error(
            // swiftlint:disable:next line_length
            "op=catalog.library.normalize phase=error oldRootPath=\(storedRoot.path.rawValue, privacy: .public) rootPath=\(normalizedPath.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    private func migrateNormalizedRootThumbnails(_ migrations: [ThumbnailPathMigration]) {
        guard !migrations.isEmpty, let thumbnailDirectory else {
            return
        }

        var failureCount = 0
        for migration in migrations {
            do {
                try ThumbnailStore.move(
                    migration.oldRelativeName,
                    to: migration.newRelativeName,
                    in: thumbnailDirectory
                )
            } catch {
                failureCount += 1
                OtosLog.thumbnails.error(
                    """
                    Thumbnail migration failed old=\(migration.oldRelativeName, privacy: .public) \
                    new=\(migration.newRelativeName, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """
                )
            }
        }

        OtosLog.thumbnails.info(
            """
            Thumbnail paths migrated for normalized root count=\(migrations.count, privacy: .public) \
            failures=\(failureCount, privacy: .public)
            """
        )
    }

    private func mediaAsset(from storedAsset: StoredAsset, rootPath: LibraryRootPath) -> MediaAsset {
        MediaAsset(
            libraryRootPath: rootPath,
            relativePath: storedAsset.relativePath,
            name: storedAsset.name,
            contentTypeIdentifier: storedAsset.contentTypeIdentifier,
            byteSize: storedAsset.byteSize,
            createdAt: storedAsset.createdAt,
            contentModifiedAt: storedAsset.contentModifiedAt,
            thumbnailPath: storedAsset.thumbnailPath,
            bestCaptureDate: storedAsset.bestCaptureDate,
            bestKind: storedAsset.bestKind,
            bestFormat: storedAsset.bestFormat,
            durationSeconds: storedAsset.durationSeconds,
            enrichedSourceSize: storedAsset.enrichedSourceSize,
            enrichedSourceMTimeSeconds: storedAsset.enrichedSourceMTimeSeconds
        )
    }

    private func mediaTileDetail(from storedDetail: StoredTileDetail, rootPath: LibraryRootPath) -> MediaTileDetail {
        MediaTileDetail(
            libraryRootPath: rootPath,
            relativePath: storedDetail.relativePath,
            thumbnailPath: storedDetail.thumbnailPath,
            bestKind: storedDetail.bestKind,
            durationSeconds: storedDetail.durationSeconds,
            enrichedSourceSize: storedDetail.enrichedSourceSize,
            enrichedSourceMTimeSeconds: storedDetail.enrichedSourceMTimeSeconds
        )
    }

    private func activity(for path: LibraryRootPath) -> CatalogLibraryActivity {
        if activeScan?.rootPath == path {
            return .scanning
        }
        return activityByRootPath[path] ?? .idle
    }

    private func libraryRoot(from storedRoot: StoredRoot) -> LibraryRoot {
        LibraryRoot(
            path: storedRoot.path,
            kind: storedRoot.kind,
            deviceIdentity: storedRoot.deviceIdentity,
            displayName: storedRoot.displayName,
            lastSeenAt: storedRoot.lastSeenAt
        )
    }

    private func rootIDsForQuery(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) -> [Int64] {
        switch selection {
        case .allMedia:
            return availableLibraryPaths.compactMap { path in
                guard rootsByPath[path]?.kind == .library else {
                    return nil
                }
                return rootRowIDsByPath[path]
            }.sorted()
        case let .library(path):
            guard availableLibraryPaths.contains(path),
                  let rootID = rootRowIDsByPath[path]
            else {
                return []
            }
            return [rootID]
        }
    }

    private func availableLibraryRootIDs() -> [Int64] {
        rootsByPath.keys.compactMap { path in
            guard availabilityByRootPath[path] == .available,
                  rootsByPath[path]?.kind == .library
            else {
                return nil
            }
            return rootRowIDsByPath[path]
        }.sorted()
    }

    private func availableRootIDsByRemovablePriority() -> (removable: [Int64], fixed: [Int64]) {
        var removable: [Int64] = []
        var fixed: [Int64] = []
        for (path, root) in rootsByPath where availabilityByRootPath[path] == .available {
            guard let rootID = rootRowIDsByPath[path] else {
                continue
            }
            if root.kind == .library {
                fixed.append(rootID)
            } else {
                removable.append(rootID)
            }
        }
        return (removable.sorted(), fixed.sorted())
    }

    private func validateNoOverlap(_ path: LibraryRootPath, ignoring existingRootRowID: Int64? = nil) throws {
        for (existingPath, root) in rootsByPath {
            if let existingRootRowID,
               rootRowIDsByPath[root.path] == existingRootRowID
            { // swiftlint:disable:this opening_brace
                continue
            }
            if let relationship = CatalogPath.relationship(candidate: path, existing: existingPath) {
                throw CatalogStoreError.overlappingRoot(existingPath: existingPath, relationship: relationship)
            }
        }
    }

    private func enqueueScans(_ paths: [LibraryRootPath], priority: ScanQueuePriority = .normal) {
        for path in paths where rootsByPath[path] != nil {
            if activeScan?.rootPath == path || pendingScanPaths.contains(path) {
                continue
            }
            switch priority {
            case .normal:
                pendingScanPaths.append(path)
            case .front:
                pendingScanPaths.insert(path, at: 0)
            }
        }
        startNextScanIfNeeded()
    }

    private func startNextScanIfNeeded() {
        guard currentScanTask == nil else {
            return
        }
        while let nextPath = pendingScanPaths.first {
            pendingScanPaths.removeFirst()
            guard rootsByPath[nextPath] != nil,
                  let rootRowID = rootRowIDsByPath[nextPath]
            else {
                continue
            }
            guard rootIsAvailable(nextPath) else {
                markRootUnavailableBeforeScan(nextPath)
                continue
            }
            setAvailability(.available, for: nextPath)
            let scan = makeActiveScan(rootPath: nextPath, rootRowID: rootRowID)
            activeScan = scan
            notifyCatalogChanged()
            OtosLog.catalog.info("Catalog scan started path=\(nextPath.rawValue, privacy: .public)")
            recordDiagnostic(
                operation: "catalog.scan",
                phase: "start",
                fields: ["rootPath": nextPath.rawValue]
            )
            // The scan task is retained in `currentScanTask`, cancelled when
            // the owning root goes away, and every callback revalidates the
            // `ActiveScan` lease before mutating actor state.
            currentScanTask = Task.detached(priority: .utility) { [scanner, scanCadence] in
                do {
                    let observedPaths = try await scanner.scanRoot(nextPath, scanCadence) { batch in
                        try await self.recordScannedBatch(batch, scan: scan)
                    }
                    await self.scanCompleted(scan: scan, observedPaths: observedPaths)
                } catch is CancellationError {
                    await self.scanCancelled(scan: scan)
                } catch {
                    await self.scanFailed(scan: scan, error: error)
                }
            }
            return
        }
    }

    private func recordScannedBatch(_ batch: [ScannedMediaFile], scan: ActiveScan) async throws {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.beforeWrite")
            throw CancellationError()
        }

        let dbQueue = try database()
        let state = OtosSignpost.persistence.beginInterval("CatalogScanBatchWrite")
        let timedChangedCount = try await timedWrite(dbQueue) { db in
            var count = 0
            for file in batch {
                let changed = try Self.upsertScannedFile(
                    file,
                    libraryRootPath: scan.rootPath,
                    libraryRootID: scan.rootRowID,
                    db: db
                )
                if changed {
                    count += 1
                }
            }
            return count
        }
        OtosSignpost.persistence.endInterval("CatalogScanBatchWrite", state)
        let changedCount = timedChangedCount.value

        // The store actor can process remove/cancel messages while SQLite is
        // writing. Recheck ownership before notifying from this batch.
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.afterWrite")
            throw CancellationError()
        }

        let visibleChange = changedCount > 0
        // SQLite reported whether this batch inserted a new row or changed existing
        // filesystem facts. Identical rescans publish nothing; changed dates still
        // count because Best Date sort and enrichment priority fall back to them.
        if visibleChange {
            notifyCatalogChanged()
        }
        await recordScanBatchWrite(
            scan: scan,
            scannedCount: batch.count,
            changedCount: changedCount,
            timing: timedChangedCount
        )
        await recordWALDiagnostics(reason: "scanBatch")
    }

    private func recordScanBatchWrite(
        scan: ActiveScan,
        scannedCount: Int,
        changedCount: Int,
        timing: DatabaseTimedValue<Int>
    ) async {
        let visibleChange = changedCount > 0
        OtosLog.catalog.debug(
            """
            Catalog scan batch path=\(scan.rootPath.rawValue, privacy: .public) \
            count=\(scannedCount, privacy: .public) changed=\(visibleChange, privacy: .public) \
            waitMs=\(timing.waitMs, privacy: .public) \
            execMs=\(timing.execMs, privacy: .public) \
            writeMs=\(timing.totalMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.scan.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(scannedCount, privacy: .public) changed=\(visibleChange, privacy: .public) changedCount=\(changedCount, privacy: .public) waitMs=\(timing.waitMs, privacy: .public) execMs=\(timing.execMs, privacy: .public) writeMs=\(timing.totalMs, privacy: .public)"
        )
    }

    private func scanCompleted(scan: ActiveScan, observedPaths: Set<MediaRelativePath>) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "completion")
            return
        }

        do {
            let deletedCount = try await reconcileMissingAssets(
                scan: scan,
                observedPaths: observedPaths
            )
            OtosLog.catalog.info(
                """
                Catalog scan completed path=\(scan.rootPath.rawValue, privacy: .public) \
                observed=\(observedPaths.count, privacy: .public) deleted=\(deletedCount, privacy: .public)
                """
            )
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=catalog.scan phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) observed=\(observedPaths.count, privacy: .public) deleted=\(deletedCount, privacy: .public)"
            )
        } catch is CancellationError {
            await recordIgnoredStaleCallback(scan, callback: "reconciliation")
            return
        } catch {
            OtosLog.catalog.error(
                """
                Catalog scan reconciliation failed path=\(scan.rootPath.rawValue, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
            OtosLog.catalog.error(
                // swiftlint:disable:next line_length
                "op=catalog.scan.reconcile phase=error rootPath=\(scan.rootPath.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }

        clearCurrentScan(scan, armFilesystemWatching: true)
    }

    /// Reconciliation changes durable membership as one actor-owned operation.
    /// Projection validates membership directly through Store queries, so Store does not
    /// maintain a second per-asset cache-invalidation fact alongside SQLite.
    private func reconcileMissingAssets(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>
    ) async throws -> Int {
        guard owns(scan) else {
            throw CancellationError()
        }
        let dbQueue = try database()
        let existingRows = try await dbQueue.read { db in
            try Self.fetchExistingAssetRows(libraryRootID: scan.rootRowID, db: db)
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        let missingRows = existingRows.filter { !observedPaths.contains($0.relativePath) }
        guard !missingRows.isEmpty else {
            return 0
        }
        // Capture the thumbnail files of soon-to-be-purged assets before their rows are
        // removed, so overlay is purged with the item (ADR 0008): the catalog rows and
        // thumbnail file all go together on proven deletion.
        let purgedThumbnails: [String] = missingRows.compactMap(\.thumbnailPath)
        let state = OtosSignpost.persistence.beginInterval("CatalogScanReconcile")
        defer { OtosSignpost.persistence.endInterval("CatalogScanReconcile", state) }

        try await dbQueue.write { db in
            for row in missingRows {
                try Self.deleteAssetRow(rootRowID: scan.rootRowID, relativePath: row.relativePath, db: db)
            }
        }
        // Removal and same-path replacement can run while GRDB owns the writer.
        // Never treat an old row's reconciliation as proof about the replacement root.
        guard owns(scan) else {
            throw CancellationError()
        }
        if let thumbnailDirectory {
            for name in purgedThumbnails {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        return missingRows.count
    }

    private func scanCancelled(scan: ActiveScan) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "cancellation")
            return
        }
        OtosLog.catalog.info("Catalog scan cancelled path=\(scan.rootPath.rawValue, privacy: .public)")
        OtosLog.catalog.notice(
            "op=catalog.scan phase=cancel rootPath=\(scan.rootPath.rawValue, privacy: .public)"
        )
        clearCurrentScan(scan, armFilesystemWatching: false)
    }

    private func scanFailed(scan: ActiveScan, error: Error) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "failure")
            return
        }
        let errorDescription = if case CatalogScanError.filesystemErrorsEncountered = error {
            "filesystemErrorsEncountered"
        } else {
            String(describing: error)
        }
        let isStillAvailable = rootIsAvailable(scan.rootPath)
        if !isStillAvailable {
            setAvailability(.unavailable, for: scan.rootPath)
            OtosLog.catalog.error(
                "Catalog scan failed because root is unavailable path=\(scan.rootPath.rawValue, privacy: .public)"
            )
            OtosLog.catalog.notice(
                "op=catalog.library.availability phase=unavailable rootPath=\(scan.rootPath.rawValue, privacy: .public)"
            )
        } else {
            OtosLog.catalog.error(
                """
                Catalog scan failed path=\(scan.rootPath.rawValue, privacy: .public) \
                error=\(errorDescription, privacy: .public)
                """
            )
        }
        var diagnosticFields = [
            "rootPath": scan.rootPath.rawValue,
            "error": errorDescription,
        ]
        if case let CatalogScanError.filesystemErrorsEncountered(count, summaries) = error {
            OtosLog.fileAccess.error("Filesystem scan errors count=\(count, privacy: .public)")
            diagnosticFields["issueCount"] = "\(count)"
            for (index, summary) in summaries.enumerated() {
                let prefix = "issue\(index)"
                diagnosticFields["\(prefix).kind"] = summary.kind
                diagnosticFields["\(prefix).error"] = summary.errorDescription
                diagnosticFields["\(prefix).count"] = "\(summary.count)"
                diagnosticFields["\(prefix).examples"] = summary.examplePaths.joined(separator: " | ")
            }
        }
        OtosLog.catalog.error(
            "op=catalog.scan phase=error fields=\(String(describing: diagnosticFields), privacy: .public)"
        )
        clearCurrentScan(scan, armFilesystemWatching: true)
    }

    private func clearCurrentScan(_ scan: ActiveScan, armFilesystemWatching: Bool) {
        guard activeScan == scan else {
            return
        }
        let rootPath = scan.rootPath
        activeScan = nil
        currentScanTask = nil

        if armFilesystemWatching, rootsByPath[rootPath] != nil {
            filesystemWatchingArmed.insert(rootPath)
        }

        if rescanAfterCurrentScan.remove(rootPath) != nil {
            filesystemEventBatches.removeValue(forKey: rootPath)
            enqueueScans([rootPath])
        }

        notifyCatalogChanged()
        startNextScanIfNeeded()
    }

    private func notifyCatalogChanged(_ change: CatalogStoreChange = .catalogChanged) {
        let state = OtosSignpost.catalog.beginInterval("CatalogChangeNotify")
        defer {
            OtosSignpost.catalog.endInterval("CatalogChangeNotify", state)
        }
        for continuation in changeContinuations.values {
            continuation.yield(change)
        }
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }

    private func rootIsAvailable(_ path: LibraryRootPath) -> Bool {
        let state = OtosSignpost.fileAccess.beginInterval("CatalogRootAvailabilityCheck")
        defer {
            OtosSignpost.fileAccess.endInterval("CatalogRootAvailabilityCheck", state)
        }
        do {
            let values = try path.url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        } catch {
            return false
        }
    }

    @discardableResult
    private func setAvailability(_ availability: LibraryAvailability, for path: LibraryRootPath) -> Bool {
        guard rootsByPath[path] != nil,
              availabilityByRootPath[path] != availability
        else {
            return false
        }
        availabilityByRootPath[path] = availability
        return true
    }

    private func markRootUnavailableBeforeScan(_ path: LibraryRootPath) {
        let changed = setAvailability(.unavailable, for: path)
        OtosLog.catalog.info("Library root unavailable before scan path=\(path.rawValue, privacy: .public)")
        recordDiagnostic(
            operation: "catalog.library.availability",
            phase: "unavailable",
            fields: ["rootPath": path.rawValue]
        )
        if changed {
            notifyCatalogChanged()
        }
    }

    /// Draining only the roots restored by the initial read keeps two automatic
    /// behaviors distinct: launch scans happen once, while a newly added root is
    /// scanned by its add intent and is never duplicated by a later `start()`.
    private func requestLoadedRootScansIfNeeded() {
        guard !unrequestedLoadedRootPaths.isEmpty else {
            return
        }
        let paths = unrequestedLoadedRootPaths
        unrequestedLoadedRootPaths.removeAll(keepingCapacity: false)
        enqueueScans(paths)
    }

    private func startFilesystemWatchingIfNeeded() {
        guard !filesystemWatchingStarted else {
            return
        }
        filesystemWatchingStarted = true
        filesystemWatcher.start(watchedRootPaths) { [weak self] event in
            // FSEvents reaches us through a synchronous C callback. The Store
            // actor is still the owner of debounce and scan scheduling, so the
            // callback performs only this actor hop.
            Task {
                await self?.handleFilesystemEvent(event)
            }
        }
    }

    private var watchedRootPaths: [LibraryRootPath] {
        rootsByPath.compactMap { path, root in
            switch root.kind {
            case .library:
                path
            case .removableVolume:
                availabilityByRootPath[path] == .available ? path : nil
            case .deviceMTP:
                nil
            }
        }
    }

    private func handleFilesystemEvent(_ event: FilesystemEvent) {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventDebounce")
        defer {
            OtosSignpost.catalog.endInterval("FilesystemEventDebounce", signpost)
        }

        guard let root = CatalogPath.owningRoot(for: event.path, among: rootsByPath.keys) else {
            recordFilesystemEventDrop(path: event.path, root: nil, reason: "outsideRoots")
            return
        }

        guard filesystemWatchingArmed.contains(root) else {
            recordFilesystemEventDrop(path: event.path, root: root, reason: "unarmed")
            return
        }

        OtosLog.catalog.debug(
            "Filesystem event received path=\(event.path, privacy: .public) root=\(root.rawValue, privacy: .public)"
        )
        filesystemEventBatches[root, default: []].append(event)
        debounceFilesystemReconcile(for: root)
    }

    private func recordFilesystemEventDrop(path: String, root: LibraryRootPath?, reason: String) {
        if let root {
            OtosLog.catalog.debug(
                """
                Filesystem event ignored path=\(path, privacy: .public) \
                root=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)
                """
            )
        } else {
            OtosLog.fileAccess.debug(
                "Filesystem event ignored outside library roots path=\(path, privacy: .public)"
            )
        }
        var fields: [String: String] = [
            "path": path,
            "reason": reason,
        ]
        if let root {
            fields["rootPath"] = root.rawValue
        }
        recordDiagnostic(
            operation: "catalog.filesystemEvent",
            phase: "drop",
            fields: fields
        )
    }

    private func debounceFilesystemReconcile(for root: LibraryRootPath) {
        filesystemDebounceTasks[root]?.cancel()
        let debounce = filesystemEventDebounce
        let sleep = filesystemEventSleep
        filesystemDebounceTasks[root] = Task { [root, sleep] in
            await sleep(debounce)
            guard !Task.isCancelled else {
                return
            }
            await processFilesystemEventBatch(for: root)
        }
    }

    /// Best-effort boundary log from synchronous Store branches. Captures only
    /// scalar strings — never catalog state or asset batches.
    private func recordDiagnostic(
        operation: String,
        phase: String,
        fields: [String: String] = [:]
    ) {
        OtosLog.catalog.notice(
            "op=\(operation, privacy: .public) phase=\(phase, privacy: .public) fields=\(String(describing: fields), privacy: .public)"
        )
    }

    private func recordWALDiagnostics(reason: String) async {
        guard databaseFileURL != nil else {
            return
        }
        let walBytes = walFileSizeBytes() ?? -1
        OtosLog.catalog.notice(
            "op=catalog.database.wal phase=sample reason=\(reason, privacy: .public) walBytes=\(walBytes, privacy: .public)"
        )
    }

    private func walFileSizeBytes() -> Int64? {
        guard let databaseFileURL else {
            return nil
        }
        let walPath = databaseFileURL.path(percentEncoded: false) + "-wal"
        guard FileManager.default.fileExists(atPath: walPath) else {
            return 0
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    // swiftlint:disable:next function_body_length
    private func processFilesystemEventBatch(for root: LibraryRootPath) async {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventBatch")
        defer {
            OtosSignpost.catalog.endInterval("FilesystemEventBatch", signpost)
        }

        guard rootsByPath[root] != nil else {
            filesystemEventBatches.removeValue(forKey: root)
            await recordFilesystemEventDrop(root: root, reason: "removed")
            return
        }
        guard filesystemWatchingArmed.contains(root) else {
            filesystemEventBatches.removeValue(forKey: root)
            await recordFilesystemEventDrop(root: root, reason: "unarmed")
            return
        }
        guard rootIsAvailable(root) else {
            filesystemEventBatches.removeValue(forKey: root)
            await recordFilesystemEventDrop(root: root, reason: "unavailable")
            return
        }

        if activeScan?.rootPath == root {
            let events = filesystemEventBatches[root] ?? []
            rescanAfterCurrentScan.insert(root)
            filesystemEventBatches.removeValue(forKey: root)
            OtosLog.catalog.debug(
                "Filesystem reconcile deferred until active scan finishes path=\(root.rawValue, privacy: .public)"
            )
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=catalog.filesystemEvent phase=schedule mode=deferred rootPath=\(root.rawValue, privacy: .public) eventCount=\(events.count, privacy: .public)"
            )
            return
        }

        let events = filesystemEventBatches.removeValue(forKey: root) ?? []
        guard !events.isEmpty else {
            return
        }

        if events.contains(where: { FilesystemEventFlags(event: $0).requiresFullRootScan }) {
            enqueueScans([root])
            OtosLog.catalog.info("Filesystem rescan scheduled path=\(root.rawValue, privacy: .public)")
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=catalog.filesystemEvent phase=schedule mode=fullRoot rootPath=\(root.rawValue, privacy: .public) eventCount=\(events.count, privacy: .public)"
            )
            return
        }

        var catalogChanged = false
        for event in events {
            guard await reconcileFilesystemEvent(event, root: root) else {
                continue
            }
            catalogChanged = true
        }
        if catalogChanged {
            notifyCatalogChanged()
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.filesystemEvent phase=reconcile mode=targeted rootPath=\(root.rawValue, privacy: .public) eventCount=\(events.count, privacy: .public) catalogChanged=\(catalogChanged, privacy: .public)"
        )
    }

    private func filesystemEventBatchFields(
        root: LibraryRootPath,
        events: [FilesystemEvent],
        mode: String,
        catalogChanged: Bool
    ) -> [String: String] {
        var actionCounts: [String: Int] = [:]
        var flagCounts: [String: Int] = [:]
        for event in events {
            let flags = FilesystemEventFlags(event: event)
            let action = if flags.requiresFullRootScan {
                "fullRoot"
            } else {
                flags.singleFileAction?.diagnosticDescription ?? "unknown"
            }
            actionCounts[action, default: 0] += 1
            for name in flags.diagnosticNames {
                flagCounts[name, default: 0] += 1
            }
        }
        let samplePaths = events.prefix(3).map(\.path).joined(separator: "|")
        return [
            "rootPath": root.rawValue,
            "mode": mode,
            "eventCount": "\(events.count)",
            "uniquePathCount": "\(Set(events.map(\.path)).count)",
            "catalogChanged": "\(catalogChanged)",
            "actions": diagnosticCounts(actionCounts),
            "flags": diagnosticCounts(flagCounts),
            "samplePaths": samplePaths,
        ]
    }

    private func diagnosticCounts(_ counts: [String: Int]) -> String {
        counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
    }

    @discardableResult
    private func reconcileFilesystemEvent(_ event: FilesystemEvent, root: LibraryRootPath) async -> Bool {
        let flags = FilesystemEventFlags(event: event)
        guard let action = flags.singleFileAction,
              let rootRowID = rootRowIDsByPath[root]
        else {
            return false
        }

        switch action {
        case .deleteIfMissing:
            return await reconcileDeletedFile(at: event.path, root: root, rootRowID: rootRowID)
        case .upsert:
            return await reconcileUpsertedFile(at: event.path, root: root, rootRowID: rootRowID)
        }
    }

    private func reconcileDeletedFile(
        at absolutePath: String,
        root: LibraryRootPath,
        rootRowID: Int64
    ) async -> Bool {
        let fileURL = URL(fileURLWithPath: absolutePath, isDirectory: false)
        if FileManager.default.fileExists(atPath: absolutePath) {
            return await reconcileUpsertedFile(at: absolutePath, root: root, rootRowID: rootRowID)
        }
        guard let relativePath = CatalogPath.relativePath(rootPath: root, fileURL: fileURL) else {
            return false
        }

        return await deleteCatalogedFile(relativePath: relativePath, rootRowID: rootRowID)
    }

    private func reconcileUpsertedFile(
        at absolutePath: String,
        root: LibraryRootPath,
        rootRowID: Int64
    ) async -> Bool {
        let fileURL = URL(fileURLWithPath: absolutePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: absolutePath) else {
            return false
        }
        let scannedFile: ScannedMediaFile?
        do {
            scannedFile = try CatalogScannedFileReader.scannedFile(fileURL: fileURL, rootPath: root)
        } catch {
            return false
        }
        guard let scannedFile else {
            guard let relativePath = CatalogPath.relativePath(rootPath: root, fileURL: fileURL) else {
                return false
            }
            return await deleteCatalogedFile(relativePath: relativePath, rootRowID: rootRowID)
        }

        let dbQueue: (any DatabaseWriter)?
        do {
            dbQueue = try database()
        } catch {
            return false
        }
        guard let dbQueue else {
            return false
        }

        do {
            return try await dbQueue.write { db in
                try Self.upsertScannedFile(
                    scannedFile,
                    libraryRootPath: root,
                    libraryRootID: rootRowID,
                    db: db
                )
            }
        } catch {
            return false
        }
    }

    private func deleteCatalogedFile(relativePath: MediaRelativePath, rootRowID: Int64) async -> Bool {
        guard let dbQueue = try? database() else {
            return false
        }

        let deletionTarget: CatalogedFileDeletionTarget
        do {
            guard let target = try await dbQueue.read({ db in
                try Self.catalogedFileDeletionTarget(relativePath: relativePath, rootRowID: rootRowID, db: db)
            }) else {
                return false
            }
            deletionTarget = target
            let deleted = try await dbQueue.write { db in
                try Self.deleteAssetRow(rootRowID: rootRowID, relativePath: relativePath, db: db)
            }
            guard deleted else {
                return false
            }
        } catch {
            return false
        }

        if let thumbnailPath = deletionTarget.thumbnailPath, let thumbnailDirectory {
            ThumbnailStore.delete(thumbnailPath, in: thumbnailDirectory)
        }
        return true
    }

    private func recordFilesystemEventDrop(root: LibraryRootPath, reason: String) async {
        OtosLog.catalog.debug(
            "Filesystem rescan dropped path=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        OtosLog.catalog.notice(
            "op=catalog.filesystemEvent phase=drop rootPath=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func cancelFilesystemDebounce(for root: LibraryRootPath) {
        filesystemDebounceTasks[root]?.cancel()
        filesystemDebounceTasks.removeValue(forKey: root)
        filesystemEventBatches.removeValue(forKey: root)
    }

    private func cancelAllFilesystemDebounces() {
        for task in filesystemDebounceTasks.values {
            task.cancel()
        }
        filesystemDebounceTasks.removeAll()
    }

    private func owns(_ scan: ActiveScan) -> Bool {
        (activeScan == scan || activeDeviceScans[scan.rootPath] == scan)
            && rootsByPath[scan.rootPath] != nil
            && rootRowIDsByPath[scan.rootPath] == scan.rootRowID
            && rootPathsByRowID[scan.rootRowID] == scan.rootPath
    }

    private func makeActiveScan(rootPath: LibraryRootPath, rootRowID: Int64) -> ActiveScan {
        nextActiveScanLeaseGeneration &+= 1
        return ActiveScan(
            rootPath: rootPath,
            rootRowID: rootRowID,
            leaseGeneration: nextActiveScanLeaseGeneration
        )
    }

    private func recordIgnoredStaleCallback(_ scan: ActiveScan, callback: String) async {
        OtosLog.catalog.debug(
            """
            Ignoring stale scan callback path=\(scan.rootPath.rawValue, privacy: .public) \
            callback=\(callback, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.scan.staleCallback phase=ignored rootPath=\(scan.rootPath.rawValue, privacy: .public) rootRowID=\(scan.rootRowID, privacy: .public) callback=\(callback, privacy: .public)"
        )
    }
}
