# On This Day — Spec

GOVERNS: `OtosKit/Views/OnThisDayView.swift`, `OtosKit/Views/OnThisDayPresentation.swift`, `OtosKit/Views/StoryPlayerView.swift`

The On This Day scope: a sidebar row whose detail is one photo card per earlier
anniversary — a year, or a month when no earlier year holds the day — and the story
player a card starts. Cites `docs/design/design-system.md` by ID; rules are
not restated. Decision record: `docs/adr/0049-on-this-day-and-its-story-player.md`.
Layout survey: `docs/research/2026-11-09-on-this-day-layouts.md`.

Owners: `OtosKit/Views/OnThisDayView.swift` (bar and cards), `OtosKit/Views/StoryPlayerView.swift`
(player), `OtosKit/Views/OnThisDayPresentation.swift` (every string). Content:
`CatalogOnThisDayState` (`OtosKit/Models/OnThisDayModels.swift`); the story:
`CatalogWindowViewModelStory.swift` with `StoryPlaybackPolicy`.

## Reference

Immich (v3.3.0 on the test Immich server, and its memories page, PR #28675): landscape cards with the
key photo, `N years ago` at the bottom left over a dark gradient, and a viewer with Close
and the title leading, Play / Pause, a segment per item and `1/20` in the middle, and the
date on the picture's top left. Otos takes these. It drops the viewer's Up Next and
Previous peeks, the heart, mute, the location line and the gallery below, none of which
was asked for.

## Terminology

| Term | Means | Not |
| --- | --- | --- |
| **On This Day** | The row and its scope: items captured on today's month and day in earlier years, or — only when no earlier year holds one — on today's day of the month in earlier months. | "Memories" (a broader idea Otos does not build) |
| **Anniversary** | One earlier year, or month, that holds a match, shown as one card. | an album, a memory |
| **Story** | The items played one after another, newest anniversary first. | a slideshow, a movie |

## Sidebar

`On This Day`, SF Symbol `calendar`, directly under `All Media`, a top-level row present
whenever one fixed library exists. No trailing count, as Places has none. The row is today's: when the
day changes it is the new day's.

## Toolbar

The view-mode picker shows no segment and is disabled (DES-053), as on the duplicates
list: the anniversaries are the scope's one presentation. The sort control is disabled in
place with the tooltip `On This Day always shows the newest first` (DES-038); View ▸ Sort
is disabled too. The filter works and narrows each anniversary; it never turns years into
months. Zoom is disabled.

## The bar — L1 and L3 (DES-112)

The surface's single fact (DES-010), 52 pt in every state in the Places bar's position
(DES-105, DES-053), drawn above the cards and above every empty state:

| Level | Text | Rule |
| --- | --- | --- |
| L1 | `9 November` | `.title3` semibold; the day in the user's locale (`dMMMM`) |
| L3 | `14 photos and videos from 4 years` / `1 photo or video from 1 year` / `612 photos and videos from 4 months` / `No photos or videos from earlier years or months` | `.subheadline`, L3 color, tabular digits (DES-005); months only when no earlier year holds the day |

## Cards (DES-112)

An adaptive grid on the `content` surface: cards 260–420 pt wide, 16 pt gaps, 20 pt
margins, leading-aligned, newest first; it scrolls when the cards do not fit.

| Part | Rule |
| --- | --- |
| Face | 16:9, radius 9; the anniversary's key photo — the first item of its run, its newest capture — aspect-filled **[deviation DES-060A]**: a cover stands for the anniversary and is not the photograph under review; Immich, Apple and Google crop covers too |
| L1 on the photo | `3 years ago` / `1 year ago`, or `1 month ago` / `14 months ago` (months are never rounded to years), white `.title3` semibold at the bottom left, 12 pt inset, over `DesignPalette.photoScrim` (black 40 %) fading to clear upward |
| Under the face | 7 pt below: the anniversary's title (ADR 0053), L2 `.body`, one line truncated at its end, held empty until one is written; then, 2 pt below, L3 `.subheadline` `9 Nov 2023 · 14` (`dMMMy`, tabular digits) |
| Before the first decode | DES-063's kind glyph at tertiary strength on the `content` well (DES-022) |
| Painted | The cover stays until a newer thumbnail for the same key item replaces it (the grid's no-blank rule, in spirit); a card made again — after a story closes, or recycled by the grid — reads the shared tile store while rendering, so it paints its cover in its first frame; the covers are pinned in that store while the scope shows, as the grid pins its visible tiles, so no budget pressure can drop one |
| Focus | The system focus ring, never suppressed (DES-081), and DES-061's 3 pt accent border on the focused card's face |

| Act | Result |
| --- | --- |
| Click | Plays that anniversary's story. |
| Return or Space | Plays the focused card's anniversary. |
| ← → ↑ ↓ | Move focus among the cards, by one or by a row. |

VoiceOver reads a card as a button: `Berry Picking, 3 years ago, 14 items, 9 November 2023`, the
title first once one is written (DES-082).

## Titles

Apple's on-device model titles each anniversary from the descriptions of up to eight of its
photos, in play order, and how long ago it is: at most six words, the people's names where
they fit (`AnniversaryTitleWriter`, ADR 0053). An anniversary none of whose photos is
described yet has no title; the title is written again when those descriptions change.

## Empty states

| State | Title | L3 |
| --- | --- | --- |
| Nothing on this day in an earlier year or month | `Nothing on This Day` (title case: `On This Day` is the scope's proper name, like `Places`) | `Photos and videos taken on 9 November in earlier years, or on this day in earlier months, appear here.` |
| Filter leaves nothing | `No Matching Media` | the shared filter message, with `Clear Filters` |
| Libraries still being checked | `Checking Libraries` | shared |
| Libraries offline | `No Available Media` | shared |

## Player (DES-112)

The player replaces the cards while it plays. View ▸ Play Story (⌘Return) plays from the
newest anniversary; a card plays from its own. Either continues into older ones after
the anniversary's last item.

**Bar**, 52 pt, the Places bar's chrome:

| Zone | Content |
| --- | --- |
| Leading | `Close` (`xmark`), then L1 `1 year ago` or `1 month ago` (`.title3` semibold), then the anniversary's title, L3 `.subheadline`, one line truncated at its end, nothing until one is written |
| Center | `Pause` / `Play` (`pause.fill` / `play.fill`), the segments, then `4/12` (`.subheadline`, L3, tabular) |
| Trailing | `Previous` (`chevron.left`), `Next` (`chevron.right`) |

Every button is a ≥ 28 pt target with a tooltip and an accessibility label (DES-051).
Segments: one per item of the current anniversary, 4 pt tall, 4 pt apart, at most 360 pt in all;
behind filled, ahead empty, the current one filling as it plays — the accent on a
`.tertiary` track (DES-024). Disabled, never removed (DES-053): Previous on the first
item, Next and Play on the last once it has finished.

**Picture**: aspect-fit on the `content` surface (DES-022, DES-060A). The item's date,
`9 November 2023` (`dMMMMy`), white `.title3` semibold at its top left, 12 pt inset, over a
top scrim. A video plays inline with its own sound and no player chrome. While bytes are
awaited, DES-086's centered indicator; before the full decode, the upscaled thumbnail;
when the item can have no picture, DES-063's slash glyph. An item change cross-fades in
0.25 s ease-out, 0.15 s under Reduce Motion (DES-070, DES-075).

**Timing**: a still holds 5 s from when its picture is on screen; an item with no picture
holds 5 s once the pane says so; a video plays to its end, its segment filling over the
range it plays (a trim's, if it has one); a video the player cannot play holds 5 s on its
poster like a still; nothing advances while bytes are awaited. Pause freezes both; Play resumes. After the last item the player stays on
it, paused.

## Keyboard

| Key | In the player |
| --- | --- |
| Space | Play / Pause |
| ← / → | Previous / next item, across anniversaries |
| Esc | Close: back to the cards, focus on the anniversary it was on |

The player is the keyboard target while it plays and draws no ring around itself
(DES-081); Tab moves to its buttons, each with its own ring.
| P / X / U, I, E | The Photo commands and the inspector, on the item on screen |

Tab reaches the cards, then the player's buttons. Changing the sidebar selection or the
day closes the player.

## Verification

`script/smoke-run.sh --verify onThisDay` selects the scope (ADR 0020), and with
`OTOS_SMOKE_CAPTURE_PATH` and `OTOS_SMOKE_APPEARANCE` writes the window's own rendering
once the anniversaries have published (or the scope is known to be empty); with
`OTOS_SMOKE_PLAY_STORY=1` it plays the story first and captures once its first picture has
settled. A capture of cards needs earlier years or months, so it runs the dev binary against a
throwaway library (`CFFIXED_USER_HOME`, wallpapers copied and given a capture date and
offset with `exiftool`), never the user's library for anything but reading. The
`op=onThisDay.*` and `op=story.*` log lines carry the query, its unit (years or months),
the scope's anniversaries and every
start, advance, hold, pause, video, end and close.

## Not in this spec

Music, a strip above the grid, notifications, saved or favourite memories, seen or
unseen marks, trips, a still-duration setting, Live Photo motion, export as a movie.
