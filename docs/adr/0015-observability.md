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
  `.debug` for detail available during `log stream` or shortly after via
  `log show`. Anything the agent must find hours later is `.notice` or above.
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
