# Otos Requirements

This is the requirements registry for current Otos behavior and process. Every
non-micro behavior change, bug fix, feature, or refactor must add or update
requirement rows and map them to verification evidence.

Statuses:

- `Current`: implemented current behavior.
- `Proposed`: accepted direction, not implemented yet.
- `Changed`: intentionally changed in the current increment.
- `Retired`: no longer a requirement.

Evidence should name concrete commands, tests, logs, traces, or manual proof.
Avoid vague evidence such as "checked manually" without the exact step.

## Foundation And Workflow

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| FND-001 | The repository shall preserve a blank-slate architecture with no compatibility shims, legacy Otos Studio architecture, or effort-based compromises. | Given a PR changes architecture, the spec lists alternatives and any retired paths; the PR confirms no shim or legacy path was introduced. | Current | `AGENTS.md`, PR checklist, `script/dod-report.sh` |
| FND-002 | Non-micro increments shall start from a decision-complete spec and required ADRs before implementation. | Given a feature touches persistence, media I/O, rendering, catalog, or reusable boundaries, the PR links a spec and any required ADR. | Current | `docs/templates/spec-template.md`, `docs/templates/adr-template.md`, PR checklist |
| FND-003 | Requirements shall map observable behavior to acceptance examples and verification evidence. | Given behavior changes, this registry has an updated row with concrete evidence before the PR is ready. | Current | `docs/requirements.md`, PR checklist |
| FND-004 | Remote CI shall provide a useful fast gate and shall not require unavailable Xcode 27 hosted runners. | Given CI runs on a PR, it performs checkout, YAML, text hygiene, script inventory, and macOS lint checks without selecting Xcode 27 or running Xcode build/test. | Current | `.github/workflows/ci.yml`, `script/ci-text-hygiene.sh` |
| FND-005 | Xcode 27 build and test verification shall be supplied as local PR evidence until a real Xcode 27 runner exists. | Given a PR is ready, it includes local `script/verify.sh` output summary and Xcode version. | Current | PR checklist, `script/verify.sh` |
| FND-006 | Performance-sensitive work shall produce repo-tooling evidence for jank or responsiveness impact. | Given a PR changes MainActor, SwiftUI, rendering, media I/O, or concurrency-sensitive paths, it lists `script/logs.sh` or `script/profile.sh` artifact paths and summarizes worst spans or blockers. | Current | `docs/process/performance.md`, PR checklist |

## Media And Privacy

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| MED-001 | User originals shall remain read-only unless a future spec explicitly changes that rule. | Given a feature reads media roots, it does not delete, modify, rewrite, or move originals without an approved spec and ADR. | Current | `AGENTS.md`, PR checklist |
| MED-002 | The app shall not fabricate user-visible or domain facts. | Given a date, path, provider state, progress value, count, or capability is unknown, the UI/domain model keeps it unknown or explicitly qualified instead of inventing a placeholder fact. | Current | `AGENTS.md`, feature tests once behavior exists |
| MED-003 | Logs shall not expose raw filenames, absolute paths, thumbnails, EXIF payloads, or user-authored metadata by default. | Given instrumentation is added, log payloads use opaque identifiers, categories, counts, durations, and privacy-safe outcomes. | Current | `Otos/Support/Instrumentation.swift`, PR checklist |

## Product Roadmap

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| PROD-001 | The first product roadmap shall be the canonical source for accepted browsing, enrichment, curation, temporary-open, and import priority. | Given an implementation spec starts for a product slice, it links the matching roadmap phase and requirement IDs. | Proposed | `docs/product/roadmap.md` |

## Source And Catalog

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| SRC-001 | Otos shall be a single-window app for the initial product roadmap. | Given a source, view, or temporary-open feature is specified, it does not introduce multi-window behavior. | Proposed | `docs/product/roadmap.md` |
| SRC-002 | Libraries shall be recursive user-selected folder roots managed only in Libraries Settings. | Given the user wants to add or remove libraries, the flow begins in Libraries Settings, and the sidebar remains navigation-only. | Proposed | `docs/product/roadmap.md` |
| SRC-003 | Library roots shall reject duplicates and prevent overlapping roots. | Given the user tries to add a duplicate or nested overlapping root, Otos does not add it and shows a clear error. | Proposed | `docs/product/roadmap.md` |
| SRC-004 | Library scans shall skip packages and shall not follow symlinks or aliases. | Given a library contains packages, symlinks, or aliases, recursive scanning does not traverse through them. | Proposed | `docs/product/roadmap.md` |
| CAT-001 | `All Media` shall aggregate persisted library roots only. | Given the sidebar shows `All Media`, it contains media from added libraries and excludes temporary opened files. | Proposed | `docs/product/roadmap.md` |
| CAT-002 | Removing a library shall delete Otos records and enrichments for that library while leaving originals untouched. | Given the user confirms library removal, the library disappears from Otos and its catalog records are deleted; original files are not modified. | Proposed | `docs/product/roadmap.md` |

