# Research: grid day-header pinning and the macOS 26+ scroll edge effect (2026-09-04)

The owner reported two defects in the Date-sort grid (DES-069, APP-030): the pinned
day header at the top of the viewport flickers and reads as see-through while
scrolling, and a second header lower down lags the tiles it belongs to.

This pass establishes the mechanism, records what AppKit actually does on the
Xcode 27 beta SDK, and rates the implementation options against Otos's own rules.
The one line that caused both defects was `header.pinToVisibleBounds = true` in
`Otos/Views/MediaGridPresentation.swift`. Option 3 below was implemented in the same
increment as this write-up.

## Method

Three independent sources, in order of authority:

1. **SDK headers**, read directly from
   `/Applications/Xcode-beta.app/.../MacOSX27.0.sdk` (Xcode 27.0, build 27A5228h) —
   `NSCollectionViewCompositionalLayout.h`, `NSScrollEdgeEffect.h`, `NSScrollView.h`,
   `NSTitlebarAccessoryViewController.h`, `NSSplitViewItemAccessoryViewController.h`.
2. **A runtime probe**: a standalone AppKit program reproducing the grid's exact
   configuration — `NSScrollView(drawsBackground: false)` + `NSCollectionView` +
   `NSCollectionViewCompositionalLayout` + a `.estimated(32)` boundary supplementary
   item hosting SwiftUI, 12 pt section insets, 5 columns — which dumps the live view
   hierarchy and the layout attributes of every visible header, at rest and during a
   scroll, across three configurations. Reproduction recipe in the appendix.
3. **Apple developer-forum reports** of the same symptoms on macOS 26 (sources at the
   end).

The probe ran outside the Otos target deliberately: the question is what AppKit does
with this layout configuration, and a minimal reproduction answers it without the
catalog, the mutation gate, or a library of real media in the way.

## Finding 1 — pinning moves every header out of the collection view

With `pinToVisibleBounds = true`, no header is a child of the collection view. Both
the pinned header and one 533 pt further down the page live in the scroll view's
floating-subviews container, a sibling of the clip view:

```
[scrolling] header s0 view=(12,   0, 876, 28) attr=(12,  600, 876, 28) z=1 in=_NSScrollViewFloatingSubviewsContainerView
[scrolling] header s1 view=(12, 533, 876, 28) attr=(12, 1103, 876, 28) z=1 in=_NSScrollViewFloatingSubviewsContainerView
```

With `pinToVisibleBounds = false`, they are ordinary document content and their view
frames equal their layout attributes exactly, at every sample:

```
[scrolling] header s1 view=(12, 1103, 876, 28) attr=(12, 1103, 876, 28) z=1 in=NSCollectionView
```

**Consequence — this is the lag.** Tiles move because AppKit shifts the clip view's
bounds origin; that is compositor work, and responsive scrolling can run it ahead of
the main thread. A floating header moves only when AppKit recomputes and re-sets its
frame on the main thread after a bounds-change notification (the private
`_updatePinnedSectionSupplementaryItemsForCurrentVisibleBounds`, named in the forum
report below). Two clocks drive two things that must stay glued together, and any
main-thread latency shows as the header sliding relative to its own tiles.

The word "pin" is misleading: it does not mean "stick the current header." It means
"take every header in the section out of the flow and reposition them all by hand."

Otos amplifies this. Each `boundsDidChange` also runs `beginScrollHold()`, a
coalesce task, a quiet-release task, `refreshHover()`, `reportViewport()`, a visible
detail query and preheat look-ahead (`MediaGridBridge.swift`, `scrollBoundsChanged`
and `flushScrollDrivenWork`). Main-thread pressure lands at exactly the moment
header repositioning needs the main thread.

## Finding 2 — pinning is what installs the Liquid Glass scroll pocket

`NSScrollPocket` is a real private AppKit view class on this machine, confirmed by
`NSClassFromString`. Its property list includes `style`, `edge`, `captureView`,
`captureColor`, `prefersSolidColorHardPocket`, and
`_shouldDescendantsContributeToScrollPocket`.

With pinning on, one is installed as a sibling of the clip view, sized to exactly the
pinned bar's rect, alongside a `BackdropView` of the same rect:

