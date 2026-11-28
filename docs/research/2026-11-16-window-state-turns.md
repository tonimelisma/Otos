# What fills the window's main-thread turns while acts run in a row (2026-11-16)

## Question

Single acts show their result within 100 ms; in a rapid series some do not (five Moves to
Trash: 86–163 ms, five Undos: 83–164 ms, `docs/research/2026-11-16-grid-applies-during-motion.md`).
That note found the window applying an older publication first, one main-thread turn of
about 60 ms, before the act's own. Which publications reach the main actor, in what order,
and what does each turn spend its time on?

## Method

- The optimised sandbox tour (`script/scorecard.sh --tour --dev --optimized --home <sandbox>`,
  28 generated JPEGs in the sandbox home, the Info pane open as the tour opens it), its
  `op=` lines read from the unified log.
- A Time Profiler recording attached to the touring dev app (`xctrace record --template
  "Time Profiler" --attach <pid>`) from the On This Day step, so it covers the acts; the
  main thread's samples exported (`xctrace export … table[@schema="time-profile"]`) and
  grouped by run-loop phase and by frame. The trace was deleted once exported.

## Findings (before)

- **The main thread is saturated while acts run.** 2,314 ms of main-thread samples in the
  2,369 ms of the five-Trash, five-Undo run.
- **One run-loop iteration is about 85 ms:** about 2 ms of main-actor jobs, then one SwiftUI
  update (`GraphHost.flushTransactions`) of 45–60 ms, then a display cycle
  (`CA::Transaction::commit`) of about 22 ms.
- **An act's state is applied one iteration after the act.** Projection publishes the hide
  in the act's own millisecond (`op=projection.hold phase=held ms=0`); the window applies it
  in the next job slot, after that iteration's update and display cycle. One act:
  `trash.move` at 58.937, `ui.state.apply delta=-1` at 59.022, the grid's commit at 59.045.
- **A republication that arrived first is applied first.** An `AsyncStream` hands a value
  straight to a consumer parked in `next()`; that consumer then waits for the main actor
  with it, and a newer value lands in the buffer behind it. A hold's landing or retiring
  republished the window (`delta=0`) just before an Undo, so the Undo's own state came one
  more iteration later: 150–170 ms.
- **What fills each 45–60 ms update is layout, and it is the same for every publication,
  the `delta=0` ones included.** Otos's own code is a few percent (`applyState` 0 ms,
  `ContentView.body` about 1 %). Of the main thread's samples in the run:
  - 14 % text layout and 12 % a SwiftUI `Grid` inside a `ScrollView`: the Info pane's rows;
  - 18 % `NSHostingView.minSize`: the window measures its whole tree again for its minimum
    size (`NSHostingView.SizeConstraints.update` from `_willUpdateConstraintsForSubtree`);
  - 13 % the toolbar (`ToolbarBridge.preferencesDidChange`, `NSToolbarItemViewer` layout).
- **Why every publication paid it.** The window state was one observed value, and
  `ContentView`'s body read it, so every publication re-rendered the whole window: the
  sidebar, every pane, the toolbar and the inspector, whose Info pane was rebuilt with new
  closures and laid its text out again, after which the window measured everything for
  its minimum size.

## Change

- **Newest-wins delivery.** A relay off the main actor puts each publication in a
  `NewestValueMailbox` as it arrives; the window's consumer, woken by a doorbell that
  carries nothing, applies the newest state there is when it runs. A publication replaced
  meanwhile is never applied (`op=ui.state.apply superseded=`).
- **The state is observed in parts** (`CatalogWindowParts`). Applying a publication notifies
  only the parts it changed: the grid by its content's identity, its descriptor and its
  detail refresh, every other part by `==` over what Projection shared. `ContentView` reads
  no part itself; `SidebarColumn`, `DetailColumn`, `InspectorColumn` and `CatalogToolbar`
  each read theirs in their own body. A one-tile hide re-renders the detail column alone; a
  publication that changed nothing re-renders nothing.
- **The Info pane is not rendered again for an equal photo** (`InfoPaneView` is `Equatable`
  over what it shows; its intents are not compared).

## After

Optimised dev build, the same sandbox home (28 generated JPEGs), one tour on the base
(`main` before this change) and two on the change
(`script/scorecard.sh --tour --dev --optimized --home <sandbox>`), act to result on the grid:

| Act | Before | After, tour 1 | After, tour 2 |
| --- | --- | --- | --- |
| Dislike / Like / Not Rated | 3 / 24 / 21 ms | 12 / 5 / 0 ms | 3 / 1 / 0 ms |
| Move to Trash (single) | 110 ms | 14 ms | 8 ms |
| Put Back (single) | 28 ms | 17 ms | 9 ms |
| Five Moves to Trash in a row | 118, 109, 125, 126, 105 ms | 17, 6, 13, 18, 2 ms | 2, 16, 14, 34, 16 ms |
| Five Undos (Put Back) in a row | 78, 97, 73, 98, 31 ms | 28, 27, 7, 4, 5 ms | 14, 7, 4, 13, 6 ms |

- **Every act now shows its result within 100 ms, a series included**: the worst of 30
  acts was 34 ms, against 126 ms before.
- The two later tours of the base and the change otherwise agree within run-to-run noise,
  except one: tour 1's last return to Duplicates painted after 6,318 ms, all of it in
  Projection before its publication (`publish=6226`), not in the window. Tour 2 painted
  the same return in 156 ms (the base: 461 ms). It is not attributed here.
- Not measured: the Time Profiler split of a main-thread turn after the change, and the
  reference-scale grid (158,000 tiles); the daily benchmarks' `window.apply.*` cases are not
  measured until the next daily run.
