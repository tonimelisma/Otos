# Acts on a reorder the grid has not shown (2026-11-17)

## Question

After the scroll hold stopped parking acts (`2026-11-17-acts-at-the-reference-library-size.md`),
three of 48 Move to Trash and Put Back acts on a seeded 160,002-file library still passed
100 ms (101, 113, 116 ms). Their grid apply logged `followsEdit=false`. What made them
compare, and what removes it?

## Mechanism

- A Move to Trash or a Put Back is published as an edit of the last publication
  (`CatalogProjection.republish`, base `publication`): `CatalogGridContent.Edit`, positions
  removed and inserted, linked to the order it was made from.
- While enrichment works a 160,000-photo backlog, reads publish new orders every
  60–100 ms, each a whole order with no link to the one before.
- The window applies only the newest publication (ADR 0004). When an act lands just after
  such a read, the grid still shows the order before the read, and the act's order is an
  edit of the read's order, not of the shown one. Each edit linked one hop, to its source
  only, held weakly, so the grid found no edit and compared the two 160,000-item orders
  item by item (`MediaGridStructureChange`, compared kind), built off the main actor.
- Deterministic twin, `GridContentEditTests.anActOnAReorderTheGridHasNotShownIsTakenInByItsEdit`:
  160,000 photos over 5,000 days, a read that moves 200 photos to other days, then a hide.
  Published whole, the read makes the grid compare more than 150,000 items for the hide.

## Change

- Projection publishes every order of the same query as an edit of the last publication's
  (`CatalogMediaGridState.sharingContent(of:)`). The edit comes from walking the two orders
  side by side (`Edit.between`), which is the walk that already told them equal, plus a
  look-up only where they differ. A photo whose day changed in place counts as moved, so
  every item an edit keeps keeps its day.
- Each content keeps the edit from every earlier order that is still held, with the edits
  in between composed (`Edit.followed(by:)`). The links are weak, so an order is dropped
  once nothing holds it. Because the edits are already composed, a skipped publication
  doesn't need to stay alive.
- The grid takes in an edit with fewer than 1,000 positions in the turn that delivers it.
  It compares nothing and looks up only what the edit inserted, which tells a moved item
  from a new one. The batch is the edit's deletes, inserts and moves. Larger edits (a scan's
  arrivals) are built off the main actor, and only a new query's order is compared.
- Rejected: applying the act first against what the grid shows and the reorder after
  (ADR 0006, alternative 10).

## Measurement

Two tours: `script/scorecard.sh --tour --dev --optimized --seed 160000 --seed-media small
--settled --settle-deadline 60 --idle 20 --deadline 300`. The step deadline was raised
from 120 s because two earlier attempts failed `sandboxLibraryNeverScanned`: under other
sessions' test load, the first scan took 114 s. Act lines come from a live log stream of
the tour's process. Values are milliseconds from the act to its main-actor commit, in an
occluded window.

| Tour | Dislike / Like / Not Rated | Move to Trash | five in a row | Put Back | five in a row |
| --- | --- | --- | --- | --- | --- |
| 1 | 7 / 3 / 3 | 65 | 17, 36, 40, 30, 33 | 29 | 34, 79, 73, 29, 98 |
| 2 | — | 16 | 13, 50, 26, 33, 19 | 29 | 35, 46, 56, 64, 92 |

- All 24 Move to Trash and Put Back acts finished within 100 ms. The worst was 98 ms.
- Every act's grid apply logged `followsEdit=true compared=0`, with `totalMs` of 3–22.
- Background reorders between acts were also edits (`moved=3…40`, `compared=0`).
- After each tour: `leftovers=0`, the home removed, no image attached, and `pgrep -x Otos`
  empty.

## What remains

- In the slowest acts the grid is no longer the cost. For the 98 ms Put Back, the state
  arrived on the main actor 93 ms after the act, and the grid committed it in 6 ms.
- The projection publishes a read every 60–100 ms during the backlog. Each publication
  spends 12–47 ms synchronously on the actor (`equalityUs` on `catalog.projection.window`).
  That time covers the 160,000-entry position index, which existed before this change, and
  the new edit walk. The two were not measured apart. An act arriving during it waits.
- Both points are measured, not changed here. They are the next place an act's time goes
  at this size.
