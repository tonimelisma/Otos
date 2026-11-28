import Foundation
import OSLog

// Activity board guide (ADR 0058, `docs/design/activity.md`)
//
// The one owner of "what is Otos doing in the background, and since when": the sidebar's
// Activity line and its popover render what it publishes, and nothing else answers it.
//
// It holds no copy of any owner's state. Each watched owner's `OwnerActivity` rings the
// board's doorbell in the steps that can change whether it works or is held (a request, a
// pass beginning or ending, a settle, a hold set or cleared), and the background room rings it
// when the machine's conditions change (a description's hold is read from the room as of the
// moment it is read, `OwnerActivity.heldNow`). One loop, woken by that doorbell
// (`.bufferingNewest(1)`), reads every watched owner's status as a value — the fact as of that
// read, never a pushed partial state that a later step could leave stale — and applies the
// round synchronously: a kind turning to work records when it started (ADR 0032 rules 1 and
// 3). Each round also reads what stops each owner's work (`QuiescentOwner.troubles`): the
// cause the surface says, which a backoff wake alone never names. Every wake that ends such a
// wait makes its owner work, which rings the board. A round that changes what the board shows
// publishes one snapshot (`.bufferingNewest(1)`, newest wins) and logs it.
//
// A kind is one outcome the user would notice missing (`ActivityKind`): the photos still to
// show, people, places, search, descriptions, duplicates, and — listed only while it works —
// the details read of items that already show. Several owners can serve one kind (the
// duplicate groups and the render signatures they compare), and one owner can serve two
// (enrichment counts the photos still to show and the details still to read apart). An owner
// can also be a kind's detail only (`Watched.Role.detail`): the downloads that let photos show
// are the row's line, never whether it works. An owner that groups a kind's finished items
// (`Watched.Role.grouping`: People's assignment, the duplicate groups) has no count; while only
// it moves the kind, the row says it groups. Bookkeeping owners — the projection, the People
// gallery's tally, the derived folder's launch tidy — are not watched: they are machinery,
// never an outcome (DES-035). Immich accounts report their own status
// (`ImmichAccountStatus`, with a persisted last sync), which the presentation reads beside
// this board's snapshot.
//
// Each kind that works or waits also carries its progress (`ActivityProgress`): the owner of
// the kind that counts its work (`QuiescentOwner.progress(for:)`) is asked how much it has
// finished, how much is left, and how many of those wait out a failure (`parked`) — the
// items it wrote, counted as it writes them, and an exact COUNT over the predicate its walk
// reads. It is asked again only when its work has moved (`OwnerWork`), so a round woken by
// anything else reads no count. A stretch of work keeps its start: `done` is what the owner
// finished since the stretch began and `total` is that plus what is left, so the bar moves
// only as the owner finishes items. An item that leaves the owed set for another reason (its
// facts unsettled again, its row gone) lowers the total and is never counted as done. A failed
// count publishes nothing new; the stretch's start ends when the kind is up to date.
//
// A kind works while an owner of it moves its work: busy, with items left that are not
// parked. Busy alone is not enough: an owner retrying parked items is busy, and a retry that
// fails moves nothing. A kind that cannot move waits, and keeps waiting through its owners'
// retries until it has finished an item more than when it began to wait — a fact its count
// reports, never a time — or nothing of it works or waits, so the row neither flickers
// between working and waiting nor drops what stopped it while a retry runs.
//
// The loop holds the board weakly across its waits and ends with it; `shutdown()` ends it at
// teardown.

/// One background outcome the Activity surface names (DES-035: the user's nouns), each said
/// as what Otos does to give it: something the user would notice missing. Declared in the
/// order the popover lists them.
nonisolated enum ActivityKind: String, CaseIterable, Sendable {
    /// Thumbnails and previews made or remade (`EnrichmentCoordinator`,
    /// `EnrichmentPurpose.thumbnail`), and the downloads of originals that lets
    /// (`MaterializationCoordinator`, a detail of this row). An Immich account's thumbnails
    /// are its sync's.
    case makingThumbnails
    /// The details the Info pane shows, read from each file, or from an account's server
    /// (`EnrichmentCoordinator`, `EnrichmentPurpose.info`), and read again after Otos learned
    /// to read more (`MetadataRefresher`).
    case readingPhotoInfo
    /// Faces detected in stills' previews (`PreviewFaceReader`) and videos' frames
    /// (`EnrichmentCoordinator`, `EnrichmentPurpose.faces`), and grouped into people
    /// (`PeopleAssignment`).
    case scanningFaces
    /// Towns and countries looked up for the map's areas (`PlaceNameReader`).
    case lookingUpPlaces
    /// What search compares a query with, made for each item (`PhotoSearchIndex`).
    case indexingForSearch
    /// Each still's description (`PhotoDescriptionWriter`).
    case writingDescriptions
    /// The duplicate groups, the render signatures they compare (`DuplicatesProjection`,
    /// `RenderSignatureRefresher`) and the digests that tell exact copies apart
    /// (`EnrichmentCoordinator`, `EnrichmentPurpose.copies`).
    case findingDuplicates
}

