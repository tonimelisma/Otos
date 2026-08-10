import Foundation
@testable import Otos
import Synchronization
import Testing

/// These tests cover the two states reproducible without a cloud provider: a local
/// file is always materialized, and a missing path is unknown. The `.dataless`
/// result cannot be produced in a unit test because only a File Provider can create
/// a dataless placeholder; that branch was validated against a real OneDrive library
/// during the spec's proof of concept (see
/// `docs/specs/0016-cloud-materialization-detection.md`).
struct FileMaterializationTests {
    @Test func materializationOutcomeDiagnosticsClassifyTerminalStates() {
        #expect(MaterializationOutcome.alreadyMaterialized.isMaterialized)
        #expect(MaterializationOutcome.materialized.isMaterialized)
        #expect(!MaterializationOutcome.requestFailed.isMaterialized)
        #expect(!MaterializationOutcome.timedOut.isMaterialized)
        #expect(!MaterializationOutcome.insufficientLocalSpace.isMaterialized)
        #expect(MaterializationOutcome.insufficientLocalSpace.diagnosticDescription == "insufficientLocalSpace")
        #expect(MaterializationOutcome.statusUnavailable.diagnosticDescription == "statusUnavailable")

        let result = MaterializationResult(outcome: .materialized, rerequestCount: 2, elapsedMs: 123)
        #expect(result.isMaterialized)
        #expect(result.rerequestCount == 2)
        #expect(result.elapsedMs == 123)
    }

    @Test func localFileIsMaterialized() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "otos-materialization-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "local.bin")
        try Data([0x01, 0x02, 0x03]).write(to: file)

        // A freshly written local file has its bytes on disk, so it is never a
        // dataless placeholder.
        #expect(FileMaterialization.status(of: file) == .materialized)
    }

    @Test func missingFileIsUnknown() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "otos-missing-\(UUID().uuidString).bin")

        #expect(FileMaterialization.status(of: missing) == .unknown)
    }

    /// Returns before the poll loop ever runs, so nothing here awaits real time: no
    /// `Task.sleep`, no deadline, nothing that can race scheduler load.
    @Test func alreadyMaterializedSkipsPolling() async {
        let url = URL(fileURLWithPath: "/tmp/otos-already-materialized-\(UUID().uuidString).jpg")
        let result = await FileMaterialization.materialize(
            url,
            providers: FileMaterializationProviders(
                status: { _ in .materialized },
                request: { _ in Issue.record("should not request a download when already materialized") },
                probe: { _ in .inconclusive }
            )
        )
        #expect(result.outcome == .alreadyMaterialized)
        #expect(result.rerequestCount == 0)
    }

    /// Also returns before the poll loop: the initial request fails synchronously.
    @Test func initialRequestFailureSkipsPolling() async {
        let url = URL(fileURLWithPath: "/tmp/otos-request-failure-\(UUID().uuidString).jpg")
        struct ProbeError: Error {}
        let result = await FileMaterialization.materialize(
            url,
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in throw ProbeError() },
                probe: { _ in .inconclusive }
            )
        )
        #expect(result.outcome == .requestFailed)
        #expect(result.rerequestCount == 0)
    }

    @Test func providerUnavailableShortCircuitsAfterTwoConsecutiveProbes() async {
        let url = URL(fileURLWithPath: "/tmp/otos-provider-unavailable-\(UUID().uuidString).jpg")
        // Simulate dataless that never materializes and provider probe returns
        // providerUnavailable twice consecutively — poll should exit early with
        // .providerUnavailable, not wait for the 120s timeout.
        let result = await FileMaterialization.materialize(
            url,
            pollInterval: .milliseconds(10),
            timeout: .seconds(10),
            requestRetryInterval: .milliseconds(20),
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in },
                probe: { _ in .providerUnavailable }
            )
        )
        #expect(result.outcome == .providerUnavailable)
        // Two retryNow ticks → two re-requests + two probes → short-circuit
        #expect(result.rerequestCount == 2)
    }

    @Test func singleTransientProviderUnavailableDoesNotShortCircuit() async {
        let url = URL(fileURLWithPath: "/tmp/otos-transient-\(UUID().uuidString).jpg")
        let probeCalls = AtomicCounter()
        let result = await FileMaterialization.materialize(
            url,
            pollInterval: .milliseconds(10),
            timeout: .milliseconds(80),
            requestRetryInterval: .milliseconds(20),
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in },
                probe: { _ in
                    let c = probeCalls.next()
                    // First probe unavailable, second inconclusive (healed), then unavailable again
                    // Never two in a row → should time out, not providerUnavailable
                    return c == 1 ? .providerUnavailable : .inconclusive
                }
            )
        )
        #expect(result.outcome == .timedOut)
    }

    private final class AtomicCounter: Sendable {
        private let storage = Mutex(0)
        func next() -> Int {
            storage.withLock { $0 += 1
                return $0
            }
        }
    }
}

