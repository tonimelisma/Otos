# 0031 — The browser place is saved at quit and restored at launch

Status: accepted.

## Context

Every launch used to start over: the default sidebar row, no filter, Date — Newest
First, grid mode, the top of the grid, nothing selected. APP-014 and APP-019 required
it, and ADR 0014 had rejected remembering the sidebar row because of "surprises on a
changed library set". The user asked for the opposite: after a restart, go back to the
view and the place they were in, covering source, filter, sort, view mode, scroll
position and selection. Lightroom Classic does the same, reopening a catalog on the last
source and the last selected photo.

The place is a set of identities (a library path, an import batch, asset paths) that
can stop existing while Otos is closed: a library removed, a card reformatted, a photo
deleted. The filesystem is the source of truth (ADR 0008), so a remembered identity is
a hint to check, never a fact to trust.

## MECE Decision Scope

This ADR owns what is remembered about the browser across launches, where and when it
is written, and how it is restored. It defers the sidebar priority policy used when
nothing is remembered to ADR 0014, the query descriptor itself to ADR 0011, and grid
centering on a focus target to ADR 0006 and ADR 0016.

## Decision

- **One value, one owner.** `BrowserPlace` holds the `CatalogQueryDescriptor`, the
  `BrowserViewMode`, the selection in display order, and one item to bring back into
  view. `CatalogWindowViewModel` is its only reader and writer.
- **Stored as a versioned preference.** One JSON string under `browserPlace` in the
  ViewModel's injected `PreferenceStore`, through a private record with an explicit
  `version`. A missing, unreadable or other-version value, or one outside today's
  vocabulary, loads as no place. An unreadable place costs the user their position,
  never their launch. The domain types gain no `Codable` conformances; the record is the
  whole schema. It lives in preferences, not the catalog database, because it is UI
  state about one window, not catalog truth or overlay.
- **Written once, at quit.** The ViewModel saves on
  `NSApplication.willTerminateNotification`. A place still waiting to be restored is
  not overwritten, so quitting before the catalog loads keeps the real one.
- **Restored in two steps, each when it becomes possible.**
  1. At init the saved descriptor becomes the ViewModel's first query, so Projection's
     first publication is already the user's collection, with no flash of the default.
  2. At the existing first-loaded-state latch (ADR 0014), a saved scope that still
     exists stands in place of `SidebarSelectionPolicy.defaultSelection`. One that is
     gone gets the default, keeps the saved filter and sort, and drops the rest.
  3. When the first non-empty result for the saved query arrives, the surviving
     selection is applied, then the mode. The grid centers on the saved item, the loupe
     opens on it, and compare re-enters from the restored selection. Each goes through
     the ordinary intents (`setFocus`, `openLoupe`, `enterCompare`), not a parallel path.
- **The grid's position is its middle visible item.** The grid already centers on a
  focus target, parking until the item exists and has been laid out. Saving the middle
  of the viewport, taken from the existing viewport report, and centering on it
  reproduces the viewport to within a row, with no new scroll mechanism.
- **Any other query drops a pending restore.** If the user picks a row, filter or sort
  before the restore applies, the old place would be a surprise jump.
- **A remembered scope wins over a card connected at launch.** The user asked to reopen
  where they were, and a card left in a reader would otherwise take over every launch.
  With nothing remembered, or a remembered scope that is gone, ADR 0014's card-first
  default still applies.

## Rejected alternatives

- **SwiftUI `@SceneStorage` / AppKit window state restoration.** These are tied to
  window restoration, which the user can turn off system-wide, and they would split the
  browser state between SwiftUI and the ViewModel that owns it.
- **Write on every change.** This adds a write to the scroll path and every selection
  change, for a value that is only read at the next launch. A crash loses the place,
  which is acceptable for a position hint.
- **Exact scroll offset.** An offset means nothing once enrichment, imports or a
  different window size reflow the grid, and restoring it would need a second scroll
  mechanism next to focus centering.
- **Restore the compare pair's left/right arrangement exactly.** That would need a
  second way to enter compare. The pair comes back in display order through
  `enterCompare`.

## Consequences

- APP-014 and APP-019 no longer reset on relaunch; APP-043 is the behavior.
- A stored place can name identities that are gone. Every restore step checks against
  the loaded catalog and drops what is missing.
- The saved selection grows with the selection (⌘A in a large library is a few MB of
  paths). It is written once per quit, which has not been measured as a problem.

## Defers

- Remembering a place per source (returning to a folder where you left it) is not part
  of this decision.
