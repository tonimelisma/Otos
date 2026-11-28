import Foundation

/// Pure admission rules for deliberate provider materialization.
///
/// `MaterializationCoordinator` owns queueing and lifecycle. This value answers only
/// whether one already-selected request fits beside the current physical transfers.
nonisolated struct MaterializationAdmissionPolicy: Equatable, Sendable {
    enum Rejection: String, Equatable, Hashable, Sendable {
        case globalConcurrency
        case deviceConcurrency
        case backgroundReserve
        case byteBudget
        case largeVideoCap
        case rootBackgroundCap
        case providerBreakerOpen
        case interactivePriority
        /// The background room holds background downloads now (ADR 0057).
        case machineHeld
    }

    struct Snapshot: Equatable, Sendable {
        var count: Int
        var bytes: Int64
        var largeVideoCount: Int
        var deviceCount: Int
        var backgroundByRoot: [LibraryRootPath: Int]

        static let empty = Snapshot(
            count: 0, bytes: 0, largeVideoCount: 0, deviceCount: 0, backgroundByRoot: [:]
        )
        var isEmpty: Bool {
            count < 1
        }
    }

    var globalConcurrency: Int
    /// How many `.device` transfers may run at once, across every attached device.
    ///
    /// One, and it is not a tuning choice. ImageCaptureCore funnels every request through
    /// a single serial `ICDeviceCommandQueue`: a process sample during the 2026-08-30
    /// session found the app parked inside `requestDownloadWithOptions` for 1,465 of 1,481
    /// samples. Concurrent device requests are therefore not parallelism — they queue
    /// inside a framework where Otos cannot observe, time, or cancel them, and they
    /// measurably cost throughput. Single-stream measured 37.2 MB/s (32 MB ARW) and
    /// 39.9 MB/s (320 MB MP4) against 0.9-8.5 MB/s under the previous 16-way window.
    ///
    /// This is separate from `globalConcurrency` because the finding is about one
    /// transport. Lowering the global cap would throttle cloud and local materialization,
    /// which are genuinely concurrent and were never the problem.
    var deviceConcurrency: Int
    var byteBudget: Int64
    var largeVideoThresholdBytes: Int64
    var largeVideoCap: Int
    /// How many background transfers one root may hold at once. Four is chosen
    /// for draining a cloud library's backlog faster; interactive
    /// work is exempt and keeps its reserved global slot.
    var backgroundPerRootCap: Int

    static let production = MaterializationAdmissionPolicy(
        globalConcurrency: 16,
        deviceConcurrency: 1,
        byteBudget: 2 * 1024 * 1024 * 1024,
        largeVideoThresholdBytes: 256 * 1024 * 1024,
        largeVideoCap: 2,
        backgroundPerRootCap: 4
    )

    func rejection(
        for request: MaterializationCoordinator.Request,
        inFlight: Snapshot
    ) -> Rejection? {
        guard inFlight.count < globalConcurrency else {
            return .globalConcurrency
        }
        // Checked before the priority-specific rules below because it is a transport
        // limit, not a scheduling preference: a second device request cannot proceed
        // regardless of how it is prioritised or how much budget is free.
        if request.priority == .device, inFlight.deviceCount >= deviceConcurrency {
            return .deviceConcurrency
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
