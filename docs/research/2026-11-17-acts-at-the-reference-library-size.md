# Acts at the reference library size (2026-11-17)

## Question

The target "every act's result is visible within 0.1 s" is measured only in a sandbox: the
reference library takes no act. Sandbox libraries of 28, 200 and 2,000 generated photos measured
the choice acts at 0–1 ms, Move to Trash at 8–34 ms and Put Back at 4–31 ms. The costs of an
act that grow with the library (the window's state apply and grid edit, the projection's
re-read, the Store's write) are met only at its size, about 160,000 items in All Media. Do the
acts hold the target there?

## Method

- `script/scorecard.sh --tour --dev --optimized --seed 160000 --seed-media small --settled
  --idle 20` on the tree of 8cdd35f6: the dev build compiled as installed, a sandbox home with
  a library on a sparse APFS image of its own. `--seed-media small` (added for this note)
  writes 64 × 64 JPEGs in a year / month / ten-day folder tree (739 folders, about 220 files
  each); one photo in 500 is a sign with words at 640 × 480, one in 500 has an exact copy and
  one a re-encoded version, one in 50 has GPS, one in 37 falls on today's date in a past year.
- An unattended Mac with the display asleep: every act ran in an occluded window and is timed
  to its main-actor commit (`docs/research/2026-11-17-act-result-in-an-occluded-window.md`).
- One diagnostic tour with a temporary `op=experiment.scrollTick` line on every scroll-bounds
  notification of the grid (clip origin, document height, the event AppKit was handling, the
  mutation gate's hold), removed after.
- After every tour the account's Trash was tested by path for each of the 160,002 generated
  names (`leftovers=0` every time), no Otos process remained and the volume was detached.

## Findings

- **The library.** 160,002 files (160,000 photos with their copies and versions, two
  videos), 628 MB on the volume, written in 94 s. The Trash check tests 160,002 names by
  path in 0.7 s, so it stays a test of every name.
- **The scan.** The Add Library intent's first walk read 739 folders and 160,740 entries and
  wrote 160,002 rows in 76.4 s and 78.6 s. A second full walk followed at once
  (`reason=events`, 21.1 s and 22.5 s, every file statted again, no row written): the change
  journal replays the generator's own writes, made before the folder was registered.
- **The settling is a race at this size.** The sandbox library is added after the first grid,
  so the launch's settlement is judged on an empty catalog. In three of six tours it was met
  1.2–1.6 s in (`by=ownersQuiescent waitMs=0`), before the scan began, and the tour started
  right after the library's scan (`op=tour phase=library`) with enrichment working its
  160,000-photo backlog. In the other three the scan began first, `launchWork` was never met
  while the backlog ran, and the tour waited out its settle deadline (900 s once, then
  `--settle-deadline 60`; the scorecard says `settled(deadline)`). No tour step met a
  deadline.
- **The choice acts hold.** Dislike 7 / 4 ms, Like 3 / 4 ms, Not Rated 2 / 2 ms.
- **Move to Trash and Put Back do not.** Move to Trash 379 / 272 ms, Put Back 365 / 332 ms;
  five in a row 305–371 / 281–424 ms and 325–420 / 337–434 ms. No act was superseded.
- **Where the time goes.** The Store write, the projection's hold and the window state are
  quick: the trashed photo is gone from the window state 13–21 ms after the act
  (`op=ui.state.apply delta=-1`), and the grid receives it 21 ms after the act. The grid then
  parks it (`actions=pending`) and applies it 250–400 ms later with `heldDuringScroll=true`:
  the mutation gate's scroll hold, which keeps the grid's content still while the user
  scrolls, released 250 ms after the last scroll-bounds tick.
- **Nobody scrolled.** Every tick in the acts' window arrived while AppKit handled an
  `appKitDefined` event, never a scroll-wheel event, and outside any live scroll. They were
  Otos's own moves: the tour's focus scroll to the act's tile, and each structural apply
  keeping its anchor (`anchor=leading`), which moves the clip a few hundred points in a
  6-million-point document. Each act's own apply therefore held the next act's result for the
  whole quiet threshold. Why the 200-photo tours did not meet the hold was not established
  (no tick line ran in them).

## Conclusion

A scroll hold is for the user's scrolling. The grid now begins it only for a tick that is the
user's (`MediaGridScrollInput`): inside AppKit's live-scroll bracket (a gesture with its
momentum, or the scroller) or while a scroll-wheel event is handled (a wheel mouse, which
sends no bracket). A bounds change Otos makes itself holds nothing, so an act's result is
taken in by the grid in the turn that delivers it. `MediaGridScrollAnchorTests` holds both
sides: a programmatic scroll leaves the gate open and the next grid is an apply, a live scroll
parks it.

## After the change

Four tours of the changed build, same command (the last three with `--settle-deadline 60`
after the 900 s wait above); the act steps' own lines, in ms:

| Tour | Dislike / Like / Not Rated | Move to Trash | five in a row | Put Back | five in a row |
| --- | --- | --- | --- | --- | --- |
| 1 | 4 / 6 / 1 | 22 | 18–101 | 38 | 32–58 |
| 2 | 14 / 15 / 11 | 21 | 20–116 | 75 | 25–90 |
| 3 | 6 / 4 / 9 | 17 | 24–89 | 84 | 29–113 |
| 4 | 6 / 4 / 4 | 20 | 19–82 | 58 | 26–66 |

No act was superseded and every one ran in an occluded window. Most acts now take their
result in by the edit path (`followsEdit=true`, 3–11 ms on the grid). Three of 48 trash and
Put Back acts still passed 100 ms (101, 113, 116 ms).

**The residual tail.** A live log stream of the fourth tour (the unified log's store lost the
second and third tours' act lines: the scorecard read no step of them) shows the mechanism of
its slowest act, 82 ms: a re-read of the catalog finished just before the act
(`assetOrderQueryMs=187`, enrichment changing capture dates while it walks the backlog), its
publication moved the order, and the window's newest-wins delivery handed the grid only the
act's state, an edit of that publication rather than of the order on screen
(`op=projection.republish base=publication editOfPublished=true`, then
`op=ui.mediaGrid.structuralApply followsEdit=false`). The grid then compared the full
160,000-item structure off the main actor (`structureBuildMs=7`, `totalMs=47`), after 16 ms
of the projection finishing the read and 26 ms of the main actor delivering the state, with
enrichment's renders using about 3.5 cores. An act that meets a background reorder at this
size pays a whole-order comparison; this was measured, not changed.

**Other numbers at this size** (settled kind, the window occluded): launch to first grid
580–714 ms (the empty catalog before the library is added); the Add Library intent's first
paint of the library 3,166–4,265 ms, FAIL, while the scan writes its rows; return to the
library 218–229 ms; first search 378–1,347 ms over six tours (four over the 1,000 ms target);
sort by name 94–458 ms; filter 169–212 ms; peak footprint 554–821 MB (over 700 MB in two
tours, 701 and 821); store stall lines 0; main-thread stalls 0.