/// How far one kind's current stretch of work is: `done` of `total` items, exact, and how
/// many of the items left wait out a failure (`parked`).
nonisolated struct ActivityProgress: Equatable, Sendable {
    let done: Int
    let total: Int
    var parked = 0

    var left: Int {
        total - done
    }
}

/// What one kind is doing, as of the board's last round.
nonisolated struct ActivityEntry: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Working since `since`, which orders the line: the work that has run longest.
        case working(since: Date)
        /// Every owner working for it waits on the machine's conditions (ADR 0057).
        case paused(BackgroundHold)
        /// Its work cannot move: something stops it (`troubles`), or every item it has left
        /// waits out a failure. It stays waiting through its owners' retries until an item
        /// finishes (`ActivityBoard`), so a retry that fails changes nothing the user sees.
        case waiting
        /// Nothing of it works or waits.
        case upToDate
    }

    let kind: ActivityKind
    let state: State
    /// What stops work it owes, in its owners' order, whatever its state: a kind can work on
    /// some items while others wait out a failure. While it waits, the last that stopped it
    /// stand through its owners' retries.
    var troubles: [OwnerTrouble] = []
    /// How far its current stretch is, once its counting owner has answered; nil while it is
    /// up to date or no count is known.
    var progress: ActivityProgress?
    /// The run of background downloads its work waits on, while it works: the row's detail,
    /// never a row of its own (a download is a means, not an outcome).
    var transfers: TransferRun?
    /// It works, and only its grouping owners move it (`ActivityBoard.Watched.Role.grouping`):
    /// its items are done or wait, and what runs is building the result from them, which no
    /// count measures.
    var isGrouping = false
}

/// What the board shows: every watched kind, in `ActivityKind` order. `watching` is false
/// until the window's owners are watched: before then nothing is known, and nothing is
/// claimed (not even "up to date").
nonisolated struct ActivitySnapshot: Equatable, Sendable {
    var watching = false
    var entries: [ActivityEntry] = []

    /// Whether `kind` works now.
    func isWorking(_ kind: ActivityKind) -> Bool {
        entries.contains { entry in
            guard entry.kind == kind, case .working = entry.state else { return false }
            return true
        }
    }
}

