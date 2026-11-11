# ADR 0049: On This Day is a scope of years, played as a story

- Status: Accepted
- Date: 2026-11-09

## Context

The owner asked for "a story player for on this day, photos and videos, similar to
Immich" after the survey `docs/research/2026-11-07-memories-and-highlights.md`, and then
chose, on 2026-11-09:

- **the unit:** On This Day — items captured on today's month and day in earlier years;
- **the content:** photos and videos;
- **the presentation:** a story player like Immich's — one progress segment per item,
  stills hold, videos play their own length, keyboard navigation;
- **the placement:** a top-level `On This Day` sidebar row under All Media, chosen from four
  options (a sidebar row, a strip above the grid, a menu command only, a sidebar row plus
  a strip);
- **the pane:** a grid of photo cards, one per earlier year, chosen from four options
  (photo cards, story circles, a by-year feed, a hero plus smaller cards) after the
  layout survey `docs/research/2026-11-09-on-this-day-layouts.md`. The reference is the
  owner's own Immich v3.3.0 memory strip and Immich's memories page (PR #28675).

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

**On This Day is a scope, and its years are what that scope looks like.** There is no
view mode for it.

1. **Placement (owner decision).** A sidebar row, `On This Day`, SF Symbol `calendar`,
   second under All Media, present whenever one fixed library exists, with no trailing count
   (owner decision, 2026-11-11).
2. **What matches.** Rows of the available fixed libraries — All Media's membership —
   whose day bucket has today's month and day in a year before today's. The day bucket
   is the day the item was taken on, on the clock where it was taken: the date of its
   local capture time, `best_capture_local` (ADR 0039). That is the same day
   `CatalogStore.orderedAssetIDs` buckets the grid by (DES-069), and it does not depend on
   the Mac's zone. Days and years are counted on the Gregorian calendar
   (`CalendarDay.calendar(in:)`), never `Calendar.current`, whose year is an era year
   under the Japanese calendar (Reiwa 8) and 2569 under the Buddhist one. What the user
   reads is formatted in their own calendar and locale. The match is exact: on a common year, 29 February
   matches nothing. Undated rows never match. It is a live query, never a snapshot, so a
   late import appears and a deleted file goes (ADR 0008).
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
   gateway turns it into half-open `best_capture_local` ranges in the read's own
   transaction: the earliest dated year comes from a `MIN(best_capture_local)` over the
   scope's roots, and `AnniversaryRanges` (pure) builds one range per year from that
   floor through `day.year − 1`, each from that day's midnight to the next on any clock.
   A local time has no zone, so a daylight-saving day is still midnight to midnight. No
   earlier dated year means no range, and the scope selects nothing without asking
   SQLite for rows.
5. **The scope fixes its order.** `SidebarSelection.fixedSort` is `dateNewest` for On
   This Day, and every read uses `CatalogQueryDescriptor.effectiveSort`. The user's sort
   stays in the descriptor as chosen, so leaving the scope restores it. The sort control
   and View ▸ Sort are disabled in place there, with the reason as the tooltip (DES-053,
   DES-038). The filter applies and narrows each year. A keyword search (ADR 0048) also
   only narrows: `CatalogQueryDescriptor.effectiveSearch` orders a fixed-order scope's
   results by that order, never by relevance, so each year stays one contiguous run.
6. **Projection publishes the years.** `CatalogWindowState.onThisDay` is
   `CatalogOnThisDayState`: the day and one `OnThisDayYear` per earlier year with a match,
   newest first, each a contiguous run of the ordered IDs with its key item (the run's
   first, its newest capture) and count, grouped by `OnThisDayYearPolicy` from the day
   buckets the fixed order carries.
7. **The pane is a grid of photo cards (owner decision).** A 52 pt bar in the Places
   bar's place (L1 the day, `9 November`; L3 `14 photos and videos from 4 years`), over
   an adaptive grid of 16:9 cards (260–420 pt wide, 16 pt gaps, 20 pt margins), one per
   year, newest first. A card's key photo is aspect-filled — a cover stands for the year,
   it is not the photograph under review, and Immich, Apple and Google all crop covers
   (`[deviation]` from DES-060A). `3 years ago` sits on the photo over a bottom scrim;
   `9 Nov 2023 · 14` under it. A single click plays that year; Return or Space plays the
   focused card; the arrow keys move focus. The years' covers are this pane's visible items, so they are pinned in the shared
   `TileContentStore` exactly as the grid pins its visible tiles (ADR 0006) while the scope
   shows, and released when it closes; a card made again reads its cover from there while
   rendering. There is no second cover cache. The view-mode picker is disabled, with no
   segment selected (DES-053, the Duplicates precedent). Rules: DES-112,
   `docs/design/on-this-day.md`.
8. **The player replaces the cards while it plays.** It is not a view mode. Its bar is
   52 pt: Close and the year (`1 year ago`) leading; Play / Pause, one segment per item of
   that year and the position `1/20` in the center; Previous and Next trailing. The
   picture is aspect-fit on the `content` surface, the item's date on its top-left over a
   top scrim; a video plays inline with its sound and no player chrome; DES-086's
   indicator shows while bytes are awaited; DES-063's slash glyph when an item can have
   no picture. View ▸ Play Story (⌘Return, Lightroom Classic's Impromptu Slideshow key)
   plays from the newest year; there is no toolbar button, since the cards are the way
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
10. **Keys.** Space plays and pauses; ← and → move across years; Esc closes. Closing
    returns to the cards with keyboard focus on the year the story was on and its item
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

Rejected by the owner's placement choice, and on Otos's own rules: the top of the grid
belongs to the day bar (DES-069), the grid is the one AppKit boundary, and a strip would
render these items a second time in All Media ("one fact, one owner").

### A snapshot of the day's items

Immich builds memories once a day; its users' most common complaint is that late
imports never appear. A live scope costs one indexed walk and follows the files.

### SQLite `localtime` to bucket days in SQL

`strftime('%m-%d', best_capture_unix, 'unixepoch', 'localtime')` (the instant column of the time) uses SQLite's notion of
the zone, which is not `Calendar.current` and is fixed per connection; the grid's day
bucket would then disagree with the scope's. It also cannot use the order index.

### A fourth view mode, or the ordinary browser

The first plan showed the scope in the ordinary grid, loupe and compare. The owner chose
a pane of its own; a view mode would inherit zoom and the day bar, as ADR 0040 found
for a map mode.

### Circles as the cards

Considered after the owner rejected the ordinary browser. No surveyed product uses
circles as a full page; a circle centre-crops a scene photo
(`docs/research/2026-11-09-on-this-day-layouts.md`).

### A timer for midnight

The platform reports the day change, so time would stand in for a fact (ADR 0033).

### A second decoder or player for the story

Two owners of one asset's picture would disagree on materialization and teardown; the
loupe's owners already answer every case the story needs.

## Consequences

- `SidebarSelection` gains `.onThisDay(CalendarDay)`; every exhaustive switch over it
  names it, and `BrowserPlace` persists it without its day.
- `CatalogScopePredicate` gains `date`; the gateway's scope clause reads the floor in the
  read's transaction, so `orderedAssetIDQuery` and `distinctFilterableTypesQuery` take
  the `Database`.
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
  `docs/research/2026-11-09-on-this-day-layouts.md`.

## Reversal Plan

If the story must play another scope, the policy and the owner are scope-agnostic over
ordered IDs and year runs; give that scope a fixed order and publish its runs. If the
cards must change shape, `OnThisDayView` takes only the per-year values and can be
swapped without touching the scope, the policy or the player.
