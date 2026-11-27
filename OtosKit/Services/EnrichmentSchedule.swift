import Foundation

/// When enrichment's waits come due. `production` is the shipped schedule; a test passes
/// its own so a retry path runs to its end without waiting real minutes.
nonisolated struct EnrichmentRetrySchedule: Equatable, Sendable {
    /// In-window background materialization retries, one delay per failed attempt. The
    /// failure after the last one hands the row to the pacing ledger.
    var backgroundDownloadDelays: [Duration]
    /// How long the ledger keeps a row whose in-window retries are exhausted from being
    /// claimed again, unless its source changes.
    var ledgerPacing: Duration
    /// How long a row whose readiness the filesystem could not report waits before it is
    /// probed again.
    var readinessRecheck: Duration
    /// A download held back by the free-space floor is offered again this often, without
    /// limit: it is a waiting condition, not a failure. time: poll — macOS reports no
    /// free-space change at an app-defined threshold (research 2026-09-09, finding 3).
    var spaceRecheck: Duration
    /// Device staging failure backoff, multiplied by the attempt number.
    var deviceFailureBackoff: Duration
    /// Device staging attempts before the item is given up as unobtainable.
    var deviceAttemptLimit: Int
    /// After a catalog write fails, the wait before the scheduler wakes to retry it.
    var writeFailureBackoff: Duration
    /// After the face model could not be loaded, how long no row is read for a video's faces.
    /// The model reports nothing when it would load, so this is a backoff.
    var faceModelBackoff: Duration = .seconds(900)

    static let production = EnrichmentRetrySchedule(
        backgroundDownloadDelays: [.seconds(15), .seconds(60), .seconds(300), .seconds(900)],
        ledgerPacing: .seconds(900),
        readinessRecheck: .seconds(1),
        spaceRecheck: .seconds(60),
        deviceFailureBackoff: .seconds(5),
        deviceAttemptLimit: 3,
        writeFailureBackoff: .seconds(5)
    )
}

