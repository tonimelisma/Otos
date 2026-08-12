# Plan 0084 — Docs / Architecture Alignment

## Goal

Make `docs/architecture.md`, `docs/adr/`, and `docs/product/roadmap.md`
describe the current code, not the code as of three increments ago. No product
behavior changes, no tests — just current truth, with every claim traceable to
a file that exists on disk.

Scope is **docs only** (`docs/architecture.md`, `docs/adr/*.md`,
`docs/product/roadmap.md`, plus any file guide that names a stale owner).
`docs/requirements.md` is out of scope except where a doc-to-requirement ID
reference is stale (then fix the reference, not the requirement).

## Why now

Architecture drift is the same failure mode as requirement truncation (plan 0081):
the doc a reviewer consults to decide "where to make a change" answers wrong.
Three independent drifts have accumulated:

1. **Roadmap vs reality on video playback.** `docs/product/roadmap.md:188`
   still says `Video playback in loupe — deferred; v1 is poster frame only
   (plan 0052)`. Code shipped click-to-play in `e9ece7c` (plan 0069) and
   `docs/requirements.md:119` (APP-020) now mandates `VideoPreviewLoader` +
   `AVPlayerView inline` with SF_DATALESS gate and interactive demand.
   `docs/architecture.md:33,38,58,166` correctly shows the new loader, so the
   roadmap is the stale peer. The same file still lists `Bare-key G/E/C view
   shortcuts — deferred; ⌘1/2/3 shipped` (`:189`) which is still accurate.

2. **Roadmap P0/P1/P2 sequencing vs shipped.** `docs/product/roadmap.md`
   sections `P0. Libraries And Sidebar` through `P2. Import Into User Libraries`
   list as ideas what is now shipped behavior (library add/remove in Settings,
   scan reconciliation, enrichment, loupe/compare view modes). The file's own
   header (line 1-14) says it is a "non-authoritative grab bag of ideas" that
   "never guides work" and is consulted only when the user explicitly asks
   "what else could we build". The P0/P1 ideas should be marked as shipped or
   removed — otherwise a reader cannot tell what is idea vs current truth.

3. **Architecture ownership table staleness.** `docs/architecture.md` actors
   table (lines 44-59) and "Where to make a change" (153-168) correctly show
   `VideoPreviewLoader` as `@MainActor final class` and `PreviewImageLoader` as
   `actor`, but file guides in `Otos/Services/` and `Otos/Views/` still carry
   stale file-guide headers from before the 0069/0070 moves (e.g., a header that
   says "loupe is poster-only" or "compare has no video owner"). `docs/adr/0016`
   (view modes and preview decode) says loupe is poster-only in its pre-0069
   revision and should note the 0069 amendment.

This is a "do it properly" increment, not a docs-only typo sweep. The prior
`97544fe` fix removed stale plan citations after 0080/0081 deletion but did not
fix the content drifts above. Plan 0084 finishes it.

## Root cause

Docs were updated per-increment for the files touched by that increment, but no
increment owned the cross-doc reconciliation. ADRs are superseded/rewritten per
AGENTS.md, but 0016 was not amended when 0069 added video; architecture.md was
updated for the new actors but the file guides and roadmap were not. The 400-char
requirements truncation (plan 0081) dominated review attention for two increments,
so doc drift was deprioritized.

A bandaid fix would be to delete the stale roadmap lines, or to add a disclaimer
to architecture.md, or to leave the drifts and rely on code as the oracle. This
plan forbids them: each stale claim is either updated to current truth with a
file trace, or explicitly marked as shipped with its landing commit and
requirement ID.

## Inventory

| # | File:line | Stale claim | Current truth | Fix |
| --- | --- | --- | --- | --- |
| D1 | `docs/product/roadmap.md:188` | `Video playback in loupe — deferred; v1 is poster frame only (plan 0052)` | Shipped `e9ece7c` (plan 0069), `APP-020` mandates click-to-play `VideoPreviewLoader` + `AVPlayerView` inline | Replace with `Video playback in loupe — shipped as loupe click-to-play poster→player swap (plan 0069, APP-020)` or delete the deferred line per user's prior `no` on video-playback deferral. Keep the `Bare-key G/E/C` line as-is (still deferred). |
| D2 | `docs/product/roadmap.md:97-165` | P0/P1/P2 sections list as ideas what is now shipped (library add, scan reconciliation, enrichment, loupe/compare) | `docs/requirements.md` ARC/APP/ENR rows are the current truth; roadmap header says it is non-authoritative ideas only | Add a one-line note after the `## Non-Authoritative Idea Sequence` header: "P0/P1 items through X are now shipped; see docs/requirements.md for current truth — the idea sequence below is retained for historical context only." Do not delete the P0/P1 text (it is historical context) and do not assign requirement IDs to it. |
| D3 | `docs/architecture.md` dataflow (lines 18-39) | Diagram shows `VideoPreviewLoader (@MainActor factory)` and `LoupeVideoPlayerView` correctly | Already current — verify, no change needed except to ensure the `TileContentStore` note matches `APP-015` monotonic rule | Confirm, add a one-line comment if missing: "loupe click-to-play: poster (tile store) → player (ViewModel-owned `loupeVideoState`)" |
| D4 | `Otos/Services/VideoPreviewLoader.swift` file guide + `Otos/Views/LoupeView.swift` | Header may still say "poster-only" or omit video | Current: loupe poster→player swap, compare poster-only | Update file guide to match `docs/architecture.md:166` and `APP-020` — one sentence, not a changelog. |
| D5 | `docs/adr/0016-view-modes-and-preview-decode.md` | States loupe is poster-only, no AVPlayer owner | ADR should note amendment: "Amended by plan 0069: loupe gains `VideoPreviewLoader` click-to-play; compare stays poster-only." | Amend ADR per AGENTS.md (supersede/rewrite the section, do not append increment history). Keep the decision, note the amendment. |
| D6 | `docs/product/roadmap.md:188-189` | Loupe 1:1 zoom/pan already removed by `40afed8` (`#195`) | Already fixed — verify no other roadmap/ADR still references 1:1 zoom as deferred | Confirm with `grep -r "1:1 zoom"` returns 0 hits (excluding research history). |

