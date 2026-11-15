import Foundation

// On This Day model guide
//
// Value types for the On This Day scope (ADR 0049). Projection publishes
// `CatalogOnThisDayState` for the `.onThisDay` scope: the scope's items grouped into one
// `OnThisDayAnniversary` per earlier day that holds a match, in play order. Those days are
// the day's month and day in earlier years, or — when no earlier year holds one — the
// day of the month in earlier months (`AnniversaryMatch`). The scope fixes its own order,
// newest day first and, within a day, its Liked photos and then the newest capture
// (`OnThisDayPicks.likedFirst`), so an anniversary is one contiguous run of the scope's ordered IDs
// and the story player walks exactly those runs.

/// One earlier anniversary of On This Day: its run in the scope's play order.
nonisolated struct OnThisDayAnniversary: Hashable, Sendable, Identifiable {
    /// The day the run was taken on: the anniversary in its year and month.
    let day: CalendarDay
    /// The run's first item in play order — the day's newest Liked photo, else its newest
    /// capture — which stands
    /// for the anniversary in the collection.
    let keyItem: MediaAssetID
    /// Where the run starts in the scope's ordered IDs.
    let firstIndex: Int
    /// How many items the run holds.
    let count: Int

    var id: CalendarDay {
        day
    }

    /// The run as indexes into the scope's ordered IDs.
    var indexes: Range<Int> {
        firstIndex ..< firstIndex + count
    }
}

/// How long before today an anniversary is: whole years when its month is today's, else
/// months. A run 14 months back is `months(14)`, never a rounded year.
nonisolated enum OnThisDayInterval: Equatable, Sendable {
    case years(Int)
    case months(Int)
}

/// What the On This Day scope shows: the day it asks about and its anniversaries, newest
/// first.
nonisolated struct CatalogOnThisDayState: Equatable, Sendable {
    let day: CalendarDay
    let anniversaries: [OnThisDayAnniversary]

    var itemCount: Int {
        anniversaries.reduce(0) { $0 + $1.count }
    }

    /// Whether every anniversary falls in today's month — earlier years — rather than in
    /// earlier months: what the bar counts its runs in.
    var isYears: Bool {
        anniversaries.allSatisfy { $0.day.month == day.month }
    }

    /// The anniversaries over `order`, which is `previous` without `hidden`: each run shorter
    /// by what it lost, an emptied one gone, and a run whose key item left keyed by its new
    /// first item — the next Liked photo or newest capture, as the run is ordered.
    func keeping(
        _ order: [MediaAssetID],
        from previous: CatalogGridContent,
        hidden: Set<MediaAssetID>
    ) -> CatalogOnThisDayState {
        var removedBefore = 0
        var kept: [OnThisDayAnniversary] = []
        for anniversary in anniversaries where anniversary.indexes.upperBound <= previous.orderedAssetIDs.count {
            let removedHere = previous.orderedAssetIDs[anniversary.indexes].count(where: hidden.contains)
            let first = anniversary.firstIndex - removedBefore
            removedBefore += removedHere
            let count = anniversary.count - removedHere
            guard count > 0, first < order.count else {
                continue
            }
            kept.append(OnThisDayAnniversary(
                day: anniversary.day,
                keyItem: hidden.contains(anniversary.keyItem) ? order[first] : anniversary.keyItem,
                firstIndex: first,
                count: count
            ))
        }
        return CatalogOnThisDayState(day: day, anniversaries: kept)
    }
}

/// The story playing over On This Day: how far its item has got. The item itself is the
/// loupe's `focusedAssetID`, its one owner, and the order and the anniversary runs are the
/// scope's own (`CatalogOnThisDayState`), so the story holds no copy of either.
nonisolated struct StoryPlayback: Equatable, Sendable {
    /// The focus visit this state describes (`CatalogWindowViewModel.focusVisit`). Every
    /// focus change is a new visit, a step back to the same item included, and a report
    /// made for another visit is dropped.
    var visit: UInt64
    var isPaused = false
    /// The story reached the end of its last item and stays on it, paused.
    var hasEnded = false
    var pane: StoryPane = .awaited
    var video: StoryVideo = .notVideo
    /// The still's hold, once its picture is on screen.
    var hold: StoryHold?
}

/// A request that the On This Day collection put keyboard focus on an anniversary,
/// numbered so the view applies each one once.
nonisolated struct OnThisDayFocusRequest: Equatable, Sendable {
    let anniversary: CalendarDay
    let revision: UInt64
}
