import Foundation
@testable import OtosKit
import Testing

/// The scheduler's waits, driven by the instants they cover. Each transition takes `now`
/// as an argument, so a 900-second pacing window is crossed by passing an instant past it.
struct EnrichmentScheduleTests {
    private let start = ContinuousClock.now
    private let root = LibraryRootPath(rawValue: "/library")

    private func id(_ name: String, root: LibraryRootPath? = nil) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root ?? self.root, relativePath: MediaRelativePath(rawValue: name))
    }

    private func work(
        _ id: MediaAssetID,
        sourceSize: Int64? = 100,
        isVideo: Bool = false,
        isDeviceStaging: Bool = false,
        captureLocalTime: CaptureLocalTime? = nil,
        attemptCount: Int = 0
    ) -> EnrichmentCoordinator.DownloadWork {
        EnrichmentCoordinator.DownloadWork(
            id: id, url: id.fileURL, sourceSize: sourceSize, captureLocalTime: captureLocalTime,
            isVideo: isVideo, isDeviceStaging: isDeviceStaging, attemptCount: attemptCount
        )
    }

    private func submitAll(_ schedule: inout EnrichmentSchedule, at now: ContinuousClock.Instant) -> [MediaAssetID] {
        schedule.takeSubmissions(globalLimit: 16, backgroundPerRoot: 16, viewport: [], now: now).map(\.id)
    }

    /// ENR-008: a cloud download held by the free-space floor spends no attempt and keeps its
    /// claim, held until the space recheck offers it again, without limit. Held, it is not
    /// outstanding, so it holds back no other row's hand-off.
    @Test func cloudDownloadHeldByTheFloorKeepsItsClaimAndRechecks() throws {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("a.jpg")
        schedule.demand(work(row), ownsStoreClaim: true, outstandingLimit: 16)
        #expect(submitAll(&schedule, at: start) == [row])
        let pending = try #require(schedule.materializations[row]?.work)
        let finished = schedule.finish(pending, outcome: .insufficientLocalSpace, now: start)
        let settlement = try #require(finished)
        let recheck = start.advanced(by: EnrichmentRetrySchedule.production.spaceRecheck)
        let entry = EnrichmentCoordinator.RetryLedgerEntry(notBefore: recheck, attemptCount: 0, sourceSize: 100)
        #expect(settlement == EnrichmentSchedule.Settlement(disposition: .paced(entry), releasesStoreClaim: false))
        #expect(schedule.materializations[row]?.isHeld == true)
        #expect(schedule.outstandingCount == 0)
        #expect(schedule.heldCount == 1)
        #expect(schedule.retryLedger[row] == nil, "the hold is the demand's, not the ledger's")
        #expect(schedule.nextWake(after: start) == recheck)
        #expect(submitAll(&schedule, at: recheck.advanced(by: .milliseconds(-1))).isEmpty)
        #expect(submitAll(&schedule, at: recheck) == [row])
        #expect(schedule.materializations[row]?.work.attemptCount == 0)
    }

    /// A claimed row the hand-off has no slot for is held with its claim and handed off when a
    /// slot frees, never given back to be claimed again.
    @Test func aRowWithNoSlotIsHeldAndHandedOffWhenOneFrees() throws {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let first = id("a.jpg")
        let second = id("b.jpg")
        schedule.demand(work(first), ownsStoreClaim: true, outstandingLimit: 16)
        schedule.demand(work(second), ownsStoreClaim: true, outstandingLimit: 1)
        #expect(schedule.outstandingCount == 1)
        #expect(schedule.heldCount == 1)
        let taken = schedule.takeSubmissions(globalLimit: 1, backgroundPerRoot: 1, viewport: [], now: start)
        #expect(taken.count == 1)
        let inFlight = try #require(taken.first)
        _ = schedule.finish(inFlight, outcome: .materialized, now: start)
        let next = schedule.takeSubmissions(globalLimit: 1, backgroundPerRoot: 1, viewport: [], now: start)
        #expect(next.count == 1)
        #expect(Set([inFlight.id] + next.map(\.id)) == [first, second])
        #expect(schedule.heldCount == 0)
    }

    /// ENR-009: background materialization retries in-window on the shipped schedule, and
    /// the failure after the last delay holds the row, with its claim, for the pacing.
    @Test func backgroundRetriesFollowTheScheduleThenPaceThroughTheLedger() throws {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("a.jpg")
        schedule.demand(work(row), ownsStoreClaim: true, outstandingLimit: 16)
        var now = start
        for delay in EnrichmentRetrySchedule.production.backgroundDownloadDelays {
            let submissions = schedule.takeSubmissions(globalLimit: 16, backgroundPerRoot: 2, viewport: [], now: now)
            let submitted = try #require(submissions.first)
            let finished = schedule.finish(submitted, outcome: .requestFailed, now: now)
            let settlement = try #require(finished)
            guard case let .retrying(retry) = settlement.disposition else {
                Issue.record("Expected an in-window retry, got \(settlement.disposition)")
                return
            }
            #expect(!settlement.releasesStoreClaim)
            #expect(retry.retryNotBefore == now.advanced(by: delay))
            // Not due a moment before its delay; due at it.
            let early = submitAll(&schedule, at: now.advanced(by: delay - .milliseconds(1)))
            #expect(early.isEmpty)
            #expect(schedule.nextWake(after: now) == now.advanced(by: delay))
            now = now.advanced(by: delay)
        }
        let lastSubmissions = schedule.takeSubmissions(globalLimit: 16, backgroundPerRoot: 2, viewport: [], now: now)
        let last = try #require(lastSubmissions.first)
        #expect(last.attemptCount == 4)
        let finished = schedule.finish(last, outcome: .requestFailed, now: now)
        let settlement = try #require(finished)
        #expect(settlement == EnrichmentSchedule.Settlement(
            disposition: .paced(EnrichmentCoordinator.RetryLedgerEntry(
                notBefore: now.advanced(by: .seconds(900)), attemptCount: 4, sourceSize: 100
            )),
            releasesStoreClaim: false
        ))
        // Held, with its claim, for the pacing; then a fresh set of in-window retries.
        #expect(schedule.outstandingCount == 0)
        #expect(schedule.heldCount == 1)
        #expect(schedule.nextWake(after: now) == now.advanced(by: .seconds(900)))
        let afterPacing = schedule.takeSubmissions(
            globalLimit: 16, backgroundPerRoot: 2, viewport: [], now: now.advanced(by: .seconds(900))
        )
        #expect(afterPacing.map(\.attemptCount) == [0])
    }

    /// ENR-009: the ledger defers a row it paces — one whose source sends the original only
    /// for the user's work — whose source signature matches until its pacing comes due, and a changed signature lets it through at once and drops the entry.
    @Test func ledgerDefersAMatchingSignatureUntilDueAndResetsOnChange() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("a.jpg")
        schedule.pace(row, sourceSize: 100, now: start)

        let beforeDue = schedule.ledgerAdmits(row, sourceSize: 100, now: start.advanced(by: .seconds(899)))
        let atDue = schedule.ledgerAdmits(row, sourceSize: 100, now: start.advanced(by: .seconds(900)))
        #expect(!beforeDue)
        #expect(atDue)
        #expect(schedule.retryLedger[row] != nil, "a due entry still counts the row's paced attempts")

        let changedSource = schedule.ledgerAdmits(row, sourceSize: 999, now: start)
        #expect(changedSource)
        #expect(schedule.retryLedger[row] == nil)
        let afterReset = schedule.ledgerAdmits(row, sourceSize: 100, now: start)
        #expect(afterReset)
    }

    /// ENR-009: success clears the row's ledger entry.
    @Test func materializationSuccessClearsTheLedgerEntry() throws {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("a.jpg")
        schedule.pace(row, sourceSize: 100, now: start)
        #expect(schedule.retryLedger[row]?.attemptCount == 1)

        schedule.demand(work(row), ownsStoreClaim: true, outstandingLimit: 16)
        _ = submitAll(&schedule, at: start)
        let finished = schedule.finish(work(row), outcome: .materialized, now: start)
        let settlement = try #require(finished)
        #expect(settlement == EnrichmentSchedule.Settlement(disposition: .materialized, releasesStoreClaim: true))
        #expect(schedule.retryLedger[row] == nil)
    }

    /// ENR-009: cancellation releases the claim without consuming an attempt or pacing.
    @Test func cancelledMaterializationReleasesItsClaimWithoutRetry() throws {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("a.jpg")
        schedule.demand(work(row), ownsStoreClaim: true, outstandingLimit: 16)
        _ = submitAll(&schedule, at: start)
        let finished = schedule.finish(work(row), outcome: .cancelled, now: start)
        let settlement = try #require(finished)
        #expect(settlement == EnrichmentSchedule.Settlement(disposition: .cancelled, releasesStoreClaim: true))
        #expect(schedule.outstandingCount == 0)
        #expect(schedule.retryLedger.isEmpty)
        #expect(schedule.nextWake(after: start) == nil)
    }

    /// Device staging backs off per attempt and gives up as unobtainable; waiting for disk
    /// space retries without limit. A device seed holds no Store claim to release.
    @Test func deviceStagingGivesUpAfterItsAttemptsButWaitsOutDiskSpace() throws {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("IMG_1.ARW", root: LibraryRootPath(rawValue: "/DeviceStaging/Camera"))
        schedule.demand(work(row, isDeviceStaging: true), ownsStoreClaim: false, outstandingLimit: 16)
        var now = start
        for attempt in 1 ..< EnrichmentRetrySchedule.production.deviceAttemptLimit {
            let pending = try #require(schedule.materializations[row]?.work)
            let submitted = submitAll(&schedule, at: now)
            #expect(submitted == [row])
            let finished = schedule.finish(pending, outcome: .requestFailed, now: now)
            let settlement = try #require(finished)
            #expect(settlement.disposition == .retrying(EnrichmentCoordinator.DownloadWork(
                id: row, url: row.fileURL, sourceSize: 100, captureLocalTime: nil, isVideo: false,
                isDeviceStaging: true, attemptCount: attempt,
                retryNotBefore: now.advanced(by: .seconds(5) * attempt)
            )))
            now = now.advanced(by: .seconds(5) * attempt)
        }
        let finalWork = try #require(schedule.materializations[row]?.work)
        _ = submitAll(&schedule, at: now)
        let givenUp = schedule.finish(finalWork, outcome: .requestFailed, now: now)
        #expect(givenUp == EnrichmentSchedule.Settlement(disposition: .unobtainable, releasesStoreClaim: false))

        schedule.demand(work(row, isDeviceStaging: true, attemptCount: 40), ownsStoreClaim: false, outstandingLimit: 16)
        _ = submitAll(&schedule, at: now)
        let spaceFinished = schedule.finish(
            work(row, isDeviceStaging: true, attemptCount: 40), outcome: .insufficientLocalSpace, now: now
        )
        let spaceWait = try #require(spaceFinished)
        guard case let .retrying(retry) = spaceWait.disposition else {
            Issue.record("Waiting for disk space must retry, got \(spaceWait.disposition)")
            return
        }
        #expect(retry.retryNotBefore == now.advanced(by: .seconds(60)))
    }

    /// ENR-011: visible rows go first, then device staging, then background work; within
    /// each, stills before videos and newest capture first. Background transfers stay
    /// within their per-root bound.
    @Test func submissionsOrderVisibleThenDeviceThenBackgroundWithinBounds() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let device = LibraryRootPath(rawValue: "/DeviceStaging/Camera")
        let video = id("clip.mov", root: device)
        let older = id("older.jpg", root: device)
        let newer = id("newer.jpg", root: device)
        let background = (0 ..< 3).map { id("bg-\($0).jpg") }
        let visible = id("visible.jpg")
        schedule.demand(work(video, isVideo: true, isDeviceStaging: true), ownsStoreClaim: false, outstandingLimit: 16)
        schedule.demand(
            work(older, isDeviceStaging: true, captureLocalTime: CaptureLocalTime(seconds: 100)),
            ownsStoreClaim: false,
            outstandingLimit: 16
        )
        schedule.demand(
            work(newer, isDeviceStaging: true, captureLocalTime: CaptureLocalTime(seconds: 200)),
            ownsStoreClaim: false,
            outstandingLimit: 16
        )
        for row in background {
            schedule.demand(work(row), ownsStoreClaim: true, outstandingLimit: 16)
        }
        schedule.demand(work(visible), ownsStoreClaim: true, outstandingLimit: 16)

        // The viewport may list a row twice; it is still one transfer.
        let submitted = schedule.takeSubmissions(
            globalLimit: 16, backgroundPerRoot: 2, viewport: [visible, visible], now: start
        ).map(\.id)

        // The visible row is background work on /library, so it takes one of its two slots.
        #expect(submitted == [visible, newer, older, video, background[0]])
        #expect(schedule.inFlightCount == 5)
        #expect(schedule.waitingCount == 2)
    }

    /// ENR-011 (B2): a readiness deferral set when a row reads `.unknown` is spent when
    /// the row is probed again. One a pass never reached is dropped when the pass ends —
    /// left behind, it would be a deadline in the past and the wake delay zero forever.
    @Test func aPassDropsReadinessDeferralsItDidNotReach() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("stale.arw")
        schedule.deferReadinessProbe(row, now: start)
        #expect(schedule.nextWake(after: start) == start.advanced(by: .seconds(1)))

        let passStart = start.advanced(by: .seconds(30))
        schedule.endPass(at: passStart)

        #expect(schedule.readinessRechecks.isEmpty)
        #expect(schedule.nextWake(after: passStart) == nil)
    }

    /// The prune removes only what is behind the pass: a deferral that has not come due
    /// is live, and it is what the next wake is for.
    @Test func aPassKeepsReadinessDeferralsThatHaveNotComeDue() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("parked.arw")
        schedule.deferReadinessProbe(row, now: start)
        let early = schedule.readinessProbeIsDue(row, now: start.advanced(by: .milliseconds(999)))
        #expect(!early)

        schedule.endPass(at: start.advanced(by: .milliseconds(500)))

        #expect(schedule.nextWake(after: start.advanced(by: .milliseconds(500))) == start.advanced(by: .seconds(1)))
        let due = schedule.readinessProbeIsDue(row, now: start.advanced(by: .seconds(1)))
        #expect(due)
        #expect(schedule.readinessRechecks.isEmpty)
    }

    /// B2 at the trigger that produced the spin: demand saturated at the outstanding limit
    /// with every transfer in flight. Nothing waiting on those can wake the loop — their
    /// completions do — so a past deferral leaves no wake at all, never one in the past.
    @Test func saturatedDemandWithAPastDeferralNeverWakesInThePast() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let camera = LibraryRootPath(rawValue: "/DeviceStaging/BigCamera")
        for index in 0 ..< 16 {
            schedule.demand(work(id("saturate_\(index).arw", root: camera), isDeviceStaging: true), ownsStoreClaim: false, outstandingLimit: 16)
        }
        let saturated = submitAll(&schedule, at: start)
        #expect(saturated.count == 16)
        schedule.deferReadinessProbe(id("never_reached.arw", root: camera), now: start.advanced(by: .seconds(-5)))

        schedule.endPass(at: start)

        #expect(schedule.nextWake(after: start) == nil)
    }

    /// A failed catalog write schedules one retry wake; a second failure before it fires
    /// keeps the first, and the pass it wakes spends it.
    @Test func aFailedCatalogWriteSchedulesOneRetryWake() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        schedule.catalogWriteFailed(now: start)
        schedule.catalogWriteFailed(now: start.advanced(by: .seconds(2)))
        #expect(schedule.nextWake(after: start) == start.advanced(by: .seconds(5)))

        schedule.endPass(at: start.advanced(by: .seconds(5)))

        #expect(schedule.writeRetryAt == nil)
        #expect(schedule.nextWake(after: start.advanced(by: .seconds(5))) == nil)
    }

    /// B1: identical scheduler passes collapse into a count reported with the next
    /// transition, so a spinning scheduler cannot flood the unified log.
    @Test func identicalSchedulerPassesCollapseIntoASuppressedCount() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let idle = SchedulerRouteFacts(
            claimed: 0, readyQueued: 0, enriching: 0, materializationPending: 0,
            materializationInFlight: 0, pendingApply: 0, dispatched: 0, limit: 32, deferred: 0
        )
        let busy = SchedulerRouteFacts(
            claimed: 4, readyQueued: 0, enriching: 4, materializationPending: 0,
            materializationInFlight: 0, pendingApply: 0, dispatched: 4, limit: 32, deferred: 0
        )

        let lines = [idle, idle, idle, busy, idle].map { schedule.routeLine(for: $0) }

        // The first pass is a transition and is reported; the repeats are only counted,
        // and the next transition carries them.
        #expect(lines == [0, nil, nil, 2, 0])
    }
}