/// The enrichment scheduler's process-local waits: materialization demands, the pacing
/// ledger, readiness rechecks, the catalog-write retry, and the scheduler-route log's
/// dedupe.
///
/// A value with synchronous transitions (ADR 0032 rule 1). `EnrichmentCoordinator` holds
/// one, applies each event to it on the actor, and acts on what the transition returns —
/// releasing a Store claim, marking a source unreadable, logging. Every instant comes in
/// as an argument, so each wait is exercised by passing the instant it covers rather than
/// by sleeping until it arrives.
///
/// The coordinator wakes for all of these waits through one deadline: `nextWake(after:)`
/// is the earliest one ahead of the instant a pass started from. A wait at or behind that
/// instant was this pass's to act on, so it never schedules a wake, and a wake can never
/// be in the past.
nonisolated struct EnrichmentSchedule: Sendable {
    typealias DownloadWork = EnrichmentCoordinator.DownloadWork
    typealias RetryLedgerEntry = EnrichmentCoordinator.RetryLedgerEntry

    /// One row's materialization: the transfer it waits for or has in flight, and whether it
    /// holds the row's Store enrichment claim (a device seed holds none).
    ///
    /// A held demand is one the hand-off cannot take now, and it keeps its Store claim while
    /// it waits. The blocked state lives here, with the owner of the hand-off, so the row is
    /// not claimed and given back on every pass to rediscover it, a claim write and a release
    /// write each time. A held demand is not outstanding: it does not stop a device seed or a
    /// local row from being admitted. Every hold names the fact that ends it (`Hold`), and
    /// every demand, held or not, also ends when its row or its root goes (`withdraw`).
    struct Materialization: Equatable, Sendable {
        var work: DownloadWork
        let ownsStoreClaim: Bool
        var isInFlight: Bool
        var hold: Hold?
        /// The row or its root went while its transfer ran: the transfer's result settles
        /// nothing but the demand's end (`MaterializationDisposition.withdrawn`).
        var isWithdrawn = false

        var isHeld: Bool {
            hold != nil
        }
    }

    /// Why a demand waits outside the outstanding count, by the fact that ends the wait.
    enum Hold: Equatable, Sendable {
        /// No transfer slot was free when it was demanded: ends when one frees
        /// (`takeSubmissions`).
        case transferSlot
        /// The free-space floor turned it away: ends at its recheck (`spaceRecheck`,
        /// time: poll).
        case freeSpace
        /// Its in-window retries are spent: ends when the pacing passes (`ledgerPacing`,
        /// time: backoff), or at once when its source changes (`reconcile`).
        case pacing
    }

    /// What became of a finished materialization.
    enum MaterializationDisposition: Equatable, Sendable {
        /// Cancelled: says nothing about the provider, so no attempt is consumed.
        case cancelled
        /// Failed in-window; the demand waits for its next attempt.
        case retrying(DownloadWork)
        case materialized
        /// Device staging exhausted its attempts: these bytes cannot be obtained.
        case unobtainable
        /// Background retries exhausted: the ledger paces the row's next claim.
        case paced(RetryLedgerEntry)
        /// The row or its root went while the transfer ran: nothing follows it.
        case withdrawn
    }

    /// What finishing a materialization asks of the coordinator.
    struct Settlement: Equatable, Sendable {
        let disposition: MaterializationDisposition
        /// The demand held the row's Store claim and no longer does; the coordinator
        /// releases it.
        let releasesStoreClaim: Bool
    }

    let retrySchedule: EnrichmentRetrySchedule
    /// The active demands: in flight, outstanding, or held for a transfer slot. Every pass
    /// reads these, so their count is bounded by the hand-off and each root's claim window.
    private(set) var materializations: [MediaAssetID: Materialization] = [:]
    /// The demands parked until a deadline: waiting out the pacing after their in-window
    /// retries, or the free-space recheck. A failing or full-disk library can park any number
    /// of rows, so no pass reads them: they come back into `materializations`, their root's room
    /// at a time, when their deadline passes (`unparkDue`), and the next wake is the earliest
    /// of them (`parkedEarliest`).
    private(set) var parked: [MediaAssetID: Materialization] = [:]
    private(set) var parkedEarliest: ContinuousClock.Instant?
    private(set) var retryLedger: [MediaAssetID: RetryLedgerEntry] = [:]
    private(set) var readinessRechecks: [MediaAssetID: ContinuousClock.Instant] = [:]
    private(set) var writeRetryAt: ContinuousClock.Instant?
    /// Until when no row is claimed for a video's faces, because the face model could not be
    /// loaded (`holdVideoFaces`, `videoFaces(at:)`).
    private(set) var videoFacesHeldUntil: ContinuousClock.Instant?
    /// Last emitted scheduler-route facts, and how many identical passes have been
    /// collapsed since (B1). The route line was once unconditional, so a scheduler spinning
    /// at zero delay emitted hundreds of identical `dispatched=0` lines per second: the
    /// 2026-08-30 camera session peaked at 2,336 lines/second and the unified log dropped
    /// ~836 download completions, which produced a false diagnosis of a wedged pipeline.
    private var lastRoute: SchedulerRouteFacts?
    private(set) var suppressedRoutes = 0

    init(retrySchedule: EnrichmentRetrySchedule) {
        self.retrySchedule = retrySchedule
    }

    // MARK: - Materialization demands

    /// The demands the hand-off has taken: in flight, or waiting for a slot it promised.
    var outstandingCount: Int {
        materializations.values.count { !$0.isHeld }
    }

    var inFlightCount: Int {
        materializations.values.count(where: \.isInFlight)
    }

    var waitingCount: Int {
        outstandingCount - inFlightCount
    }

    /// The demands held until a slot frees, the floor lets them through, or their pacing ends.
    var heldCount: Int {
        materializations.values.count(where: \.isHeld) + parked.count
    }

    /// Each root's active demands that hold a Store claim and are not in flight: held for a
    /// slot, or waiting for a slot or an in-window retry. Each is claimed work that has not
    /// started, so it takes a place in its root's claim window (`EnrichmentClaimRoom`).
    /// Outside it, every pass would claim a window's more rows to hold, until every row of a
    /// cloud-only library was held and each pass walked them all.
    var claimedWaitingByRoot: [LibraryRootPath: Int] {
        var counts: [LibraryRootPath: Int] = [:]
        for (id, demand) in materializations where demand.ownsStoreClaim && !demand.isInFlight {
            counts[id.libraryRootPath, default: 0] += 1
        }
        return counts
    }

    var hasDemands: Bool {
        !materializations.isEmpty || !parked.isEmpty
    }

    func hasDemand(for id: MediaAssetID) -> Bool {
        materializations[id] != nil || parked[id] != nil
    }

    /// Brings back the parked demands whose deadline is at or behind `now`, earliest first,
    /// as many as each one's root has `room` for, held for a transfer slot with their claim;
    /// returns their rows. The rest stay parked, and the earliest deadline still ahead is the
    /// next wake.
    mutating func unparkDue(now: ContinuousClock.Instant, room: EnrichmentClaimRoom) -> [MediaAssetID] {
        guard let earliest = parkedEarliest, earliest <= now else {
            return []
        }
        let due = parked.filter { ($0.value.work.retryNotBefore ?? now) <= now }
            .sorted { ($0.value.work.retryNotBefore ?? now) < ($1.value.work.retryNotBefore ?? now) }
        var taken: [LibraryRootPath: Int] = [:]
        var unparked: [MediaAssetID] = []
        for (id, record) in due where taken[id.libraryRootPath, default: 0] < room.room(for: id.libraryRootPath) {
            taken[id.libraryRootPath, default: 0] += 1
            parked[id] = nil
            var active = record
            active.hold = .transferSlot
            materializations[id] = active
            unparked.append(id)
        }
        parkedEarliest = parked.values.compactMap(\.work.retryNotBefore).min()
        return unparked
    }

    func hasInFlightWork(under rootPath: LibraryRootPath) -> Bool {
        materializations.contains { $0.key.libraryRootPath == rootPath && $0.value.isInFlight }
    }

    func inFlightCount(under rootPath: LibraryRootPath) -> Int {
        materializations.count { $0.key.libraryRootPath == rootPath && $0.value.isInFlight }
    }

    /// Records that a row needs its bytes before it can be enriched, and returns whether it
    /// was held for want of a transfer slot. It replaces any record for the row: a row whose
    /// enrichment found it dataless after an earlier demand finished is demanded afresh.
    /// Below `outstandingLimit` the demand is outstanding, a slot the hand-off promises; at
    /// it, the row keeps its claim and is held until a slot frees (`takeSubmissions`), never
    /// claimed and given back to wait.
    @discardableResult
    mutating func demand(_ work: DownloadWork, ownsStoreClaim: Bool, outstandingLimit: Int) -> Bool {
        let held = outstandingCount >= outstandingLimit
        materializations[work.id] = Materialization(
            work: work,
            ownsStoreClaim: ownsStoreClaim,
            isInFlight: false,
            hold: held ? .transferSlot : nil
        )
        return held
    }

    /// The active demands' rows, in flight or not; parked rows are not among them.
    var activeIDs: [MediaAssetID] {
        Array(materializations.keys)
    }

    /// Every claim the demands hold, parked ones included: what shutdown gives back.
    var claimedIDs: [MediaAssetID] {
        materializations.compactMap { $0.value.ownsStoreClaim ? $0.key : nil }
            + parked.compactMap { $0.value.ownsStoreClaim ? $0.key : nil }
    }

    /// Ends the demands `ends` names: their row or their root is gone, or the root no longer
    /// lets enrichment read it. A demand not in flight is dropped; one in flight is marked
    /// withdrawn and ends when its transfer comes back (`finish`), so the slot it holds is
    /// counted until then. Parked demands are read only `includingParked`: a pass asks of the
    /// active ones alone, and the parked ones when the fact could reach them (a root's change).
    /// Returns how many were dropped now, and those whose Store claim the demand held, for the
    /// coordinator to give back.
    mutating func withdraw(
        includingParked: Bool = true,
        where ends: (MediaAssetID, Materialization) -> Bool
    ) -> (dropped: Int, claimsToRelease: [MediaAssetID]) {
        var dropped = 0
        var claims: [MediaAssetID] = []
        for (id, record) in materializations where !record.isWithdrawn && ends(id, record) {
            if record.isInFlight {
                materializations[id]?.isWithdrawn = true
                continue
            }
            materializations[id] = nil
            dropped += 1
            if record.ownsStoreClaim {
                claims.append(id)
            }
        }
        if includingParked {
            let ending = parked.filter { ends($0.key, $0.value) }
            for (id, record) in ending {
                parked[id] = nil
                dropped += 1
                if record.ownsStoreClaim {
                    claims.append(id)
                }
            }
            if !ending.isEmpty {
                parkedEarliest = parked.values.compactMap(\.work.retryNotBefore).min()
            }
        }
        return (dropped, claims)
    }

    /// Applies what the Store reports of the rows in `checked`: `sources` holds each row it
    /// still offers, with its current byte size. A row it no longer offers is withdrawn. A row
    /// whose size changed is other bytes than the ones the demand failed on, so its attempts
    /// and its pacing start over, as the ledger's changed signature does (ENR-007); a wait for
    /// free space keeps its recheck, since other bytes need the space as much. A demand made
    /// after the read started is not in `checked` and is left alone. Returns the claims to
    /// give back.
    mutating func reconcile(sources: [MediaAssetID: Int64?], checked: [MediaAssetID]) -> [MediaAssetID] {
        var claims: [MediaAssetID] = []
        var parkedChanged = false
        for id in checked where sources[id] == nil {
            if let record = materializations[id], !record.isWithdrawn {
                if record.isInFlight {
                    materializations[id]?.isWithdrawn = true
                } else {
                    materializations[id] = nil
                    if record.ownsStoreClaim {
                        claims.append(id)
                    }
                }
            } else if let record = parked.removeValue(forKey: id) {
                parkedChanged = true
                if record.ownsStoreClaim {
                    claims.append(id)
                }
            }
        }
        for id in checked {
            // A parked row whose source changed is due at once: other bytes, a fresh start.
            if let size = sources[id], let record = parked[id], record.work.sourceSize != size {
                parked[id] = nil
                parkedChanged = true
                var active = record
                active.hold = .transferSlot
                materializations[id] = active
            }
            guard let size = sources[id], var record = materializations[id], !record.isWithdrawn,
                  record.work.sourceSize != size
            else {
                continue
            }
            let work = record.work
            let keepsWait = record.isInFlight || record.hold == .freeSpace
            record.work = DownloadWork(
                id: work.id,
                url: work.url,
                sourceSize: size,
                captureLocalTime: work.captureLocalTime,
                isVideo: work.isVideo,
                isDeviceStaging: work.isDeviceStaging,
                attemptCount: keepsWait ? work.attemptCount : 0,
                retryNotBefore: keepsWait ? work.retryNotBefore : nil,
                showsFirstThumbnail: work.showsFirstThumbnail
            )
            if record.hold == .pacing {
                record.hold = .transferSlot
            }
            materializations[id] = record
            retryLedger[id] = nil
        }
        if parkedChanged {
            parkedEarliest = parked.values.compactMap(\.work.retryNotBefore).min()
        }
        return claims
    }

    /// Picks the demands to hand to the materializer now and marks them in flight:
    /// visible rows first, then device staging, then background work, each ordered still
    /// before video, newest capture first. A demand whose retry has not come due at `now`
    /// waits, and background work stays within `backgroundPerRoot` transfers per root.
    mutating func takeSubmissions(
        globalLimit: Int,
        backgroundPerRoot: Int,
        viewport: [MediaAssetID],
        now: ContinuousClock.Instant
    ) -> [DownloadWork] {
        var available = max(globalLimit - inFlightCount, 0)
        let ready = materializations.values
            .filter { !$0.isInFlight && $0.work.isDue(at: now) }
            .map(\.work)
        var seen: Set<MediaAssetID> = []
        let visible = viewport.compactMap { id in
            seen.insert(id).inserted ? ready.first { $0.id == id } : nil
        }
        let visibleIDs = Set(visible.map(\.id))
        let rest = ready.filter { !visibleIDs.contains($0.id) }
        let ordered = visible
            + rest.filter(\.isDeviceStaging).sorted(by: Self.downloadPrecedes)
            + rest.filter { !$0.isDeviceStaging }.sorted(by: Self.downloadPrecedes)
        var selected: [DownloadWork] = []
        for work in ordered where available > 0 {
            if !work.isDeviceStaging,
               backgroundInFlightCount(under: work.id.libraryRootPath) >= backgroundPerRoot
            {
                continue
            }
            materializations[work.id]?.isInFlight = true
            materializations[work.id]?.hold = nil
            selected.append(work)
            available -= 1
        }
        return selected
    }

    /// Settles a finished transfer. Returns nil when the row has no demand — it was
    /// dropped by a drain, or the coordinator is past it.
    mutating func finish(
        _ work: DownloadWork,
        outcome: MaterializationOutcome,
        now: ContinuousClock.Instant
    ) -> Settlement? {
        guard let record = materializations[work.id] else {
            return nil
        }
        if record.isWithdrawn {
            materializations[work.id] = nil
            return Settlement(disposition: .withdrawn, releasesStoreClaim: record.ownsStoreClaim)
        }
        if outcome == .cancelled {
            materializations[work.id] = nil
            return Settlement(disposition: .cancelled, releasesStoreClaim: record.ownsStoreClaim)
        }
        if outcome == .insufficientLocalSpace, !work.isDeviceStaging {
            // A cloud download held by the free-space floor spends no attempt and is held,
            // with its claim, until the recheck offers it again. Held, it is not outstanding,
            // so enrichment of files already local is not stuck behind a full disk.
            let entry = RetryLedgerEntry(
                notBefore: now.advanced(by: retrySchedule.spaceRecheck),
                attemptCount: work.attemptCount,
                sourceSize: work.sourceSize,
                cause: .diskFull
            )
            holdUntil(entry.notBefore, work, attemptCount: work.attemptCount, hold: .freeSpace, record: record)
            return Settlement(disposition: .paced(entry), releasesStoreClaim: false)
        }
        if let retry = retry(after: work, outcome: outcome, now: now) {
            materializations[work.id] = Materialization(
                work: retry,
                ownsStoreClaim: record.ownsStoreClaim,
                isInFlight: false,
                hold: nil
            )
            return Settlement(disposition: .retrying(retry), releasesStoreClaim: false)
        }
        materializations[work.id] = nil
        if outcome.isMaterialized {
            retryLedger[work.id] = nil
            return Settlement(disposition: .materialized, releasesStoreClaim: record.ownsStoreClaim)
        }
        if work.isDeviceStaging {
            return Settlement(disposition: .unobtainable, releasesStoreClaim: record.ownsStoreClaim)
        }
        // The in-window retries are spent: the row is held, with its claim, for the pacing,
        // and then starts a fresh set of retries. It ends sooner when the row or its root goes
        // (`withdraw`) or its source changes (`reconcile`).
        let entry = RetryLedgerEntry(
            notBefore: now.advanced(by: retrySchedule.ledgerPacing),
            attemptCount: work.attemptCount,
            sourceSize: work.sourceSize,
            cause: .downloadsFailed
        )
        holdUntil(entry.notBefore, work, attemptCount: 0, hold: .pacing, record: record)
        return Settlement(disposition: .paced(entry), releasesStoreClaim: false)
    }

    /// Parks a finished transfer's demand until `notBefore`, keeping whatever claim it held.
    private mutating func holdUntil(
        _ notBefore: ContinuousClock.Instant,
        _ work: DownloadWork,
        attemptCount: Int,
        hold: Hold,
        record: Materialization
    ) {
        materializations[work.id] = nil
        parkedEarliest = min(parkedEarliest ?? notBefore, notBefore)
        parked[work.id] = Materialization(
            work: DownloadWork(
                id: work.id,
                url: work.url,
                sourceSize: work.sourceSize,
                captureLocalTime: work.captureLocalTime,
                isVideo: work.isVideo,
                isDeviceStaging: work.isDeviceStaging,
                attemptCount: attemptCount,
                retryNotBefore: notBefore,
                showsFirstThumbnail: work.showsFirstThumbnail
            ),
            ownsStoreClaim: record.ownsStoreClaim,
            isInFlight: false,
            hold: hold
        )
    }

    /// The next attempt for a failed transfer, or nil when its in-window attempts are
    /// spent. Background work follows `backgroundDownloadDelays`; device staging backs off
    /// per attempt up to `deviceAttemptLimit`, except that waiting for disk space is
    /// retried without limit.
    private func retry(
        after work: DownloadWork,
        outcome: MaterializationOutcome,
        now: ContinuousClock.Instant
    ) -> DownloadWork? {
        guard !outcome.isMaterialized else {
            return nil
        }
        let attemptCount = work.attemptCount + 1
        let delay: Duration
        if work.isDeviceStaging {
            if outcome == .insufficientLocalSpace {
                delay = retrySchedule.spaceRecheck
            } else {
                guard attemptCount < retrySchedule.deviceAttemptLimit else {
                    return nil
                }
                delay = retrySchedule.deviceFailureBackoff * attemptCount
            }
        } else {
            let delays = retrySchedule.backgroundDownloadDelays
            guard attemptCount <= delays.count else {
                return nil
            }
            delay = delays[attemptCount - 1]
        }
        return DownloadWork(
            id: work.id,
            url: work.url,
            sourceSize: work.sourceSize,
            captureLocalTime: work.captureLocalTime,
            isVideo: work.isVideo,
            isDeviceStaging: work.isDeviceStaging,
            attemptCount: attemptCount,
            retryNotBefore: now.advanced(by: delay),
            showsFirstThumbnail: work.showsFirstThumbnail
        )
    }

    private func backgroundInFlightCount(under rootPath: LibraryRootPath) -> Int {
        materializations.count { id, record in
            record.isInFlight && !record.work.isDeviceStaging && id.libraryRootPath == rootPath
        }
    }

    private static func downloadPrecedes(_ left: DownloadWork, _ right: DownloadWork) -> Bool {
        if left.isVideo != right.isVideo {
            return !left.isVideo
        }
        switch (left.captureLocalTime, right.captureLocalTime) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate > rightDate
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return left.id.relativePathPrecedes(right.id)
        }
    }

    // MARK: - Pacing ledger

    /// Holds a row that `cause` stopped, for `ledgerPacing`, so it is not claimed again until
    /// then (`ledgerAdmits`). `holdingClaim` when the row's Store claim passes to the ledger
    /// rather than back to the Store (`holdPacedClaims`).
    mutating func pace(
        _ id: MediaAssetID,
        sourceSize: Int64?,
        cause: OwnerTrouble.Cause,
        now: ContinuousClock.Instant,
        holdingClaim: Bool = false,
        showsFirstThumbnail: Bool = false
    ) {
        retryLedger[id] = RetryLedgerEntry(
            notBefore: now.advanced(by: retrySchedule.ledgerPacing),
            attemptCount: (retryLedger[id]?.attemptCount ?? 0) + 1,
            sourceSize: sourceSize,
            cause: cause,
            holdsStoreClaim: holdingClaim,
            showsFirstThumbnail: showsFirstThumbnail
        )
    }

    /// The row's read landed: the ledger no longer paces it. A row the ledger paces stays
    /// there until then, so the ledger's entries are the rows held back now.
    mutating func endPacing(_ id: MediaAssetID) {
        retryLedger[id] = nil
    }

    /// The rows that wait out a failure before they are read again, or are being read again,
    /// apart by whether their tile still shows a placeholder: the pacing ledger's rows it holds
    /// back now — not yet due, holding their Store claim, or claimed again and being read
    /// (`isClaimed`) — since a row stays in the ledger until its next read lands; transfers
    /// parked after failing or turned away by the free-space floor; and transfers that failed
    /// before and wait for, or are in, their next attempt. A due entry whose row no claim holds
    /// is not counted: its row may no longer be owed at all (gone, or its facts written another
    /// way), and nothing would remove it. `userWorkOnly` counts the ledger's rows whose source
    /// sends them only for the user's work: no background read can do them, so they are no
    /// work left at all (`OwnerTrouble.Standing.userWorkOnly`).
    func parkedRows(at now: ContinuousClock.Instant, isClaimed: (MediaAssetID) -> Bool) -> ParkedRows {
        var rows = ParkedRows()
        for (id, entry) in retryLedger where entry.notBefore > now || entry.holdsStoreClaim || isClaimed(id) {
            if entry.cause.standing == .userWorkOnly {
                rows.add(\.userWorkOnly, showsFirstThumbnail: entry.showsFirstThumbnail)
            } else {
                rows.add(\.parked, showsFirstThumbnail: entry.showsFirstThumbnail)
            }
        }
        for record in parked.values
            where !record.work.isDeviceStaging && (record.hold == .pacing || record.hold == .freeSpace)
        {
            rows.add(\.parked, showsFirstThumbnail: record.work.showsFirstThumbnail)
        }
        for record in materializations.values where !record.work.isDeviceStaging && record.work.attemptCount > 0 {
            rows.add(\.parked, showsFirstThumbnail: record.work.showsFirstThumbnail)
        }
        return rows
    }

    /// What stops rows at `now`, by cause, in `OwnerTrouble.Cause` order: rows the ledger
    /// paces, transfers parked after failing or turned away by the free-space floor, transfers
    /// waiting for an in-window retry, and every video's faces while the face model is missing.
    /// A transfer waiting only for a slot is not stopped: it is queued.
    func troubles(at now: ContinuousClock.Instant) -> [OwnerTrouble] {
        var counts: [OwnerTrouble.Cause: Int] = [:]
        for entry in retryLedger.values where entry.notBefore > now {
            counts[entry.cause, default: 0] += 1
        }
        for record in parked.values where record.work.retryNotBefore.map({ $0 > now }) ?? true {
            switch record.hold {
            case .pacing: counts[.downloadsFailed, default: 0] += 1
            case .freeSpace: counts[.diskFull, default: 0] += 1
            case .transferSlot, nil: break
            }
        }
        for record in materializations.values where !record.isInFlight {
            if let retry = record.work.retryNotBefore, retry > now {
                counts[.downloadsFailed, default: 0] += 1
            }
        }
        var troubles = OwnerTrouble.Cause.allCases.compactMap { cause in
            counts[cause].map { OwnerTrouble(cause, count: $0) }
        }
        if let held = videoFacesHeldUntil, held > now {
            troubles.append(OwnerTrouble(.faceModelUnavailable))
        }
        return troubles
    }

    /// Keeps the Store claims of paced rows a claim just found (`ledgerAdmits` said no): the
    /// row cannot progress until its pacing passes, so its claim stays out of the Store, and
    /// no later pass claims it only to give it back — a claim write and a release write each
    /// time, at every completion's pass, for every paced row ahead of real work in the
    /// Store's order (ADR 0032 rule 8). The hold ends when the pacing passes
    /// (`releaseDuePacedClaims`), or sooner when its source may have moved or its root is no
    /// longer offered (`endPacedClaims`). A row the ledger does not pace is not held.
    mutating func holdPacedClaims(_ ids: [MediaAssetID]) {
        for id in ids {
            retryLedger[id]?.holdsStoreClaim = true
        }
    }

    /// The paced rows whose claim the ledger holds and whose pacing has passed at `now`: their
    /// claims go back to the Store, which offers them to the next claim, and the ledger admits
    /// them then. time: backoff — the wake is the ledger's deadline (`nextWake`).
    mutating func releaseDuePacedClaims(now: ContinuousClock.Instant) -> [MediaAssetID] {
        var due: [MediaAssetID] = []
        for (id, entry) in retryLedger where entry.holdsStoreClaim && entry.notBefore <= now {
            retryLedger[id]?.holdsStoreClaim = false
            due.append(id)
        }
        return due
    }

    /// Ends the claim holds of the paced rows `ends` names, and returns them for their claims
    /// to go back: a change that may have resized one (its source may differ, which the
    /// ledger compares when it is claimed again, ENR-007), or a root no longer offered. Their
    /// pacing stays.
    mutating func endPacedClaims(where ends: (MediaAssetID) -> Bool) -> [MediaAssetID] {
        var ended: [MediaAssetID] = []
        for (id, entry) in retryLedger where entry.holdsStoreClaim && ends(id) {
            retryLedger[id]?.holdsStoreClaim = false
            ended.append(id)
        }
        return ended
    }

    /// Whether the ledger holds `id`'s Store claim: a row on screen it holds is not asked of
    /// the Store until the hold ends.
    func holdsPacedClaim(_ id: MediaAssetID) -> Bool {
        retryLedger[id]?.holdsStoreClaim == true
    }

    /// The rows whose Store claim the ledger holds: what shutdown gives back.
    var pacedClaimIDs: [MediaAssetID] {
        retryLedger.compactMap { $0.value.holdsStoreClaim ? $0.key : nil }
    }

    /// Whether a row the Store just claimed may proceed at `now`. A row the ledger paces
    /// waits until its entry comes due, unless its `sourceSize` — the ledger's fragment of
    /// the `(size, mtime)` source signature (ENR-007) — changed since the entry was
    /// written, which drops the entry and lets it through at once.
    mutating func ledgerAdmits(_ id: MediaAssetID, sourceSize: Int64?, now: ContinuousClock.Instant) -> Bool {
        guard let entry = retryLedger[id] else {
            return true
        }
        if entry.sourceSize != sourceSize {
            retryLedger[id] = nil
            return true
        }
        return entry.notBefore <= now
    }

    // MARK: - Video faces while the model is missing

    /// Holds every video's faces for `faceModelBackoff`: no video can be read for them while the
    /// face model cannot be loaded, so reading one after another would download and decode
    /// every library video for nothing, and claiming one for them would write its claim and
    /// its release for nothing.
    mutating func holdVideoFaces(now: ContinuousClock.Instant) {
        videoFacesHeldUntil = now.advanced(by: retrySchedule.faceModelBackoff)
    }

    /// Whether a claim at `now` may hand out a video's faces: the one answer the coordinator
    /// passes to every Store claim, so a held video is never claimed for them, rather than
    /// claimed and given back.
    func videoFaces(at now: ContinuousClock.Instant) -> VideoFacesAdmission {
        guard let held = videoFacesHeldUntil, held > now else {
            return .admitted
        }
        return .held
    }

    // MARK: - Readiness rechecks

    /// Whether a claimed row's readiness may be probed at `now`. A row deferred until
    /// later is not; otherwise its deferral, if any, is spent.
    mutating func readinessProbeIsDue(_ id: MediaAssetID, now: ContinuousClock.Instant) -> Bool {
        if let recheckAt = readinessRechecks[id], recheckAt > now {
            return false
        }
        readinessRechecks[id] = nil
        return true
    }

    /// Defers a row whose readiness the filesystem could not report.
    mutating func deferReadinessProbe(_ id: MediaAssetID, now: ContinuousClock.Instant) {
        readinessRechecks[id] = now.advanced(by: retrySchedule.readinessRecheck)
    }

    // MARK: - Catalog write retry

    /// Schedules one wake to retry after a failed catalog write; a retry already
    /// scheduled stands.
    mutating func catalogWriteFailed(now: ContinuousClock.Instant) {
        if writeRetryAt == nil {
            writeRetryAt = now.advanced(by: retrySchedule.writeFailureBackoff)
        }
    }

    // MARK: - Pass end and wake

    /// Ends a pass that started at `now`, dropping the waits it has spent.
    ///
    /// A readiness deferral is set when a row reads `.unknown` and spent when that row is
    /// probed again, so one at or behind `now` belongs to a row this pass did not reach —
    /// and waiting cannot change that, because nothing happens at a deadline already
    /// behind it. Device staging guarantees the case rather than merely allowing it: while
    /// a camera stages, demand sits saturated at the outstanding limit and every pass
    /// stops early. A due catalog-write retry is spent by the pass that woke for it.
    mutating func endPass(at now: ContinuousClock.Instant) {
        readinessRechecks = readinessRechecks.filter { $0.value > now }
        if let writeRetryAt, writeRetryAt <= now {
            self.writeRetryAt = nil
        }
        if let videoFacesHeldUntil, videoFacesHeldUntil <= now {
            self.videoFacesHeldUntil = nil
        }
    }

    /// The earliest wait still ahead of `now`, or nil when nothing waits. Due work needs no
    /// wake: a pass from `now` handles it, and a completion signals the coordinator when
    /// capacity frees.
    func nextWake(after now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        let downloads = materializations.values.compactMap { $0.isInFlight ? nil : $0.work.retryNotBefore }
        let deadlines = downloads
            + retryLedger.values.map(\.notBefore)
            + readinessRechecks.values
            + [writeRetryAt, videoFacesHeldUntil, parkedEarliest].compactMap(\.self)
        return deadlines.filter { $0 > now }.min()
    }

    // MARK: - Scheduler-route log

    /// The number of identical passes to report with these facts, or nil when they repeat
    /// the last line and are only counted. Every field is a level, not an event; a
    /// transition is always reported, including the one to all-zero, so the quiet state is
    /// visible rather than inferred from silence.
    mutating func routeLine(for facts: SchedulerRouteFacts) -> Int? {
        guard facts != lastRoute else {
            suppressedRoutes += 1
            return nil
        }
        let suppressed = suppressedRoutes
        lastRoute = facts
        suppressedRoutes = 0
        return suppressed
    }
}

private extension EnrichmentCoordinator.DownloadWork {
    nonisolated func isDue(at now: ContinuousClock.Instant) -> Bool {
        guard let retryNotBefore else {
            return true
        }
        return retryNotBefore <= now
    }
}

/// Rows enrichment holds back, by kind of work they owe (`EnrichmentSchedule.parkedRows`):
/// those whose tile still shows a placeholder (`showing…`) and the rest (`details…`).
nonisolated struct ParkedRows: Equatable, Sendable {
    struct Counts: Equatable, Sendable {
        /// Rows waiting out a failure, or being tried again.
        var parked = 0
        /// Rows only the user's work can read (ADR 0046 §4).
        var userWorkOnly = 0
    }

    var showing = Counts()
    var details = Counts()

    mutating func add(_ count: WritableKeyPath<Counts, Int>, showsFirstThumbnail: Bool) {
        if showsFirstThumbnail {
            showing[keyPath: count] += 1
        } else {
            details[keyPath: count] += 1
        }
    }
}
