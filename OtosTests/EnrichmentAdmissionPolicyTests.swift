import Foundation
@testable import OtosKit
import Testing

/// ENR-009: the video cap holds back background videos only; a video on screen is admitted
/// while two background videos read.
struct EnrichmentAdmissionPolicyTests {
    private let busyWithTwoVideos = EnrichmentAdmissionPolicy.InFlightSnapshot(
        enrichCount: 2, enrichBytes: 2 * 1024 * 1024, videoEnrichCount: 2
    )

    @Test func aBackgroundVideoWaitsBehindTheVideoCap() {
        let candidate = EnrichmentAdmissionPolicy.Candidate(sourceSize: 1024 * 1024, isVideo: true, isViewportOrDevice: false)
        let admission = EnrichmentAdmissionPolicy.production.canDispatchEnrichment(candidate: candidate, inFlight: busyWithTwoVideos)
        guard case .failure(.videoEnrichCap) = admission else {
            Issue.record("expected the video cap, got \(admission)")
            return
        }
    }

    // Validates: ENR-009
    @Test func aVideoOnScreenIsNeverHeldByTheVideoCap() {
        let candidate = EnrichmentAdmissionPolicy.Candidate(sourceSize: 1024 * 1024, isVideo: true, isViewportOrDevice: true)
        let admission = EnrichmentAdmissionPolicy.production.canDispatchEnrichment(candidate: candidate, inFlight: busyWithTwoVideos)
        guard case .success = admission else {
            Issue.record("expected admission, got \(admission)")
            return
        }
    }
}
