# Grid applies during motion (2026-11-16)

## Question

Every act's result is to be visible within 100 ms (plan 0116). Like, Dislike and Not Rated
are (14 to 24 ms). Move to Trash and Put Back were not: #852's optimised sandbox tour
measured them at 245 and 381 ms. The grid held a new state as pending while an earlier
structural apply's animation ran, and applied it only when AppKit reported the motion
finished. Can the grid apply a state while an earlier batch still moves, and what does
AppKit then draw? And what is the rest of the time from the act to the grid?

## Method

1. A probe test (removed after it ran) on a bare `NSCollectionView` with a flow layout in
   an ordered-in window, 20 items, every batch issued through `animator()` inside an
   `NSAnimationContext` group, as `MediaGridViewController.applyBatch` does.
2. The dev app's unified log for one optimised sandbox tour before the change
   (`script/scorecard.sh --tour --dev --optimized --home <sandbox>`, 28 generated JPEGs),
   read line by line from the Move to Trash intent to the Put Back result.

## Findings: AppKit

| Probe | Result |
| --- | --- |
| Four batches (delete, delete, insert, insert) of 0.35 s issued back to back, each before the earlier ones' motion ended | No exception. On each return the item count, the visible items and their index paths are the new data source's. |
| Their completions | All four arrive, every one `finished=true`, out of order (`b2, b1, b3, b4`), after the motion. None arrives before `performBatchUpdates` returns. |
| A tile's drawn position when a second batch is issued mid-motion | The second motion starts where the tile is drawn: 162.01 pt before the batch, 162.02 pt in the frame after, then travelling to the new frame. It changes course; it does not jump to the first batch's end or back to its start. |
| A batch with a zero duration (Reduce Motion) | Its completion arrives on the next main-queue turn, never before the call returns. |
| An animated layout swap issued during a batch's motion, then a batch during the swap's | No exception; counts are the data source's; both completions arrive. |
| `removeAllAnimations()` on the item layers mid-motion | The batch's completion arrives on the next turn, `finished=true`. Ending a motion early is possible, but not needed: a new batch already carries the tiles on. |

So a structural apply is complete, for every fact the grid holds, when `performBatchUpdates`
returns: the data, the layout and the item views are the new structure's. Only the drawn
positions are still travelling, and a later batch takes them over smoothly.

## Findings: the 187 ms of a Move to Trash with no motion running

In the before tour (main `df674c59`), Move to Trash showed at 187 ms and Put Back at
286 ms. The Trash's state did not wait for a motion this time (the previous apply had
finished 146 ms before the act); Put Back's did:

| ms after the intent | Line | What it is |
| --- | --- | --- |
| 0 | `op=ui.actToResult phase=start act=moveToTrash` | the intent |
| 0.1 | `op=projection.hold phase=held hold=trash:…` | Projection holds the hide, off the main actor |
| 11.6, 28.4 | `Media grid state received … actions=refreshVisible` | two SwiftUI updates for the act's other changes (the successor's selection, the Info pane) |
| 85.3 | `op=ui.state.apply … delta=-1` | the window's state without the item, applied on the main actor |
| 107.9 | `Media grid state received items=27 … actions=apply` | SwiftUI hands it to the grid; the gate starts the apply |
| 134.3 | `op=ui.state.apply … delta=0` | another main-thread state apply |
| 186.7 | `Media grid structural apply started` | the off-main build's result committed |
| 187.9 | `op=ui.actToResult phase=finish act=moveToTrash ms=187` | the result |
| 347.0 | `op=ui.actToResult phase=start act=putBack` | Undo |
| 417.9 | `op=ui.state.apply … delta=1` | the state with the item back |
| 440.8 | `Media grid state received items=28 … actions=pending` | held: the Trash removal is still moving |
| 627.5 | `Media grid structural apply finished … removed=1` | the removal's motion ends (441 ms after its commit) |
| 631.9 | `Media grid structural apply started items=28` | Put Back applied: 286 ms after Undo |

- **Put Back waited 191 ms for the Trash's motion** (440.8 to 631.9). The change below
  removes that wait.
- **What was left of the Trash's 187 ms was the main thread, not the grid.** The hide
  reached Projection in 0.1 ms; the window applied the state 85 ms later, and the grid's
  commit followed 79 ms after SwiftUI handed the state over. Each step waited for the main
  thread's next turn, and the turns were 25 to 55 ms apart in an optimised build with the
  Info pane open. The log does not say what filled them.

## Change

- **An apply completes when its commit returns** (`MediaGridViewController.commitStructure`).
  The completion — tile pruning, the visible-detail pass, the selection render, the gate's
  drain — runs there, so the gate is free for the next grid at once. AppKit's completion only
  reports how long the motion ran (`op=ui.mediaGrid.motion`), and the grid counts the motions
  still running (`motionsInFlight`, logged on each apply as `motionsInFlightAtCommit`).
- **The motion is unchanged:** 0.35 s, the same curve, the same fade and inset of a removed or
  inserted tile, none under Reduce Motion. What changes on screen is only that a tile already
  moving changes course toward its newest place when the next change arrives, instead of the
  next change appearing after the motion ends.