/// Covers the polling retry/timeout bookkeeping that
/// `materializationRerequestsUntilProviderClearsDataless` used to exercise indirectly
/// through three real `Task.sleep` calls inside a fixed wall-clock deadline — flaky
/// under a loaded parallel `script/verify.sh` run because the cooperative pool can
/// stall any one of those sleeps arbitrarily. `materializationPollDecision` is pure
/// (no clock reads, no I/O), so every case here is driven by synthetic instants built
/// with `Instant.advanced(by:)` off a single real sample — no waiting, ever.
struct MaterializationPollDecisionTests {
    @Test func materializedStatusStopsRegardlessOfRetryTiming() {
        let now = ContinuousClock().now
        #expect(
            FileMaterialization.materializationPollDecision(
                now: now,
                nextRetry: now.advanced(by: .seconds(1)),
                status: .materialized
            ) == .materialized
        )
    }

    @Test func datalessBeforeNextRetryWaits() {
        let now = ContinuousClock().now
        #expect(
            FileMaterialization.materializationPollDecision(
                now: now,
                nextRetry: now.advanced(by: .milliseconds(1)),
                status: .dataless
            ) == .waitMore
        )
    }

    @Test func datalessAtOrPastNextRetryRetriesNow() {
        let now = ContinuousClock().now
        #expect(
            FileMaterialization.materializationPollDecision(
                now: now,
                nextRetry: now,
                status: .dataless
            ) == .retryNow
        )
        #expect(
            FileMaterialization.materializationPollDecision(
                now: now.advanced(by: .milliseconds(1)),
                nextRetry: now,
                status: .dataless
            ) == .retryNow
        )
    }

    @Test func unknownStatusStopsPolling() {
        let now = ContinuousClock().now
        #expect(
            FileMaterialization.materializationPollDecision(
                now: now,
                nextRetry: now,
                status: .unknown
            ) == .statusUnavailable
        )
    }

    /// Same scenario `materializationRerequestsUntilProviderClearsDataless` asserted
    /// (materializes on the 3rd request, 2 retries counted), driven synchronously
    /// against the pure decision function instead of a real polling loop.
    @Test func retriesTwiceThenReportsMaterializedOnThirdRequest() {
        let retryInterval = Duration.milliseconds(1)
        let base = ContinuousClock().now
        var nextRetry = base.advanced(by: retryInterval)
        var rerequestCount = 0
        var requestCount = 1 // the initial pre-loop request `materialize` always issues
        let materializesOnRequest = 3

        var tick = base
        var finalDecision: MaterializationPollDecision?
        while finalDecision != .materialized {
            tick = tick.advanced(by: retryInterval)
            let status: FileMaterializationStatus = requestCount >= materializesOnRequest ? .materialized : .dataless
            let decision = FileMaterialization.materializationPollDecision(
                now: tick,
                nextRetry: nextRetry,
                status: status
            )
            switch decision {
            case .materialized:
                finalDecision = .materialized
            case .retryNow:
                rerequestCount += 1
                requestCount += 1
                nextRetry = tick.advanced(by: retryInterval)
            case .waitMore, .statusUnavailable:
                Issue.record("expected only retryNow ticks before materialization in this fixture")
                return
            }
        }

        #expect(rerequestCount == 2)
        #expect(requestCount == 3)
    }
}
