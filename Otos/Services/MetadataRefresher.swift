import Foundation
import MediaMetadata
import OSLog

/// Metadata refresh guide
///
/// MediaMetadata raises `MediaMetadataReader.extractionRevision(for:)` for a format family
/// whenever the same bytes of that family can read differently (ADR 0039). Every metadata
/// record carries its family's revision at the read; this owner re-reads library rows whose
/// record an older reading produced, so a parser fix reaches the catalog without a
/// hand-written migration per fix, and only for the families it touched.
///
/// It pays only for bytes already on this Mac. A row whose original is cloud-only is
/// skipped, never downloaded: re-reading a whole cloud library for a parser fix would move
/// hundreds of gigabytes to correct a few fields (`docs/research/2026-10-25-mediametadata-0.7.md`).
/// A skipped row is offered again on the next pass, so it is re-read once it is local.
///
/// One exception, by the owner's decision: an Apple-made record that predates the content
/// identifier may be half of a Live Photo, and the pair cannot form without its bytes
/// (ADR 0041). This pass reads nothing for it; it hands the row to enrichment
/// (`CatalogStore.requestEnrichmentDownload`), which downloads it once and derives every
/// product from that one read.
///
/// One pass per launch, started with enrichment. The pass walks candidates in path order
/// through the store's cursor, asks the shared materializer where each original is
/// (`locality(of:)`, ADR 0046 §4) and reads only a local one, re-checking the file's
/// materialization immediately before its read, reads on the cooperative pool off this actor (`@concurrent`), and hands records
/// to `CatalogStore.applyMetadataRefresh`, which writes one only while its row still has
/// the signature it was read at. The actor holds no state but the pass's task.
actor MetadataRefresher {
    private let store: CatalogStore
    private let locality: @Sendable (MediaAssetID) async -> OriginalLocality
    private let pageSize: Int
    private var task: Task<MetadataRefreshSummary, Never>?

    init(
        store: CatalogStore,
        locality: @escaping @Sendable (MediaAssetID) async -> OriginalLocality,
        pageSize: Int = 64
    ) {
        self.store = store
        self.locality = locality
        self.pageSize = pageSize
    }

    /// Starts this launch's pass; a second call joins the first.
    @discardableResult
    func refresh() async -> MetadataRefreshSummary {
        if let task {
            return await task.value
        }
        let store = store
        let locality = locality
        let pageSize = pageSize
        let pass = Task {
            await Self.runPass(store: store, locality: locality, pageSize: pageSize)
        }
        task = pass
        return await pass.value
    }

    func shutdown() {
        task?.cancel()
    }

    private static func runPass(
        store: CatalogStore,
        locality: @escaping @Sendable (MediaAssetID) async -> OriginalLocality,
        pageSize: Int
    ) async -> MetadataRefreshSummary {
        let start = ContinuousClock.now
        var summary = MetadataRefreshSummary()
        var cursor: MediaAssetID?
        OtosLog.metadata.noticeOperation("metadata.refresh", phase: "start", fields: [:])
        while !Task.isCancelled {
            let page: [MetadataRefreshCandidate]
            do {
                page = try await store.backgroundReads.metadataRefreshCandidates(after: cursor, limit: pageSize)
            } catch {
                summary.failed = true
                OtosLog.metadata.errorOperation("metadata.refresh", phase: "candidatesFailed", fields: [
                    "error": String(describing: error),
                ])
                break
            }
            guard let last = page.last else { break }
            cursor = last.id
            var refreshes: [MetadataRefresh] = []
            var downloads: [MetadataRefreshCandidate] = []
            for candidate in page where !Task.isCancelled {
                switch await read(candidate, locality: locality) {
                case let .read(refresh):
                    refreshes.append(refresh)
                case .notLocal where candidate.mayCompleteLivePhoto:
                    downloads.append(candidate)
                case .notLocal, .retry:
                    summary.skipped += 1
                }
            }
            summary.read += refreshes.count
            do {
                summary.written += try await store.applyMetadataRefresh(refreshes)
                summary.downloadsRequested += try await store.requestEnrichmentDownload(downloads)
            } catch {
                summary.failed = true
                OtosLog.metadata.errorOperation("metadata.refresh", phase: "writeFailed", fields: [
                    "count": "\(refreshes.count)", "error": String(describing: error),
                ])
                break
            }
        }
        OtosLog.metadata.noticeOperation("metadata.refresh", phase: Task.isCancelled ? "cancelled" : "finish", fields: [
            "read": "\(summary.read)",
            "written": "\(summary.written)",
            "skipped": "\(summary.skipped)",
            "downloadsRequested": "\(summary.downloadsRequested)",
            "failed": "\(summary.failed)",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return summary
    }

    private enum CandidateRead {
        case read(MetadataRefresh)
        /// The original is not on this Mac; this pass reads nothing that would download it.
        case notLocal
        /// The reader asked to retry; the row stays a candidate for the next pass.
        case retry
    }

    /// The candidate's record as the current reader reads it, when its original is local.
    /// The file's own materialization is re-checked immediately before the read, so the read
    /// never downloads one evicted since `locality` answered.
    @concurrent
    private static func read(
        _ candidate: MetadataRefreshCandidate,
        locality: @Sendable (MediaAssetID) async -> OriginalLocality
    ) async -> CandidateRead {
        let url = candidate.id.fileURL
        guard await locality(candidate.id) == .local, FileMaterialization.status(of: url) == .materialized else {
            return .notLocal
        }
        let result = MediaMetadataReader.read(url: url)
        guard !result.outcome.shouldRetry else { return .retry }
        return .read(MetadataRefresh(
            id: candidate.id,
            metadata: MediaEnricher.map(result),
            enrichedKind: MediaEnricher.normalizedKind(result.format),
            enrichedFormat: MediaFormatToken.normalize(result.format),
            sourceSize: candidate.sourceSize,
            sourceMTimeSeconds: candidate.sourceMTimeSeconds
        ))
    }
}

/// What one refresh pass did, for its log line and its tests.
nonisolated struct MetadataRefreshSummary: Equatable, Sendable {
    var read = 0
    var written = 0
    /// Rows whose original is not local, or whose read the reader asked to retry.
    var skipped = 0
    /// Cloud-only rows that may complete a Live Photo, handed to enrichment to download.
    var downloadsRequested = 0
    var failed = false
}
