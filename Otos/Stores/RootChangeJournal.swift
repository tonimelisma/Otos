import Foundation

// Root change journal guide
//
// A fixed library's own change journal is its volume's FSEvents history (ADR 0002,
// "Change Journal"). The catalog stores, per root, the last event ID it fully applied,
// with the identity of the volume's event database and of the root folder
// (`FilesystemJournalPosition`). At launch the root's stream replays the history since
// that ID, and the events are reconciled like live ones; a launch walks the root only
// when the journal cannot vouch for it (`JournalLaunchDecision`). The source wins: the
// filesystem's journal is the fact, and when it cannot vouch, the walk is.
//
// `RootChangeJournal` is the process-local half: how far this session's stream has
// delivered, whether its replay has ended, and whether anything this session could not
// apply is still outstanding. It decides only which position may be stored; the Store
// owns the stream, the reconciliation and the write, and confines this value to its actor
// like `RootRegistry`.

/// What the catalog stores for a root: every event through `eventID` is reflected in it.
nonisolated struct FilesystemJournalPosition: Equatable {
    /// The volume's event database (`FSEventsCopyUUIDForDevice`); event IDs mean nothing
    /// across two of them.
    let volumeUUID: String
    let eventID: UInt64
    /// The root folder's inode when the position was stored: a folder replaced at the same
    /// path while Otos was not running reads as another.
    let rootIdentity: UInt64
}

/// Why a pass over a root ran, or why a launch ran none (`op=catalog.scan reason=`).
nonisolated enum ScanReason: String, Equatable {
    /// The replay since the stored position delivered nothing: no walk.
    case noChanges
    /// The replay or the live stream named what changed, and only that was reconciled; or
    /// an event whose shape names no narrower scope made the whole root dirty.
    case events
    /// The volume keeps no FSEvents history, or the stored position is ahead of it.
    case noHistory
    /// The volume's event database is not the one the position came from.
    case uuidChanged
    /// The stream dropped events or its IDs wrapped (`UserDropped`, `KernelDropped`,
    /// `EventIdsWrapped`).
    case dropped
    /// The root folder is not the one the position came from, or the stream reported a
    /// change on the path to it or a mount under it (`RootChanged`, `Mount`, `Unmount`).
    case rootChanged
    /// No position is stored: the root's first walk in this catalog.
    case firstWalk
    /// The root could not be read when the launch looked at it.
    case unreadable
    /// The 24-hour integrity walk of a long session.
    case integrity
    /// An owner asked for a walk after its own work (reorganization, a lease release, a
    /// failed library removal).
    case requested
    /// A removable volume, which keeps no journal Otos reads.
    case removable
}

/// What a launch does with a fixed library root.
nonisolated enum JournalLaunchDecision: Equatable {
    /// Replay the history since this ID; walk nothing unless an event says to.
    case replay(since: UInt64)
    case walk(ScanReason)

    static func decide(stored: FilesystemJournalPosition?, probe: FilesystemJournalProbe?) -> JournalLaunchDecision {
        guard let probe else {
            return .walk(.unreadable)
        }
        guard let volumeUUID = probe.volumeUUID else {
            return .walk(.noHistory)
        }
        guard let stored else {
            return .walk(.firstWalk)
        }
        guard stored.volumeUUID == volumeUUID else {
            return .walk(.uuidChanged)
        }
        guard stored.rootIdentity == probe.rootIdentity else {
            return .walk(.rootChanged)
        }
        guard stored.eventID <= probe.currentEventID else {
            return .walk(.noHistory)
        }
        return .replay(since: stored.eventID)
    }
}

