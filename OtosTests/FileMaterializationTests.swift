import Foundation
@testable import OtosKit
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
                probe: { _ async in .inconclusive }
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
                probe: { _ async in .inconclusive }
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
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: true,
                deadline: .seconds(10),
                requestRetryInterval: .milliseconds(20)
            ),
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in },
                probe: { _ async in .providerUnavailable }
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
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: true,
                deadline: .milliseconds(80),
                requestRetryInterval: .milliseconds(20)
            ),
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in },
                probe: { _ async in
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

    /// The oracle for plan 0102.
    ///
    /// A provider that is merely slow returns `ETIMEDOUT` on the one-byte probe exactly as
    /// a dead one does, so the two-strike short-circuit abandoned the image in front of the
    /// user. Measured 2026-08-31: 43 interactive requests failed between 2402 ms and
    /// 5539 ms against a 120 s budget, while the slowest *successful* materialization in
    /// the same window took 62,316 ms. Healthy hydration on this library reaches 8.9 s
    /// (research 2026-07-11) — inside the 3 s probe timeout's blind spot.
    ///
    /// Interactive persistence must therefore outlast an unbroken run of refusals and still
    /// deliver when the bytes land. Fails before this change; the probe is not even called.
    @Test func interactiveMaterializationOutlastsAnUnbrokenRunOfProviderRefusals() async {
        let probes = Mutex(0)
        let polls = Mutex(0)
        let result = await FileMaterialization.materialize(
            URL(fileURLWithPath: "/tmp/slow-provider.arw"),
            pollInterval: .milliseconds(1),
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: false,
                deadline: nil,
                requestRetryInterval: .milliseconds(1)
            ),
            providers: FileMaterializationProviders(
                status: { _ in
                    // Arrives only after far more polling than the fail-fast would allow.
                    let seen = polls.withLock { (count: inout Int) -> Int in
                        count += 1
                        return count
                    }
                    return seen < 200 ? .dataless : .materialized
                },
                request: { _ in },
                probe: { _ async in
                    probes.withLock { $0 += 1 }
                    return .providerUnavailable
                }
            )
        )

        #expect(
            result.outcome == .materialized,
            "an interactive request must wait out a slow provider, not read it as a refusal"
        )
        #expect(
            probes.withLock { $0 } == 0,
            "the probe is a faulting one-byte read whose only consumer was the short-circuit"
        )
    }

    /// The other half, so the change is scoped rather than global: background keeps PR 172's
    /// behaviour exactly, because its reason still holds — a background transfer squatting
    /// `rootBackgroundCap=1` blocks every other candidate for that root.
    @Test func backgroundMaterializationStillShortCircuitsOnTheSameInput() async {
        let result = await FileMaterialization.materialize(
            URL(fileURLWithPath: "/tmp/slow-provider.arw"),
            pollInterval: .milliseconds(1),
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: true,
                deadline: .seconds(10),
                requestRetryInterval: .milliseconds(1)
            ),
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in },
                probe: { _ async in .providerUnavailable }
            )
        )

        #expect(result.outcome == .providerUnavailable)
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
