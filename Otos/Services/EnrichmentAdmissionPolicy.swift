import Foundation

/// Concrete enrichment admission policy (plan 0056).
///
/// Count maxima alone treat a tiny JPEG and a multi-gigabyte video as equal work.
/// This value type answers whether one candidate may enter a materialization or
/// enrichment slot given current in-flight facts. It is not a generalized
/// scheduler: `EnrichmentCoordinator` remains the owner and calls these pure
/// helpers at dispatch time.
nonisolated struct EnrichmentAdmissionPolicy: Equatable {
    struct InFlightSnapshot: Equatable {
        var downloadCount: Int
        var enrichCount: Int
        var downloadBytes: Int64
        var enrichBytes: Int64
        var largeVideoDownloadCount: Int
        var videoEnrichCount: Int
        var eagerDownloadCountByRoot: [LibraryRootPath: Int]

        static let empty = InFlightSnapshot(
            downloadCount: 0,
            enrichCount: 0,
            downloadBytes: 0,
            enrichBytes: 0,
            largeVideoDownloadCount: 0,
            videoEnrichCount: 0,
            eagerDownloadCountByRoot: [:]
        )
    }

    struct Candidate: Equatable {
        var sourceSize: Int64?
        var isVideo: Bool
        var isViewportOrDevice: Bool
        var rootPath: LibraryRootPath
        var isEagerBackground: Bool
    }

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case downloadCountCap
        case enrichCountCap
        case viewportDownloadReserve
        case downloadByteBudget
        case enrichByteBudget
        case largeVideoDownloadCap
        case videoEnrichCap
        case rootEagerFairness

        var description: String {
            switch self {
            case .downloadCountCap: "downloadCountCap"
            case .enrichCountCap: "enrichCountCap"
            case .viewportDownloadReserve: "viewportDownloadReserve"
            case .downloadByteBudget: "downloadByteBudget"
            case .enrichByteBudget: "enrichByteBudget"
            case .largeVideoDownloadCap: "largeVideoDownloadCap"
            case .videoEnrichCap: "videoEnrichCap"
            case .rootEagerFairness: "rootEagerFairness"
            }
        }
    }

    var downloadConcurrency: Int
    var enrichConcurrency: Int
    var downloadByteBudget: Int64
    var enrichByteBudget: Int64
    var largeVideoDownloadCap: Int
    var videoEnrichCap: Int
    var largeVideoThresholdBytes: Int64
    var eagerDownloadsPerRootSoftCap: Int

    static let production = EnrichmentAdmissionPolicy(
        downloadConcurrency: 16,
        enrichConcurrency: 8,
        // Camera Roll sample: p95 ~128 MiB, max ~6.8 GiB. A 2 GiB aggregate
        // download budget admits many images while blocking multi-large-video floods.
        downloadByteBudget: 2 * 1024 * 1024 * 1024,
        enrichByteBudget: 1024 * 1024 * 1024,
        largeVideoDownloadCap: 2,
        videoEnrichCap: 2,
        largeVideoThresholdBytes: 256 * 1024 * 1024,
        eagerDownloadsPerRootSoftCap: 8
    )

    func canDispatchDownload(
        candidate: Candidate,
        inFlight: InFlightSnapshot
    ) -> Result<Void, Rejection> {
        guard inFlight.downloadCount < downloadConcurrency else {
            return .failure(.downloadCountCap)
        }
        let eagerSlotLimit = max(downloadConcurrency - 1, 0)
        if candidate.isEagerBackground, inFlight.downloadCount >= eagerSlotLimit {
            return .failure(.viewportDownloadReserve)
        }
        if candidate.isEagerBackground {
            let rootCount = inFlight.eagerDownloadCountByRoot[candidate.rootPath, default: 0]
            if rootCount >= eagerDownloadsPerRootSoftCap, !inFlightAloneAllowsOversized(candidate, inFlight) {
                return .failure(.rootEagerFairness)
            }
        }
        if isLargeVideo(candidate),
           inFlight.largeVideoDownloadCount >= largeVideoDownloadCap,
           !inFlightAloneAllowsOversized(candidate, inFlight)
        {
            return .failure(.largeVideoDownloadCap)
        }
        let size = estimatedBytes(candidate.sourceSize)
        if inFlight.downloadCount > 0, inFlight.downloadBytes + size > downloadByteBudget {
            if inFlightAloneAllowsOversized(candidate, inFlight) {
                return .success(())
            }
            return .failure(.downloadByteBudget)
        }
        return .success(())
    }

    func canDispatchEnrichment(
        candidate: Candidate,
        inFlight: InFlightSnapshot
    ) -> Result<Void, Rejection> {
        guard inFlight.enrichCount < enrichConcurrency else {
            return .failure(.enrichCountCap)
        }
        if candidate.isVideo, inFlight.videoEnrichCount >= videoEnrichCap, inFlight.enrichCount > 0 {
            return .failure(.videoEnrichCap)
        }
        let size = estimatedBytes(candidate.sourceSize)
        if inFlight.enrichCount > 0, inFlight.enrichBytes + size > enrichByteBudget {
            // Viewport may overcommit once when nothing else holds enrich bytes.
            if candidate.isViewportOrDevice, inFlight.enrichBytes == 0 {
                return .success(())
            }
            return .failure(.enrichByteBudget)
        }
        return .success(())
    }

    func isLargeVideo(_ candidate: Candidate) -> Bool {
        candidate.isVideo && estimatedBytes(candidate.sourceSize) >= largeVideoThresholdBytes
    }

    /// Unknown size is a small background unit so it remains dispatchable and
    /// cannot deadlock behind a byte budget it cannot satisfy.
    func estimatedBytes(_ sourceSize: Int64?) -> Int64 {
        max(sourceSize ?? (4 * 1024 * 1024), 0)
    }

    private func inFlightAloneAllowsOversized(
        _ candidate: Candidate,
        _ inFlight: InFlightSnapshot
    ) -> Bool {
        inFlight.downloadCount == 0 && estimatedBytes(candidate.sourceSize) > downloadByteBudget / 2
    }
}

/// Retained name for existing call sites/tests; forwards to the concrete policy.
nonisolated enum EnrichmentDownloadSchedulingPolicy {
    static func canDispatchDownload(
        isViewportWork: Bool,
        inFlightDownloadCount: Int,
        downloadConcurrency: Int
    ) -> Bool {
        let policy = EnrichmentAdmissionPolicy.production
        var tuned = policy
        tuned.downloadConcurrency = downloadConcurrency
        let result = tuned.canDispatchDownload(
            candidate: EnrichmentAdmissionPolicy.Candidate(
                sourceSize: 1,
                isVideo: false,
                isViewportOrDevice: isViewportWork,
                rootPath: LibraryRootPath(rawValue: "/"),
                isEagerBackground: !isViewportWork
            ),
            inFlight: EnrichmentAdmissionPolicy.InFlightSnapshot(
                downloadCount: inFlightDownloadCount,
                enrichCount: 0,
                downloadBytes: 0,
                enrichBytes: 0,
                largeVideoDownloadCount: 0,
                videoEnrichCount: 0,
                eagerDownloadCountByRoot: [:]
            )
        )
        if case .success = result {
            return true
        }
        return false
    }
}