## Filesystem Scan And Reconciliation

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| SCN-001 | First scan shall persist library roots and filesystem-only records. | Given a new library is added, Otos records source-relative identity, file classification, type identifier, size/allocation, filesystem dates, and file resource identifier when available. | Proposed | `docs/product/roadmap.md` |
| SCN-002 | First scan shall not read media-content facts. | Given first scan runs, it does not read dimensions, duration, EXIF/IPTC, embedded capture date, thumbnails, or checksums. | Proposed | `docs/product/roadmap.md` |
| SCN-003 | Scan results shall stream to UI-visible state in coalesced batches. | Given a large library is scanning, placeholder records appear without per-file UI churn or main-thread filesystem work. | Proposed | `docs/product/roadmap.md` |
| REC-001 | Otos shall render persisted records immediately on launch before background reconciliation completes. | Given the app launches with existing library records, the user can browse known records while reconciliation runs. | Proposed | `docs/product/roadmap.md` |
| REC-002 | Reconciliation shall remove records for files no longer present. | Given reconciliation finds a previously recorded file is gone, the Otos media record is removed. | Proposed | `docs/product/roadmap.md` |
| REC-003 | Changed cheap filesystem facts shall invalidate all derived facts. | Given reconciliation finds a file changed, metadata, thumbnails, checksums, and future derived facts are marked stale for lazy update. | Proposed | `docs/product/roadmap.md` |
| REC-004 | Running-app filesystem changes shall use file-level events where available with affected-root recursive fallback. | Given macOS reports changed paths precisely, Otos reconciles those paths; given event precision is lost, Otos reconciles the affected root. | Proposed | `docs/product/roadmap.md` |

## Browsing UI

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| UI-001 | Empty state shall offer Add Library and open Libraries Settings. | Given no libraries exist, the main window gives the user a route to Libraries Settings rather than directly mutating library state. | Proposed | `docs/product/roadmap.md` |
| UI-002 | The sidebar shall be navigation-only for `All Media`, libraries, and later temporary opened files. | Given the user views the sidebar, add/remove library controls are not presented there. | Proposed | `docs/product/roadmap.md` |
| UI-003 | Grid shall show placeholder tiles before thumbnails exist. | Given filesystem records exist but thumbnails are not generated, Grid still displays placeholder media tiles. | Proposed | `docs/product/roadmap.md` |
| UI-004 | Grid and film-strip tile details shall show filename, best-known date, and media kind without early path display. | Given a tile renders, it may show a filename and basic facts, but it does not require full or relative path display. | Proposed | `docs/product/roadmap.md` |
| UI-005 | Default Grid sort shall start as newest-first filesystem date and later use best-known date. | Given metadata enrichment discovers better dates, ordering can be updated in coalesced batches while preserving current choice state. | Proposed | `docs/product/roadmap.md` |

## Enrichment And Rendering

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| ENR-001 | Apple-common media shall be in scope, with RAW and Live Photos first-class. | Given RAW media or a known Live Photo pair is discovered, Otos treats it as supported roadmap media rather than an exception. | Proposed | `docs/product/roadmap.md` |
| ENR-002 | Live Photos shall become a single media item when pairing is known. | Given paired still and motion components are recognized, the user sees one media item. | Proposed | `docs/product/roadmap.md` |
| ENR-003 | Sidecars shall be acknowledged as later work and excluded from first discovery behavior. | Given a sidecar file exists, the first discovery requirements do not promise parsing or pairing behavior. | Proposed | `docs/product/roadmap.md` |
| ENR-004 | Metadata enrichment shall be read-only and broad EXIF/IPTC, including GPS/location when present. | Given metadata enrichment runs, Otos persists read-only metadata facts and does not write originals or sidecars. | Proposed | `docs/product/roadmap.md` |
| ENR-005 | Unknown metadata shall remain explicitly unknown. | Given a metadata fact is missing, Otos does not fabricate a user-visible value. | Proposed | `docs/product/roadmap.md` |
| THM-001 | Thumbnail enrichment shall generate the shared thumbnail representation used by Grid and film strip. | Given thumbnails are generated, the same concept serves dense browsing surfaces without a separate display-preview tier. | Proposed | `docs/product/roadmap.md` |
| VIEW-001 | Image view shall show a film strip with one main media item loaded from the original asynchronously. | Given Image view opens, it can show a placeholder until the original media is ready. | Proposed | `docs/product/roadmap.md` |
| VIEW-002 | Compare view shall show a film strip with two chosen media items loaded from originals asynchronously. | Given Compare view opens with two media items, it can show placeholders until originals are ready. | Proposed | `docs/product/roadmap.md` |
| PERF-001 | High-volume scan, reconciliation, Grid, and film-strip updates shall be performance-sensitive. | Given a spec changes these paths, it includes instrumentation and jank evidence requirements. | Proposed | `docs/product/roadmap.md`, `docs/process/performance.md` |
| PERF-002 | Original-media loading for Image and Compare shall be performance-sensitive. | Given a spec implements these views, it instruments original-media loading and rendering. | Proposed | `docs/product/roadmap.md`, `docs/process/performance.md` |

## Curation And Filters

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| CUR-001 | Pick/Reject/Unpick shall come after Grid, Image, and Compare and persist in the Otos catalog. | Given curation is implemented, rejected media remains visible unless a filter hides it. | Proposed | `docs/product/roadmap.md` |
| FIL-001 | Filters shall come after curation and start with curation-state filtering in a toolbar control. | Given filters are first implemented, the user can filter by Pick/Reject/Unpick state from the toolbar. | Proposed | `docs/product/roadmap.md` |

## Temporary Opened Files And Import

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| OPEN-001 | File > Open, Finder open, and drag/drop shall share one temporary open path for one or more files. | Given the user opens arbitrary files, they appear in an ephemeral `Opened Files` sidebar source and are excluded from `All Media`. | Proposed | `docs/product/roadmap.md` |
| IMP-001 | Import shall be supported only into user-configured library directories from another folder or Otos library. | Given import is specified, it supports copy or move into a user library and does not introduce a private app-owned media destination. | Proposed | `docs/product/roadmap.md` |

## Future Rows

Add feature rows here before or with the implementing PR. Prefer requirement IDs
that group naturally by area, for example `CAT-*` for catalog, `REN-*` for
rendering, `THM-*` for thumbnails, and `UI-*` for user-interface behavior.
