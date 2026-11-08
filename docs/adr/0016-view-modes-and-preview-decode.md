# ADR 0016: View Modes And Preview Decode

- Status: Accepted
- Date: 2026-07-10

## Context

Otos has loupe and compare browser modes (APP-020, APP-021). Loupe needs a full-size (display
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
- Compare pair semantics (APP-021; no separate ADR
  until persistence or a second owner appears).
- Compare's active pane is a transient positional keyboard-command target only;
  it is not a Select/Candidate role and never owns a curation value.

## Decision

Loupe also has `VideoPreviewLoader` (`@MainActor` stateless
factory) for click-to-play inline `AVPlayerView` (`controlsStyle=.inline`) with
the same `ensureLocal` demand and re-check before the byte-backed player item
as preview decode; compare stays poster-only.

**`PreviewImageLoader` is a dedicated actor and the app's only full-size image
decode path.** Loupe and compare call it with a target long edge (main-display backing
scale × window long edge). It:

1. Asks the shared `MaterializationCoordinator` for the original
   (`ensureLocal`, interactive priority). The coordinator owns where an original's
   bytes are (`locality(of:)`: `local`, `fetchable`, `unreachable`): for an in-place
   root, its `SF_DATALESS` status; for a root that stages its originals (a camera), a
   file absent from the staging folder is fetchable, not missing (ADR 0046 §4).
   Every other byte reader that may fetch — video playback, the edit lanes, export,
   hand-off — asks the same two questions.
2. When the original is fetchable, the coordinator transfers it and the loader awaits
   it. Interactive materialization is
   *persistent*: it re-asserts the provider request every 500 ms and waits until the
   bytes arrive, which the file's vnode reports, or the request is cancelled, with no fail-fast and no deadline
   (APP-023). There is therefore no "attempt did not materialize" outcome to report —
   the loader returns the decoded image, or `.unavailable` when the file is genuinely
   absent or the request was cancelled. It then checks `FileMaterialization.status`
   again immediately before the byte read.
3. Decodes images via Image I/O
   `CGImageSourceCreateThumbnailAtIndex` with
   `kCGImageSourceThumbnailMaxPixelSize` (bounded memory; embedded RAW previews
   preferred when large enough).
4. Decodes video posters via `QLThumbnailGenerator` at the same target; loupe
   video playback after 0069 is via `VideoPreviewLoader` → `AVPlayerView` (not here).
5. Coalesces per-id in-flight work and keeps a small byte-capped LRU (~256 MB)
   pinned to the focus neighborhood.

The 256 px enrichment thumbnail paints immediately in loupe; the full decode
replaces it when ready (APP-015 monotonic rule — never blank, never regress to
placeholder).

## Rejected Alternatives

| Alternative | Why rejected |
| --- | --- |
| Enrichment-side pregenerated large previews on disk | Rejected here before measurement; reversed by ADR 0035 once 92% of the library's RAWs measured cloud-only, so opening a photo meant a download first. The loader now decodes the stored preview for every request short of full resolution |
| SwiftUI `AsyncImage` / direct `NSImage(contentsOf:)` | No dataless gate, no coalescing, main-thread decode risk |
| Extend `EnrichmentCoordinator` to also serve loupe | Mixes background whole-library enrichment with user-initiated viewing; different lifetime and cancellation |
| Decode on MainActor inside the loupe view | Violates MainActor media-I/O rule |

## Consequences

- `PreviewImageLoader` remains the sole full-size decode owner, while
  `MaterializationCoordinator` is the sole provider-transfer scheduling owner shared
  with enrichment. Both consumers recheck live `FileMaterialization` status before
  reading bytes.
- Interactive preview demand prevents new device/background transfer dispatch until
  no effective interactive waiter remains. Same-ID lower-priority work is promoted
  while queued or joined in flight without a duplicate provider request; an
  interactive join raises the in-flight entry's effective priority immediately,
  and cancellation lowers it only when that last interactive waiter leaves.
- Viewing a dataless original accepts its download cost (consistent with
  ADR 0008's permission for deliberate materialization).
- Pane content is identity-keyed: `PanePreview` binds a decode to its
  `MediaAssetID`, and the ViewModel's sole staleness guard is
  `expectedAsset(for: slot) == id`. Generation counters are not used. A slot
  whose expected id already matches keeps its preview across pair/focus churn;
  a mismatched or nil expectation clears that slot and re-requests. Each
  `PaneSlot` owns at most one `paneRequestTasks` entry at `.userInitiated`; superseded
  requests cancel after the detail fetch before enqueueing another decode. There is no
  downloading-retry task: the pane's 500 ms re-request was correct when an attempt lasted
  120 s, and became a hot loop when the fail-fast shortened attempts ~24×. The spinner is
  driven by an outstanding request, and a cancelled request deliberately does not clear it
  — its replacement already owns that slot. `PreviewImageLoader`'s per-id dedup task is
  also `.userInitiated` so decode does not inherit ambient/default QoS.
- Entering Compare activates the right position; clicking a pane activates only
  that position; strip replacement and sliding activate the arriving position;
  swapping exchanges the two asset identities while preserving the active
  position. `MediaChoice` remains attached to each asset across the swap.
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