```
[rest] NSScrollPocket frame=(12, 0, 876, 28) hidden=false alpha=1.0 style=0 prefersSolidColorHardPocket=0
         PocketMask
         PocketBlur -> PortalView
         NSHardPocketView -> _NSLayerBasedFillColorView
         LuminanceAdjustment -> ... -> PortalView
```

With pinning off, the same pocket collapses to `(0, 0, 0, 0)`.

`style = 0` with `prefersSolidColorHardPocket = 0` is the **soft** pocket, not the
hard opaque one. `PocketBlur` wraps a `PortalView` — a live portal of the content
behind it — and `LuminanceAdjustment` re-evaluates as that content moves.

**Consequence — this is the see-through flicker.** The system composites a live blur
of the tiles passing underneath, and re-derives luminance as they pass. Otos did not
ask for this and has no way to decline it (Finding 5).

## Finding 3 — the header's layout zIndex ties with the cells

The probe reports `z=1` for every header. `NSCollectionViewCompositionalLayout.h`
explains why, on `NSCollectionLayoutDecorationItem.zIndex`:

> default is 0; all other section items will be automatically be promoted to zIndex=1

So cells and boundary supplementary items sit at the same level and tie-breaking is
undefined. Setting `header.zIndex = 2` moves it to 2, verified. Today's grid relies
on an unordered tie.

## Finding 4 — the pinned bar is inset 12 pt at each end

`section.contentInsets` is 12 pt all round (DES-060) and
`supplementariesFollowContentInsets` defaults to YES, so the bar is 876 pt wide in a
900 pt viewport. Content scrolls past uncovered in a 12 pt gutter at each end.
Setting `supplementariesFollowContentInsets = false` makes the bar and its pocket
span the full width — verified: `(0, 0, 900, 28)`.

## Finding 5 — the scroll edge effect cannot be controlled on a collection view

`NSScrollEdgeEffect.h` (new in macOS 26.1) defines `NSScrollEdgeEffectStyle` with
`automaticStyle`, `softStyle`, and `hardStyle`. Grepping the whole AppKit headers
directory for consumers of that type returns exactly two:

- `NSTitlebarAccessoryViewController.preferredScrollEdgeEffectStyle`
- `NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle`

Nothing on `NSScrollView`, nothing on `NSCollectionView`, nothing on the layout item.
The forum thread reaches the same conclusion independently: there is no public API to
detect or control the effect's state, and the reporter's workaround was to hide
`NSScrollPocket` instances through private API.

**Consequence.** A pinned collection-view header on macOS 26+ gets the glass
treatment unconditionally. Two Otos design rules are outside our control while it
does: the pocket's blur does not honor DES-084 (Reduce Transparency makes bar and
sidebar opaque at DES-022 values), and its fade is neither one of DES-070's three
durations nor subject to DES-075's Reduce Motion cross-fade. The one route to a
controllable effect is an accessory view controller, which is window chrome.

## Finding 6 — the header has no elevation step and no hairline

Repo-side, independent of AppKit. `MediaGridDayHeaderView.swift` paints
`DesignPalette.content(for:)`. Meanwhile nothing else in the grid paints a content
surface at all: `collectionView.backgroundColors = [.clear]`,
`scrollView.drawsBackground = false` (`MediaGridBridge.swift`), and `MediaGridView`
sets no background.

DES-022 orders the surfaces content, sidebar, bar and states the bar value is
brighter than content "per platform elevation order". A header floating above
scrolling tiles is elevated chrome using the content token, over no content surface,
with no `DesignPalette.hairline` beneath it though DES-023 defines one and
`ImportPlanFooter` uses it.

This is a second, independent contributor to "I can see through it", and it is wrong
whichever option is chosen.

## Finding 7 — an app-owned bar needs no new data path

`CatalogMediaGridState.dayBuckets` is `[Date?]`, paired index-for-index with
`orderedAssetIDs`, and is delivered into the AppKit controller on every structural
apply. `dataSource.snapshot().sectionIdentifiers` already answers which day a section
is, `MediaGridDayHeaderPresentation.map` is already a pure and tested mapper, and
`captureScrollAnchor` already queries `layout.layoutAttributesForElements(in:)` for
the viewport on the same pass. Everything a controller-owned bar needs is present
inside the existing boundary.