actor ActivityBoard {
    /// One owner the board reads, and the kind it serves.
    struct Watched {
        let kind: ActivityKind
        let owner: any QuiescentOwner
        var role: Role = .items
    }

    /// What one watched owner does for its kind.
    enum Role: Sendable {
        /// Does the kind's work on its items, counted (`QuiescentOwner.progress(for:)`) or not
        /// (a metadata refresh).
        case items
        /// Builds the kind's result from its finished items, which no count measures: People's
        /// assignment of faces to people, the duplicate groups. While only such owners move
        /// the kind, the row says that step (`ActivityEntry.isGrouping`).
        case grouping
        /// Only says how the kind's work goes (the downloads behind the photos to show), never
        /// whether it works: the owner it serves says that.
        case detail
    }

    private var watched: [Watched] = []
    /// The start of each working kind's current stretch of work.
    private var workingSince: [ActivityKind: Date] = [:]
    /// What each counting owner had finished, by its index in `watched`, when its kind's
    /// current stretch began.
    private var stretchStarts: [Int: Int] = [:]
    /// Each kind's progress as last published, kept while a count is not read again.
    private var progressByKind: [ActivityKind: ActivityProgress] = [:]
    /// Each watched owner's work as of its last successful count, by its index in `watched`:
    /// the count is read again only once this has moved.
    private var countedAt: [Int: OwnerWork] = [:]
    /// Each watched owner's last count, by its index: whether its own work for its kind can
    /// move (items left that are not parked), or that it reports a run of transfers.
    private var lastCount: [Int: WorkProgress] = [:]
    /// The kinds that wait, each with what it had done when it began to: it waits until it has
    /// done more, or nothing works or waits.
    private var waitingAt: [ActivityKind: Int] = [:]
    /// What stopped each waiting kind last, said while its owners retry.
    private var heldTroubles: [ActivityKind: [OwnerTrouble]] = [:]
    private var published = ActivitySnapshot()
    private let now: @Sendable () -> Date
    private let doorbell: AsyncStream<Void>.Continuation
    private let rings: AsyncStream<Void>
    private let snapshotContinuation: AsyncStream<ActivitySnapshot>.Continuation
    /// Every change of what the board shows, newest wins; its one consumer is the window.
    nonisolated let snapshots: AsyncStream<ActivitySnapshot>
    private var loop: Task<Void, Never>?
    private var roomObservation: BackgroundRoomObservation?

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        (rings, doorbell) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (snapshots, snapshotContinuation) = AsyncStream<ActivitySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Rings the doorbell: something a watched owner holds may have changed. Callable from any
    /// isolation, in the step that changed it.
    nonisolated func ring() {
        doorbell.yield()
    }

    /// Starts watching `owners`, once, and the room's conditions, which a description's hold
    /// is read from. Each owner's activity rings the board from now on; the first round reads
    /// them all.
    func watch(_ owners: [Watched], room: BackgroundRoom?) async {
        guard watched.isEmpty, !owners.isEmpty else { return }
        watched = owners
        for entry in owners {
            await entry.owner.ringActivity { [weak self] in self?.ring() }
        }
        roomObservation = room?.observe { [weak self] in self?.ring() }
        loop = Task { [weak self, rings] in
            for await _ in rings {
                guard let self else { return }
                await round()
            }
        }
        ring()
    }

    /// Ends the loop and the room's observation at teardown.
    func shutdown() {
        loop?.cancel()
        loop = nil
        roomObservation = nil
        snapshotContinuation.finish()
    }

    /// Reads every watched owner's status and what stops its work, then applies what they say
    /// in one step.
    private func round() async {
        let owners = watched
        var statuses: [(index: Int, kind: ActivityKind, status: OwnerStatus)] = []
        var counts: [Counted] = []
        for (index, entry) in owners.enumerated() {
            var status = await entry.owner.status
            status.troubles = await OwnerTrouble.stopping(entry.owner.troubles(for: entry.kind))
            statuses.append((index, entry.kind, status))
            // Counted only while it works or something stops it, and only once its work moved.
            guard !status.isQuiescent || !status.troubles.isEmpty, countedAt[index] != status.work else { continue }
            if let progress = await entry.owner.progress(for: entry.kind) {
                counts.append(Counted(index: index, kind: entry.kind, work: status.work, progress: progress))
            }
        }
        guard !Task.isCancelled else { return }
        apply(statuses, counts: counts, at: now())
    }

    /// One owner's count read in a round, with its work as of the read.
    private struct Counted {
        let index: Int
        let kind: ActivityKind
        let work: OwnerWork
        let progress: WorkProgress
    }

    /// The stretch is over: the next one counts from its own start.
    private func endStretch(of kind: ActivityKind) {
        progressByKind[kind] = nil
        waitingAt[kind] = nil
        heldTroubles[kind] = nil
        for (index, entry) in watched.enumerated() where entry.kind == kind {
            countedAt[index] = nil
            lastCount[index] = nil
            stretchStarts[index] = nil
        }
    }

    /// A count applied to its kind's stretch. Several owners can count one kind (a still's
    /// faces and a video's; the render signatures and the digests duplicates compare), so the
    /// kind's progress sums its counting owners' last counts: what each finished since the
    /// stretch began, of that and what each has left. A run of downloads is the kind's detail,
    /// not its count.
    private func record(_ counted: Counted) {
        countedAt[counted.index] = counted.work
        lastCount[counted.index] = counted.progress
        guard case let .counted(completed, _, _) = counted.progress else { return }
        stretchStarts[counted.index] = stretchStarts[counted.index] ?? completed
        var progress = ActivityProgress(done: 0, total: 0)
        for (index, entry) in watched.enumerated() where entry.kind == counted.kind {
            guard case let .counted(completed, left, parked) = lastCount[index] else { continue }
            let done = max(completed - (stretchStarts[index] ?? completed), 0)
            progress = ActivityProgress(
                done: progress.done + done, total: progress.total + done + left, parked: progress.parked + parked
            )
        }
        progressByKind[counted.kind] = progress
    }

    /// Whether an owner that is not quiescent moves its kind's work: one with no count of its
    /// own (the duplicate groups, People's assignment, a metadata refresh) does, one that
    /// counts does while it has items left that are not parked, and one that reports
    /// transfers never does by itself (the work they serve says so).
    private func moves(_ index: Int) -> Bool {
        guard watched[index].role != .detail else { return false }
        return switch lastCount[index] {
        case nil: true
        case let .counted(_, left, parked): left > parked
        case .transfers: false
        }
    }

    /// The run of background downloads a working kind's busy owners report, if any.
    private func backgroundTransfers(of owners: [(index: Int, kind: ActivityKind, status: OwnerStatus)]) -> TransferRun? {
        var transfers: TransferRun?
        for owner in owners where !owner.status.isQuiescent {
            if case let .transfers(run) = lastCount[owner.index], run.purpose == .background {
                transfers = run
            }
        }
        return transfers
    }

    /// One round's facts applied. A kind works while one of its owners moves its work
    /// (`moves`), and is paused while every one of those waits on a hold. A kind none of whose
    /// owners moves its work waits while something stops it or items it has left are parked,
    /// and it keeps waiting — through its owners' retries, which make them busy without moving
    /// anything — until it has finished an item more than when it began to wait, or nothing of
    /// it works or waits. Otherwise it is up to date. A backoff wake alone is no trouble: an
    /// owner that waits out a failure says which (`QuiescentOwner.troubles`).
    private func apply(
        _ statuses: [(index: Int, kind: ActivityKind, status: OwnerStatus)],
        counts: [Counted],
        at moment: Date
    ) {
        for counted in counts {
            record(counted)
        }
        var entries: [ActivityEntry] = []
        for kind in ActivityKind.allCases {
            let owners = statuses.filter { $0.kind == kind }
            guard !owners.isEmpty else { continue }
            let progress = progressByKind[kind]
            let troubles = owners.flatMap(\.status.troubles)
            let blocked = !troubles.isEmpty || (progress?.parked ?? 0) > 0
            let busy = owners.contains { !$0.status.isQuiescent && watched[$0.index].role != .detail }
            if let since = waitingAt[kind], (progress?.done ?? 0) > since {
                waitingAt[kind] = nil
            }
            let moving = owners.filter { !$0.status.isQuiescent && moves($0.index) }
            let state: ActivityEntry.State
            if waitingAt[kind] != nil {
                state = busy || blocked ? .waiting : .upToDate
            } else if !moving.isEmpty {
                let holds = moving.map(\.status.heldBy)
                state = if holds.allSatisfy({ $0 != nil }), let hold = holds.first ?? nil {
                    .paused(hold)
                } else {
                    .working(since: workingSince[kind] ?? moment)
                }
            } else if blocked {
                waitingAt[kind] = progress?.done ?? 0
                state = .waiting
            } else {
                state = .upToDate
            }
            switch state {
            case let .working(since):
                workingSince[kind] = since
            case .paused:
                break
            case .waiting, .upToDate:
                workingSince[kind] = nil
            }
            var said = troubles
            if state == .waiting {
                if said.isEmpty {
                    said = heldTroubles[kind] ?? []
                } else {
                    heldTroubles[kind] = said
                }
            } else {
                heldTroubles[kind] = nil
            }
            if state == .upToDate {
                endStretch(of: kind)
            }
            var entry = ActivityEntry(kind: kind, state: state, troubles: said, progress: progressByKind[kind])
            if case .working = state {
                entry.transfers = backgroundTransfers(of: owners)
                entry.isGrouping = moving.allSatisfy { watched[$0.index].role == .grouping }
            }
            entries.append(entry)
        }
        let snapshot = ActivitySnapshot(watching: true, entries: entries)
        guard snapshot != published else { return }
        published = snapshot
        snapshotContinuation.yield(snapshot)
        OtosLog.ui.debugOperation("activity", phase: "changed", fields: [
            "working": entries.compactMap { entry -> String? in
                guard case .working = entry.state else { return nil }
                return entry.kind.rawValue
            }.joined(separator: ","),
            "paused": entries.compactMap { entry -> String? in
                guard case let .paused(hold) = entry.state else { return nil }
                return "\(entry.kind.rawValue)(\(hold.rawValue))"
            }.joined(separator: ","),
            "waiting": entries.compactMap { entry -> String? in
                entry.state == .waiting ? entry.kind.rawValue : nil
            }.joined(separator: ","),
            "progress": entries.compactMap { entry -> String? in
                entry.progress.map { "\(entry.kind.rawValue)(\($0.done)/\($0.total) parked=\($0.parked))" }
            }.joined(separator: ","),
            "troubles": entries.flatMap { entry in
                entry.troubles.map { "\(entry.kind.rawValue)(\($0.cause.rawValue)=\($0.count.map { "\($0)" } ?? "all"))" }
            }.joined(separator: ","),
        ])
    }
}
