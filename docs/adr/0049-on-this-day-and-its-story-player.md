# ADR 0049: On This Day is a scope of anniversaries, played as a story

- Status: Accepted
- Date: 2026-11-09

## Context

On This Day is a story player for photos and videos, similar to Immich's, decided after
the survey `docs/research/2026-11-07-memories-and-highlights.md`, with these choices made
on 2026-11-09:

- **the unit:** On This Day — items captured on today's month and day in earlier years;
  and, on 2026-11-12, photos from months ago when nothing newer is available: a
  library with nothing from an earlier year on the day — a library seven months
  deep showed `Nothing on This Day` while holding 713 items taken on the 12th of earlier
  months — shows the day of the month in earlier months instead;
- **the content:** photos and videos;
- **the presentation:** a story player like Immich's — one progress segment per item,
  stills hold, videos play their own length, keyboard navigation;
- **the placement:** a top-level `On This Day` sidebar row under All Media, chosen from four
  options (a sidebar row, a strip above the grid, a menu command only, a sidebar row plus
  a strip);
- **the pane:** a grid of photo cards, one per earlier year, chosen from four options
  (photo cards, story circles, a by-year feed, a hero plus smaller cards) after the
  layout survey `docs/research/2026-11-09-on-this-day-layouts.md`. The reference is
  Immich v3.3.0's memory strip and Immich's memories page (PR #28675).

Otos's architecture splits *scope* (`SidebarSelection`, what media) from *presentation*
(`BrowserViewMode`). Places (ADR 0040) and Duplicates (ADR 0042) are scopes whose detail
is their own presentation; On This Day is the third.

## MECE Decision Scope

This ADR owns: what the On This Day scope holds and how its query is built; who owns
today and how it follows the platform; the scope's fixed order; the card pane and how it
starts a story; the story player's position, timing and keys; and what On This Day never
does.

It references but does not own: scope resolution and the sidebar default (ADR 0014); the
query descriptor and the scope predicate (ADR 0011, ADR 0010); the browser place (ADR
0031); the owner-state rules (ADR 0032); time tags (ADR 0033); the loupe's pane, video
and materialization (ADR 0016, ADR 0023); the no-blank grid rule (ADR 0006).

## Decision

**On This Day is a scope, and its anniversaries are what that scope looks like.** There is no
view mode for it.

1. **Placement.** A sidebar row, `On This Day`, SF Symbol `calendar`,
   second under All Media, present whenever one fixed library exists, with no trailing count.
2. **What matches.** Rows of the available fixed libraries — All Media's membership —
   whose day bucket has today's month and day in a year before today's — or, only when no
   such row exists, today's day of the month in a month before today's (§4). The day bucket
   is the day the item was taken on, on the clock where it was taken: the date of its
   local capture time, `best_capture_local` (ADR 0039). That is the same day
   `CatalogStore.orderedAssetIDs` buckets the grid by (DES-069), and it does not depend on
   the Mac's zone. Days and years are counted on the Gregorian calendar
   (`CalendarDay.calendar(in:)`), never `Calendar.current`, whose year is an era year
   under the Japanese calendar (Reiwa 8) and 2569 under the Buddhist one. What the user
   reads is formatted in their own calendar and locale. The match is exact: on a common year, 29 February
   matches nothing, and a 30-day month has no 31st. Undated rows never match. It is a live query, never a snapshot, so a
   late import appears and a deleted file goes (ADR 0008). Of the rows that match, it
   leaves out a Disliked photo (a stack by its key, ADR 0052) and one Vision is confident is
   a screenshot or a document (`OnThisDayPicks`, 2026-11-13). Those labels
   count only from the photo's current search row, the one read from the thumbnail it has
   now (ADR 0048's staleness, `OnThisDayPicks.leftOutSQL`): a row read from an earlier
   picture — a re-rendered thumbnail, a new file at a deleted photo's path, an older model —
   says nothing about this one, so the photo stays, exactly as one not yet read for search
   does, until its new reading arrives. The scope is read again for a new thumbnail as
   for a new label.
3. **Today is a typed value in the selection.** `SidebarSelection.onThisDay(CalendarDay)`,
   where `CalendarDay` is the Gregorian `{year, month, day}` in the user's time zone. The ViewModel owns
   `today`: it reads it at init and again whenever the platform reports
   `NSCalendarDayChanged` or `NSSystemTimeZoneDidChange`. Each report rings a newest-wins
   doorbell whose one consumer reads the day and applies it synchronously (ADR 0032). A
   day that moved while On This Day is selected re-selects `.onThisDay(new)` through the
   ordinary selection intent, so the scope re-queries like any scope change, and a story
   playing closes. The row's tag is `.onThisDay(today)`. `BrowserPlace` saves the kind
   `onThisDay` without a day and restores it as `.onThisDay(today)`.
4. **The predicate carries the date dimension.** `CatalogScopePredicate.DateConstraint`
   is `.any` or `.anniversary(CalendarDay)`, resolved only by
   `RootRegistry.scopePredicate`, so ordered IDs and counts agree. The
   gateway turns it into one predicate over `best_capture_local` in the read's own
   transaction (`AnniversaryMatch`, pure): that column is the clock's reading counted on a
   UTC calendar, so SQLite's `strftime(…, 'unixepoch')` writes the date the clock showed
   with no zone applied, and a daylight-saving day is midnight to midnight like any
   other. Years match month 11 and day 12 on rows taken before the day's year began;
   months match day 12 on rows taken before its month began. The day and month are stored
   as generated columns (`capture_day`, `capture_month`, schema v62) that lead
   `idx_media_asset_capture_day`, so a read of the scope seeks the day's rows, a few
   hundred, instead of testing the date of every row before the end
   (`docs/research/2026-11-15-proportional-small-scopes.md`). A day holding more than
   half the rows a walk of the order visits — a library taken in one day — walks the
   order instead, testing each row's capture time in the index, and judges its rows by
   every stack of its roots: sorting and building stacks from that many sought rows costs
   more than the walk (`docs/research/2026-11-15-large-narrow-scopes.md`). The match itself
   always seeks, since it stops at the first row shown. The
   scope's rows under the years' match — its roots and visibility rules, never the filter —
   decide the unit by the rule that fills the cards (`OnThisDayPicks.shows`): a year is
   offered exactly when its card would hold a photo, so any row On This Day would show keeps
   the years, and none falls back to the months. A row the exclusion leaves in is still not
   shown when it is a file of a stack whose key is Disliked (ADR 0052), so the match
   judges the year's rows by stacks from the same transaction: the stacks the caller holds,
   or else only the stacks that hold those rows, built from their folders and bursts
   (`PhotoStackSQL.build(rootPaths:holding:pairing:db:)`), which judge them exactly as every stack
   would.
   Because the filter takes no part, it only narrows: a video filter on a scope whose
   year holds only photos shows nothing, never last month's videos. Every read decides
   the same unit from the same snapshot, so order, counts and filter options agree, and
   `op=onThisDay.match` logs the unit. The predicate's size does not depend on how many
   years the library spans (`docs/research/2026-11-12-on-this-day-months.md`).
5. **The scope fixes its order.** `SidebarSelection.fixedSort` is `dateNewest` for On
   This Day, and every read uses `CatalogQueryDescriptor.effectiveSort`. The user's sort
   stays in the descriptor as chosen, so leaving the scope restores it. The sort control
   and View ▸ Sort are disabled in place there, with the reason as the tooltip (DES-053,
   DES-038). The filter applies and narrows each anniversary. A keyword search (ADR 0048) also
   only narrows: `CatalogQueryDescriptor.effectiveSearch` orders a fixed-order scope's
   results by that order, never by relevance, so each anniversary stays one contiguous run.
6. **Projection publishes the anniversaries.** `CatalogWindowState.onThisDay` is
   `CatalogOnThisDayState`: the day and one `OnThisDayAnniversary` per earlier year — or
   month — with a match, newest first, each a contiguous run of the ordered IDs with its
   key item (the run's first, its newest capture) and count, grouped by year and month by
   `OnThisDayAnniversaryPolicy` from the day buckets the fixed order carries; the scope
   holds at most one day a month, so a year and month names every run in either unit.
   An anniversary's distance (`OnThisDayInterval`) is whole years when its month is
   today's and months otherwise, so a run 14 months back reads `14 months ago`, never a
   rounded year; the bar counts in years when every run is in today's month.
7. **The pane is a grid of photo cards.** A 52 pt bar in the Places
   bar's place (L1 the day, `9 November`; L3 `14 photos and videos from 4 years`, or
   `612 photos and videos from 4 months`), over an adaptive grid of 16:9 cards (260–420 pt
   wide, 16 pt gaps, 20 pt margins), one per anniversary, newest first. A card's key photo is aspect-filled — a cover stands for the anniversary,
   it is not the photograph under review, and Immich, Apple and Google all crop covers
   (`[deviation]` from DES-060A). `3 years ago` (or `2 months ago`) sits on the photo over a bottom scrim;
   `9 Nov 2023 · 14` under it. A single click plays that anniversary; Return or Space plays the
   focused card; the arrow keys move focus. The anniversaries' covers are this pane's visible items, so they are pinned in the shared
   `TileContentStore` exactly as the grid pins its visible tiles (ADR 0006) while the scope
   shows, and released when it closes; a card made again reads its cover from there while
   rendering. There is no second cover cache. The view-mode picker is disabled, with no
   segment selected (DES-053, the Duplicates precedent). Rules: DES-112,
   `docs/design/on-this-day.md`.
8. **The player replaces the cards while it plays.** It is not a view mode. Its bar is
   52 pt: Close and the anniversary (`1 year ago`, `1 month ago`) leading; Play / Pause, one
   segment per item of that anniversary and the position `1/20` in the center; Previous and Next trailing. The
   picture is aspect-fit on the `content` surface, the item's date on its top-left over a
   top scrim; a video plays inline with its sound and no player chrome; DES-086's
   indicator shows while bytes are awaited; DES-063's slash glyph when an item can have
   no picture. View ▸ Play Story (⌘Return, Lightroom Classic's Impromptu Slideshow key)
   plays from the newest anniversary; there is no toolbar button, since the cards are the way
   in.
9. **Timing.** A still — a photo, or a Live Photo shown as its still — holds 5 s from the
   moment its picture is on screen (the pane published its decode), a product schedule
   tagged `time: schedule` (ADR 0033; Immich's default). An item with no picture holds
   5 s once the pane reports there is none. A video advances when its player reports
   `AVPlayerItemDidPlayToEndTime`, never on a timer; its segment fills over the range it
   plays, a trim's if it has one (ADR 0036). A video whose player reports it cannot play
   (`failedToPlayToEndTime`, or the item's status turning `.failed`), or that can have no
   player, holds 5 s like a still on its poster. While bytes are awaited the segment does
   not advance, and a read that failed leaves it waiting with an `op=story.stalled` line. Pause freezes the hold's remainder (`StoryHold`, on
   `ContinuousClock`) and the video; Play resumes both. After the last item the player
   stays on it, paused, with Next and Play disabled.
10. **Keys.** Space plays and pauses; ← and → move across anniversaries; Esc closes.
    Closing returns to the cards with keyboard focus on the anniversary the story was on and its item
    selected. Changing the sidebar selection or the day closes it. P / X / U and the
    inspector act on the item on screen.
11. **Reuse, not a second pipeline; focus is the item's one owner.** While a story plays
    the ViewModel is in `.loupe`, and the story's item *is* the loupe's `focusedAssetID`;
    the story keeps no copy. So the picture, the video and their downloads are the
    loupe's own — the pane slot through `PreviewImageLoader`, `loupeVideoState` through
    `VideoPreviewLoader`, the `MaterializationCoordinator` at interactive priority — and
    Photo commands go through the loupe's target resolver. Every writer of focus — the
    story's moves, Move to Trash's successor, a reorganization's remap — moves the story,
    because there is nothing else to move. Every `setFocus` is a new visit
    (`focusVisit`), and the story's state (`StoryPlayback`: the visit, pause, the pane's
    report, the video's state, the hold) starts over with it. Every report — the pane's,
    the kind read's, the player's, the hold's — carries the visit it was made for and is
    dropped for any other, so a late report from an earlier visit of the same item, or a
    cancelled video preparation, moves nothing. `CatalogWindowViewModelStory` owns this;
    the pure `StoryPlaybackPolicy` decides the start, next, previous, the end, the
    survivor after a catalog change (the loupe's `pruneFocus`) and when a hold may start.
    The loupe's own tools that draw on its pane — crop, the white-balance picker, zoom,
    Trim Video, Live Photo motion — are disabled while the story plays, and its
    advance-after-choice does not move the story.
12. **Not built:** music, a strip above the grid, notifications, saved or favourite
    memories (no albums), seen/unseen marks or any stored watched state, trips, quality
    filtering, "feature less", hiding date ranges, a still-duration setting, Live Photo
    motion, export as a movie, Immich's Up Next and Previous peeks, a heart, a mute
    button, a location line, and a gallery below the player.

## Alternatives Considered

### A strip above the grid (Immich, Google Photos)

Rejected by the placement choice, and on Otos's own rules: the top of the grid
belongs to the day bar (DES-069), the grid is the one AppKit boundary, and a strip would
render these items a second time in All Media ("one fact, one owner").

### A snapshot of the day's items

Immich builds memories once a day; its users' most common complaint is that late
imports never appear. A live scope costs one walk of the scope and follows the files.

### SQLite `localtime` to bucket days in SQL

`strftime('%m-%d', best_capture_unix, 'unixepoch', 'localtime')` (the instant column of the time) uses SQLite's notion of
the zone, which is not `Calendar.current` and is fixed per connection; the grid's day
bucket would then disagree with the scope's. The chosen predicate applies no zone: it
writes `best_capture_local`, already the clock's reading.

### One range of `best_capture_local` per earlier year or month

The first build: an `OR` of half-open day ranges from the earliest dated capture,
which the order index answers about 20× faster on 500,000 rows (6 ms against 106 ms).
But SQLite refuses an expression deeper than 1,000 terms and more than 32,766 bound
arguments, so one photo dated 1904 — a scan, or a camera that lost its clock — gives
1,464 month ranges and the scope fails to read. A balanced `OR` tree avoids the depth
but not the argument limit for a bogus year. The predicate costs 21 ms on the reference library's
19,500 items and stays linear; measure again before reaching for ranges.

### A fourth view mode, or the ordinary browser

The first plan showed the scope in the ordinary grid, loupe and compare. A pane of its own
was chosen instead; a view mode would inherit zoom and the day bar, as ADR 0040 found
for a map mode.

### Circles as the cards

Considered after the ordinary browser was rejected. No surveyed product uses
circles as a full page; a circle centre-crops a scene photo
(`docs/research/2026-11-09-on-this-day-layouts.md`).

### Months beside years, always

Showing last month's 12th next to 12 November three years ago crowds the years out of the
cards in any library older than a few months, and months are wanted only when nothing
newer is available. Months are the fallback, never mixed in.

### Deciding years or months with the filter applied

Then a video filter over a scope whose year holds only photos would show last month's
videos under the same day — the filter would widen the scope instead of narrowing it.
The unit is the scope's, decided before the filter, as every other scope dimension is.

### The nearest earlier day with photos

Walking back to the closest day that holds anything answers "what happened recently",
not "what happened on this day"; it would also need a search the ranges do not.

### A timer for midnight

The platform reports the day change, so time would stand in for a fact (ADR 0033).

### A second decoder or player for the story

Two owners of one asset's picture would disagree on materialization and teardown; the
loupe's owners already answer every case the story needs.

## Consequences

- `SidebarSelection` gains `.onThisDay(CalendarDay)`; every exhaustive switch over it
  names it, and `BrowserPlace` persists it without its day.
- `CatalogScopePredicate` gains `date`; the gateway's scope clause decides the unit in the
  read's transaction, so `orderedAssetIDQuery` and `filterOptionRowsQuery` take
  the `Database`.
- `DateConstraint.anniversary` resolves to years or months inside each read with one
  extra walk of the year's rows (`CatalogQueryGateway.anniversaryRowsQuery`, through a
  capture-time index), which stops at its first row shown; the order read builds the
  stacks in its own transaction before its rows and hands them to the walk, and a count,
  read only for an empty scope, builds them once for the walk and for itself, counting only
  the rows `OnThisDayPicks.shows`, so the empty state it decides agrees with the cards; the scope's
  reads filter rows by a function rather than an index range, linear in the scope's
  rows, and `op=onThisDay.query` carries the cost. The benchmark cases
  `projection.windowState.onThisDay.years` and `.months` watch it.
- `CatalogWindowState` grows `onThisDay`; `CatalogMediaEmptyState` grows
  `nothingOnThisDay(CalendarDay)`.
- A time-zone change that keeps the same calendar day does not re-query by itself; the
  next catalog change does, with the new zone.
- Keyboard: the cards are focusable and arrow-navigable; the player takes focus while
  it plays.

## Retirement Proof

Nothing is replaced. The Places stack's thumbnail load moved to the shared
`ThumbnailLoad`, which the cards use too.

## Living Documentation Impact

- `docs/requirements.md`: APP-069, APP-070, APP-071 added; APP-002, APP-013, APP-019
  amended.
- `docs/design/design-system.md`: DES-112; `docs/design/on-this-day.md`.
- `docs/architecture.md`: dataflow, ViewModel row, where-to-change row.
- `docs/research/2026-11-07-memories-and-highlights.md`,
  `docs/research/2026-11-09-on-this-day-layouts.md`,
  `docs/research/2026-11-12-on-this-day-months.md`.

## Reversal Plan

If the story must play another scope, the policy and the owner are scope-agnostic over
ordered IDs and anniversary runs; give that scope a fixed order and publish its runs. If the
cards must change shape, `OnThisDayView` takes only the per-anniversary values and can be
swapped without touching the scope, the policy or the player.