## Research grounding

- `docs/requirements.md:119` (APP-020) — loupe click-to-play with SF_DATALESS gate,
  `MaterializationCoordinator` interactive demand, `AVPlayerView` inline.
- `docs/architecture.md:33,38,58,166` — `VideoPreviewLoader` as `@MainActor final
  class`, `LoupeVideoPlayerView` as `NSViewRepresentable AVPlayerView`, compare
  poster-only.
- `git log --oneline` — `e9ece7c` plan 0069 landed loupe video; `40afed8` (#195)
  removed 1:1 zoom; `97544fe` removed stale plan citations but not content.
- `docs/product/roadmap.md:1-14` header — roadmap is non-authoritative idea pile,
  never guides work.
- `AGENTS.md` Documentation — `docs/architecture.md` is the one-page current-state
  code map, `docs/adr/` is one decision per ADR, `docs/requirements.md` is the
  authoritative registry. Current-state only.
- `script/requirements-authority-check.sh` and `script/check-doc-citations.sh`
  must stay green — any doc change that cites a file must cite one that exists.

## Stages

Each stage is independently mergeable and leaves `script/verify.sh` green
(docs-only increments skip build/test per AGENTS.md lightweight path — run
`script/ci-text-hygiene.sh check` and `script/requirements-authority-check.sh`).

### Stage 1 — Fix the one stale roadmap line (D1)

Smallest correct step, establishes the pattern:

- Edit `docs/product/roadmap.md:188` from `Video playback in loupe — deferred;
  v1 is poster frame only (plan 0052)` to `Video playback in loupe — shipped as
  loupe click-to-play poster→player swap (plan 0069, APP-020)` — or delete the
  line if the user's `no` on video-playback deferral is meant to keep the idea
  pile minimal. Either is correct; decide with the reviewer in the PR, do not
  leave both.
- Keep the `Bare-key G/E/C` line untouched (still deferred, `APP-019` is ⌘1/2/3).

Verification: `grep -n "deferred; v1 is poster" docs/product/roadmap.md` returns
0, `script/requirements-authority-check.sh check` clean.

### Stage 2 — Annotate P0/P1 as shipped (D2)

- Add one sentence after `## Non-Authoritative Idea Sequence`:
  > "P0/P1 items through Import Into User Libraries are now largely shipped;
  > current truth is in `docs/requirements.md` — the sequence below is retained
  > for historical context and does not guide work."

No other edits to the P0/P1 text. Do not assign requirement IDs to roadmap
items.

Verification: architecture vs roadmap header no longer conflict; a new reader
can tell idea vs current truth.

### Stage 3 — File guides + ADR 0016 (D4/D5)

- Update file guides in `VideoPreviewLoader.swift`, `LoupeView.swift`,
  `LoupeVideoPlayerView.swift` to match the architecture diagram and APP-020 —
  one sentence each, no history.
- Amend `docs/adr/0016-view-modes-and-preview-decode.md` to note the 0069
  amendment: loupe poster→player swap, compare poster-only. Do not append a
  changelog; rewrite the affected section per AGENTS.md ADR style.

Verification: `script/check-doc-citations.sh` clean, `docs/architecture.md`
actors table + file guides + ADR 0016 agree on who owns video playback.

### Stage 4 — Confirm no remaining drift

- `grep -r "1:1 zoom\|click-to-zoom\|poster frame only" docs/ 2>/dev/null`
  returns 0 hits (excluding `docs/research/` history, which is retained as
  dated research — research is allowed to be historical).
- `docs/architecture.md` dataflow + actors table matches current `Otos/Services/`
  and `Otos/ViewModels/` file list.
- `script/verify.sh` green on the docs-only path
  (`script/ci-text-hygiene.sh check` + `script/requirements-authority-check.sh`).

## Non-goals and guards

- Do not delete the P0/P1 idea text — it is historical context per the roadmap's
  non-authoritative contract. Annotate, don't erase.
- Do not touch `docs/requirements.md` rows (plan 0082 owns that).
- Do not run `swiftformat`/`swiftlint` or touch code — plan 0083 owns that.
- Do not add requirement IDs to roadmap items.
- Do not append increment history to ADRs — supersede/rewrite the section.