- A zoom swap still holds the gate for its 0.30 s motion: its anchor scroll is animated and
  its visible-detail pass must read the viewport the scroll ends at.
- `MediaGridBatchApplyTests` deliver five hides and a Put Back, each while every earlier apply
  still moves (the motion lengthened so it is still running under any load), and check the
  visible items at each commit; another runs the same under Reduce Motion.

## After the first change: the off-main build's turn

The first after tour (Move to Trash 217 ms, Put Back 245 ms) showed no wait for motion, and
a new gap: the grid took the Trash's state at +111 ms and committed it at +217 ms. The
build ran off the main actor in under a millisecond; its result then waited 106 ms for a
main-thread turn to come back to. Every commit in these sessions landed within 0.2 ms after
an `op=ui.state.apply`, the next turn the main thread had free.

A hide's structure does not need that turn. Built from the old sections and the edit, it
costs the sections and the edit, not the items (ARC-023). Yet in the tour the hide was not
an edit of the order on screen. Projection took the items off `lastBuiltState`, but every
publication hands an unchanged order on as the last publication's own object
(`sharingUnchanged`). After any read, the build's order and the published one were equal
arrays in different objects, so `CatalogGridContent.edit(from:)` found no edit.

- **Projection takes a hide off its last publication** while nothing was built since it and
  the holds only take more off (`CatalogProjection.republish`). By value it is the same
  window; its order is an edit of the one the window shows, and so is each of several hides
  in a row. `CatalogProjectionTests.eachHideIsAnEditOfTheOrderLastPublished` pins it.
- **The grid builds an edit in the turn that delivers it** and commits it there
  (`MediaGridViewController.applyStructure`). Every other build still runs off the main
  actor.

## Before and after

Optimised dev build, sandbox home, 28 generated JPEGs, one tour each
(`script/scorecard.sh --tour --dev --optimized --home <sandbox>`):

| Act (intent to grid) | Before (`df674c59`) | Applies do not wait for motion | And a hide commits in its own turn |
| --- | --- | --- | --- |
| Dislike / Like / Not Rated | 23 / 23 / 21 ms | 29 / 25 / 23 ms | 21 / 21 / 18 ms |
| Move to Trash | 187 ms | 217 ms | **98 ms** |
| Put Back | 286 ms | 245 ms | 292 ms |
| Put Back's file work done | 3 ms | 4 ms | 66 ms |

- **Move to Trash now meets the 100 ms target.** In the final run the window applied the
  hidden state at +77 ms, SwiftUI handed it to the grid at +97 ms, and the grid committed
  it in the same call at +97.1 ms.
- **Put Back does not, and the grid is not what holds it.** Its result follows the Store
  (APP-085): the file is put back, the Store records it, and Projection reads the order
  again. In the final run Projection published the item back at +110 ms, after the file
  work. The state reached the grid at +173 ms. That publication is a fresh read, not an
  edit, so its build ran off the main actor, and its result waited for a main-thread turn
  until +288 ms. A Put Back within 100 ms would have to show the item before the Store has
  it back, as a Move to Trash does. That changes APP-085, and it is not done here.
- What fills the main thread's 25 to 55 ms turns is still not attributed. The Time
  Profiler runs for these tours did not complete: one attached after the acts had run, and
  an all-process recording grew to 1.7 GB on a disk with 6 GB free and was stopped and
  deleted.

## Put Back before its file work (the follow-up)

Put Back now shows its result the way Move to Trash does: Projection puts each item back
beside the neighbours its hide recorded, first into the order last published, so the grid
takes it in by the inserts and commits it in the turn that delivers it; the file work and
the Store follow (APP-085, DES-119). Optimised dev build, sandbox home, 28 generated JPEGs,
two tours (`script/scorecard.sh --tour --dev --optimized --home <sandbox>`), the tour now
also running five Moves to Trash in a row and then five Undos, each issued once the one
before shows its result:

| Act (intent to grid) | Tour A | Tour B |
| --- | --- | --- |
| Put Back (single) | 100 ms | 27 ms |
| Five Moves to Trash | 342 (fixed below), 85, 96, 171, 85 ms | 86, 163, 100, 121, 104 ms |
| Five Undos | 83, 84, 66, 88, 25 ms | 83, 150, 164, 85, 85 ms |
| Put Back's file work done | 192–552 ms | 196–491 ms |

- **Every Put Back and every Move to Trash committed in the call that delivered it** (the
  grid's `actions=apply` and `structural apply started` in the same millisecond).
- **What is over 100 ms is the window's main thread.** In each slow act the window first
  applied a publication from before the act (`op=ui.state.apply … delta=0` at +60 to +76
  ms), then the act's own at +121 to +141 ms: one main-thread turn of about 60 ms each.
  This is not the grid, and it is not attributed further here.
- **Tour A's 342 ms Move to Trash was a defect, fixed before Tour B.** It trashed the photo
  whose Put Back was still held, and the Put Back put it back on every publication until
  its hold retired. A Put Back now never puts back an item a newer Move to Trash holds
  (`CatalogProjectionTests.aPutBackStaysShownThroughAnotherHideAndARead`).
