# An act's result behind a grid reorder (2026-11-19)

## Question

A seeded sandbox tour (`script/scorecard.sh --tour --dev --optimized --seed 160000
--seed-media small`, a visible window) measured Like at `resultMs=516`, over the 100 ms
target, while Dislike before it took 5 ms and Not Rated after it 0 ms. What did the Like wait
on?

## Method

The failing session's unified log read back with `log show` for the app's process, every line
from Dislike's start to Not Rated's finish, and the tour's choice step read against it
(`SmokeTourRunner.choiceAct`). Then more tours of the same command, from another checkout.

## Findings

- **The Like's own work took under a millisecond to reach the tile store, and its write 6 ms.**
  `op=ui.actToResult phase=start act=liked` and `op=mediaChoice.submit choice=liked` landed
  together, and `op=catalog.mediaChoice phase=finish` 6 ms later. No stall was reported, and
  the main thread logged throughout the 516 ms; every `op=ui.state.apply` in it took
  `applyMs=0`.
- **The tile was not held when the choice reached the grid.** The reconfigure that follows
  the submit, 0.6 ms after it, logged `op=ui.mediaGrid.choice phase=reconfigured changed=1
  rendered=0`: none of the collection view's visible items was the act's photo. Dislike's and
  Not Rated's logged `rendered=1` and finished in the same pass.
- **The grid was reordering under the tour.** Enrichment was still learning capture dates
  (`op=catalog.enrichment.batch … facts=captureDate,…`), and each batch it applied reached the
  grid as a structural apply with `reorderOnly=true`, every 50 to 190 ms; the visible set's
  size moved between 5 and 10 tiles from one apply to the next
  (`op=ui.mediaGrid.visibleThumbnails phase=complete visible=…`). Between Dislike's finish
  and Like's submit three of them landed.
- **The result came with a later apply.** `op=ui.actToResult phase=finish act=liked ms=516`
  was logged inside the structural apply that started 8 ms before it: the reorder that laid
  the tile out again, which renders it from the tile store with the choice.
- **Why the tour submitted to a tile it did not hold.** The step checked that its photo was in
  the settled visible set, then selected it and waited for the earlier choices to settle
  (`settled()`), and submitted after that wait. The reorders that landed during the wait moved
  the tile out; nothing checked again before the submit.

- **It did not recur in three more tours.** One on the same tree (Dislike, Like, Not Rated at
  5, 4, 1 ms, window visible) and two with the change below (9, 5, 1 ms with the window
  occluded; 4, 3, 1 ms visible), each with `broughtBack=0`: in none of them did a reorder move
  the tile out before its act. Every tour's Trash check printed `leftovers=0`, and no Otos
  process or sandbox home remained.

## Conclusion

The 516 ms was the tour's instrument, not the act: it timed a reorder bringing the tile back,
because the check that the tile is held came before an await. The choice step now submits
only in the main-actor turn that found the tile held, after every wait
(`SmokeTour.submitWhileHeld`). A tile that left the held set is brought back on screen and
the wait repeated, and the step says how often (`broughtBack=`), so a reorder that moves the
tile is visible in the step and never in its `resultMs`.

Whether the grid should keep a selected tile in place while enrichment reorders it is a
product question this note does not answer.