extension EnrichmentScheduleTests {
    /// ADR 0047: while the face model cannot be loaded, no claim hands out a video's faces,
    /// and the hold is a wait the scheduler wakes for, spent once it passes. A held claim
    /// covers everything else it covers: a library's other products, an account's metadata.
    @Test func aMissingFaceModelHoldsEveryVideosFacesUntilItsBackoffPasses() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        #expect(schedule.videoFaces(at: start) == .admitted)

        schedule.holdVideoFaces(now: start)
        let backoff = EnrichmentRetrySchedule.production.faceModelBackoff
        #expect(schedule.videoFaces(at: start) == .held)
        #expect(schedule.nextWake(after: start) == start.advanced(by: backoff))

        let after = start.advanced(by: backoff)
        #expect(schedule.videoFaces(at: after) == .admitted)
        schedule.endPass(at: after)
        #expect(schedule.videoFacesHeldUntil == nil)

        #expect(EnrichmentClaim.library.admitting(.held) == .products)
        #expect(EnrichmentClaim.account.admitting(.held) == .metadata)
        for claim in EnrichmentClaim.allCases {
            #expect(claim.admitting(.admitted) == claim)
        }
        #expect(EnrichmentClaim.metadata.admitting(.held) == .metadata)
        #expect(EnrichmentClaim.products.admitting(.held) == .products)
    }
}
