# Spec: Package Descendant Scan Skip

## Classification

- Work type: Bug fix, scanner behavior, diagnostics
- Current requirement IDs: FND-025, FND-027, FND-036, APP-005, APP-006
- Future idea or candidate links explicitly requested by the user: none
- ADRs: ADR 0002

## Problem

Scanning `/Users/example/Pictures` failed because macOS denied enumeration
inside `Photos Library.photoslibrary`. The scanner recorded the detailed JSONL
issue, but the regular-file scan still ended as failed after writing the regular
files it could observe.

Repo inspection found:

- `CatalogScanner` requests `contentTypeKey` but not `isPackageKey`.
- `CatalogScanner` uses `FileManager` enumeration options `[]`, so it descends
  into package directories.
- The denied Photos library reports top-level resource values before descent,
  including `isPackage = true` and `contentType = com.apple.photos.library`.
- Current catalog behavior stores regular files only.
- Debug JSONL diagnostics already support bounded scan issue records.

## Scope

In scope:

- Request `isPackageKey` during scan enumeration.
- Use `.skipsPackageDescendants`.
- Treat package roots as intentionally skipped traversal inputs, not media rows.
- Record `catalog.scan.skippedPackage` diagnostics with package path and
  available content type identifier.
- Summarize skipped package counts in `script/catalog-diagnostics.sh`.
- Add tests proving package descendants are not cataloged and do not fail the
  root scan.
- Add comments explaining why package descendants are skipped.

Out of scope:

- AVCHD, XAVC, Blu-ray, camera-card, or other compound media-container import.
- Media eligibility beyond regular files.
- User-facing scan warnings or skipped-package UI.
- Photos library integration, PhotoKit, Full Disk Access prompts, sandboxing, or
  security-scoped bookmarks.
- Treating inaccessible non-package directories as completed scans.

## Captured Requirements For User Verification

The user guidance was explicit enough to record directly:

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| ADD-001 | Architecture | The regular-file scanner shall skip macOS package descendants by default. | Current | `docs/requirements.md`, ADR 0002, this spec |
| ADD-002 | Tooling | The scanner shall record skipped package diagnostics with path and available content type identifier. | Current | `docs/requirements.md`, this spec |
| ADD-003 | Architecture | Skipped packages shall not be treated as filesystem errors for reconciliation. | Current | `docs/requirements.md`, ADR 0002, this spec |
| ADD-004 | Process | Code comments shall explain why package descendants are skipped and why media-container support is separate. | Current | `docs/requirements.md`, `AGENTS.md`, this spec |
| NON-001 | Architecture | This increment shall not implement package/container media import. | Current | ADR 0002, this spec |

Acceptance examples:

- Given a library root contains `visible.jpg` and
  `Photos Library.photoslibrary/hidden-inside-package.jpg`, the completed scan
  catalogs only `visible.jpg`.
- Given that package root is observed, diagnostics include
  `catalog.scan.skippedPackage` with `com.apple.photos.library` when macOS
  provides that content type.
- Given a package is skipped, the root scan can still complete and reconcile
  observed regular files.

## Architectural Alternatives

### Continue Crawling Packages

Pros:

- Finds any regular files inside package directories.
- No scanner behavior change.

Cons:

- Keeps failing on protected package internals such as Photos libraries.
- Treats compound app/document stores as ordinary media folders.
- Risks cataloging implementation files that users do not think of as originals.

Failure modes:

- A single protected package causes a normal root scan to fail.
- Future reconciliation cannot distinguish intentional media from private
  package internals.

### Selected: Skip Package Descendants

Pros:

- Matches current regular-file-only catalog scope.
- Uses the native `FileManager` package traversal option.
- Avoids protected package internals before they become enumeration errors.
- Keeps skipped package evidence in diagnostics.

Cons:

- Does not discover media stored inside package-style camera containers.

Failure modes:

- A camera package with real media is skipped until explicit container support
  is implemented.

### Whitelist Known Media Packages Now

Pros:

- Could support AVCHD or similar camera layouts earlier.
- Avoids skipping some relevant video media.

Cons:

- Requires format-specific fixtures and import semantics.
- Broadens the increment from scan reliability into media-container design.

Failure modes:

- A partial whitelist gives users false confidence that all package media is
  supported.
- Package support starts as path folklore rather than tested product behavior.

### Treat All Enumeration Issues As Non-Fatal

Pros:

- Scans complete despite inaccessible files or directories.
- Simple behavioral change.

Cons:

- A completed partial scan could delete previously cataloged rows for files
  hidden behind a transient access failure.
- Does not distinguish safe package skips from serious filesystem failures.

Failure modes:

- Reconciliation becomes unsafe for non-package access failures.

## Selected Approach

Use `.skipsPackageDescendants` and request `isPackageKey`. When the enumerator
returns a package root, record a `catalog.scan.skippedPackage` diagnostic and do
not create a media asset row. Package skips do not enter `filesystemIssues`, so
they do not fail the scan or block reconciliation.

This is the simplest correct approach because it fixes the observed Photos
library failure while preserving the current regular-file-only scanner. It does
not invent camera package import behavior without fixtures or product
requirements.

## Interfaces, Ownership, And Data Flow

- `CatalogScanner` owns package detection during enumeration.
- `CatalogDiagnostics` records package skips as debug JSONL events.
- `CatalogStore` still owns scan lifecycle and reconciliation.
- `media_asset` schema is unchanged.
- `script/catalog-diagnostics.sh` summarizes skipped package counts.

## Concurrency And Actor Ownership

- Package detection runs inside the existing scanner task, off the MainActor.
- No new long-running task, actor, queue, or cancellation path is introduced.
- Diagnostics writes remain actor-isolated through `CatalogDiagnostics`.

## Instrumentation And Profiling

- Add `catalog.scan.skippedPackage` with:
  - `rootPath`
  - `path`
  - `contentTypeIdentifier` when available
- Add a debug `FileAccess` log line for skipped package roots.
- Add a diagnostics summary count for skipped packages.
- No Instruments trace is required because this is not performance-sensitive.

## Test And Acceptance Criteria

- Store/scanner test proves package descendants are skipped and the root scan
  completes.
- Diagnostics test proves the summary reports skipped package counts.
- Existing scan failure and reconciliation tests still pass.
- `script/verify.sh` passes locally.
- Runtime diagnostics check reports skipped package counts after launching with a
  library that contains a package root.

## Code-Smell Review

- MainActor gravity: unchanged; scan work stays off the MainActor.
- State duplication: no new catalog state is introduced.
- Diagnostic payload sprawl: package diagnostics contain bounded path/type
  fields only.
- Speculative flexibility: avoided by not implementing camera package import in
  this bug fix.

## Verification

- Local checks: `script/verify.sh`
- Runtime check: `script/build_and_run.sh --verify` and
  `script/catalog-diagnostics.sh check`
