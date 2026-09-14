# ADR 0028: Grid Drag-Out Representation

- Status: Accepted
- Date: 2026-09-13

## Context

ADR 0012 decided what ⌘C places on the pasteboard for selected assets — one original
file URL per asset, references only — and named drag-and-drop out of the grid as an
adjacent decision requiring its own ADR. Plan 0103 E builds that drag. The same facts
apply: Otos is unsandboxed, so a plain file URL is directly readable by the receiver;
a file URL is the only representation that works for video and the only one that
attaches at full fidelity for a few bytes; and byte reads must never accidentally
materialize a dataless cloud placeholder.

Two mechanics are specific to the grid. `MediaGridCollectionView` owns `mouseDown`
and never calls `super` (spec 0046: AppKit's native mouse selection raced the
ViewModel-owned model), so AppKit's own drag initiation never runs and the view must
detect the drag itself. And the grid applied a plain click on an already-selected tile
at mouse-down, which would collapse a multi-selection before a drag could carry it.

## MECE Decision Scope

Owned here: the drag pasteboard representation for assets dragged out of the grid or
filmstrip, the rule for which assets a drag carries, the drag source's operation mask,
and the mouse-down deferral that makes a multi-item drag possible.

Referenced, not owned: the selection model and click semantics (APP-010/011); the
clipboard representation (ADR 0012); asset→URL construction (`MediaAssetID.fileURL`).

Adjacent decisions requiring their own ADR when built: dropping files *onto* Otos; a
file-promise drag that renders or transcodes at drop time; any pixel representation.

## Decision

A drag out of the grid or filmstrip writes one original **file URL** (`public.fileURL`)
per asset, in display order, and nothing else — the objects ⌘C writes. A drag that
starts on a selected tile carries the whole selection; one that starts on an
unselected tile carries that tile alone (Finder's rule). The source offers `.copy`
outside Otos and nothing within it, since Otos has no drop target. Otos reads no bytes
and requests no materialization; a receiver that reads a dataless original downloads
it as its own act on a file the user handed it.

A plain mouse-down on an already-selected tile no longer changes the selection at
mouse-down; the change waits for mouse-up, and a drag that begins in between cancels
it. Every other click applies at mouse-down as before, and a double-click applies then
opens. The decision is a pure function (`MediaGridDragPolicy.decision`) so the timing
rule is tested, not inferred.

## Alternatives Considered

### File URLs only (chosen)

Tiny, lossless, works for video and every file receiver, reads no bytes. Does not
drop as inline pixels into a browser text field — the same accepted gap as ADR 0012.

### `NSFilePromiseProvider`

Designed for content that exists only at drop time. Every dragged original already
exists on disk, so a promise would add a callback, a temporary file and a second code
path to produce a copy Finder would have made itself. Rejected until a transcoding
export exists.

### Restoring `super.mouseDown` for drag initiation

Would hand mouse selection back to AppKit's undocumented commit timing, which spec 0046
measured and rejected. Rejected.

## Consequences

- Dragging photos and videos into Finder, Mail and Messages works at full fidelity
  with no byte I/O in Otos.
- A plain click on a selected tile commits on mouse-up rather than mouse-down; the
  visible difference is a few milliseconds and it is what Finder does.
- The drag image is a snapshot of each visible tile; assets scrolled out of view share
  the origin tile's frame.

## Living Documentation Impact

- `docs/requirements.md`: APP-038.
- ADR 0012: drag-out moves from "adjacent" to "decided here".
- `docs/architecture.md`: where-to-change row for drag-out.
