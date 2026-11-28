# Launch first frame and the duplicates build: where the time goes (2026-11-01)

Two costs remained after the launch fixes of 2026-11-01 (#548, #549): about 1.4 s per
duplicates build and about 1 s before the window's first frame. This note records what
each one is, measured on the test Mac (Xcode 27.2, Debug builds as installed, ADR 0030).

## The duplicates build

Evidence: the installed app's logs after a launch with a camera card attached, and the
Time Profiler trace `build/Profiles/launch-20261101-104820.trace` (deleted 2026-11-10
to free disk; the figures below are its only record).

- Each window pass rebuilt the groups, so they were rebuilt back to back while the catalog
  changed: 1.5–2.5 s apart for as long as the card was being read.
- A scope change queued behind a build in flight. Choosing the card took 1,995 ms to paint
  (`ui.sidebarSelectionToPaint ms=1995`). The intent arrived at 21.829 s, and its pass
  started at 23.116 s, when the build ended.
- In the trace, the same-photo half was almost all of a build:

  | Part | Share |
  |---|---|
  | Reading candidates | 53 %, most of it decoding every still's metadata record (JSON) for two fields |
  | Comparing renders | 34 %: the pixel loop, unoptimized in Debug, over every proposed pair |
  | Proposing pairs | 11 %, done twice per build |

- Inputs on the reference catalog:
  - stills: 14,164;
  - stills without capture metadata, each tested against its whole aspect bucket:
    1,631, making about 690,000 hash comparisons;
  - proposed pairs: 1,877, covering 2,548 stills.

Changes (ADR 0042, "The groups have their own owner"):
- Builds move to `DuplicatesProjection`, asked only after a catalog change, never awaited
  by a window pass.
- Records and renders are read only for the stills in proposed pairs.
- Pairs are proposed once, with the hash checked first.
- The render comparison uses vDSP.

All builds below found the same groups: 164 groups, 54 same-photo, 375 copies, 1,651
pairs, 2,462 stills detailed. Timings are from the installed app's `duplicates.groups
phase=built` log lines, read from the reference library.

| Build | Candidates ms | Details ms | Compare ms | Total ms |
|---|---|---|---|---|
| Before (inside each window pass) | — | — | — | ~1,500–2,500 apart, back to back |
| #552: own owner, details only for pairs | 420–475 | 280–306 | 51–55 | 814–1,061 |
| #555: pairing facts only, cursor read, cached detail statement | 151–248 | 157–256 | 55–60 | 496–552 |

The candidate SQL alone runs in 31 ms (14,914 rows, `sqlite3`), so what remains of the
candidate phase is Swift work in a Debug build:
- building an asset identity for each still;
- about 690,000 hash tests for stills without capture metadata.

What remains of the details phase is decoding 2,462 metadata records.

## The window's first frame

Evidence: a Time Profiler trace of a dev build's launch (`xctrace record --launch`, 8 s).
The main thread was busy for about 1.45 s, from 1.67 s to 3.6 s after launch.

| Main-thread work | ms |
|---|---|
| SwiftUI `showInitialWindows` | 514 |
| — of it, `windowDidLoad` (content and toolbar layout) | 291 |
| — of it, re-sizing to the saved frame (`sizeAndPlaceWindow`) | 176 |
| — of it, toolbar item hosting (`ToolbarBridge.makeStorage`) | 116 |
| `NSToolbarView` layout | 141 |
| Main menu from the scene's commands (`makeMainMenu`) | 118 |
| `AppKitWindow.init` | 102 |
| dyld `dlopen` | 58 |
| SF Symbol rendition lookups (`CUICatalog`) | ~57 |
| `CatalogWindowViewModel.init` | 32 |

Rows indented under `showInitialWindows` are part of it. Several rows overlap: a sample
counts toward every frame on its stack.

Almost all of it is SwiftUI and AppKit building the window, its toolbar and its menus;
Otos's own code is a few percent. The cost scales with the UI Otos declares, not with a
defect, so nothing was changed. On the installed app, the window attached 0.9 s after the
view model started (`op=window.attached`). The catalog had loaded and its first state was
ready 0.28 s before that.