The reverse route is worse than it looks: `CatalogWindowViewModel.viewportChanged`
yields into a stream documented as forwarding "verbatim with no main-actor work" to
the enrichment coordinator's priority hint. It is not a general-purpose viewport hook,
and a second consumer with opposite requirements does not belong on it.

## Finding 8 — a bar the app positions cannot lag

Following from Findings 1 and 7. A bar constrained to the top edge of the scroll view
has a constant frame; only its text changes. There is no frame to fall behind the
tiles, at any main-thread load. This is the property that separates the real fixes
from the cosmetic ones, and it is not available to any option that leaves AppKit
owning the bar's position.

## What was not verified

No visual confirmation from Otos itself. Screenshotting the reproduction mid-fling
raised a macOS screen-recording consent dialog, which was not granted; posting
synthetic scroll events needs Accessibility, also not granted. The mechanism above is
proven from view hierarchy, layout attributes, and SDK headers. The *pixels* are
inferred from that mechanism plus the forum reports.

This is the same gap APP-030 already records as `unverified: live pinned-header
scroll behavior needs runtime/visual confirmation, this agent environment cannot
drive the built app's UI`. That clause is what allowed both defects to ship.

## Options

Rated against Otos's own rules, 5 best. C1 eliminates both defects; C2 independent of
undocumented AppKit; C3 simplicity and blank-slate fit; C4 one owner per question;
C5 main-thread cost per scroll tick; C6 design-system conformance; C7 Reduce Motion
and Reduce Transparency; C8 spec churn (extending wording beats withdrawing a
capability); C9 testability including retiring APP-030's `unverified:` clause;
C10 blast radius. Score weights C1 to C4 double, following AGENTS.md's order of
correctness, simplicity, ownership, then performance.

| Option | C1 | C2 | C3 | C4 | C5 | C6 | C7 | C8 | C9 | C10 | Score |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 Unpin only | 5 | 5 | 5 | 5 | 5 | 2 | 4 | 2 | 3 | 5 | 4.2 |
| 2 Harden the pinned header | 2 | 1 | 4 | 2 | 3 | 3 | 2 | 5 | 1 | 5 | 2.6 |
| 3 Unpin plus a controller-owned bar | 5 | 5 | 3 | 5 | 4 | 5 | 5 | 4 | 5 | 3 | 4.5 |
| 3b Owned bar, no day sections | 5 | 5 | 5 | 5 | 5 | 3 | 5 | 2 | 5 | 4 | 4.4 |
| 4 Titlebar or split-item accessory | 5 | 4 | 2 | 3 | 4 | 2 | 4 | 3 | 2 | 2 | 3.2 |
| 5 SwiftUI overlay via the ViewModel | 5 | 5 | 3 | 2 | 2 | 5 | 5 | 4 | 4 | 3 | 3.6 |
| 6 Transient scrubber pill | 5 | 5 | 4 | 5 | 4 | 2 | 4 | 2 | 4 | 3 | 3.8 |
| 7 Date in the scroller gutter | 5 | 5 | 2 | 4 | 3 | 2 | 4 | 1 | 3 | 1 | 3.0 |
| 8 Wait for Apple | 1 | 1 | 5 | 2 | 3 | 3 | 2 | 5 | 1 | 5 | 2.4 |

**1 — Unpin only.** `pinToVisibleBounds = false`. Both defects gone, proven. DES-069's
pin clause and its check "a date is visible at all times" both fail: at 6 columns a
large day scrolls for several screens with no date on screen. Withdraws a shipped
capability.

**2 — Harden the pinned header.** zIndex 2, full-width supplementaries, bar token,
hairline, opaque layer-backed view. Each piece does what it claims, and none of them
touch either reported defect: the headers stay in the floating container and the
pocket stays alive. Preserves APP-030's `unverified:` debt exactly. This is the trap
option — small, plausible, and not a fix.

