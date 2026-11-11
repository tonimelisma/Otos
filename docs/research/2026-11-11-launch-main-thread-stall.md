# The launch's main-thread stall (2026-11-11)

## Question

The installed app logged `op=mainThreadStall stallMs=1180` on its first state update after
a launch (2026-11-10 23:41, `latestUpdateID=1`), and the stall line named no cause: the
stall monitor's tick runs only once the main thread is free again.

## Instrument

`StalledThreadWatcher` (ADR 0015) samples the main thread's stack every 50 ms while a stall
lasts, and `script/stall-stacks.sh` prints each stall's heaviest, own and innermost frames.
A Debug dev build of this branch, launched with `open -n`, Apple M-series, macOS 27 beta.

## Findings

- **A bare SwiftUI app stalls about 260 ms at launch.** A `Window` with a
  `NavigationSplitView` of 20 rows, built `-O`, timed by the same 100 ms lateness test:
  284, 253 and 264 ms over three launches. Otos stalled 1,092–1,491 ms over eight launches.
- **Otos's own code was rarely on the stack.** In a 1,166 ms launch stall, 17 of 18 samples
  held no Otos frame: the time was SwiftUI and AppKit building and laying out the first
  window (`showInitialWindows`, `GraphHost.flushTransactions`, `CA::Transaction::commit`).
- **The SwiftUI template named the views.** In an 8 s launch trace, the edit panel's views
  updated at launch: 150 `EditSliderRow` bodies, 330 slider updates and 700 text-field
  updates, though no photo was being edited.
  - **Why it was built:** `ContentView` builds the inspector's last pane even when the
    inspector is closed, and the last pane started as `.edit`. The window therefore built a
    hidden edit panel on every launch.
- **Two Core Image contexts were made on the main thread.** `LiveEditRenderer` and
  `FaceAnalyzer` are built by the view model and created their `CIContext` in `init`: 33 ms
  of main-thread samples at 10 kHz.

## Change and result

- The inspector builds no pane until one is first shown.
- Both contexts are made on first use, on their actors' queues.

| Build | First launch stall | Second launch stall |
|---|---|---|
| Before | 1,092 / 1,266 / 1,277 / 1,311 ms | 154–387 ms in three of four launches |
| After | 575 / 654 / 760 ms | none |

Launches where another app was frontmost are excluded, because the monitor ignores
lateness in an inactive app.

What remains has no Otos frame in more than one of ten samples. It is the first window's
framework work: runtime type-metadata lookups (`swift_getTypeByMangledName`) in a Debug
build, Auto Layout, and the toolbar.
