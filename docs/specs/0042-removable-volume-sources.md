# Spec: Removable Volume Sources

## Classification

- Work type: Feature
- Current requirement IDs: APP-016, APP-017, ENR-011; updates FND-019,
  FND-020, FND-023, FND-024, APP-002, APP-003, APP-005, ENR-001
- ADRs: `docs/adr/0013-removable-and-device-sources.md`
- User guidance source: root `PLAN.md`, explicitly approved for full implementation
  in this increment

## Problem

Otos needs to treat an attached SD card or other removable filesystem volume as a
temporary media source without pretending it is a permanent fixed library. The
source should appear immediately, scan first, preserve overlay across ordinary
detach/remount, and remain outside All Media unless the user explicitly selects it.

## Scope

In scope:

- Detect removable mounted filesystems through `NSWorkspace`, `FileManager`
  volume facts, and Disk Arbitration disappearance callbacks.
- Store removable volumes as catalog roots with `kind = removableVolume`, stable
  `volume:<uuid>` identity when available, raw display name, ejectability, and
  `lastSeenAt`.
- Disambiguate simultaneously mounted duplicate volume UUIDs by mount path
  without adding content fingerprints or a second source table.
- Reuse/remap an existing source row when the same source identity returns at a
  new mount path.
- Scan attached removable volumes immediately at the front of the scan queue.
- Include already-attached available removable volumes when filesystem watching
  starts.
- Exclude removable volume rows from All Media while allowing explicit source
  selection.
- Quiesce on pre-unmount/eject, resume after failed eject, and mark confirmed
  detach as unavailable while preserving rows/overlay; Settings Forget removes the
  source and overlay.
- Skip hidden, AppleDouble, `.Spotlight-V100`, `.Trashes`, `AVF_INFO`, and
  `M4ROOT/SUB` paths during scan.
- Prioritize available removable roots before fixed roots in fallback enrichment
  candidate claiming.

Out of scope:

- Importing or copying originals into app-owned storage.
- Writing sidecars or modifying media folders.
- Durable content fingerprints or generated asset IDs.
- User-authored overlay portability/export.
- Hardware UI automation beyond agent-owned unit and build/test verification.

## Current Repo State

Before this increment, Store supported fixed library roots only. Library roots were
path-only values loaded from SQLite, scanned on add/start, and listed in one
sidebar section. Projection's All Media scope queried all available roots.
Enrichment fallback claims used the default newest-best-date order across every
available root. The scanner already skipped packages, symlinks, and non-media
regular files, but not the removable-media junk path families named above.

## Captured Requirements For User Verification

| Label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| REM-SIDEBAR | Functional | Removable mounted volumes appear in a separate sidebar section, never in the fixed Libraries section. | Current | APP-016, this spec |
| REM-ALLMEDIA | Functional | All Media includes fixed-library roots only; selecting a removable source shows that source's media. | Current | APP-016, tests |
| REM-IDENTITY | Architecture | A stable removable volume source is identified by `volume:<uuid>` and remaps to the current mount path on reattach. | Current | ADR 0013, APP-017 |
| REM-DETACH | Architecture | Detach marks the source unavailable and preserves catalog rows/overlay; Forget removes the source and overlay. | Current | APP-017 |
| REM-SCAN | Functional | Attach scans immediately and is inserted at the front of pending scans. | Current | APP-017 |
| REM-DUPUUID | Functional | Simultaneously mounted removable volumes with the same UUID are kept as distinct runtime identities by adding the mount path to colliding identities. | Current | APP-017, FND-071 |
| REM-EJECT | Functional | Eject quiesces and drains the source before off-main unmount; failed unmount resumes the source rather than detaching it. | Current | APP-017 |
| REM-WATCH | Functional | Filesystem watching starts with all available fixed libraries and available removable volumes already attached at watcher startup. | Current | APP-017 |
| REM-JUNK | Functional | Hidden, AppleDouble, Finder/Spotlight trash, and camera helper paths are excluded from catalog scans. | Current | APP-017 |
| REM-ENRICH | Architecture | Available removable roots are offered before fixed roots during fallback enrichment candidate claiming. | Current | ENR-011 |

## Architectural Alternatives

### Alternative A: Treat removable volumes as ordinary fixed libraries

Pros:

- Minimal schema and UI change.

Cons:

- All Media becomes polluted by temporary card contents.
- Detach/remount cannot preserve source identity when the mount path changes.
- Settings has no way to distinguish "forget this card" from "remove fixed library."

Failure modes:

- A card briefly attached for review keeps affecting All Media after it disappears.

### Alternative B: Separate removable-source table

Pros:

- Distinct persistence model for source metadata.
- Clear SQL separation between fixed roots and devices.

Cons:

- Media identity still needs a root path, so queries and foreign keys become split
  across two root owners.
- Adds complexity before a requirement needs different asset-row ownership.

Failure modes:

