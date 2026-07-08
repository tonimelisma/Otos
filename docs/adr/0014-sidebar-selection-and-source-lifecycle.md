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
  once at startup after the first *loaded* state, before any explicit user choice
  (`userHasChosenSource`).
- `selectionOnAttach(attached:)` — a newly-attached removable/camera source is
  **always** selected (camera-import intent), even over a current selection.
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
  (`.ejected` / `.busy(displayName)` / `.failed(description)`); busy/failed surface a
  localized alert, the spinner clears, and the source stays mounted and visible.

## Why This Is Simplest Correct

The selection rules are a small pure function over the current source set — no
durable UI state, no second selection owner, one application point. Driving eject
removal from the OS unmount event (rather than an internal availability flip) makes
the sidebar a faithful mirror of what is actually mounted, and a typed outcome makes
failure a first-class, user-visible result instead of a swallowed error.

## Consequences

- The sidebar never shows a stale selection or a still-mounted-but-hidden source.
- A remembered card re-inserted at a new mount is remapped by the Store and jumped
  to as a fresh attach.
- "All Media" quietly disappears when a single library is the whole world.
- Busy-eject detection depends on the OS error shape; the outcome mapping is a small
  heuristic that logs the underlying error for refinement.

## References

- Implemented in `Otos/Services/SidebarSelectionPolicy.swift`,
  `Otos/ViewModels/CatalogWindowViewModelSidebarPolicy.swift`,
  `Otos/ViewModels/CatalogWindowViewModelMutation.swift`,
  `Otos/Services/CatalogWindowPolicy.swift`, `Otos/Views/SidebarView.swift`.
- Tested by `OtosTests/SidebarSelectionPolicyTests.swift`,
  `OtosTests/ViewModelDefaultSelectionTests.swift`,
  `OtosTests/RemovableEjectOutcomeTests.swift`.
- Requirements ARC (ViewModel ownership) and the APP sidebar rows.
- ADR 0013 (removable and device sources); prior-app reference:
  `../Otos Studio_old` `DiskVolumeCommandService` + `MediaRootPresenceEventSource`.
