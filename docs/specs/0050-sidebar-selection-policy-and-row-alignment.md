# Spec 0050: Sidebar Selection Policy and Row Alignment

## Classification

- Work type: Bug fix (PLAN.md Parts 3 and 4).
- Current requirement IDs: APP-002 (sidebar structure), FND-023 (ViewModel sidebar intent
  ownership), FND-050 (removed-selection fallback).
- Future idea or candidate links explicitly requested by the user: none.
- ADRs: none (pure policy + SwiftUI layout; no persistence or reusable boundary change).

## Problem

Owner hand-testing reported sidebar defects (PLAN.md §3.1, §4.1):

1. **No removable auto-select.** At startup with a card attached, the app stays on All Media
   instead of showing the card. Inserting a card does not switch to it.
2. **Redundant All Media with one library.** With a single fixed library the sidebar still
   shows All Media and lands there.
3. **Icon misalignment.** The All Media row uses SwiftUI `Label` while library/removable rows
   use hand-rolled `HStack` layouts, so icons and titles do not share one leading rail.

### Root cause (verified in code)

- `CatalogWindowViewModel` initializes `sidebarSelection = .allMedia` and never promotes a
  smarter default once sources load.
- `CatalogWindowPolicy.resolvedSidebarSelection` only demotes invalid `.library` to
  `.allMedia`; it never promotes to a connected removable or single library.
- Attach flows persist the source but never change selection.
- `SidebarView` renders the All Media row unconditionally.

## Scope

In scope:

- Pure `SidebarSelectionPolicy` with unit tests.
- Startup default selection once projected sources are known (before explicit user choice).
- Always jump to a newly attached removable/camera source.
- Fallback when the selected source disappears uses `defaultSelection`, not hard-coded All
  Media.
- Hide All Media when there is exactly one fixed library; resolve `.allMedia` to that library
  when hidden.
- `userHasChosenSource` flag: set on explicit sidebar clicks only; attach and startup
  defaults ignore it; unrelated source churn does not yank a browsing user.
- Unified `SidebarRow` for every sidebar row (All Media, libraries, removables).
- Update `APP-002` acceptance and related requirements once implemented.

Out of scope:

- Grid selection (spec 0046), thumbnail hit area (spec 0049), honest eject (spec 0051).
- Settings scene layout changes.
- New onboarding empty-state selection enum (deferred; single-library auto-select covers the
  common case).

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state inspected.
- [x] Owner decisions restated as acceptance examples below.
- [x] Three alternatives compared.
- [x] Ownership, concurrency, instrumentation, and tests addressed.

## Current Repo State (verified by inspection)

- `CatalogWindowViewModel.sidebarSelection` defaults to `.allMedia`
  ([CatalogWindowViewModel.swift](../../Otos/ViewModels/CatalogWindowViewModel.swift)).
- `selectSidebar` funnels through `setQueryDescriptor` without distinguishing user vs
  automatic selection.
- `applyState` resets removed library selection to `.allMedia` via
  `currentSelectionWasRemoved`.
- `SidebarView` always renders All Media via `Label` and filters removables with
  `isAvailable` ([SidebarView.swift](../../Otos/Views/SidebarView.swift)).
- `CatalogWindowPolicy.resolvedSidebarSelection` takes only `libraries` and falls back to
  `.allMedia` ([CatalogWindowPolicy.swift](../../Otos/Services/CatalogWindowPolicy.swift)).

## Design

### `SidebarSelectionPolicy`

New file `Otos/Services/SidebarSelectionPolicy.swift`, `nonisolated`, no side effects.

| API | Rule |
| --- | --- |
| `showsAllMedia(libraries:)` | `true` iff 2+ fixed libraries (`kind == .library`). |
| `defaultSelection(libraries:removableSources:)` | Most-recently-attached connected removable/camera (`lastSeenAt`) → else single fixed library → else `.allMedia`. |
| `selectionOnAttach(attached:)` | `.library(path)` for non-fixed sources; `nil` for fixed libraries. |
| `selectionOnSelectedSourceRemoved(libraries:removableSources:)` | `defaultSelection`. |

