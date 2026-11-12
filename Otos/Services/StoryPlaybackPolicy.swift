import Foundation

/// Story playback policy guide
///
/// Pure rules for the On This Day story player (ADR 0049). The story plays the scope's
/// items in the scope's own order — newest anniversary first, newest capture first within
/// one — so its order is the scope's ordered IDs and its runs are the scope's
/// `OnThisDayAnniversary`s. This type decides where playback starts, what next and previous are,
/// where it ends, what survives a catalog change, and when a still's hold may start; the
/// ViewModel (`CatalogWindowViewModelStory.swift`) applies those answers.
nonisolated enum StoryPlaybackPolicy {
    /// How long a still holds once its picture is on screen: a product schedule, as in
    /// Immich's default (ADR 0049).
    static let stillHold: Duration = .seconds(5)

    /// The item a story starts on: the chosen anniversary's first item, or the newest one's
    /// when none is chosen. Nil when the scope holds nothing.
    static func start(
        anniversary: CalendarDay?,
        anniversaries: [OnThisDayAnniversary],
        orderedIDs: [MediaAssetID]
    ) -> MediaAssetID? {
        let chosen = anniversary.flatMap { day in anniversaries.first { $0.day == day } } ?? anniversaries.first
        guard let chosen, orderedIDs.indices.contains(chosen.firstIndex) else {
            return nil
        }
        return orderedIDs[chosen.firstIndex]
    }

    /// The item after `current`, across anniversaries; nil at the end.
    static func next(after current: MediaAssetID, in orderedIDs: [MediaAssetID]) -> MediaAssetID? {
        guard let index = orderedIDs.firstIndex(of: current), index + 1 < orderedIDs.count else {
            return nil
        }
        return orderedIDs[index + 1]
    }

    /// The item before `current`, across anniversaries; nil at the start.
    static func previous(before current: MediaAssetID, in orderedIDs: [MediaAssetID]) -> MediaAssetID? {
        guard let index = orderedIDs.firstIndex(of: current), index > 0 else {
            return nil
        }
        return orderedIDs[index - 1]
    }

    /// The item the story shows after the scope changed under it: `current` while it is
    /// still there, else the loupe's survivor — the first later item that remains, else the
    /// closest earlier one (`BrowserModePolicy.pruneFocus`). Nil when nothing
    /// remains.
    static func survivor(
        of current: MediaAssetID,
        previousOrderedIDs: [MediaAssetID],
        survivingOrderedIDs: [MediaAssetID]
    ) -> MediaAssetID? {
        BrowserModePolicy.pruneFocus(
            previous: current,
            previousOrderedIDs: previousOrderedIDs,
            survivingOrderedIDs: survivingOrderedIDs
        )
    }

    /// Where `current` stands in its anniversary: the anniversary and the item's 1-based
    /// position in it. Nil when the item is in none.
    static func place(
        of current: MediaAssetID,
        anniversaries: [OnThisDayAnniversary],
        orderedIDs: [MediaAssetID]
    ) -> (anniversary: OnThisDayAnniversary, position: Int)? {
        guard let index = orderedIDs.firstIndex(of: current),
              let anniversary = OnThisDayAnniversaryPolicy.anniversary(containing: index, in: anniversaries)
        else {
            return nil
        }
        return (anniversary, index - anniversary.firstIndex + 1)
    }

    /// Whether a still's hold may start: the item is known not to be a playable video,
    /// and its pane has either put its picture on screen or reported it has none. A video
    /// counts as a still once its player is known to be unavailable. Waiting on bytes or on
    /// the kind never advances (ADR 0049).
    static func holdCanStart(kind: MediaKind?, pane: StoryPane, video: StoryVideo) -> Bool {
        guard let kind, pane != .awaited else {
            return false
        }
        return kind != .video || video == .unavailable
    }
}

/// What the player's pane holds for the current item.
nonisolated enum StoryPane: Equatable, Sendable {
    /// The picture is being decoded or its bytes downloaded.
    case awaited
    /// The decoded picture is on screen.
    case shown
    /// The pane reported there is no picture to show.
    case none
}

/// Where the current item's video stands; `.notVideo` for a still.
nonisolated enum StoryVideo: Equatable, Sendable {
    case notVideo
    case preparing
    case playing
    case unavailable
}

/// A still's 5 s hold: how much of it is left, and since when it has been counting. Paused,
/// it keeps its remainder and counts from nowhere; playing again counts the remainder from
/// then. Instants are `ContinuousClock`'s, so a clock change never stretches a hold.
nonisolated struct StoryHold: Equatable, Sendable {
    let total: Duration
    private(set) var remaining: Duration
    private(set) var countingSince: ContinuousClock.Instant?

    init(total: Duration = StoryPlaybackPolicy.stillHold, startingAt instant: ContinuousClock.Instant?) {
        self.total = total
        remaining = total
        countingSince = instant
    }

    /// The remainder after counting stops at `instant`.
    func pausing(at instant: ContinuousClock.Instant) -> StoryHold {
        guard let countingSince else {
            return self
        }
        var paused = self
        paused.remaining = max(.zero, remaining - (instant - countingSince))
        paused.countingSince = nil
        return paused
    }

    /// The same remainder, counting from `instant`.
    func resuming(at instant: ContinuousClock.Instant) -> StoryHold {
        guard countingSince == nil else {
            return self
        }
        var resumed = self
        resumed.countingSince = instant
        return resumed
    }

    /// How much of the hold has passed at `instant`, 0 through 1: the player's segment fill.
    func fraction(at instant: ContinuousClock.Instant) -> Double {
        let left = countingSince.map { max(.zero, remaining - (instant - $0)) } ?? remaining
        guard total > .zero else {
            return 1
        }
        return min(1, max(0, 1 - left / total))
    }
}
