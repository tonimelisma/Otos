import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// These tests cover the two states reproducible without a cloud provider: a local
/// file is always materialized, and a missing path is unknown. The `.dataless`
/// result cannot be produced in a unit test because only a File Provider can create
/// a dataless placeholder; that branch was validated against a real OneDrive library
/// (see `docs/research/2026-07-11-onedrive-materialization-fsevents.md`).
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
                probe: { _ async in .inconclusive },
                changes: noAttributeChanges
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
                probe: { _ async in .inconclusive },
                changes: noAttributeChanges
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
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: true,
                deadline: .seconds(10),
                requestRetryInterval: .milliseconds(20)
            ),
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in },
                probe: { _ async in .providerUnavailable },
                changes: noAttributeChanges
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
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: true,
                deadline: .milliseconds(80),
                requestRetryInterval: .milliseconds(20)
            ),
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in },
                probe: { _ async in
                    let call = probeCalls.next()
                    // First probe unavailable, second inconclusive (healed), then unavailable again
                    // Never two in a row → should time out, not providerUnavailable
                    return call == 1 ? .providerUnavailable : .inconclusive
                },
                changes: noAttributeChanges
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

    /// The oracle for APP-023's persistence rule.
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
                },
                changes: noAttributeChanges
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
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: true,
                deadline: .seconds(10),
                requestRetryInterval: .milliseconds(1)
            ),
            providers: FileMaterializationProviders(
                status: { _ in .dataless },
                request: { _ in },
                probe: { _ async in .providerUnavailable },
                changes: noAttributeChanges
            )
        )

        #expect(result.outcome == .providerUnavailable)
    }

    /// Arrival is reported, not polled for: an attribute change on the file wakes the
    /// wait, which reads the flag and returns, with the next re-request an hour away.
    @Test func anAttributeChangeEndsTheWaitBeforeAnyRerequest() async throws {
        let arrived = Mutex(false)
        let statusReads = Mutex(0)
        let sink = Mutex<AsyncStream<Void>.Continuation?>(nil)
        let wait = Task {
            await FileMaterialization.materialize(
                URL(fileURLWithPath: "/tmp/otos-arrival-\(UUID().uuidString).jpg"),
                persistence: FileMaterialization.Persistence(
                    failsFastOnProviderUnavailable: false,
                    deadline: nil,
                    requestRetryInterval: .seconds(3600)
                ),
                providers: FileMaterializationProviders(
                    status: { _ in
                        statusReads.withLock { $0 += 1 }
                        return arrived.withLock { $0 } ? .materialized : .dataless
                    },
                    request: { _ in },
                    probe: { _ async in .inconclusive },
                    changes: { _ in
                        let (stream, continuation) = AsyncStream<Void>.makeStream()
                        sink.withLock { $0 = continuation }
                        return stream
                    }
                )
            )
        }
        // One read before the request, one on the wait's own first look.
        try await waitUntil { statusReads.withLock { $0 } >= 2 }

        arrived.withLock { $0 = true }
        try #require(sink.withLock { $0 }).yield()

        let result = await wait.value
        #expect(result.outcome == .materialized)
        #expect(result.rerequestCount == 0)
    }

    /// The live watch reports a change to a file's attributes through an event-only
    /// descriptor. `chmod` stands in for the kernel clearing `SF_DATALESS`, which only a
    /// File Provider can do.
    @Test func attributeChangesReportsAnAttributeChangeOnAFile() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "otos-watch-\(UUID().uuidString).jpg")
        try Data("jpeg".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let changes = FileMaterialization.attributeChanges(of: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    /// A file that cannot be watched leaves the re-request schedule to wake the wait.
    @Test func attributeChangesFinishesAtOnceForAMissingFile() async {
        let changes = FileMaterialization.attributeChanges(
            of: URL(fileURLWithPath: "/tmp/otos-missing-\(UUID().uuidString).jpg")
        )
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

/// Covers the re-request bookkeeping of one arrival-wait wake.
/// `materializationWakeDecision` is pure (no clock reads, no I/O), so every case here is
/// driven by synthetic instants built with `Instant.advanced(by:)` off a single real
/// sample — no waiting, ever.
struct MaterializationWakeDecisionTests {
    @Test func materializedStatusStopsRegardlessOfRetryTiming() {
        let now = ContinuousClock().now
        #expect(
            FileMaterialization.materializationWakeDecision(
                now: now,
                nextRetry: now.advanced(by: .seconds(1)),
                status: .materialized
            ) == .materialized
        )
    }

    @Test func datalessBeforeNextRetryWaits() {
        let now = ContinuousClock().now
        #expect(
            FileMaterialization.materializationWakeDecision(
                now: now,
                nextRetry: now.advanced(by: .milliseconds(1)),
                status: .dataless
            ) == .waitMore
        )
    }

    @Test func datalessAtOrPastNextRetryRetriesNow() {
        let now = ContinuousClock().now
        #expect(
            FileMaterialization.materializationWakeDecision(
                now: now,
                nextRetry: now,
                status: .dataless
            ) == .retryNow
        )
        #expect(
            FileMaterialization.materializationWakeDecision(
                now: now.advanced(by: .milliseconds(1)),
                nextRetry: now,
                status: .dataless
            ) == .retryNow
        )
    }

    @Test func unknownStatusStopsPolling() {
        let now = ContinuousClock().now
        #expect(
            FileMaterialization.materializationWakeDecision(
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
        var finalDecision: MaterializationWakeDecision?
        while finalDecision != .materialized {
            tick = tick.advanced(by: retryInterval)
            let status: FileMaterializationStatus = requestCount >= materializesOnRequest ? .materialized : .dataless
            let decision = FileMaterialization.materializationWakeDecision(
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

/// A file whose attributes never change: the re-request schedule alone wakes the wait.
private let noAttributeChanges: @Sendable (URL) -> AsyncStream<Void> = { _ in
    AsyncStream { $0.finish() }
}