**3 — Unpin plus a controller-owned bar.** Headers scroll in flow. The controller adds
one opaque bar as a subview of the scroll view, constrained to the top edge, full
width, `DesignPalette.bar` plus a DES-023 hairline. On each already-existing coalesced
scroll flush it asks a new pure policy for the bar's state from the topmost visible
section and whether that section's own in-flow header is on screen, showing the bar
only when that header is off screen — DES's "One fact, one owner" satisfied literally.
Cross-fade through `MediaGridAnimation`, so DES-070 and DES-075 hold by construction.
Constant frame (Finding 8), our colors (DES-084), outside the layout object so a zoom
swap cannot disturb it, outside the collection view so applies and APP-015 are
untouched. Converts an untestable AppKit behavior into a pure function.

**3b — Owned bar, no day sections.** The bar is the sole rendering of the day and the
snapshot collapses to one flat section, deleting `MediaGridSectionGroupingPolicy`, the
`sectionProvider` variance, `sectionShowsDayHeader`, the supplementary registration
and provider. Simplest and cheapest. Costs the in-flow day break entirely: no header
rows, no section inset, days run together mid-row. DES-069 says "grouped into day
sections", which reads as a visible grouping, so this is a substantial rewrite of the
rule rather than an extension of it.

**4 — Titlebar or split-item accessory.** The only route with public control of the
effect (Finding 5). But the detail-pane-scoped variant needs the underlying
`NSSplitViewItem`, which SwiftUI's `NavigationSplitView` does not vend, and the
titlebar variant spans the sidebar too. Adds a second AppKit escape hatch, which
ARC-001 asks to be justified.

**5 — SwiftUI overlay in `MediaGridView`.** Visually equivalent to option 3, and
`MediaGridView` already has the shape. Needs a new grid-to-SwiftUI channel firing per
scroll flush and a SwiftUI body re-evaluation per tick — what `ContentView`'s own file
guide warns against. Option 3 gets the same result without leaving the boundary where
the data already is (Finding 7).

**6 — Transient pill.** Appears on scroll, fades at rest. A pill over a gap never has
the opaque-bar-over-content problem. But DES-069's check is "a date is visible at all
times", and at rest it is not, which makes an orientation cue motion-dependent.

**7 — Date in the scroller gutter.** Answers "where am I in the timeline", not "what
day is this". A different feature; largest blast radius.

**8 — Wait for Apple.** Both are Apple bugs on macOS 26 and 27, and there is no public
opt-out. The repo targets the latest beta by policy, so waiting is not neutral.

## Conclusion

Option 3, implemented in this increment.

It was originally scoped as two — unpin first (option 1), then add the bar — since
unpinning is a strict prefix of option 3 and would have stopped the flicker
immediately. Both halves were ready in the same session, so they landed together
rather than leaving a `main` that knowingly failed DES-069's "a date is visible at
all times" between two merges.

What shipped:

- `pinToVisibleBounds` removed; day headers scroll in flow.
- `MediaGridDayBarView`, a controller-owned bar constrained to the grid's top edge,
  with `DesignPalette.bar` and a DES-023 hairline (Finding 6). The in-flow header
  stops painting a surface of its own for the same reason.
- `MediaGridDayBarPolicy`, the pure rule for what the bar names: the day owning the
  viewport's top edge. Self-review caught a near-miss here before it shipped — keying
  the bar off the topmost visible *item* puts up to 24 pt of section inset between one
  day's last row and the next day's header, and a bar that hid while the top edge sat
  in that gap blinks out and back at every day boundary. Naming the day that owns the
  edge is what a pinned header does implicitly, and it changes the text once per
  boundary instead.
- `appliedDaySections`, a controller-held record of the applied snapshot's per-section
  day facts, so neither the bar nor header dequeue copies the whole snapshot through
  `dataSource.snapshot()` on a scroll-adjacent path.
- DES-069 and APP-030 rewritten; APP-030's `unverified:` clause narrowed from the
  whole behavior to the rendered appearance alone.

Option 2 was rejected explicitly rather than treated as a cheap partial: it is the
only option scoring 1 on both OS-independence and testability, and it leaves the app
fighting private AppKit machinery while appearing to have fixed something.

Option 3b remains the choice instead of 3 only if the in-flow day break is judged not
to earn its place. That is a product call, and it is open.

## Follow-up pass (2026-09-05): what the bar should look like

