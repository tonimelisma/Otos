import Foundation
import MediaMetadata
import OSLog

/// Metadata refresh guide
///
/// MediaMetadata raises `MediaMetadataReader.extractionRevision` whenever the same bytes
/// can read differently (ADR 0039). Every metadata record carries the revision it was read
/// with; this owner re-reads library rows whose record an older revision produced, so a
/// parser fix reaches the catalog without a hand-written migration per fix.
///
/// It pays only for bytes already on this Mac. A row whose original is cloud-only is
/// skipped, never downloaded: re-reading a whole cloud library for a parser fix would move
/// hundreds of gigabytes to correct a few fields (`docs/research/2026-10-25-mediametadata-0.7.md`).
/// A skipped row is offered again on the next pass, so it is re-read once it is local.
///
/// One pass per launch, started with enrichment. The pass walks candidates in path order
/// through the store's cursor, checks each file's materialization immediately before its
/// read, reads on the cooperative pool off this actor (`@concurrent`), and hands records
/// to `CatalogStore.applyMetadataRefresh`, which writes one only while its row still has
/// the signature it was read at. The actor holds no state but the pass's task.
actor MetadataRefresher {
    private let store: CatalogStore
    private let isLocal: @Sendable (URL) -> Bool
    private let pageSize: Int
    private var task: Task<MetadataRefreshSummary, Never>?

    init(
        store: CatalogStore,
        isLocal: @escaping @Sendable (URL) -> Bool = { FileMaterialization.status(of: $0) == .materialized },
        pageSize: Int = 64
    ) {
        self.store = store
        self.isLocal = isLocal
        self.pageSize = pageSize
    }

    /// Starts this launch's pass; a second call joins the first.
    @discardableResult
    func refresh() async -> MetadataRefreshSummary {
        if let task {
            return await task.value
        }
        let store = store
        let isLocal = isLocal
        let pageSize = pageSize
        let pass = Task {
            await Self.runPass(store: store, isLocal: isLocal, pageSize: pageSize)
        }
        task = pass
        return await pass.value
    }

    func shutdown() {
        task?.cancel()
    }

    private static func runPass(
        store: CatalogStore,
        isLocal: @escaping @Sendable (URL) -> Bool,
        pageSize: Int
    ) async -> MetadataRefreshSummary {
        let revision = MediaMetadataReader.extractionRevision
        let start = ContinuousClock.now
        var summary = MetadataRefreshSummary()
        var cursor: MediaAssetID?
        OtosLog.metadata.noticeOperation("metadata.refresh", phase: "start", fields: ["revision": "\(revision)"])
        while !Task.isCancelled {
            let page: [MetadataRefreshCandidate]
            do {
                page = try await store.metadataRefreshCandidates(belowRevision: revision, after: cursor, limit: pageSize)
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
            for candidate in page where !Task.isCancelled {
                if let refresh = await read(candidate, isLocal: isLocal) {
                    refreshes.append(refresh)
                } else {
                    summary.skipped += 1
                }
            }
            summary.read += refreshes.count
            do {
                summary.written += try await store.applyMetadataRefresh(refreshes)
            } catch {
                summary.failed = true
                OtosLog.metadata.errorOperation("metadata.refresh", phase: "writeFailed", fields: [
                    "count": "\(refreshes.count)", "error": String(describing: error),
                ])
                break
            }
        }
        OtosLog.metadata.noticeOperation("metadata.refresh", phase: Task.isCancelled ? "cancelled" : "finish", fields: [
            "revision": "\(revision)",
            "read": "\(summary.read)",
            "written": "\(summary.written)",
            "skipped": "\(summary.skipped)",
            "failed": "\(summary.failed)",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return summary
    }

    /// The candidate's record as the current reader reads it, or nil when its original is
    /// not local. The materialization check sits immediately before the read, so the read
    /// never downloads.
    @concurrent
    private static func read(
        _ candidate: MetadataRefreshCandidate,
        isLocal: @Sendable (URL) -> Bool
    ) async -> MetadataRefresh? {
        let url = candidate.id.fileURL
        guard isLocal(url) else { return nil }
        let result = MediaMetadataReader.read(url: url)
        guard !result.outcome.shouldRetry else { return nil }
        return MetadataRefresh(
            id: candidate.id,
            metadata: MediaEnricher.map(result),
            enrichedKind: MediaEnricher.normalizedKind(result.format),
            enrichedFormat: MediaFormatToken.normalize(extension: result.format.fileExtension),
            sourceSize: candidate.sourceSize,
            sourceMTimeSeconds: candidate.sourceMTimeSeconds
        )
    }
}

/// What one refresh pass did, for its log line and its tests.
nonisolated struct MetadataRefreshSummary: Equatable, Sendable {
    var read = 0
    var written = 0
    /// Rows whose original is not local, or whose read the reader asked to retry.
    var skipped = 0
    var failed = false
}
