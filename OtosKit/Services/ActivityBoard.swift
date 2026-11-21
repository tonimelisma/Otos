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
// round synchronously: a kind turning to work records when it started, a kind turning idle
// records when it finished (ADR 0032 rules 1 and 3). A round that changes what the board
// shows publishes one snapshot (`.bufferingNewest(1)`, newest wins) and logs it.
//
// A kind is one outcome the user owns (`ActivityKind`); several owners can serve one kind (the
// duplicate groups and the render signatures they compare), and the kind works while any of
// them does. Bookkeeping owners — the projection, the People gallery's tally, the derived
// folder's launch tidy — are not watched: they are machinery, never an outcome (DES-035).
// Immich accounts report their own status (`ImmichAccountStatus`, with a persisted last
// sync), which the presentation reads beside this board's snapshot.
//
// The loop holds the board weakly across its waits and ends with it; `shutdown()` ends it at
// teardown.

/// One background outcome the Activity surface names (DES-035: the user's nouns). Declared
/// in the order the popover lists them.
nonisolated enum ActivityKind: String, CaseIterable, Sendable {
    /// Thumbnails, previews and each item's details (`EnrichmentCoordinator`).
    case readingPhotos
    /// Originals fetched from a cloud provider (`MaterializationCoordinator`).
    case downloadingOriginals
    /// Details re-read after Otos learned to read more (`MetadataRefresher`).
    case updatingDetails
    /// Faces found in stills and video frames (`PreviewFaceReader`).
    case findingFaces
    /// Faces put together into people (`PeopleAssignment`).
    case recognizingPeople
    /// Countries and towns named for located items (`PlaceNameReader`).
    case namingPlaces
    /// What search reads in each photo (`PhotoSearchIndex`).
    case preparingSearch
    /// Each still's description (`PhotoDescriptionWriter`).
    case describingPhotos
    /// The duplicate groups and the render signatures they compare (`DuplicatesProjection`,
    /// `RenderSignatureRefresher`).
    case findingDuplicates
}

/// What one kind is doing, as of the board's last round.
nonisolated struct ActivityEntry: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Working since `since`; `heldBy` while every owner working for it waits on the
        /// machine's conditions (ADR 0057).
        case working(since: Date, heldBy: BackgroundHold?)
        /// Worked this session and finished at `at`.
        case finished(at: Date)
    }

    let kind: ActivityKind
    let state: State
}

/// What the board shows: every kind that works now or worked this session, in
/// `ActivityKind` order. `watching` is false until the window's owners are watched: before
/// then nothing is known, and nothing is claimed (not even "up to date").
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
    }

    /// What a kind did across rounds: the start of its current stretch of work, or when its
    /// last one finished.
    private enum Phase: Equatable {
        case working(since: Date)
        case finished(at: Date)
    }

    private var watched: [Watched] = []
    private var phases: [ActivityKind: Phase] = [:]
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

    /// Reads every watched owner's status, then applies what they say in one step.
    private func round() async {
        let owners = watched
        var statuses: [(ActivityKind, OwnerStatus)] = []
        for entry in owners {
            await statuses.append((entry.kind, entry.owner.status))
        }
        guard !Task.isCancelled else { return }
        apply(statuses, at: now())
    }

    /// One round's facts applied: each kind works while any of its owners is not quiescent,
    /// and is held while every one of those waits on a hold.
    private func apply(_ statuses: [(ActivityKind, OwnerStatus)], at moment: Date) {
        var working: [ActivityKind: [OwnerStatus]] = [:]
        for (kind, status) in statuses where !status.isQuiescent {
            working[kind, default: []].append(status)
        }
        var entries: [ActivityEntry] = []
        for kind in ActivityKind.allCases {
            if let busy = working[kind] {
                let since: Date = if case let .working(since) = phases[kind] {
                    since
                } else {
                    moment
                }
                phases[kind] = .working(since: since)
                let holds = busy.map(\.heldBy)
                let held = holds.allSatisfy { $0 != nil } ? holds.first ?? nil : nil
                entries.append(ActivityEntry(kind: kind, state: .working(since: since, heldBy: held)))
            } else if let phase = phases[kind] {
                let finished: Date = switch phase {
                case .working: moment
                case let .finished(at): at
                }
                phases[kind] = .finished(at: finished)
                entries.append(ActivityEntry(kind: kind, state: .finished(at: finished)))
            }
        }
        let snapshot = ActivitySnapshot(watching: true, entries: entries)
        guard snapshot != published else { return }
        published = snapshot
        snapshotContinuation.yield(snapshot)
        OtosLog.ui.debugOperation("activity", phase: "changed", fields: [
            "working": entries.compactMap { entry -> String? in
                guard case let .working(_, held) = entry.state else { return nil }
                return held.map { "\(entry.kind.rawValue)(\($0.rawValue))" } ?? entry.kind.rawValue
            }.joined(separator: ","),
            "finished": entries.filter {
                if case .finished = $0.state {
                    true
                } else {
                    false
                }
            }
            .map(\.kind.rawValue).joined(separator: ","),
        ])
    }
}