The first pass fixed the flicker and the lag and left the appearance wrong. Shipped
screenshots showed three things: the bar painted `bar` while the in-flow header
painted nothing, so the two read as unrelated; at a day boundary the bar named a day
with none of its content on screen while the incoming header sat immediately beneath
it; and the bar clipped the top row of tiles. The owner's summary was that the old,
flickering version "looked nicer".

It did, and the reason is worth stating plainly: **the old version had exactly one
date on screen.** A pinned header does not add a second rendering — the pinned thing
*is* the section's header. Every complaint above is a consequence of there now being
two renderings of one fact, with two surfaces, that can be adjacent.

### What the platform actually offers

- **Apple's structural answer is an accessory bar, not a pinned header.** WWDC25
  "Build an AppKit app with the new design": *"Split item accessories, along with
  titlebar accessories, are the best way to incorporate floating content into the
  scroll edge effect. They influence the size and shape of the effect, and they inset
  the content safe area, simplifying content layout."*
  `NSSplitViewItemAccessoryViewController` is new in macOS 26 and carries an animatable
  `hidden` that collapses it to zero height, plus `preferredScrollEdgeEffectStyle` in
  26.1. It attaches to an `NSSplitViewItem`, which SwiftUI's `NavigationSplitView` does
  not vend — so it is unreachable here without replacing the window's composition.
- **The style for this job is hard, not soft.** WWDC25 "Get to know the new design
  system": *"Hard is mostly used on macOS. It creates a stronger, more opaque
  boundary — ideal for interactive text, controls without backgrounds, or pinned table
  headers that need extra clarity."* Also *"avoid mixing or stacking them"* and
  *"apply one scroll edge effect per view"*.
- **SwiftUI has the same shape**: the macOS 27 SDK's `SwiftUI.swiftinterface` carries
  `safeAreaBar(edge:alignment:spacing:content:)`, `scrollEdgeEffectStyle(_:for:)`, and
  `scrollEdgeEffectHidden(_:for:)`. Apple considers hiding the effect legitimate; they
  simply never exposed it on `NSScrollView`.
- **Photos does not keep a persistent date bar.** In iOS 26 the date indicator appears
  only while actively scrolling and fades a second or two after, showing a single date
  rather than a range; the always-visible date range users remember was removed. Its
  accessibility footnote is a warning: with Reduce Transparency on, Photos' indicator
  stops showing at all — *"presumably a white on white problem"*. That is the DES-084
  failure this repo avoids by owning its colors, shipping in Apple's own app.

macOS Photos' exact pixels were not verified: screenshotting needs a permission this
environment does not have, and loading `PhotosUICore` into a probe process trapped
(SIGTRAP, library validation). The Photos behavior above is documentation and user
reports, not direct observation.

### Two repo-side findings

- **`DesignPalette.content` had zero callers.** `bar` and `sidebar` were painted;
  `content` was not, so DES-022's own check — *"chrome is distinguishable from content
  by value alone"* — could not pass: there was no content surface to be distinguished
  from, and the bar was a grey band on the raw window background. This codebase has a
  precedent for exactly this: the ambient hierarchy level was retired because
  *"DesignPalette had zero real callers for it"*. The two honest resolutions were to
  paint it or to retire it; painting it is what the surface order was written for.
- **`sectionShowsDayHeader` called `dataSource.snapshot()` once per section, per
  layout pass**, purely to answer whether a section carried a header. With a day
  section per day and enrichment applying about once a second, that was the most
  expensive remaining reader of a structure the controller already held in
  `appliedDaySections`. Unmeasured, but structural: it is a full snapshot copy per
  section.

### Options

| | Approach | Fixes the clash | Fixes the boundary stacking | Cost |
| --- | --- | --- | --- | --- |
| A | Paint the grid's content surface | yes | no | one line |
| B | Bar drops to the `content` value | yes | no | one line |
| C | Bar only; drop the in-flow header | yes | yes | deletes code |
| D | Push the bar out with the incoming header | partly | yes | per-tick frame update |
| E | `safeAreaBar` — real bar, content inset | yes | no | small |
| F | Transient pill, as Photos ships | yes | yes | medium |

