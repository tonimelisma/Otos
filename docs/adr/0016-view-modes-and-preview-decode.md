# ADR 0016: View Modes And Preview Decode

- Status: Accepted
- Date: 2026-07-10

## Context

Plan 0052 adds loupe and compare browser modes. Loupe needs a full-size (display
long-edge) decode of the focused original. The catalog already has a 256 px
thumbnail overlay produced by `EnrichmentCoordinator` / `MediaEnricher`
(ADR 0009), but nothing decodes originals for on-screen preview. Byte reads must
gate on `FileMaterialization.status` (ADR 0008); accidental faulting of dataless
cloud placeholders is forbidden.

## MECE Decision Scope

This ADR owns:

- Who may read original bytes for on-screen preview (loupe/compare).
- Where full-size / display-edge decode lives.
- The preview outcome model (image / downloading / unavailable).
- Rejected alternatives for preview production and storage.

This ADR references, but does not own:

- Overlay lifecycle and materialization permission (ADR 0008).
- Thumbnail enrichment storage and staleness (ADR 0009).
- Grid rendering, filmstrip parameterization, and selection model (ADR 0006;
  selection ownership on the ViewModel).
- Compare pair semantics (product requirements / plan 0052; no separate ADR
  until persistence or a second owner appears).

## Decision

**`PreviewImageLoader` is a dedicated actor and the app's only full-size decode
path.** Loupe and compare call it with a target long edge (main-display backing
scale × window long edge). It:

1. Checks `FileMaterialization.status` immediately before every byte read.
2. On `.dataless`, returns `.downloading`, requests deliberate non-blocking
   materialization (existing injectable helpers), and re-decodes on arrival.
3. Decodes images via Image I/O
   `CGImageSourceCreateThumbnailAtIndex` with
   `kCGImageSourceThumbnailMaxPixelSize` (bounded memory; embedded RAW previews
   preferred when large enough).
4. Decodes video posters via `QLThumbnailGenerator` at the same target (no
   playback in v1).
5. Coalesces per-id in-flight work and keeps a small byte-capped LRU (~256 MB)
   pinned to the focus neighborhood.

The 256 px enrichment thumbnail paints immediately in loupe; the full decode
replaces it when ready (APP-015 monotonic rule — never blank, never regress to
placeholder).

## Rejected Alternatives

| Alternative | Why rejected |
| --- | --- |
| Enrichment-side pregenerated large previews on disk | Scale machinery before measurement; doubles overlay disk; violates "measure before optimizing" |
| SwiftUI `AsyncImage` / direct `NSImage(contentsOf:)` | No dataless gate, no coalescing, main-thread decode risk |
| Extend `EnrichmentCoordinator` to also serve loupe | Mixes background whole-library enrichment with user-initiated viewing; different lifetime and cancellation |
| Decode on MainActor inside the loupe view | Violates MainActor media-I/O rule |

## Consequences

- Two deliberate byte-reading owners exist: `EnrichmentCoordinator` (background
  enrichment) and `PreviewImageLoader` (user-initiated loupe/compare). Both gate
  on `FileMaterialization`.
- Viewing a dataless original accepts its download cost (consistent with
  ADR 0008's permission for deliberate materialization).
- Pane content is identity-keyed: `PanePreview` binds a decode to its
  `MediaAssetID`, and the ViewModel's sole staleness guard is
  `expectedAsset(for: slot) == id`. Generation counters are not used. A slot
  whose expected id already matches keeps its preview across pair/focus churn;
  a mismatched or nil expectation clears that slot and re-requests.
- The filmstrip uses a horizontal `NSCollectionViewCompositionalLayout`
  configuration (plain layout, not `MediaGridAnimatedLayout`) so the outer clip
  view scrolls horizontally. Orthogonal section scrolling was rejected: an
  embedded orthogonal scroller never posts the controller's clip-view bounds
  changes, which starves scroll-driven detail queries and preheat. The animated
  subclass stays grid-only — the strip needs no insert/remove choreography.
- Same-session file-content staleness (original bytes change while a cache entry
  remains) is an accepted limitation; no stamp plumbing.
- Requirements APP-020 / APP-021 / APP-022 / APP-023 record loupe/compare entry,
  strip scroll loading, and preview decode policy.
- Instrumentation: `MediaIO` signposts + `op=preview.decode` notice logs with
  `decodeMs`, `source` (imageio / embedded / quicklook), and materialization
  outcome.
