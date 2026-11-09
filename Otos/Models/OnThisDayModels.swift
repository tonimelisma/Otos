import Foundation

// On This Day model guide
//
// Value types for the On This Day scope (ADR 0049). Projection publishes
// `CatalogOnThisDayState` for the `.onThisDay` scope: the scope's items grouped into one
// `OnThisDayYear` per earlier year that holds a match, in play order. The scope fixes its
// own order — newest year first, newest capture first within a year — so a year is one
// contiguous run of the scope's ordered IDs, and the story player walks exactly those runs.

/// One earlier year of On This Day: its run in the scope's play order.
nonisolated struct OnThisDayYear: Hashable, Sendable, Identifiable {
    /// The anniversary in that year.
    let day: CalendarDay
    /// The year's first item in play order — its newest capture of the day — which stands
    /// for the year in the collection.
    let keyItem: MediaAssetID
    /// Where the year's run starts in the scope's ordered IDs.
    let firstIndex: Int
    /// How many items the year holds.
    let count: Int

    var year: Int {
        day.year
    }

    var id: Int {
        year
    }

    /// The year's run as indexes into the scope's ordered IDs.
    var indexes: Range<Int> {
        firstIndex ..< firstIndex + count
    }
}

/// What the On This Day scope shows: the day it asks about and its years, newest first.
nonisolated struct CatalogOnThisDayState: Equatable, Sendable {
    let day: CalendarDay
    let years: [OnThisDayYear]

    var itemCount: Int {
        years.reduce(0) { $0 + $1.count }
    }
}

/// The story playing over On This Day: how far its item has got. The item itself is the
/// loupe's `focusedAssetID`, its one owner, and the order and the year runs are the
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

/// A request that the On This Day collection put keyboard focus on a year, numbered so
/// the view applies each one once.
nonisolated struct OnThisDayFocusRequest: Equatable, Sendable {
    let year: Int
    let revision: UInt64
}