**D** is the faithful rebuild of the old look and the only option that keeps both
renderings and still reads correctly at a boundary. Its price is a per-scroll-tick
frame update — the same mechanism the first pass removed. It would be a frame late
across the ~28 pt push window: invisible on a fling, invisible when scrolling slowly,
a slight rubber-band at mid speed. Bounded, and far milder than the original defect
where every header tracked content over its whole travel — but not free, and it keeps
the per-section snapshot copy.

**E** was rejected because with C the bar is always visible anyway, so making it real
chrome that permanently insets 28 pt trades the content-forward feel for nothing that
C does not already give. **F** fails DES-069's "a date is visible at all times", and
Apple's own version carries the Reduce Transparency bug above.

### Conclusion

**A + C** was implemented, and **C was wrong**. Corrected below.

**A + C**, as implemented at the time. Paint the content surface, and let the bar
be the only rendering of the day.

C removes the clash and the boundary stacking by construction rather than by rule,
and it deletes rather than adds: the supplementary registration, the supplementary
view provider, `makeDayHeader`, the header view, the per-section
`dataSource.snapshot()` copy, the `sectionProvider` closure, and the bar's whole
visibility rule all go. Against the repo's stated order — correctness, simplicity,
ownership, then performance — it wins on each.

The cost, stated plainly because it is the whole cost: **the inline day label is
gone.** The day is read from the bar, not from text between the rows, and a day run
is marked by the section inset alone. That was an owner decision, taken with D on the
table as the alternative.

## Correction (2026-09-05): C was the wrong half

Shipping C — the bar as the only rendering, no in-flow header — removed the day
labels from the middle of the grid, and the owner wanted them. Re-examining the
screenshots that motivated it, the diagnosis was wrong.

A bar reading "Yesterday" with "Last Wednesday" arriving beneath it **is not a bug**.
That is what a sticky header looks like a moment before the swap. What made it read
as broken was that the two were styled as unrelated objects: a chrome-valued band
directly above bare text, with no content surface underneath to explain why one was
elevated and the other was not. The defect was the treatment, not the existence of
two labels — symptom, not cause, for the second time in this thread.

**A was the whole fix.** With the content surface painted, the relationship between
the two becomes legible. What A alone did not do is make them *identical*, and that
is what closes it.

### The correct approach

A day is named twice: in flow at the head of its run, and by the bar at the top edge.
Those are **one label at two moments** — which is precisely what a pinned header is,
and why the original looked right despite the flicker. So:

- One view of the label, in `MediaGridDayLabel.swift`. Both hosts draw it; neither may
  restyle it. Identical type, colors, height, and horizontal position.
- Its surface is `content`, opaque. Opaque so the bar covers tiles passing beneath;
  `content` because it is a section header, not chrome. DES-022 gains the exception:
  the elevation order governs chrome over content, and this floats without being
  chrome.
- The bar reserves no space, and withdraws rather than doubling a visible header:
  while a day's own header is still fully below the top edge that header is the
  rendering, and at the very top of the grid the bar is absent. (The first draft
  claimed the bar would lie exactly on the first header — false: the header sits at
  the 12 pt section inset, so drawing both would print the same date twice, 12 pt
  apart. The test caught it.) The `contentInsets.top` reservation added with C is
  removed.
- The rule is unchanged from the first pass and was always correct: the bar names the
  day owning the viewport's top edge, and the inset gap between runs belongs to the day
  being left.
- `sectionShowsDayHeader` returns, but answered from `appliedDaySections` in O(1)
  rather than from `dataSource.snapshot()`. The per-section snapshot copy C removed
  stays removed; only the header comes back.

**Accepted artifact.** For roughly 28 pt of travel at each boundary the incoming
header is partly behind the bar, so the lower part of its text is briefly visible
under a bar still naming the previous day. Avoiding it needs the push (option D),
which reintroduces per-tick frame updates — the mechanism the first pass removed. At
any real scroll speed 28 pt is one to three frames, and it is the same "content
scrolls under an opaque surface" every tile in the grid already does.

### What to take from this

Two corrections in two increments, both the same mistake: treating a visual symptom as
the design problem. The first pass read "the header slides and flickers" and removed
pinning without asking what pinning was *for*; the second read "two labels stack" and
removed a label without asking why they looked unrelated. The invariant that survives
both is the one the original design had by accident: **a day is one label, and it
should look like one label wherever it is drawn.**

