# Code Review

This document defines how Otos changes are reviewed. It applies to human review,
agent self-review before opening a PR, and any automated review pass. The goal is
to protect a small, correct foundation as it grows into the genuinely hard parts of
a photo library tool, the media pipeline and any future edit model, without letting
the architecture rot or accreting complexity the evidence does not justify.

Sources this review philosophy draws on:

- [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- [Swift 6.2 default actor isolation](https://www.avanderlee.com/concurrency/default-actor-isolation-in-swift-6-2/)
- [Image I/O downsampling and thumbnailing](https://www.swiftjectivec.com/optimizing-images/)
- [SwiftUI versus AppKit performance for large collections](https://digitalblake.com/2026/04/28/swiftui-vs-appkit-macos-ui-performance/)
- [Apple File Provider and dataless files](https://eclecticlight.co/2026/05/09/explainer-file-provider-and-cloud-services/)
- [Martin Fowler: Code Smell](https://martinfowler.com/bliki/CodeSmell.html)
- [Google Testing Blog: Test behavior, not implementation](https://testing.googleblog.com/2013/08/testing-on-toilet-test-behavior-not.html)

## Reviewing Lens

Hold every change against these, in priority order:

1. Ownership is the product. Every fact has one owner; every user action has one
   implementation path. Most defects in a tool like this are ownership defects, two
   things that can answer the same domain question, not algorithm defects.
2. The filesystem is the source of truth. The catalog and all overlay are a
   subordinate, rebuildable projection. Originals are read-only, Otos never writes
   into the user's media folders, and overlay follows the single lifecycle in
   `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`.
3. Simplest correct, measure before optimizing. Follow Rob Pike's 5 Rules
   (canonical statement in `AGENTS.md`). Do not demand or add scale machinery
   without measured evidence; do require that any new complexity removes current
   complexity or answers a verified need.
4. Never fabricate domain facts. Unknown dates, counts, paths, and capabilities
   stay unknown or explicitly qualified.
5. The media pipeline is the app's heartbeat. Thumbnail and metadata work and image
   decode get the strictest concurrency, materialization, and instrumentation
   scrutiny when they land.

## Review Rubric

For each domain: what the reviewer checks, and the standard it is held to.

### Architecture and ownership

- The `CatalogStore` to `CatalogProjection` to `CatalogWindowViewModel` to passive
  `View` boundary stays intact. Views do not call SQLite, subscribe to snapshot
  streams, sort, filter, or orchestrate scans.
- No new duplicate source of truth: no second field, cache, or projection that can
  disagree with an existing one.
- A new abstraction (protocol, cache, layer, pipeline) removes current complexity
  or answers a verified need; speculative flexibility is rejected.
- One user action routes through one owner intent across button, menu, shortcut,
  and test.

### Filesystem, originals, and overlay

- Originals are never written, moved, or deleted by Otos except through an explicit,
  opt-in, user-initiated action with an approved spec.
- Overlay follows ADR 0008: held while the item exists, purged in full only on
  proven deletion (absent from a reachable, fully enumerated root), never on
  temporary absence (ejected drive, offline volume, unreachable root, dataless
  cloud placeholder, user-excluded subtree).
- Asset identity stays the filesystem path. No durable identifiers, content
  fingerprints, generated UUIDs, or sidecars are introduced.
- Cloud safety: no code path force-materializes a dataless file for cataloging,
  thumbnailing, or metadata; byte access is deferred to user-visible, off-main work.
- Scans stay read-only, idempotent reconciliation with no durable scan identity or
  history.

### Concurrency and data-race safety

- No scanning, metadata read, image decode, thumbnail generation, database work,
  filesystem traversal, or export runs on the MainActor.
- Every long-running task has an owner, a cancellation path, and stale-completion
  rejection. Ownership is revalidated after each await, following the existing
  `ActiveScan` lease pattern.
- `.task` synchronous setup is treated as main-thread work; heavy setup is flagged.
- `Sendable` boundaries are explicit; no `@unchecked Sendable` without proof. Public
  types state their actor isolation explicitly rather than relying on target-level
  default isolation.

### Performance and responsiveness

- MainActor work stays under the 100 ms hang threshold; scroll, grid, animation,
  and pointer paths have tighter, named budgets in the spec.
- No render or scroll path synchronously decodes, scans, queries, or formats.
- Per Pike's rules: optimizations are not added on intuition. Performance-sensitive
  changes carry signpost or `script/profile.sh` and `script/logs.sh` evidence and a
  worst-span summary; "looks fine" is not evidence. Absent measured jank, the simple
  resident-list catalog model is accepted as-is.

### Media pipeline (thumbnails, decode, RAW), when it lands

- Downsample with Image I/O (`CGImageSourceCreateThumbnailAtIndex`), honoring EXIF
  orientation and decoding off the main thread; never decode full images to resize.
- Prefer embedded previews where present; prioritize visible and selected media,
  then backfill, with bounded in-flight work and viewport cancellation.
- Thumbnails are durable backed-up overlay with the ADR 0008 lifecycle, not an
  evictable cache. Generation differs by media type and never force-materializes
  dataless cloud files.

### SwiftUI and AppKit boundary

- AppKit is used only where SwiftUI cannot meet a capability or measured
  responsiveness bar, with the SwiftUI option and the evidence named.
- AppKit bridges stay narrow: viewport, reuse, and layout only, never domain state
  or workflow. Telemetry on hot paths uses signposts, not per-update JSONL tasks.
- Native desktop structure (sidebar, detail, inspector, toolbar, commands, Settings
  scene); no iOS push navigation; one main window; no light-only colors.

### Instrumentation

- Every meaningful path is observable to the submodule level: category and
  operation name, start and end signposts, result count or size when safe,
  cancellation status, and error outcome without private payloads.
- High-frequency UI paths use Logger and signposts; durable JSONL is reserved for
  coarse boundaries and real stalls. New subsystems light up their log category.

### Testing

- Tests derive from requirements and acceptance examples and assert behavior at the
  narrowest owner boundary, not implementation details.
- Concurrency is tested deterministically with injected clocks, expectations, or
  suspension hooks; no fixed `sleep`. Persistence has migration, unknown-schema,
  preservation, and failure-mode tests.
- `SourceHygieneTests` grep-based invariants are a tripwire, not the proof: each
  architectural invariant they guard also has at least one behavioral test.

### Documentation and process

- The spec is decision-complete before implementation, with at least three
  alternatives, the simplest-correct choice justified, and ownership, concurrency,
  cancellation, instrumentation, and tests named. Required ADRs exist.
- Living docs: every affected ADR, spec, requirement, and comment is updated in the
  same increment; stale claims are deleted. Requirements stay current-state only;
  futures are conditional architecture in ADRs, never TBD feature lists.
- Code smells are reported every PR, including `None observed` after actually
  looking.

## Severity And Merge Gate

| Severity | Definition | Action |
| --- | --- | --- |
| Blocker | Originals at write-risk; data race or unsafe `Sendable`; new duplicate source of truth; MainActor doing IO, decode, or DB; overlay purged on temporary absence or force-materialized dataless read; persistence or schema change with no ADR; fabricated domain fact; missing spec for non-micro work. | Cannot merge. |
| Major | Ownership leak (view orchestrating catalog, bridge owning domain state); perf-sensitive path with no evidence; unbounded or uncancellable task; an architectural invariant guarded only by a grep test. | Fix before merge, or an ADR'd, recorded exception. |
| Minor | Naming or units clarity, comment accuracy, test at the wrong altitude, missing log-category usage. | Fix, or file a tracked follow-up. |
| Nit | Style within lint rules. | Optional. |

The merge gate is the Definition of Done in `AGENTS.md`: local `script/verify.sh`
green on Xcode 27, the CI fast gate green, spec, ADR, and requirements updated in
the same increment, instrumentation present, the code-smell section filled, and the
originals and diagnostics review done. The reviewer's job is to confirm these are
real, not checked-off.