### ViewModel wiring

- `@ObservationIgnored private var userHasChosenSource = false`
- `@ObservationIgnored private var hasAppliedInitialDefault = false`
- `selectSidebar` sets `userHasChosenSource = true` then calls `setQueryDescriptor`.
- `applyAutomaticSidebarSelection(_:)` calls `setQueryDescriptor` without setting the flag.
- In `applyState`, before generation sync:
  1. Newly attached available removables (identity not in previous state) →
     `selectionOnAttach` (always, regardless of `userHasChosenSource`).
  2. Else if `!userHasChosenSource && !hasAppliedInitialDefault` → `defaultSelection` once.
  3. Else existing generation / removed-selection logic; removed path uses
     `selectionOnSelectedSourceRemoved` instead of `.allMedia`.

### Projection policy

- `CatalogWindowPolicy.resolvedSidebarSelection` and `resolvedDescriptor` take both
  `libraries` and `removableSources`.
- When `.allMedia` is selected but `showsAllMedia` is false, resolve to `defaultSelection`
  (the single library).
- When `.library(path)` is invalid, resolve via `selectionOnSelectedSourceRemoved`.

### Sidebar UI

- `SidebarView` takes `showsAllMedia: Bool`.
- Private `SidebarRow` with 20pt icon rail, spacing 8, shared by all rows.
- Eject button remains trailing accessory on removable rows (spinner added in spec 0051).

## Alternatives

1. **Pure policy in ViewModel (selected).** Smallest correct model; unit-testable without
   SwiftUI; mirrors `CatalogWindowPolicy`.
2. **Projection-owned defaults.** Rejected: selection intent must originate from ViewModel
   per ADR 0004; Projection only resolves invalid scopes.
3. **Persist last sidebar choice across launches.** Rejected: owner wants smart defaults and
   card jump; session-only descriptor policy (APP-014) applies to filter/sort, not this
   increment's scope.

## Concurrency

- `SidebarSelectionPolicy` is `nonisolated` pure functions.
- ViewModel applies policy on MainActor inside `applyState`.
- No new actors or background work.

## Instrumentation

- Existing `CatalogQueryDescriptorIntent` signpost on `setQueryDescriptor` covers automatic
  and user selection; log line already includes descriptor diagnostic description.
- No new JSONL; policy is not high-frequency.

## Tests

- `SidebarSelectionPolicyTests`: every policy rule and edge case.
- Update `CatalogWindowViewModelTests` for single-library default, attach jump, removed
  fallback.
- Update `CatalogProjectionTests` / lifecycle tests for hidden All Media resolution.

## Acceptance examples

| # | Condition | Expected |
| --- | --- | --- |
| 1 | Startup, card connected, user has not clicked sidebar | Grid shows card source |
| 2 | Startup, one fixed library, no removables | All Media row hidden; library selected |
| 3 | Two libraries, no removables | All Media visible; default All Media |
| 4 | User browsing library A; card inserted | Selection jumps to card |
| 5 | Selected card ejected/detached | Falls back per defaultSelection |
| 6 | User explicitly chose All Media with 2+ libraries; unrelated blip | Selection unchanged |
| 7 | All sidebar row icons align on one 20pt rail | Visual/layout test via SidebarRow |

## Code smells

- Watch for duplicating default rules between Policy and ViewModel (policy must be single
  source).
- Watch for `applyState` growing further (keep policy calls in one private helper).

## Stale-document audit

- Update `docs/requirements.md` APP-002, FND-023, FND-050.
- Update `docs/onboarding.md` sidebar section.
- Delete `docs/product/PLAN-grid-selection-and-sidebar-fixes.md` when all plan parts land
  (final increment with spec 0051).
