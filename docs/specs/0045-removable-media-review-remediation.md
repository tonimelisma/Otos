# Spec: Removable Media Review Remediation

## Classification

Bug fix, refactor, and process follow-through. This spec implements the 15
review findings captured in the root `PLAN.md` for removable volumes, MTP camera
enumeration, device staging, eject, and connected-source enrichment scheduling.
It is part of the same increment as spec 0044 because the user explicitly asked
to wrap both sets of fixes into one increment.

## Problem

The removable-media implementation allowed several stale or partial platform
events to act as current truth. A stale MTP enumeration could reconcile-delete
rows written by a newer attach; ImageCapture readiness was treated as a complete
catalog after a fixed sleep; camera ready/close callbacks could be missed; cloned
volume UUIDs could crash the monitor; startup FSEvents could drop attached cards;
eject detached before unmount success and blocked the MainActor; and device
staging reused cloud eager-download state.

These are correctness and data-retention bugs. The fix must land at the owning
boundaries rather than adding more sleeps, broader `try?`, or post-hoc cleanup.

## Scope

In scope:

- Store-owned MTP enumeration leases using the same root path plus root-row plus
  in-memory lease-generation discipline as filesystem scans.
- Fail-closed camera reconciliation: partial or unstable ImageCapture catalogs
  may upsert visible rows but must not prove deletion.
- Latched camera session readiness/open/close state.
- Attach-time camera identity retention for detach.
- Duplicate removable-volume identity disambiguation.
- Watch-root derivation that includes already-attached available removable
  volumes when watching starts.
- Eject quiesce/drain/unmount/resume ordering, with unmount work off the
  MainActor.
- Device staging separated from cloud eager downloads; `freshly` made one-shot;
  failed staging work retried with backoff or low-space pause.
- Startup staging sweep moved off the MainActor.
- DiskArbitration callback unregister/stop.
- Requirements, ADR, onboarding, and index updates.

Out of scope:

- New schema.
- Device import/copy/delete workflows.
- Camera control.
- Hardware-only guarantees when no matching hardware is available to the agent.

## Current Repo State

Inspection found:

- `CatalogStore.reconcileMissingAssets` accepted `requiresOwnership: false` for
  device completion, bypassing the stale-scan guard.
- `DeviceCameraSession` stored one open continuation and one ready continuation
  and installed them after awaits, so callbacks could be missed.
- `openAndWaitForCatalog` slept 250 ms after ImageCapture's complete-catalog
  callback.
- `RemovableVolumeMonitor.refresh` used `Dictionary(uniqueKeysWithValues:)`.
- `CatalogStore.startFilesystemWatchingIfNeeded` started with fixed library roots
  only.
- Eject called `detachRemovableSource` before synchronous `NSWorkspace` unmount on
  the main actor.
- `stageDevice` set the global `eagerMode` latch used by cloud dataless work.
- `DeviceStagingRegistry.init` synchronously swept staging roots on the main actor.

## Requirements

- A device enumeration completion may reconcile missing rows only while its
  Store-issued enumeration lease is still current.
- A partial or unstable camera catalog may make observed items visible but must
  preserve unobserved existing rows and overlay.
- Session open, catalog ready, close, remove, timeout, and explicit close are
  latched states; waiters check state before installing continuations and every
  terminal event resumes pending waiters.
- Camera detach uses the identity recorded at attach time whenever possible.
- Duplicate volume UUIDs never trap and are disambiguated by mount path.
- Watch startup derives all current watchable roots, including available removable
  volumes attached before watcher start.
- Eject quiesces and drains first, then requests unmount off the MainActor; failed
  eject resumes the source instead of detaching it.
- Device staging dispatch does not enable cloud eager materialization.
- `freshly` entries are one-shot priority hints and are removed after the priority
  claim attempt that submitted them.
- Low disk space for device staging is a distinct retryable pause, not a timeout
  busy loop.
- Startup staging cleanup runs off the MainActor.
- DiskArbitration callbacks are unregistered before monitor deallocation.

## Alternatives

### Add More Sleeps

Pros: smallest diff.

Cons: still treats timing as truth, preserves the data-loss class, and fails under
slow ImageCapture or OS contention.

Rejected.

### Disable Device Reconciliation

Pros: prevents accidental deletion.

Cons: permanently stale camera rows after real deletion and avoids the ownership
bug instead of fixing it.

Rejected.

### Store Leases Plus Fail-Closed Reconciliation

Pros: reuses the proven scan-ownership model, preserves overlay when completeness
is not proven, and still reconciles after stable catalogs.

Cons: requires broader owner-aware API changes.

Selected because it is the smallest correct fix for the data-loss class.

## Selected Approach

Use `CatalogStore.ActiveScan` as the process-local lease for both filesystem
scans and MTP enumerations. The lease carries the root path, private root row, and
an in-memory generation so two same-root enumerations cannot both be current.
Device batches and completion revalidate that lease before and after database
awaits. `DeviceCameraSession` maintains latched state for open/catalog/terminal
events and separately tests catalog stability. The ViewModel records partial rows
and starts staging, but calls deletion reconciliation only when the snapshot is
stable.

Removable monitor work is split into attach, quiesce, resume, and detach events.
Store owns quiesce/resume state. Eject uses quiesce plus coordinator drain before
off-main unmount; normal detach still comes from OS unmount/disappearance.
Coordinator scheduling distinguishes device staging from cloud eager downloads
and retains retryable staging failures with backoff.

## Ownership And Concurrency

- Store owns root state, enumeration leases, reconciliation, quiesce/resume, and
  catalog persistence.
- ViewModel owns monitor lifetimes and per-camera flow tasks.
- `DeviceCameraSession` remains MainActor-isolated for ImageCapture objects.
- `DeviceStagingRegistry` routes staging materialization; startup sweeping runs
  in a detached utility task.
- `EnrichmentCoordinator` owns staging/download scheduling and retry state.
- Eject unmount work leaves the MainActor through a detached utility task.

## Verification

- Store tests cover stale device enumeration rejection.
- Watcher tests cover attach-before-start removable root watching.
- Policy tests cover duplicate removable volume identity disambiguation.
- Materialization tests cover low-space as a distinct non-materialized outcome.
- Existing coordinator tests cover device staging order.
- Full local `script/verify.sh` is required.

Hardware probes remain non-blocking when no matching device/card is available in
the agent environment: MTP replug storm, empty card, mid-enumeration yank, eject
with open file, and cloned-card UUID collision.

## Code Smells

- MainActor gravity: addressed by moving eject and staging sweep work off-main.
- State duplication: accepted only for process-local leases and retry state; Store
  remains catalog truth.
- Unsafe callback lifetime: addressed by DiskArbitration unregister/stop.
- Stringly identity: unchanged source namespaces, with path suffix only for truly
  ambiguous cloned volume UUIDs.
