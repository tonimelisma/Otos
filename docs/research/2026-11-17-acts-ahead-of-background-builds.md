# Acts ahead of background builds (2026-11-17)

## Question

After every publication of a query became an edit of the last one
(`2026-11-17-acts-on-an-unshown-reorder.md`), the slowest trash and Put Back acts on a seeded
160,002-file library took 98 and 92 ms, and most of that passed before the state reached the
main actor. Where does an act's time go between the act and the main actor, and which part is
work and which is waiting?

## Method

- Counted, not timed: `CatalogGridContent.Work` (items visited one at a time, position-index
  entries written, items copied in runs) on every content, logged on each publication
  (`gridWork=`) and bounded by `ActPublicationWorkTests`, at 160,000 and 16,000 photos.
- New lines on the act path: `op=projection.act` (how long the act waited for the projection
  actor, `waitedUs`, and how long its own step took, `applyUs`), `deliveryWaitUs` on
  `op=ui.state.apply` (how long a publication waited in the window's mailbox for the main
  actor).
- Tours: `script/scorecard.sh --tour --dev --optimized --seed 160000 --seed-media small
  --settled --idle 20`, one at a time under the machine's reference-scale lock, with a second
  `log stream` of the toured process beside the scorecard's own capture. An unattended Mac
  with other sessions' builds and tests running; every act ran in an occluded window.

## Split of one act (before the change)

Counted at 160,000 photos, one photo:

| Act | visited | index entries written | copied in runs |
| --- | --- | --- | --- |
| Move to Trash | 1 | 159,999 | 159,999 |
| Put Back | 159,999 | 160,000 | 0 |

The Move to Trash's publication wrote a new position table for the whole order; the Put Back
walked the order to place one photo and wrote the table again.

On a baseline tour (instrumented, algorithm unchanged), in ms from the act:

| Act | total | waited for the projection | its own step | to the main actor | main actor to commit |
| --- | --- | --- | --- | --- | --- |
| Move to Trash | 23 | 0 | 9.7 | 9 | 5 |
| Put Back | 27 | 0 | 21.9 | 1 | 4 |
| Move to Trash (run) | 93, 40, 29, 26, 43 | 15.3, 0, 0, 0, 0 | 8.2, 8.1, 12.6, 12.9, 9.9 | 48, 22, 10, 3, 19 | 23, 10, 7, 11, 14 |
| Put Back (run) | 76, 49, 60, 87, 75 | 0, 0, 0, 11.5, 0 | 22.6, 26.4, 24.9, 38.0, 34.9 | 49, 18, 0, 27, 37 | 5, 6, 9, 11, 4 |

- An act's own step on the projection was 8–13 ms (Move to Trash) and 22–38 ms (Put Back): the
  table and the walk.
- Twice an act waited 11–15 ms for the actor, which was running a background pass's
  synchronous steps (the collapse, the publication's comparison: `equalityUs` 20–37 ms on
  those passes).
- The rest was the main actor: a publication waited 0–49 ms in the mailbox while the main
  actor committed the previous publication's grid change (a background reorder's batch update,
  `commitMs` p50 8, p90 25 at this size) or other main-thread work, then 4–23 ms to commit.

## Change

- A content's position index is a table of an order it was made from, the edit from that
  order, and its inserted items by identity (`Positions`); an order made by an edit takes its
  source's index with the edit composed. Only an order read whole writes a table, off the
  actor. A Put Back finds its neighbours by the index and copies the order's runs between its
  insertions (`CatalogGridContent.inserting`).
- Every step of a pass that walks the scope runs off the projection actor (`@concurrent`), the
  publication's comparison and index included (`preparePublication`); the pass's publication
  takes the acts held at its step on top, in the edit's cost, linked to the last publication
  through the base both were made from (`CatalogGridContent.edit(from:)` through a shared
  order, `Edit.inverse`). ADR 0005, "An act's publication is its edit" and "An act is never
  queued behind a build".
- An edit that removes and inserts the same items at the same places changes nothing
  (`Edit.changesNothing`), so a publication equal to the last is handed on as it even when the
  edits that made it took a photo out and put it back.

Counted after the change at 160,000 photos: a Move to Trash visits 2 and writes 0 index
entries, its Put Back visits 5 and writes 1, the same as at 16,000. A read published while a
Move to Trash was held, the read prepared off the actor before the act, costs visited ≤ 8 and
writes ≤ 4 on the actor (`anActWhileABuildIsPublishedIsNotQueuedBehindIt`).

## After the change

Three tours of the changed build. The first's capture lost lines (`dropped=4`,
`complete=no`, the Mac at 62 MB free with 5 GB of swap); the second and third were complete.
Values in ms from the act to its main-actor commit:

| Tour | Dislike / Like / Not Rated | Move to Trash | five in a row | Put Back | five in a row |
| --- | --- | --- | --- | --- | --- |
| before | 5 / 4 / 5 | 23 | 93, 40, 29, 26, 43 | 27 | 76, 49, 60, 87, 75 |
| 1 (partial) | 16 / 22 / 3 | 53 | 137, 25, 98, 40, 34 | 18 | 99, 7, 14, 6, 17 |
| 2 | 5 / 5 / 3 | 18 | 12, 29, 21, 61, 25 | 21 | 18, 8, 14, 64, 9 |
| 3 | 7 / 8 / 3 | 26 | 23, 32, 21, 23, 26 | 58 | 15, 22, 19, 44, 14 |

- On the projection every act now waited 0 ms for the actor and its own step took 0.2–2.9 ms
  (`projection.act`), against 8–38 ms of work and up to 15 ms of waiting before. Its
  publication visited 2–17 positions and wrote 0–5 index entries (`gridWork=`).
- A pass's synchronous publication step (`equalityUs`) fell from p50 12.1 ms, p90 22.2 ms to
  p50 8 µs, p90 11 µs, at most 4.2 ms: what it measured now runs off the actor.
- What is left is the main actor. In the slowest complete acts: the 64 ms Put Back's state
  was applied 2 ms after the act and the grid's batch update then took 57 ms to commit
  (`commitMs=57`, one insertion among 160,001 items); the 61 ms Move to Trash waited 39 ms to
  reach the main actor; the 58 ms Put Back waited 46 ms in the mailbox while the main actor
  committed a background reorder. In the partial tour, the 137 ms and 99 ms acts waited 129 ms
  and 73 ms for the main actor; in the first of them no thread of the process logged anything
  for 68 ms, under the memory pressure above.
- Peak footprint 1,001, 697 and 877 MB against 582 MB before; the grid's tile images, which
  grow with how far enrichment had come, were 193, 100 and 147 MB against 56 MB. An act's
  index now shares its source's table instead of writing one, so the projection holds less per
  publication, not more; the rise was not attributed further.
- After each tour: `leftovers=0`, the sandbox home removed and its volume detached, and
  `pgrep -x Otos` empty.

## What remains

The act → result time at this size is now the main actor's: the delivery wait behind the
grid's commit of background reorders (`commitMs` p50 7, p90 10–12, up to 127 ms) and the
commit of the act's own batch update. That is the grid's apply (ADR 0006), measured here, not
changed.