- Parallel root tables drift in behavior, query paths, and overlay cleanup.

### Alternative C: One root table with source kind and device identity (selected)

Pros:

- Keeps the current Store-owned query model and media identity.
- Adds only the source facts needed by current behavior.
- Supports remap by stable source identity while preserving root-relative media rows.

Cons:

- All Media and sidebar projection must consciously filter by kind.

Failure modes:

- If a source lacks a stable UUID, path fallback identity may not preserve overlay
  across different mount paths.

## Selected Approach

Alternative C is the simplest correct model. It keeps one catalog root owner and
adds the smallest source metadata needed for removable behavior. Store remains the
only catalog writer; monitors only report attach/detach events. Projection remains
the only UI-state builder and splits fixed libraries from removable sources.

## Interfaces, Ownership, Data Flow, And Persistence

- `RemovableVolumeMonitor` is `@MainActor` and listens to workspace mount,
  pre-unmount/unmount notifications plus Disk Arbitration disappearance
  callbacks. It emits attachment, quiesce, resume, and detach identity/reason
  events, and disambiguates duplicate mounted UUIDs by mount path.
- `CatalogStore.attachRemovableVolume(...)` normalizes the mount path, inserts or
  remaps a `library_root` row, marks it available, adds filesystem watching, and
  queues a front scan.
- `CatalogStore.quiesceRemovableSource(...)` and
  `resumeRemovableSource(...)` own pre-unmount/eject availability changes. User
  eject drains coordinator work for that root and requests OS unmount off the
  MainActor before waiting for platform detach confirmation.
- `CatalogStore.detachRemovableSource(...)` cancels runtime work, removes the
  watcher root, releases enrichment claims, marks availability unavailable, and
  preserves catalog rows for stable identities.
- `CatalogProjection` sorts all roots, publishes fixed rows as `libraries` and
  removable rows as `removableSources`, and excludes removable rows from All Media.
- `SettingsView` lists removable sources in a separate tab and routes Forget
  through the same Store removal path as other root removals.
- Schema migration `v5_removable_source_roots` adds `kind`, `device_identity`,
  `display_name`, `last_seen_at`, and a unique partial index for stable source
  identity.

## Concurrency And Actor Ownership

- Platform notifications stay on the main actor only long enough to create typed
  values. Store mutations cross one lossless serial ViewModel mutation stream.
- Store scan ownership remains the existing process-local path plus row-id plus
  in-memory generation lease.
- Quiesce/resume/detach events cross the lossless mutation stream. Detach releases
  enrichment claims for that root and starts the next queued scan.
- Disk Arbitration runs on a private dispatch queue and hops to the main actor for
  the event callback; callback registration uses an explicit retained context that
  is unregistered and released during monitor stop.

## Instrumentation And Profiling Plan

- `catalog.removable.attach` and `catalog.removable.detach` diagnostics record
  source kind, identity, path, display name, and detach reason.
- Existing scan, persistence, and enrichment diagnostics cover scan writes,
  claim ordering, and detail refresh.
- No performance-oriented data structure was added. If attach-scan latency becomes
  product-sensitive, capture unified logs and `script/profile.sh "File Activity"`.

## Test And Acceptance Criteria

- `CatalogStoreRemovableSourceTests.removableVolumeRemountsByIdentityAndStaysOutOfAllMedia`
- `CatalogStoreRemovableSourceTests.startWatchingIncludesAlreadyAttachedRemovableVolumes`
- `CameraSourcePolicyTests.duplicateRemovableVolumeIdentitiesArePathDisambiguated`
- `CatalogProjectionTests.removableSourcesAreSeparateAndExcludedFromAllMedia`
- `CatalogStoreMediaEligibilityTests.scanSkipsHiddenAppleDoubleAndCameraJunkPaths`
- `CatalogStoreEnrichmentClaimTests.fallbackEnrichmentClaimsRemovableSourcesBeforeFixedLibraries`
- Source hygiene test verifies root `PLAN.md` is retired after conversion.
- Local `script/verify.sh` must pass before final closure.

## Code-Smell Review

- MainActor gravity: avoided; Store and Projection still own catalog work off-main.
- State duplication: source availability/activity remains Store runtime state; UI
  receives projected rows only.
- Stringly typed facts: source identity strings are constrained by namespace
  prefixes and stored only as root metadata.
- AppKit bridge sprawl: none; no AppKit surface added beyond existing macOS APIs.
- Diagnostic payload sprawl: identities and paths are logged as developer
  diagnostics; no media bytes or secrets are logged.

## Stale-Document And Comment Audit

- Update `docs/index.md`, `docs/requirements.md`, `docs/onboarding.md`, ADR 0013,
  and this spec.
- Removed root `PLAN.md` after the plan was captured into current docs.
- Update file guides/comments in Catalog models, Store, scanner, Projection,
  ViewModel, and enrichment code where removable-source ownership is now current
  reality.
