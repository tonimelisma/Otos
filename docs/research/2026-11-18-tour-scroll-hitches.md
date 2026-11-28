# The tour's continuous scroll and its hitch rate (2026-11-18)

## Question

Scrolling was reported as visibly stuttering, frame by frame, in the full reference library and in a
109-asset import alike. The installed app's log showed a main-thread stall of 100–220 ms
(`op=mainThreadStall`, `bracketedOp=MediaGridViewController.reconfigureVisibleItems`,
`scrollHold=true`) on nearly every new row while the user scrolled. The weekly tour passed: its scroll
steps jump 300 items with a focus scroll, so each shows one screenful in one commit and stalls
once, and its only stall target is `mainThreadStalls.worstMs` ≤ 250 ms. What does the tour have
to do to catch a scroll that hitches on every row, and what number should it judge?

## Method

- Apple's measure for scrolling smoothness: the hitch-time ratio, hitch time in ms divided by
  the interval's duration in seconds. In WWDC20 session 10077, *Eliminate animation hitches with
  XCTest*, Apple says under 5 ms/s is a good experience and the ratio Apple's own tools
  target; at 5–10 ms/s people notice hitches. A frame is a hitch when it reaches the screen
  later than expected; its hitch time is how late it was.
- What a scroll in the tour can observe without Instruments: the display link
  (`NSView.displayLink(target:selector:)`, macOS 14+) calls back on the main thread once per
  refresh, with `timestamp` (the frame being displayed) and `targetTimestamp` (the next one).
  A main thread held past a refresh delays the next callback by as much, so the callback
  intervals are what a person sees while the main thread scrolls.

## Decisions

- **The step scrolls as a trackpad does.** `ScrollHitchProbe` moves the grid's clip view on
  each display-link callback to where a scroll at a steady speed is at the frame being
  prepared (`targetTimestamp`). A late frame therefore jumps as far as a finger would have moved,
  and AppKit lays out, reconfigures and commits what that reveals in the same main-thread
  passes as for a person's scroll. The scroll is bracketed by the live-scroll notifications
  AppKit posts around a gesture, so the grid treats it as a gesture (its scroll hold).
- **Speed and distance: 1,500 points a second for 12,000 points (8 s).** A steady two-finger
  scroll moves about one to three thousand points a second. At the default six columns in a
  1,512-point window a row is about 250 points, so the step reveals about 48 rows, six a
  second. That is several new rows every second, which is what stalled for the user, and
  long enough that one slow frame does not decide the ratio.
- **The hitch rule.** An interval longer than 1.5 refreshes adds its time past one refresh to
  the hitch time (`ScrollFrameTally`). An interval within half a refresh is the display's own
  jitter and counts as on time. The report gives frames, duration, hitch ms, hitch ms per
  second, the worst frame and the refresh interval it judged against (`op=ui.scrollHitches
  phase=finish`, and the tour step `kind=continuousScroll`).
- **The target is Apple's: `scroll.hitchMsPerSecond` ≤ 5.** `scroll.worstFrameMs` is printed
  beside it as a number.
- **An occluded window is not judged.** A window not on screen presents no frames and its
  display link stops (`docs/research/2026-11-17-act-result-in-an-occluded-window.md`). The step
  refuses to start there (`reason=windowOccluded`), and a window covered midway ends the scroll on
  the window server's occlusion report (`ending=occluded`). The scorecard prints both as
  `OCCLUDED`, never as a pass. A tour on an unattended Mac whose display is asleep therefore
  measures no scroll; that is the window server's account of what is on screen, which a tour
  cannot change without changing a user setting.

## What it predicts

The user's stalls were 100–220 ms on about every other row at a handful of rows a second, so
the probe's hitch rate for that build is on the order of a hundred ms/s, far past 5. A probe
outside the app measured the same cause: 60 thumbnails shown in one commit took 182–215 ms of
main-thread work when their pixels were decoded lazily, and 1.3 ms when the pixels were already
decoded. The first weekly run after this lands measures the real number on the reference library.

## Sources

- [WWDC20 10077: Eliminate animation hitches with XCTest](https://developer.apple.com/videos/play/wwdc2020/10077/)
- [WWDC20 10077 notes](https://wwdcnotes.com/notes/wwdc20/10077)
- [MetricKit: MXAnimationMetric hitch time](https://developer.apple.com/documentation/metrickit/hitchtimemetric)