## Follow-up (2026-09-05): alignment, motion, and how to differentiate the bar

Shipping the one-label design surfaced two more things: the handoff between header and
bar showed a visible slide, and neither label was distinguishable from the content
behind it.

### The slide was a geometry bug, not a transition

Measured with a probe, viewport 900 pt wide, section insets 12 pt:

```
supplementariesFollowContentInsets = true    header = x=12  y=0  w=876
supplementariesFollowContentInsets = false   header = x=0   y=0  w=900
```

The bar spans the viewport (x=0, w=900); the header followed the section's content
insets. So the label moved 12 pt sideways at every handoff, and the cross-fade smeared
that into a slide. Vertical already agreed — the section's 12 pt top inset lands
*below* the header, between it and the first row, not above it. My guess had been that
both axes were off; the probe corrected it.

With `supplementariesFollowContentInsets = false` the two occupy the same rect, and the
cross-fade goes away entirely: appearing and disappearing changes no pixel, so there is
nothing for motion to explain (DES-070). The cross-fade only put both labels at partial
alpha over each other, which is what read as a slide.

### How to differentiate a floating label — the options

| | Approach | macOS precedent | Keeps one label |
| --- | --- | --- | --- |
| A | Nothing; opaque, matching the surface | the shipped state | yes |
| B | Hairline underneath while floating | `NSTitlebarSeparatorStyle.automatic` | yes |
| C | Background value step (chrome band) | NSTableView column headers, Finder path bar | no |
| D | Soft shadow underneath | `NSTitlebarSeparatorStyle.shadow` | yes |
| E | Material / vibrancy | sidebars, popovers, Liquid Glass | partly |
| F | The real scroll edge effect | WWDC25's recommendation | yes, but blocked |

The discriminator is whether the option touches the label's **background** or only adds
an **edge**. Changing the background makes the bar stop matching the in-flow header,
which is the two-objects problem the one-label design exists to prevent. An edge leaves
the label identical and adds only the boundary — and the boundary is not part of the
label, it is the scroll edge.

**B chosen.** It is the literal system convention: `NSTitlebarSeparatorStyle` has
defaulted to `.automatic` since macOS 11, drawing a line beneath the titlebar while
content is scrolled under it and hiding it at the top, and WWDC25 describes the macOS
hard scroll-edge style the same way — "a more opaque backing to provide greater
separation… ideal for pinned table headers". It reuses DES-023 and DES-084 with no new
rule, and because the bar is shown only when content is scrolled under it, the line is
contextual for free: at the top of the grid the header renders and no line is drawn,
because nothing is underneath yet.

C is what an earlier increment shipped and the owner rejected. E reintroduces the
translucency that started this thread, and Apple's own Photos carries a live bug in that
direction — its date indicator stops showing entirely under Reduce Transparency. F
remains unreachable from `NavigationSplitView`.

## Follow-up (2026-09-05): the bar is on continuously, and updates per tick

Two more reports on the shipped bar: scrolling down, the first header left the
viewport and the bar took *seconds* to appear. Both the delay and the state that
caused it are gone.

### The delay was a debounce with no maximum wait

`updateDayBar()` lived in `flushScrollDrivenWork()`, behind this
(`MediaGridBridge.scrollBoundsChanged`):

```swift
scrollCoalesceTask?.cancel()
scrollCoalesceTask = Task {
    try await Task.sleep(for: .milliseconds(16))
    …
    flushScrollDrivenWork()
}
```

Cancel-and-restart on every bounds change is a trailing-edge debounce with no maximum
wait. Bounds-change notifications arrive at display rate during a fling — roughly every
8 ms — so the task is cancelled before its 16 ms window elapses, every time. Work behind
it does not run until scrolling *pauses*. That is exactly the reported symptom.

The bar's update is a layout read plus a pure decision, so it now runs directly in the
bounds-change handler. That cadence — coalesce the expensive thing, run the cheap thing
per tick — is the right split; the mistake was putting a label that names what the user
is looking at on the same clock as Store queries.