/// One fixed root's journal in this session.
nonisolated struct RootChangeJournal: Equatable {
    /// The event database the stream reads; nil when the volume keeps none, and then no
    /// position is ever stored.
    let volumeUUID: String?
    /// What the catalog holds, or nil.
    private(set) var stored: FilesystemJournalPosition?
    /// The highest event ID the stream has delivered for the root; it starts at the ID the
    /// stream was started from.
    private(set) var delivered: UInt64
    /// The replay since `stored` has not ended yet: events delivered now are history.
    private(set) var isReplaying: Bool
    private(set) var replayedEvents = 0
    private(set) var historyDone: Bool
    /// Work only a completed full walk settles — a walk owed, an event dropped or not
    /// applied — counted as a revision (ADR 0032): `owed` advances when one appears, and a
    /// walk that completes settles what was owed when it started.
    private(set) var owed: UInt64 = 0
    private(set) var settled: UInt64 = 0
    /// The `owed` a walk in flight covers.
    private var walkCovers: UInt64?

    /// A stream started from `since` to replay the history after `stored`.
    static func replaying(from stored: FilesystemJournalPosition) -> RootChangeJournal {
        RootChangeJournal(volumeUUID: stored.volumeUUID, stored: stored, delivered: stored.eventID, isReplaying: true, historyDone: false)
    }

    /// A stream started from the probe's current ID, ahead of a walk that will cover
    /// everything before it. A volume with no history never reports `historyDone`.
    static func walking(probe: FilesystemJournalProbe, stored: FilesystemJournalPosition?) -> RootChangeJournal {
        var journal = RootChangeJournal(
            volumeUUID: probe.volumeUUID,
            stored: stored,
            delivered: probe.currentEventID,
            isReplaying: false,
            historyDone: false
        )
        journal.oweWalk()
        return journal
    }

    private init(
        volumeUUID: String?,
        stored: FilesystemJournalPosition?,
        delivered: UInt64,
        isReplaying: Bool,
        historyDone: Bool
    ) {
        self.volumeUUID = volumeUUID
        self.stored = stored
        self.delivered = delivered
        self.isReplaying = isReplaying
        self.historyDone = historyDone
    }

    /// The stream started from `since` when watched: nil watches from now.
    var streamStart: UInt64? {
        volumeUUID == nil ? nil : delivered
    }

    /// An event the stream delivered; an ID of zero (`RootChanged`) names no position.
    mutating func deliver(eventID: UInt64) {
        if isReplaying {
            replayedEvents += 1
        }
        delivered = max(delivered, eventID)
    }

    mutating func endHistory() {
        isReplaying = false
        historyDone = true
    }

    /// Something only a full walk settles is outstanding.
    mutating func oweWalk() {
        owed &+= 1
    }

    mutating func walkStarted() {
        walkCovers = owed
    }

    /// A walk that reconciled the whole root: everything owed when it started is settled.
    mutating func walkCompleted() {
        if let walkCovers {
            settled = max(settled, walkCovers)
        }
        walkCovers = nil
    }

    mutating func walkEnded() {
        walkCovers = nil
    }

    /// The journal can vouch for the root: its volume keeps history, the replay has ended,
    /// and no walk is owed.
    var canVouch: Bool {
        volumeUUID != nil && historyDone && settled == owed
    }

    /// The stream has delivered past what is stored, or nothing is stored yet.
    var hasNewPosition: Bool {
        stored.map { $0.eventID != delivered || $0.volumeUUID != volumeUUID } ?? true
    }

    /// The position to store when every delivered event has been applied (`isApplied`, the
    /// Store's fact: no batch, pass, dirt, scan or lease left for the root), or nil when
    /// there is nothing new to store or the journal cannot vouch: no history, a replay not
    /// yet ended, or a walk still owed. `rootIdentity` and `volumeUUID` are read now, so a
    /// position is never stored for a database or folder other than the one streamed.
    func positionToStore(isApplied: Bool, probe: FilesystemJournalProbe?) -> FilesystemJournalPosition? {
        guard isApplied, canVouch, let volumeUUID, let probe, probe.volumeUUID == volumeUUID
        else {
            return nil
        }
        let position = FilesystemJournalPosition(volumeUUID: volumeUUID, eventID: delivered, rootIdentity: probe.rootIdentity)
        return position == stored ? nil : position
    }

    mutating func didStore(_ position: FilesystemJournalPosition) {
        stored = position
    }
}
