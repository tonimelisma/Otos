import Foundation

/// Pure admission rules for byte-reading enrichment after media is local.
/// Materialization capacity and root fairness belong to `MaterializationAdmissionPolicy`.
nonisolated struct EnrichmentAdmissionPolicy: Equatable, Sendable {
    struct InFlightSnapshot: Equatable, Sendable {
        var enrichCount: Int
        var enrichBytes: Int64
        var videoEnrichCount: Int

        static let empty = InFlightSnapshot(enrichCount: 0, enrichBytes: 0, videoEnrichCount: 0)
    }

    struct Candidate: Equatable, Sendable {
        var sourceSize: Int64?
        var isVideo: Bool
        var isViewportOrDevice: Bool
    }

    enum Rejection: Error, Equatable, Hashable, CustomStringConvertible, Sendable {
        case enrichCountCap
        case enrichByteBudget
        case videoEnrichCap

        var description: String {
            switch self {
            case .enrichCountCap: "enrichCountCap"
            case .enrichByteBudget: "enrichByteBudget"
            case .videoEnrichCap: "videoEnrichCap"
            }
        }
    }

    var enrichConcurrency: Int
    var enrichByteBudget: Int64
    var videoEnrichCap: Int

    static let production = EnrichmentAdmissionPolicy(
        enrichConcurrency: 8,
        enrichByteBudget: 1024 * 1024 * 1024,
        videoEnrichCap: 2
    )

    func canDispatchEnrichment(
        candidate: Candidate,
        inFlight: InFlightSnapshot
    ) -> Result<Void, Rejection> {
        guard inFlight.enrichCount < enrichConcurrency else {
            return .failure(.enrichCountCap)
        }
        // The video cap keeps background videos from filling the workers; a video on screen is
        // not background work and never waits behind it.
        if candidate.isVideo, !candidate.isViewportOrDevice, inFlight.videoEnrichCount >= videoEnrichCap,
           inFlight.enrichCount > 0
        {
            return .failure(.videoEnrichCap)
        }
        let size = estimatedBytes(candidate.sourceSize)
        if inFlight.enrichCount > 0, inFlight.enrichBytes + size > enrichByteBudget {
            if candidate.isViewportOrDevice, inFlight.enrichBytes == 0 {
                return .success(())
            }
            return .failure(.enrichByteBudget)
        }
        return .success(())
    }

    /// Unknown size remains a small unit so it cannot deadlock behind an unknown budget.
    func estimatedBytes(_ sourceSize: Int64?) -> Int64 {
        max(sourceSize ?? (4 * 1024 * 1024), 0)
    }
}

/// Bounds enrichment-originated demand before it crosses into physical scheduling.
/// The defaults are derived from materialization admission: one look-ahead beyond
/// each root's active cap, and no more global waiters than global physical slots.
nonisolated struct EnrichmentMaterializationHandoffPolicy: Equatable, Sendable {
    let globalOutstandingLimit: Int
    let backgroundOutstandingPerRoot: Int

    static func production(
        materialization: MaterializationAdmissionPolicy = .production
    ) -> EnrichmentMaterializationHandoffPolicy {
        EnrichmentMaterializationHandoffPolicy(
            globalOutstandingLimit: materialization.globalConcurrency,
            backgroundOutstandingPerRoot: materialization.backgroundPerRootCap + 1
        )
    }
}
