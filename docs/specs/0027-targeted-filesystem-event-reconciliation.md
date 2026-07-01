# Spec 0027: Targeted Filesystem Event Reconciliation

## Classification

- Work type: Feature / architecture amendment
- User-visible goal: files changed while Otos is running appear or disappear without
  paying a full-root scan for safe single-file events
- Current requirement IDs: amends FND-056, FND-067, and APP-005
- ADRs: amends ADR 0002 and ADR 0008

## Problem And Goal

Spec 0023 made running-app FSEvents correct by routing every qualifying event to a
debounced full-root rescan. That preserved one proven reconciliation path, but it
made a single file create/delete/modify pay the same cost as a whole-root change.

The goal is a targeted first step: only single regular-file events with safe flags
take a one-path Store reconciliation path. Every ambiguous event remains a hint and
falls back to the existing full-root rescan.

## Scope

In scope:

- `FilesystemEventFlags` classification for regular-file targeted events versus
  full-root fallback.
- `CatalogScannedFileReader`, shared by full scans and targeted reconciliation for
  resource keys, symlink/package handling, and media eligibility.
- Store-owned targeted upsert/delete for single regular-file paths.
- Full-root fallback for directory events, symlinks, unknown flags, dropped events,
  `MustScanSubDirs`, root/mount ambiguity, and any unsupported shape.
- Tests for flag classification, targeted create/upsert, targeted delete, and
  unchanged full-root fallback behavior.

Out of scope:

- Rename-pair correlation, inode identity, generated file IDs, or move preservation.
- Directory subtree incremental reconciliation.
- Cloud-provider-specific materialization or selective-sync detection.
- Changed-ID payloads into the grid.

## Captured Requirements

| ID | Type | Requirement | Current or candidate | Storage |
| --- | --- | --- | --- | --- |
| FND-067 | Architecture | Safe single regular-file FSEvents reconcile one path; unsafe events fall back to full-root reconciliation. | Current | `docs/requirements.md` |
| FND-056 | Architecture | A missing exact path after a regular-file remove event under an armed available root is a proven deletion for that one row and its overlay. | Current | `docs/requirements.md`, ADR 0008 |
| APP-005 | Functional | Automatic scanning remains launch, add-library, and running-app filesystem-event reconciliation; no manual scan UI. | Current | `docs/requirements.md` |

## Architectural Alternatives

### A: Target single regular-file events, fallback otherwise (selected)

FSEvents remain hints. Store validates actual filesystem state before writing.
Regular-file create/modify/xattr/inode/rename reads one path and upserts; regular
file remove checks absence and deletes one row; everything ambiguous schedules the
existing full-root scan.

Pros:

- Removes the highest-confidence full-root rescan waste.
- Keeps filesystem truth in Store and persistence, not in the watcher.
- Avoids durable inode identity and rename correlation.

Cons:

- Directory changes still pay full-root cost.
- Single-path remove is a narrower deletion proof than completed enumeration and
  must stay explicitly documented.

Failure modes:

- Misclassified flags could miss membership changes; tests pin unsafe flags to
  fallback.
- A provider event with stale path facts may no-op and rely on later fallback or
  launch scan.

### B: Keep full-root rescans for all events

Pros: already proven and simple.

Cons: repeats whole-root I/O for safe single-file changes; measured plan evidence
showed this path was a material cost source.

Failure modes: large roots remain slow to converge during common single-file
updates.

### C: General subtree/inode event engine

Pros: handles directory moves and rename preservation with less scanning.

Cons: introduces durable filesystem identity, provider-specific behavior, and a
second membership model before current requirements need it.

Failure modes: stale identity or rename pairing can preserve overlay for the wrong
file, violating ADR 0008.

## Selected Approach

Use `FilesystemEventFlags` to admit only regular-file targeted events. Store waits
for the existing debounce, then:

- If any event in the batch requires fallback, enqueue one full-root scan.
- If all events are targeted, reconcile each path and notify once if any row changed.
- If a scan is already active for the root, drop the event batch and schedule one
  follow-up full-root scan after the active scan completes.

This is the simplest correct approach because it changes only the safe case and
keeps the existing full-scan proof for everything else.

## Persistence, Concurrency, And Side Effects

Targeted upsert uses the same `upsertScannedFile` SQL as full scans. Targeted delete
deletes only the `(library_root_id, relative_path)` row after the exact path is
absent and deletes that row's thumbnail file from Application Support. User originals
are never modified.

The Store actor owns the debounce batches, active-scan fallback, row writes, and
notifications. The watcher only delivers events. `CatalogScannedFileReader` reads
filesystem facts only and never reads media bytes.

## POC And Verification

- `FilesystemEventFlagsTests` pins regular-file create/remove to targeted handling
  and unknown/directory events to full-root fallback.
- `CatalogStoreFilesystemEventTests.targetedFileEventReconcilesWithoutFullScan`
  proves a regular-file create upserts without another scan invocation.
- `CatalogStoreFilesystemEventTests.targetedFileRemovalDeletesWithoutFullScan`
  proves a regular-file remove deletes one row without another scan invocation.
- Existing spec 0023 tests keep debounce, arming, active-scan follow-up, removal,
  and full-root fallback behavior covered.

## Stale-Document And Comment Audit

- ADR 0002 now owns targeted-first FSEvents with full-root fallback.
- ADR 0008 now names single-path missing-after-remove as a current proven-deletion
  path.
- `docs/requirements.md` FND-056/FND-067/APP-005 are current.
- `docs/onboarding.md` describes targeted FSEvents and the shared file-fact reader.
- File guides in `CatalogStore`, `CatalogFilesystemWatcher`, and `CatalogScanner`
  remain current after the shared reader extraction.
