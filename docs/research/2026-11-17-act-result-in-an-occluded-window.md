# An act's result in a window nothing presents (2026-11-17)

## Question

Four seeded sandbox tours on one build (`script/scorecard.sh --tour --dev --optimized --seed
200`, an unattended Mac whose display was asleep) measured Move to Trash at 12 to 48 ms and
Put Back at 4 to 28 ms, and skipped every choice act (Like, Dislike, Not Rated) as
`windowOccluded`. Both kinds of act are timed by `op=ui.actToResult`. What does each wait on,
why does only the choice depend on a lit, uncovered window, and what does an occluded window
still do on the main actor?

## Method

Three seeded tours of the dev build compiled as installed (`--optimized`, `--seed 200`, a
sandbox home on its own volume, the display asleep), with the tour's up-front skip removed and
temporary `op=experiment` lines: the window's `occlusionState`, and at every focus scroll,
scroll-bounds change and visible-set pin the collection view's visible index paths, clip
origin and height, and document height. Every tour's Trash check printed `leftovers=0`; no
Otos process remained and nothing stayed mounted. The temporary lines were removed after.

## Findings

- **What each act waits on.** Move to Trash and Put Back end in the grid's structural apply,
  right after the collection view is handed the new order (`completeMembershipToResult`).
  A choice ends when the grid renders the act's tile from the tile store
  (`completeChoiceToResult`): the reconfigure of a tile the collection view holds, in the
  SwiftUI update that delivers the choice, or the tile's next layout. Both are main-actor
  commits; neither waits on a presented frame.
- **The SwiftUI update runs in an occluded window.** The same tours' trash acts, delivered
  through the same `updateNSViewController`, finished in 3 to 62 ms with
  `occlusionVisible=false`.
- **What the choice could not get was its precondition.** The tour first brought its photo
  (the first of the loupe's run, at position 187 or 198 of 202) on screen and waited for a
  visible-thumbnails report holding it. Every run reached that wait's deadline
  (`reason=notOnScreen`, 30 and 120 s deadlines alike).
- **An occluded window's layout runs about once a second and lags.** After the tour returned
  from Compare's strip to the grid, the collection view's document height stayed 897 points,
  the clip's height, while the focus scroll aimed at a tile at y = 8155: the scroll clamped to
  y = 0. The document height then grew in steps about a second apart (897, 11360, 12984,
  15316, … 38091) and the visible set changed with it each time (17 to 43 tiles, never the
  target). AppKit lays out an occluded window's views lazily, so a tile not laid out before
  the window was covered is not laid out on time, and a scroll to it does not land.
- **A tile the collection view already holds needs no layout.** Its reconfigure sets its
  views and layers in the main-actor pass that receives the choice; whether the window server
  composites the window afterwards is the display's part, and an occluded window presents no
  frame at all.

## Conclusion

The act's result is measured to its main-actor commit for every act: an order handed to the
collection view, or the act's tile rendered with the choice. The tour's choice acts act on a
tile the collection view holds when the first one runs, so they need no layout and measure in
an occluded window as Move to Trash does. The frame that composites a commit is a separate
number (`op=ui.actToResult phase=presented`, the first display-link callback after the
commit), armed only while the window is visible; the finish line names the window's state
(`window=visible|occluded|noWindow`), and the scorecard prints `occluded` for that number
when the window presented nothing.

Nothing lets a tour make its own window visible on an unattended Mac without changing a user
setting or waking the display: occlusion is the window server's account of what is on screen,
and a sleeping display shows nothing. The tour does not try.
