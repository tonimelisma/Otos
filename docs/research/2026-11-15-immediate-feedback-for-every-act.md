# Immediate feedback for every act (2026-11-15)

## Question

The owner, after using the installed build: a sidebar click and Move to Trash stall the window
instead of showing their result at once. Apple's HIG (Loading: show something as soon as
possible, placeholders replaced as content arrives; Progress indicators: indeterminate while the
duration is unknown, kept moving, in one place; Feedback: status beside what it describes) asks
for the opposite. Which acts wait on a store write or a projection read before the user sees
anything, and which of those can show their result from what the window already holds?

## Method

Code reading of every act's path from its intent to the first state change the window draws;
tests at the owner boundaries that hold the competing event at its suspension; the benchmark
catalog (ADR 0043) for main-actor and Projection cost. Nothing was read from the installed app
or its catalog.

## Findings

### A sidebar click (DES-118, APP-084)

- Before: the panes were chosen from the *published* scope (`state.detailSurface`), so between
  the click and Projection's publication the pane, its bar and its title stayed on the scope the
  user left (#754 and #775 made it inert, #774 made held returns fast). Under load that interval
  was seconds (`docs/research/2026-11-15-scope-returns-and-superseded-builds.md`).
- After: `CatalogWindowViewModel.detailPane` (`CatalogDetailPane`) is the one answer to which
  pane shows: the selected scope's surface, and `shown` or `waiting(showsIndicator:)`. The title
  comes from the same policy Projection uses (`CatalogWindowPolicy.title`), the surface's bar is
  drawn with only what the window holds without the scope's read, and the content area is empty.
- The indicator: DES-086's one centered indeterminate indicator. It appears only after the
  waiting pane reports a presented frame (`FramePresentedReporter`, its display link's first
  callback after joining the window), so a scope whose state is applied within the frame of the
  click never shows one. This is a platform report, not a timer (ADR 0033); an occluded window
  presents nothing and needs no indicator. Decided against "indicator at once": every held
  return would flash it for the one or two frames its publication takes.
- What each bar shows while waiting (DES-030/031: no count the read decides):

  | Surface | L1 while waiting | L3 while waiting |
  | --- | --- | --- |
  | Media browser | none (the day bar names the day under the grid; there is no grid) | — |
  | Places (DES-105) | empty line, height held | — |
  | On This Day (DES-112) | the day (`15 November`), which the window holds | empty, height held |
  | People (DES-109) | `14 people` from People, which is the same in every scope; empty before its first build | the tally likewise |
  | Duplicates (DES-107) | the bar from the groups, which are the same in every scope, its act and links disabled in place | likewise |

### Move to Trash (DES-119, APP-085)

- Before: `moveTargetedMediaToTrash` → (with the question on) a catalog read to size the
  download → `store.markPendingTrash` (a write that queues behind background writers) → the
  store's change → a Projection read of the scope → the grid's apply. The tiles left only at
  the end, the selection moved after the write, and Undo was registered after it.
- After: in the step that applies the intent the targets leave the window, the selection or
  focus moves to the nearest survivor, `Undo Move to Trash` is registered and the duplicates
  receipt shown; the mark follows on the trash intent stream.
  - Projection owns what is shown, so the hide is a Projection intent
    (`CatalogProjectionIntent.hide`) on the one lossless stream that also carries the queries.
    Projection takes the items off the window it last built (`CatalogWindowState.hidingItems`:
    the order and its day buckets, the tiles' stacks, the map, On This Day's runs, the duplicate
    groups) with no catalog read, and every later publication leaves through the same function
    until a pass that read the catalog after the mark covers it. A held answer covers nothing,
    so it can never retire a hide.
  - The trash queue's consumer relays the mark's result: `hideLanded` (records the membership
    change the mark is and rings the loop) or `hideWithdrawn` (a failed mark, or an undo that put
    the items back). The read of the landed mark publishes a grid equal to the hidden one, which
    `sharingUnchanged` hands on as the hidden one's own content: nothing is applied twice.
  - The mark, undo and redo travel the trash intent stream in order. The consumer keeps what
    each command's mark hid, so an undo pressed before the mark lands is applied after it and
    puts back exactly what it hid. A mark that fails or hides nothing takes its own undo entry
    off the stack (`TrashUndoTarget`).
  - A failed mark was silent before (`op=trash.queue phase=failed` was logged and nothing was
    shown, which was harmless while nothing had been hidden). Now the items come back selected
    under DES-076's existing failure alert.
- The large-download question (APP-045) stays before the hide. The window holds no locality
  fact — dataless is a point-in-time filesystem fact Otos never stores (ADR 0008) — so the answer
  cannot be known synchronously. What it costs: one `lstat` per target's own file, off the main
  actor, plus a catalog read of the cloud-only targets' members. `downloadBytes` now reads the
  catalog only for items whose own file is cloud-only; a command of local items is answered from
  their files' flags. A cloud-only companion of a local file is still downloaded by the queue but
  no longer counted toward the question.

### Every other act

| Act | Same frame today | Waits on | Verdict |
| --- | --- | --- | --- |
| Like / Dislike / Not Rated | nothing: pane previews, tile icons, the toolbar control and the advance all follow the store write; tile icons follow the detail refresh after it | `setMediaChoices` (writer queue) | Result knowable locally; not fixed here — needs a pending-choice owner the tile detail reads consult (no such mechanism exists to reuse) |
| Expand / collapse a stack | nothing until Projection re-collapses | a Projection pass (no read: the order is reused) | Waits on the loop, not a read; not fixed |
| Filter, sort | the old content, same scope | a Projection read | Not knowable locally (a new order); the scope stays, as today — no status surface |
| Search text | `Searching…` subtitle | the search reader | Status shown at once (ADR 0048) |
| Select a library / import / any scope | the selected scope waiting | the scope's read | Fixed (DES-118) |
| Name / rename a person, merge, hide/unhide, favourite, make key photo, This Is Not a Face | nothing until People rebuilds | the people write and a People build | Knowable locally for name/favourite/hide; not fixed — People has only `PendingPeopleActs` for merges |
| Edit sliders, Rotate / Flip, Revert | the live render in the loupe at once | — | Already render-first |
| Undo of Move to Trash | items return when the store's withdrawal is read | the queue's undo, then a read | Now read at once instead of on the cadence (`hideWithdrawn(storeChanged:)`) |
| Eject | the source's row marks ejecting at once | — | Already immediate |
| Start an import | the bar's state changes when the coordinator publishes | the import coordinator's next presentation | Not measured as slow; not fixed |
| Cancel an import | `Stopping…` at once | — | Already immediate |

## Benchmarks

`script/bench.sh run` on e0079031 (Debug build, three processes, generated catalog):

| Case | M instructions | Median ms | What it is |
| --- | --- | --- | --- |
| `projection.hide.days5000` | 19.7 | 2.3 | Projection takes 5 of 158,000 photos off the held window (`hidingItems`), off the main actor |
| `grid.hideApply.days5000.mainThread` | 138.0 | 116.3 | The grid's main-thread apply of that removal (and, alternating, its return) |
| `grid.structuralApply.days5000.mainThread` | 136.1 | 109.3 | For comparison: a whole-grid structural apply |
| `grid.reorderApply.days5000.mainThread` | 297.8 | 356.1 | For comparison: the 200-photo reorder |

- The hide itself is cheap and in proportion to the change past one copy of the order.
- The grid's removal of a few items is not: its main-thread apply costs about what a
  whole-grid structural apply does, about 116 ms in Debug at 158,000 tiles. Which part of
  `MediaGridStructuralApply` spends it was not profiled here. So Move to Trash at owner scale
  is one frame-dropping apply rather than the seconds it waited before, but not under 16 ms.
  Bringing a removal of N items down to cost in N is the grid structure's work (the reorder-build
  branch in flight), not this change's.

## Not established

- The waiting pane was not seen in a running build: ImageRenderer captures (light, dark,
  grayscale) show the bars and the indicator's position but cannot draw AppKit's spinner, and no
  sandboxed dev build was driven.
- Whether a held return's state arrives within the frame of the click on the owner's machine:
  it decides whether such a return ever shows the indicator.
