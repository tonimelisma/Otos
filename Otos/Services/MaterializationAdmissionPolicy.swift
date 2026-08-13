import Foundation

/// Pure admission rules for deliberate provider materialization.
///
/// `MaterializationCoordinator` owns queueing and lifecycle. This value answers only
/// whether one already-selected request fits beside the current physical transfers.
nonisolated struct MaterializationAdmissionPolicy: Equatable, Sendable {
    enum Rejection: String, Equatable, Hashable, Sendable {
        case globalConcurrency
        case backgroundReserve
        case byteBudget
        case largeVideoCap
        case rootBackgroundCap
        case providerBreakerOpen
        case interactivePriority
    }

    struct Snapshot: Equatable, Sendable {
        var count: Int
        var bytes: Int64
        var largeVideoCount: Int
        var backgroundByRoot: [LibraryRootPath: Int]

        static let empty = Snapshot(count: 0, bytes: 0, largeVideoCount: 0, backgroundByRoot: [:])
        var isEmpty: Bool {
            count < 1
        }
    }

    var globalConcurrency: Int
    var byteBudget: Int64
    var largeVideoThresholdBytes: Int64
    var largeVideoCap: Int
    var backgroundPerRootCap: Int

    static let production = MaterializationAdmissionPolicy(
        globalConcurrency: 16,
        byteBudget: 2 * 1024 * 1024 * 1024,
        largeVideoThresholdBytes: 256 * 1024 * 1024,
        largeVideoCap: 2,
        backgroundPerRootCap: 1
    )

    func rejection(
        for request: MaterializationCoordinator.Request,
        inFlight: Snapshot
    ) -> Rejection? {
        guard inFlight.count < globalConcurrency else {
            return .globalConcurrency
        }
        if request.priority == .background,
           inFlight.count >= max(globalConcurrency - 1, 0)
        {
            return .backgroundReserve
        }
        if request.priority == .background,
           inFlight.backgroundByRoot[request.id.libraryRootPath, default: 0] >= backgroundPerRootCap
        {
            return .rootBackgroundCap
        }
        if isLargeVideo(request), inFlight.largeVideoCount >= largeVideoCap,
           !allowsOversizedSolo(request, inFlight: inFlight)
        {
            return .largeVideoCap
        }
        let bytes = estimatedBytes(request.sourceSize)
        if !inFlight.isEmpty, inFlight.bytes + bytes > byteBudget,
           !allowsOversizedSolo(request, inFlight: inFlight)
        {
            return .byteBudget
        }
        return nil
    }

    func estimatedBytes(_ sourceSize: Int64?) -> Int64 {
        max(sourceSize ?? (4 * 1024 * 1024), 0)
    }

    func isLargeVideo(_ request: MaterializationCoordinator.Request) -> Bool {
        request.isVideo && estimatedBytes(request.sourceSize) >= largeVideoThresholdBytes
    }

    private func allowsOversizedSolo(
        _ request: MaterializationCoordinator.Request,
        inFlight: Snapshot
    ) -> Bool {
        inFlight.isEmpty && estimatedBytes(request.sourceSize) > byteBudget / 2
    }
}
