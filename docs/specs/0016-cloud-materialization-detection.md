# Spec: Cloud Materialization Detection And The Media-Metadata Boundary

## Classification

- Work type: Feature (detection primitive added as dead code) plus architecture
  documentation
- Current requirement IDs: FND-053, FND-057; adds FND-059, FND-060; sharpens FND-057
- Future idea or candidate links explicitly requested by the user: none
- ADRs: `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`

## Problem

Most Otos media lives in cloud-synced folders. A file the provider has not
downloaded is an APFS dataless placeholder: its filesystem facts (name, size, dates,
type) are readable for free, but reading its bytes forces the provider to download
(materialize) it, which can pull hundreds of megabytes per file. The catalog scanner
is already safe because it reads only filesystem facts and no bytes. The future
thumbnail and media-metadata pipelines are not safe by construction: they read bytes,
so they can trigger large, surprising downloads unless they check materialization
first.

Two gaps block those future increments from being built correctly:

1. The repo has no verified facts about how to detect a dataless file across the
   common providers, and no shared function to do it. ADR 0008 states the policy
   ("never force-materialize dataless files") but not the mechanism.
2. The word "metadata" is ambiguous. The catalog stores cheap filesystem facts, but
   "metadata" also means EXIF and similar media metadata that requires reading bytes.
   Conflating them invites a future developer to read bytes thinking it is cheap.

This increment closes both gaps with documentation and one dead function, without
wiring anything into a live path and without persisting any materialization state.

## Scope

In scope:

- Record verified, provider-aware facts about detecting dataless files.
- Define the media-metadata versus filesystem-facts distinction and make "metadata"
  mean media metadata from now on.
- Add `FileMaterialization.status(of:)` as dead code: a point-in-time, no-byte-read
  detector that future byte-reading work calls before materializing a file.
- Add tests for the reproducible states and cite the proof of concept for the
  dataless state.
- Update ADR 0008, `AGENTS.md`, and `docs/requirements.md` accordingly.

Out of scope:

- Wiring the detector into any live path. It stays dead until the thumbnail or
  media-metadata pipeline is built.
- The thumbnail and media-metadata pipelines themselves.
- Persisting materialization status anywhere. It is transient and never stored.
- Further proofs of concept on other providers.
- Changing the catalog schema, scanner, or any runtime behavior.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance is restated as precise requirements for verification.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas are kept out of `docs/requirements.md`.
- [x] Ownership, side effects, persistence, cancellation, errors, privacy,
      instrumentation, and tests are addressed.
- [x] At least three alternatives are compared.
- [x] Retirement proof is defined (nothing retired).
- [x] A repository-wide stale-document audit is defined.
- [x] A code-comment accuracy audit is defined.
- [x] Performance evidence is defined (none; the detector reads no bytes and is not
      wired into a hot path).
- [x] Open questions are answered or out of scope.

## Verified Facts About Materialization Detection

On current macOS, iCloud Drive, OneDrive, Dropbox, and Google Drive all sync through
the File Provider framework, and an unmaterialized item is an APFS dataless
placeholder carrying the kernel flag `SF_DATALESS` (`0x40000000`, `<sys/stat.h>`,
macOS 10.15+). Reading inode metadata (`lstat`, resource values) does not
materialize; reading bytes does. Apple's guidance is
[TN3150: Getting ready for dataless files](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files).

Proof of concept run against a real OneDrive library
(`~/Desktop/OneDrive/Pictures/Camera Roll/2026/06`, 5,254 files, 2,611 dataless):

| Signal | Materialized file | Dataless file | Reads bytes? |
| --- | --- | --- | --- |
| `st_flags` SF_DATALESS bit (`lstat`) | clear (`0x40`) | set (`0x40000060`) | no |
| `ls -lO` / `stat -f %Sf` | `-` | `compressed,dataless` | no |
| `URLResourceValues.ubiquitousItemDownloadingStatus` | `Current` | `NotDownloaded` | no |
| `isUbiquitousItem` | `true` | `true` | no |
| `fileSize` | known | known | no |

Findings: the `SF_DATALESS` kernel flag distinguishes the states with no
materialization; the higher-level `ubiquitousItemDownloadingStatus` reports the same
state and, notably, populates for OneDrive even though it is a third-party (non-iCloud)
provider; filesystem facts including size are available for dataless files.

Provider coverage: iCloud Drive is Apple's own File Provider; OneDrive is
POC-verified above; Dropbox and Google Drive use the same File Provider plus APFS
dataless substrate, so detection is expected to be identical but was not separately
POC-verified per the owner's instruction to run no further POCs. This residual is
recorded as a risk; the chosen kernel-flag signal is provider-agnostic by
construction.

## Captured Requirements For User Verification

