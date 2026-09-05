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
- Apple, [NSCollectionViewCompositionalLayout](https://developer.apple.com/documentation/appkit/nscollectionviewcompositionallayout).
- WWDC25 session 310, [Build an AppKit app with the new
  design](https://developer.apple.com/videos/play/wwdc2025/310/) — covers the scroll
  edge effect; gives no guidance for customizing views inside it.
- `MacOSX27.0.sdk` AppKit headers, Xcode 27.0 (27A5228h): `NSScrollEdgeEffect.h`,
  `NSCollectionViewCompositionalLayout.h`, `NSTitlebarAccessoryViewController.h`,
  `NSSplitViewItemAccessoryViewController.h`.
