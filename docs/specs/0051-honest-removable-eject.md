# Spec 0051: Honest Removable Volume Eject

## Classification

- Work type: Bug fix (PLAN.md Part 5).
- Current requirement IDs: APP-017 (removable volume eject behavior).
- Future idea or candidate links explicitly requested by the user: none.
- ADRs: none (behavior correction within existing removable-source boundary; ADR 0013
  references eject but does not own UI timing).

## Problem

Clicking the sidebar eject button removes the source row from the sidebar but the physical
volume stays mounted in Finder.

### Root cause (verified in code)

`performEjectRemovableSource` calls `quiesceRemovableSource`, which sets availability to
`.unavailable`. `SidebarView` filters `removableSources.filter(\.isAvailable)`, so the row
vanishes before `unmountAndEjectDevice` runs. Failures are logged only; `resumeRemovableSource`
restores availability with no user-visible error.

## Scope

In scope:

- Decouple quiesce from sidebar visibility: `quiesceRemovableSource` pauses work but does
  **not** flip availability to `.unavailable`.
- Eject intent: cancel/drain enrichment and runtime work, then call
  `unmountAndEjectDevice` off MainActor; row removal driven by real `didUnmount` detach.
- `RemovableEjectOutcome` (`.ejected`, `.busy(displayName:)`, `.failed(description:)`).
- Surface `.busy` / `.failed` via standard macOS alert; never swallow.
- Transient "Ejecting…" spinner in sidebar row trailing accessory during the intent.
- Unit tests for outcome mapping and quiesce-not-hiding-row rule.
- Update APP-017 acceptance.

Out of scope:

- DiskArbitration dissenter UI (use `NSWorkspace` error mapping first; DA only if needed).
- Manual hardware verification (after-DoD).
- Camera MTP eject (cameras detach via ImageCapture, not volume eject).

## Definition Of Ready

- [x] Goal, scope, and non-goals explicit.
- [x] Current repo state inspected.
- [x] Three alternatives compared.
- [x] Tests and instrumentation addressed.

## Current Repo State

- `CatalogStore.quiesceRemovableSource` sets `.unavailable`
  ([CatalogStore.swift](../../Otos/Stores/CatalogStore.swift)).
- `performEjectRemovableSource` quiesces, drains, unmounts; on failure resumes
  ([CatalogWindowViewModelMutation.swift](../../Otos/ViewModels/CatalogWindowViewModelMutation.swift)).
- `SidebarView` hides unavailable removables from the Removable section.

## Design

### Quiesce semantics

`quiesceRemovableSource` retains: cancel runtime work, idle activity, release enrichment
claims. **Remove** `setAvailability(.unavailable)`. Sidebar continues to show the source
until `detachRemovableSource` runs on real unmount.

`resumeRemovableSource` remains for aborted system unmount (willUnmount timeout path).

### Eject flow

1. ViewModel marks identity in `ejectingSourceIdentities` and submits mutation (same stream).
2. `performEjectRemovableSource` returns `RemovableEjectOutcome`:
   - `quiesce` (work-only) + `drainWork` + `unmountAndEjectDevice`.
   - Map `NSError` domain/code to `.busy` when volume in use; else `.failed`.
   - On success return `.ejected` (row disappears when monitor fires detach).
   - On failure **do not** resume availability (it was never cleared).
3. Mutation forwarding delivers outcome to ViewModel `handleEjectOutcome` on MainActor:
   clear ejecting state; present alert for non-`.ejected`.

### Sidebar UI

- `ejectingSourceIdentities: Set<String>` passed to `SidebarView`.
- Trailing accessory: `ProgressView` when ejecting, else eject button when ejectable.

### Alert

- `ContentView` binds `.alert` to ViewModel `ejectAlertMessage` (nil = hidden).
- Message: *The disk "NAME" couldn't be ejected because it's in use.* for busy; localized
  description for other failures.

## Alternatives

1. **Quiesce without availability flip (selected).** Minimal change; detach still owns row
   removal; grid may briefly show quiesced media during eject (acceptable).
2. **Separate `isMounted` flag on `CatalogLibraryState`.** Rejected: detach already models
   unmount; extra field duplicates monitor truth.
3. **Eject outside mutation stream.** Rejected: violates one user action / one path (FND-052).

## Concurrency

- Eject mutation stays on serial mutation stream.
- `unmountAndEjectDevice` off MainActor (unchanged).
- Outcome handled on MainActor for alert + `ejectingSourceIdentities`.

## Instrumentation

- Keep `CatalogEjectRemovableSourceIntent` signpost.
- Log outcome case at info; error detail at error without private payloads.
- Diagnostics JSONL `catalog.removable.eject` phase `finish` with outcome case.

## Tests

- `RemovableEjectOutcomeTests` or extend mutation tests: busy error mapping.
- `CatalogStoreRemovableSourceTests`: quiesce leaves `availability == .available`.
- ViewModel test: ejecting identity set/cleared (mock mutation outcome).

## Acceptance examples

| # | Condition | Expected |
| --- | --- | --- |
| 1 | User clicks eject; unmount succeeds | Row shows spinner briefly; row gone after unmount |
| 2 | Unmount throws "in use" | Alert shown; row remains; no silent failure |
| 3 | System willUnmount quiesces source | Row stays visible until didUnmount |
| 4 | Quiesce during eject | Availability stays `.available` until detach |

## Code smells

- Avoid parallel eject Task outside mutation stream.
- Avoid alert state sprawl (one optional message string).

## Stale-document audit

- Update APP-017 in `docs/requirements.md`.
- Update onboarding eject/removable section.
- Delete PLAN.md (final plan increment).