| ID | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-057 (sharpened) | Non-functional | Catalog, thumbnail, and media-metadata work must not force-materialize dataless cloud files; it consults the materialization detector before any byte access. | Current | docs/requirements.md, ADR 0008, AGENTS.md |
| FND-059 | Architecture | Media metadata (EXIF and similar, requires reading bytes) is distinct from filesystem facts (resource values, no materialization). The catalog stores only filesystem facts; "metadata" and the Metadata instrumentation category mean media metadata. | Current | docs/requirements.md, ADR 0008, AGENTS.md |
| FND-060 | Architecture | One `FileMaterialization` owner reports point-in-time dataless status via `SF_DATALESS` without reading bytes; the status is transient and is never persisted; byte-reading operations consult it before materializing. | Current | docs/requirements.md, ADR 0008, this spec |

## Architectural Alternatives

### Alternative A: SF_DATALESS kernel flag via `lstat`, exposed by a dead owner

Pros:

- Provider-agnostic kernel truth that directly answers "will reading materialize
  this?"; no dependency on iCloud-flavored keys being populated by every provider.
- Pure inode read, no byte access, callable off the main actor.
- One owner the future pipelines call; no rediscovery of the cloud hazard.

Cons:

- Uses a small amount of POSIX interop and a hardcoded flag constant.

Failure modes:

- A future macOS could change the flag value (mitigated: it is a stable published
  constant; a single owner localizes any change).

### Alternative B: `URLResourceValues.ubiquitousItemDownloadingStatus` only

Pros:

- Pure Swift, no POSIX interop.

Cons:

- iCloud-framed; not guaranteed to populate for every third-party provider. It did
  populate for OneDrive in the POC, but relying on it alone is less robust than the
  kernel flag for the exact question we ask.

Failure modes:

- A provider that sets `SF_DATALESS` but not the ubiquitous keys would be misread as
  materialized, causing a surprise download.

### Alternative C: Persist a dataless flag in the catalog at scan time

Pros:

- The pipelines could read it without a fresh filesystem call.

Cons:

- Materialization is transient; a provider can evict or download a file at any time,
  so a stored flag is stale immediately and would cause both missed thumbnails and
  surprise downloads. Contradicts ADR 0008 (overlay is filesystem-derived, not a
  second source of truth).

Failure modes:

- The catalog asserts a download state that no longer matches the filesystem.

## Selected Approach

Alternative A. `FileMaterialization.status(of:)` reads the `SF_DATALESS` flag via
`lstat` and returns `materialized`, `dataless`, or `unknown`. It is the single owner
of materialization detection, reads no bytes, and is never persisted. It is added as
dead code: nothing calls it yet, and the catalog scanner does not need it because it
reads only filesystem facts. The thumbnail and media-metadata pipelines will call it
at their byte-read boundary and skip or defer dataless files.

## Interfaces, Ownership, And Data Flow

- `Otos/Services/FileMaterialization.swift`: `nonisolated enum FileMaterialization`
  with `static func status(of: URL) -> FileMaterializationStatus`, and
  `nonisolated enum FileMaterializationStatus { materialized, dataless, unknown }`.
- No actor isolation, no shared mutable state, `Sendable` by construction.
- No persistence. The result is computed on demand and discarded by the caller.
- No live caller in this increment.

## Retirement Proof

Nothing is retired. The increment adds one file and three documentation updates. The
catalog schema, scanner, and runtime behavior are unchanged.

## Living Documentation And Comment Audit

- Added: `Otos/Services/FileMaterialization.swift`,
  `OtosTests/FileMaterializationTests.swift`, this spec.
- Updated: `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`,
  `docs/requirements.md`, `AGENTS.md`, `docs/index.md`.
- The new file carries a substantial file guide explaining the cloud hazard, the
  transient non-persisted nature, the chosen signal, and that it is not wired up.

## Instrumentation And Performance

None in this increment. The detector reads no bytes and is not on any live path. When
a future pipeline wires it in, that pipeline instruments materialization checks at its
batch boundary under `FileAccess` or `MediaIO`, not per file inside this function.

## Code-Smell Review

- Stringly typed facts: avoided by returning a typed `FileMaterializationStatus`.
- Diagnostic payload sprawl: not applicable; no logging of media content.
- Dead code: intentional and documented; tests keep it compiled and verified so it
  cannot silently rot before it is wired in.

## Acceptance Criteria

- `FileMaterialization.status(of:)` exists, reads no bytes, and returns the typed
  status; a local file is `materialized` and a missing path is `unknown` in tests.
- No code path persists materialization status.
- ADR 0008 records the detection mechanism and the media-metadata versus
  filesystem-facts distinction; `docs/requirements.md` has FND-059 and FND-060 and a
  sharpened FND-057; `AGENTS.md` names the distinction and the detector.
- `script/verify.sh` passes.

## Verification

- Local checks: `script/verify.sh` (lint, requirements-authority, build, test).
- Focused tests: `OtosTests/FileMaterializationTests.swift`.
- Dataless branch: validated by the OneDrive proof of concept recorded above; it
  cannot be unit-tested because only a File Provider creates a dataless placeholder.
- Stale-document audit: completed across ADR 0008, requirements, AGENTS.md, and the
  index.
- CI expectations: fast gate green; remote CI does not run Xcode 27 build/test.
