# ADR 0014: Sidebar Selection And Source Lifecycle

## Status

Accepted.

## Decision Scope

This ADR owns which sidebar row is selected (startup default, on-attach, and after
the selected source disappears), whether the "All Media" aggregate row exists, and
the user-facing eject behavior for removable sources. It references but does not
own: catalog root persistence, availability, and attach/detach state (ADR 0013 and
the Store); grid rendering and grid selection (ADR 0006); catalog UI ownership
(ADR 0004). The rules live in the pure `SidebarSelectionPolicy`; the ViewModel
applies them and the Store owns the effects.

## Context

The sidebar lists fixed libraries plus connected removable/camera sources, with an
optional "All Media" aggregate. Two problems motivated this decision:

1. There was no default-selection policy. Startup always landed on "All Media" even
   with a single library or a connected card, and inserting a card never switched to
   it — wrong for a camera-import product where plugging in a card should take you to
   it.
2. Eject removed the source row but did not reliably eject the volume. The row was
   hidden by an internal *quiesce* (which flipped availability to unavailable, and
   the sidebar filtered on availability) *before* the physical unmount, and unmount
   failures were swallowed — so the row vanished while the disk stayed mounted.

## Alternatives

- **Selection default:** (a) always All Media (status quo — ignores the common
  camera-import intent); (b) remember the last selection across launches (adds
  durable UI state and surprises on a changed library set); (c) **a pure priority
  policy computed from current sources** — chosen.
- **Eject removal trigger:** (a) hide on quiesce (status quo — UI diverges from
  reality on failure); (b) **drive removal from the real unmount event, keep the row
  visible with an "ejecting" state until then** — chosen, matching how the prior
  app (`Otos Studio`) drove removal from `NSWorkspace.didUnmountNotification`.

## Decision

**Selection is governed by the pure `SidebarSelectionPolicy`, applied by
`CatalogWindowViewModel` whenever projected sources change:**

- `showsAllMedia(libraries:)` — the All Media row/selection exists **iff there are
  ≥2 fixed libraries**. All Media aggregates fixed libraries only (never
  removable/camera), so its visibility depends solely on the fixed-library count.
- `defaultSelection(libraries:removableSources:)` — priority: most-recently-attached
  connected removable/camera source → the single fixed library → All Media. Applied
  once at startup after the first *loaded* state (at least one library or removable
  root), before any explicit user choice (`userHasChosenSource`). An empty pre-load
  publication must not latch the default. This is the only automatic jump the app
  makes; a card connected at launch (or already connected when the app starts) is
  what satisfies the camera-import intent.
- **Attach-time selection hijack is deliberately absent**: attaching
  a card *after* the one-time startup default has already applied never moves the
  user, even if they are looking at an unrelated library or All Media. Always
  jumping to a newly-available card was tried and rejected — it interrupted a user
  who had already navigated elsewhere for no benefit once the startup case is
  covered, and a card that flaps unavailable → available mid-session would re-jump
  the user repeatedly for a transient filesystem event they didn't cause.
- `selectionOnSelectedSourceRemoved(...)` — if the selected source disappears, fall
  back to `defaultSelection` instead of leaving a dead selection.

The user's explicit sidebar click sets `userHasChosenSource`, which suppresses the
one-time default (but not the always-jump-on-attach). All of these route through the
single `setQueryDescriptor` writer, so automatic and manual selection share one path.

**Eject is honest and unmount-driven:**

- `quiesce` pauses the source's work (cancels runtime work, releases enrichment
  claims) but **does not** flip availability, so the row stays visible. The sidebar
  shows a per-identity "ejecting" spinner while the eject is in flight.
- The eject drains in-flight enrichment under the root, then calls
  `NSWorkspace.unmountAndEjectDevice`. Success unmounts the volume, and the row
  disappears because the real `didUnmountNotification` → detach removes it — UI and
  reality never diverge. Failure returns a typed `RemovableEjectOutcome`
  (`.ejected` / `.cancelled` / `.busy(displayName)` / `.failed(description)`).
  User-cancelled eject clears the spinner with no alert. Busy/failed surface a
  localized alert, the spinner clears, and the source stays mounted and visible.
  Busy detection prefers typed underlying errors (POSIX `EBUSY`, DiskArbitration
  dissenter) over English substring matching.

## Why This Is Simplest Correct

The selection rules are a small pure function over the current source set — no
durable UI state, no second selection owner, one application point. Driving eject
removal from the OS unmount event (rather than an internal availability flip) makes
the sidebar a faithful mirror of what is actually mounted, and a typed outcome makes
failure a first-class, user-visible result instead of a swallowed error.

## Consequences

- The sidebar never shows a stale selection or a still-mounted-but-hidden source.
- "All Media" quietly disappears when a single library is the whole world.
- Busy-eject detection depends on the OS error shape; the outcome mapping is a small
  heuristic that logs the underlying error for refinement.

## References

- Implemented in `Otos/Services/SidebarSelectionPolicy.swift`,
  `Otos/ViewModels/CatalogWindowViewModel.swift`,
  `Otos/ViewModels/CatalogWindowViewModelMutation.swift`,
  `Otos/Services/CatalogWindowPolicy.swift`, `Otos/Views/SidebarView.swift`.
- Tested by `OtosTests/SidebarSelectionPolicyTests.swift`,
  `OtosTests/CatalogWindowViewModelDefaultSelectionTests.swift`,
  `OtosTests/RemovableEjectOutcomeTests.swift`.
- Requirements ARC (ViewModel ownership) and the APP sidebar rows.
- ADR 0013 (removable and device sources); prior-app reference:
  `../Otos Studio_old` `DiskVolumeCommandService` + `MediaRootPresenceEventSource`.
