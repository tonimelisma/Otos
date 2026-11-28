import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// These tests cover the two states reproducible without a cloud provider: a local
/// file is always materialized, and a missing path is unknown. The `.dataless`
/// result cannot be produced in a unit test because only a File Provider can create
/// a dataless placeholder; that branch was validated against a real OneDrive library
/// (see `docs/research/2026-07-11-onedrive-materialization-fsevents.md`).
@Suite(.testScope)
struct FileMaterializationTests {
    // Validates: ARC-034
    @Test func localFileIsMaterialized() throws {
        let directory = try makeTestDirectory()

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

    // Validates: ENR-008
    @Test func providerUnavailableShortCircuitsAfterTwoConsecutiveProbes() async {
        let url = URL(fileURLWithPath: "/tmp/otos-provider-unavailable-\(UUID().uuidString).jpg")
        // Simulate dataless that never materializes and provider probe returns
        // providerUnavailable twice consecutively. No deadline: the two refusals are the
        // only way the wait can end, so the outcome cannot depend on how fast the machine
        // is — a wall-clock bound here once returned `.timedOut` under a parallel build.
        let result = await FileMaterialization.materialize(
            url,
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: true,
                deadline: nil,
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

    /// Probes answer unavailable, inconclusive (healed), unavailable: never two refusals
    /// in a row, so the fail-fast must not fire. The bytes arrive once the third probe
    /// has answered, so the wait ends by the file's own report, not by a deadline — a
    /// streak that failed to reset on the healed probe returns `.providerUnavailable`
    /// at the third probe instead.
    @Test func singleTransientProviderUnavailableDoesNotShortCircuit() async {
        let url = URL(fileURLWithPath: "/tmp/otos-transient-\(UUID().uuidString).jpg")
        let answers: [FileMaterializationProbeResult] = [.providerUnavailable, .inconclusive, .providerUnavailable]
        let probeCalls = Mutex(0)
        let result = await FileMaterialization.materialize(
            url,
            persistence: FileMaterialization.Persistence(
                failsFastOnProviderUnavailable: true,
                deadline: nil,
                requestRetryInterval: .milliseconds(1)
            ),
            providers: FileMaterializationProviders(
                status: { _ in
                    probeCalls.withLock { $0 } < answers.count ? .dataless : .materialized
                },
                request: { _ in },
                probe: { _ async in
                    let call = probeCalls.withLock { (count: inout Int) -> Int in
                        count += 1
                        return count
                    }
                    guard call <= answers.count else {
                        Issue.record("probed \(call) times; the bytes had already arrived")
                        return .inconclusive
                    }
                    return answers[call - 1]
                },
                changes: noAttributeChanges
            )
        )
        #expect(result.outcome == .materialized)
        #expect(result.rerequestCount == answers.count)
        #expect(probeCalls.withLock { $0 } == answers.count)
    }

    // Validates: APP-023
    /// APP-023's persistence rule, by construction: a provider that is merely slow returns
    /// `ETIMEDOUT` on a one-byte probe exactly as a dead one does, so a probe or a run of
    /// re-requests abandoned the image in front of the user (measured 2026-08-31: 43
    /// interactive requests failed between 2402 ms and 5539 ms while the slowest successful
    /// one took 62,316 ms), and one re-request that failed ended a download still under way.
    /// Interactive work is one coordinated read instead: no request, no probe, no re-request,
    /// and its outcome is the read's answer — the bytes arrived, it was cancelled, or the
    /// provider refused it.
    @Test func anInteractiveDownloadIsOneCoordinatedReadThatEndsWithItsAnswer() async {
        func download(_ answer: CoordinatedReadAnswer, arrives: Bool) async -> MaterializationResult {
            let arrived = Mutex(false)
            let reads = Mutex(0)
            let result = await FileMaterialization.materialize(
                MaterializationCoordinator.Request(
                    id: MediaAssetID(
                        libraryRootPath: LibraryRootPath(rawValue: "/tmp"),
                        relativePath: MediaRelativePath(rawValue: "slow-provider-\(UUID().uuidString).arw")
                    ),
                    sourceSize: nil, isVideo: false, priority: .interactive
                ),
                providers: FileMaterializationProviders(
                    status: { _ in arrived.withLock { $0 } ? .materialized : .dataless },
                    request: { _ in Issue.record("an interactive download requests nothing") },
                    probe: { _ async in
                        Issue.record("an interactive download probes nothing")
                        return .providerUnavailable
                    },
                    changes: noAttributeChanges,
                    coordinatedRead: { _ async in
                        reads.withLock { $0 += 1 }
                        if arrives {
                            arrived.withLock { $0 = true }
                        }
                        return answer
                    }
                )
            )
            #expect(reads.withLock { $0 } == 1)
            #expect(result.rerequestCount == 0)
            return result
        }

        #expect(await download(.read, arrives: true).outcome == .materialized)
        #expect(await download(.read, arrives: false).outcome == .requestFailed)
        #expect(await download(.failed(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)), arrives: false).outcome
            == .requestFailed)
        #expect(await download(.cancelled, arrives: false).outcome == .cancelled)
    }

    // Validates: APP-023
    /// The production coordinated read grants a read of a file that is there, through a
    /// coordinator on its own queue.
    @Test func aCoordinatedReadOfALocalFileIsGranted() async throws {
        let directory = try makeTestDirectory()
        let file = directory.appending(path: "local.jpg")
        try Data([0xFF, 0xD8]).write(to: file)

        #expect(await FileMaterialization.coordinatedRead(of: file) == .read)
    }

    // Validates: ARC-034
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

    // Validates: ARC-034
    /// The live watch reports a change to a file's attributes through an event-only
    /// descriptor. `chmod` stands in for the kernel clearing `SF_DATALESS`, which only a
    /// File Provider can do.
    @Test func attributeChangesReportsAnAttributeChangeOnAFile() async throws {
        let url = try makeTestDirectory().appending(path: "watched.jpg")
        try Data("jpeg".utf8).write(to: url)

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
}

/// A file whose attributes never change: the re-request schedule alone wakes the wait.
private let noAttributeChanges: @Sendable (URL) -> AsyncStream<Void> = { _ in
    AsyncStream { $0.finish() }
}
