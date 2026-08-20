# ADR 0015: Observability (Unified Logging + Instruments)

- Status: Accepted
- Date: 2026-07-09

## Context

Otos previously had three overlapping diagnostic sinks: `OtosLog`/signposts,
a bespoke `CatalogDiagnostics` JSONL actor, and `GridTelemetry` scalar counters
flushed to JSONL. No human reads logs; the agent consumes unified logging, and
Instruments consumes interval signposts. The extra sinks had no consumer and
added actor-hop latency plus maintenance cost.

## Decision

**One facade (`OtosLog`), one sink (unified logging), plus interval signposts
solely as Instruments annotations.**

### Logging

- Levels: `.error`/`.fault` for failures and stalls (always persisted);
  `.notice` for operation boundaries the agent greps after a run; `.info`/
  `.debug` for detail available only live, during `log stream`. **macOS does not
  persist `.debug` (or, in practice, `.info`) for a subsystem without an explicit
  logging configuration profile** — confirmed 2026-08-03 by capturing a live
  session and finding zero `.debug` messages retrievable via
  `log show --info --debug`, even though `log show` requests both levels. A
  signal named in `docs/requirements.md` as a diagnostic contract — anything the
  agent must be able to find in a capture taken after the fact — is therefore
  emitted at `.notice` or above; `.debug` is only for chatter the agent accepts
  losing (per-frame/per-asset volume) and is willing to read solely via a live
  `log stream` session.
- Structured `op=`/`phase=` boundary lines go exclusively through
  `Logger.noticeOperation`/`errorOperation`/`debugOperation`
  (`Otos/Support/Instrumentation.swift`) — never a hand-rolled
  `.debug("op=…")`/`.info("op=…")` string. A SwiftLint custom rule
  (`structured_log_via_helper`) makes the accidental form a build error, so the
  log level of a structured line is always a deliberate choice.
- Everything is `privacy: .public` — the agent must read paths and scalars;
  this is an unsandboxed local tool on the user's machine.
- Structured convention: messages start with a stable `op=` token, then
  `key=value` pairs (e.g. `op=catalog.library.ensure phase=finish rootPath=…`).

### Signposts

Interval signposts remain only for operations an Instruments template inspects
(structural apply, zoom, scan enumerate/write/flush/reconcile, enrichment
batch write, store queries, window publication/state build/apply, filesystem
event batch). A new signpost must name the Instruments question it answers.
Bare event signposts (`emitEvent`) are rejected — no Instruments workflow
consumes them; use a log line instead.

### Agent workflows

- `script/logs.sh stream [Category]` — live capture.
- `script/logs.sh show --last <duration> [Category]` — post-hoc ndjson.
- `script/profile.sh "<Template>" <duration>` — `xctrace record`.
- `script/profile-export.sh <trace>` — `xctrace export` wrapper.

### Explicit rejections

| Rejected | Reason |
| --- | --- |
| Bespoke JSONL sinks (`CatalogDiagnostics`) | No consumer; unified logging already persists `.notice`+ |
| Bare event signposts (`emitEvent`) | No Instruments workflow points at them |
| Scalar counter snapshot machinery (`GridTelemetry`) | One unread JSONL row; hot-path counters without a reader |

## Consequences

- Smoke `--verify` asserts `op=catalog.library.ensure` via `log show`, not JSONL.
- Stall detection logs `op=mainThreadStall` at `.fault`.
- Session correlation: `op=sessionStart session=… kind=…` once at launch.
- Store query paths emit `waitMs` (pool acquisition) and `execMs` separately so
  GRDB reader-pool contention is measurable without Instruments; tile-detail
  logs those fields at `.debug` (live-stream only, not durable — see above), and
  slow queries (`queryMs > 50`) also at `.notice` (durable). See
  `docs/research/2026-07-10-grdb-reader-pool-qos.md`.
- Import naming decisions, presentation frames, enrichment-to-plan invalidation,
  and the explicit card-erase path are durable structured diagnostics. Naming
  logs identify wall-clock versus settled filesystem-mtime decisions; presentation
  logs identify the state and byte progress applied to the bar; erase logs report
  actual deleted, skipped, failed, and freed-byte totals rather than planned
  counts.