**Wider finding, not addressed here.** The same debounce also gates `refreshHover()`,
`reportViewport()`, visible detail queries and preheat. ARC-023 states hover
"recomputes from the pointer's real position on every scroll tick"; during a sustained
fling it currently does not. Changing the cadence of Store-backed work needs
measurement and its own increment.

### The withdraw-at-the-top state bought nothing

The bar previously hid at the top of the grid so it would not double the first
section's header. Since the two were given the same rect, that reasoning no longer
holds: at the top the bar rests *exactly* on the first header and draws the same label,
so it is indistinguishable from it. Hiding it was a state with no visible effect and one
more thing to get wrong — which it duly did, by taking the debounce's latency with it on
the way back.

The bar is now shown continuously wherever there is a day to name, and hidden only where
there is none: an empty grid, or the single `.ungrouped` section that `.name`/`.size`
sort produces. The rule for *which* day is unchanged, with one boundary correction —
a header level with the top edge (`headerMinY == viewportMinY`, which is the top of the
grid) now names its own day rather than falling through to a preceding day that does not
exist.

The hairline stays contextual on the same fact, sharing the one-point tolerance
`captureScrollAnchor` uses for the same reason: elasticity leaves a sub-point residue at
rest.

## Appendix: reproducing the probe

A single-file AppKit program, compiled with `xcrun swiftc`, is enough. The essentials:

- `NSScrollView` with `drawsBackground = false`, `hasVerticalScroller = true`,
  documentView an `NSCollectionView` with a compositional layout whose section has
  12 pt insets, a 5-column group, and one `NSCollectionLayoutBoundarySupplementaryItem`
  of `.estimated(32)` at `.top`.
- Toggle `pinToVisibleBounds`, `zIndex`, and `supplementariesFollowContentInsets`
  from the environment so the three configurations run from one binary.
- After layout, walk the window's view tree printing each view's class and frame, and
  for every visible supplementary print its view frame, its
  `layoutAttributesForSupplementaryView` frame, the attribute `zIndex`, and the
  superview class. Sample at rest, during a timer-driven scroll, and after it settles.

The superview class is the finding: `_NSScrollViewFloatingSubviewsContainerView`
versus `NSCollectionView`. The pocket is found by class-name substring; note that
`NSScrollPocket` responds to `style`, `edge`, `captureColor` and
`prefersSolidColorHardPocket` through KVC.

Programmatic `scroll(to:)` does not enter the live-scroll phases, so the probe cannot
observe the pocket's blur children becoming visible; that part rests on the forum
reports and on the pocket's presence and sizing.

## Sources

- Apple Developer Forums, [NSCollectionLayoutBoundarySupplementaryItem background blur
  covering the entire layout section](https://developer.apple.com/forums/thread/804872)
  — macOS 26.0.1; identifies `NSScrollPocket` as the cause; workarounds are layout
  invalidation or hiding the pocket through private API.
- Apple Developer Forums, [NSCollectionView Liquid Glass Section Headers Don't Show
  After Fading Out on Scroll Sometimes](https://developer.apple.com/forums/thread/800790)
  — pinned headers fade out on scroll and sometimes do not fade back; concludes no
  public API exists to detect or control the effect.
- Apple, [NSScrollEdgeEffectStyle](https://developer.apple.com/documentation/appkit/nsscrolledgeeffectstyle).
- Apple Developer Forums, [No date showing in gallery when scrolling through
  photos](https://discussions.apple.com/thread/256140985) — iOS 26 Photos shows the
  date only while scrolling, and not at all under Reduce Transparency.
- Apple, [scrollEdgeEffectStyle(_:for:)](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)).
- Apple, [NSCollectionViewCompositionalLayout](https://developer.apple.com/documentation/appkit/nscollectionviewcompositionallayout).
- WWDC25 session 310, [Build an AppKit app with the new
  design](https://developer.apple.com/videos/play/wwdc2025/310/) — covers the scroll
  edge effect; gives no guidance for customizing views inside it.
- `MacOSX27.0.sdk` AppKit headers, Xcode 27.0 (27A5228h): `NSScrollEdgeEffect.h`,
  `NSCollectionViewCompositionalLayout.h`, `NSTitlebarAccessoryViewController.h`,
  `NSSplitViewItemAccessoryViewController.h`.
