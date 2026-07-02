# Spec: Placeholder Media Grid And Catalog Ordering

## Change Type

Bug fix, rendering refactor, and catalog projection refactor.

## Problem Statement

The retired SwiftUI/AppKit table path could enter a permanent main-thread stall
after repeated All Media/library scope changes with approximately 23,000 rows.
Runtime samples and heap evidence located the runaway work in private table row
hosting and layout while Otos catalog publication was idle. The implemented grid
is the regression fix for that evidence.

## User-Facing Goal

Show every currently cataloged image or video asset in a responsive, six-column media
grid that remains usable while scans update and while the user repeatedly
switches between All Media and libraries.

## Current Repo State

- `CatalogStore` owns catalog truth and persists the media working set to
  SQLite.
- `CatalogProjection` owns the coalesced UI publication loop and asks Store for
  descriptor-ordered IDs.
- `CatalogWindowViewModel` assigns final state on the MainActor.
- The media browser uses `NSCollectionView`; Spec 0010 retains the failure
  evidence that justifies that boundary. The Settings table is unrelated.
- Catalog rows contain filesystem facts but no thumbnails.

## In Scope

- Keep a passive SwiftUI shell around the narrow AppKit `NSCollectionView`
  bridge.
- Render exactly six responsive square columns with filenames and video-only
  markers.
- Preserve all cataloged non-video image assets as generic tiles.
- Split structural identity order from detail values.
- Reuse Projection's ordered-ID cache only after direct identity validation.
- Coalesce imperative collection updates to one structural apply in flight.
- Preserve and extend diagnostics, tests, and runtime performance evidence.

## Out Of Scope

Real thumbnails, decoding, preview, metadata, audio support, selection, activation,
drag and drop, Finder actions, keyboard actions, zoom controls, animated updates,
manual scan, sandboxing, bookmarks, durable scan IDs, and SQLite schema changes.

## Captured Requirements

### Functional

- The media browser shows a square placeholder tile for every visible cataloged
  image or video asset.
- Each tile shows one middle-truncated filename at the top, falling back to the
  final relative-path component when the stored name is unavailable.
- A tiny `video.fill` marker and subdued system-blue background appear only when
  the content type conforms to `UTType.movie`.
- Images and all other non-video files have one neutral presentation and no
  icon. Audio has no special behavior.
- The grid has no media activation, preview, Finder, drag, or keyboard behavior.
  (Selection and ⌘C copy were added later; see spec 0031 and APP-010/APP-012.)
- A query descriptor change through sidebar scope, sort, or filter scrolls to
  the first item; same-descriptor scan updates preserve the current scroll
  position.
- Existing `Checking Library`, `Checking Libraries`, `Library Unavailable`,
  `No Available Media`, and `No Media` states remain visible when the projected
  grid is empty.

### Architecture

- Store truth remains keyed by library root and relative path.
- `CatalogStore` exposes ordered media IDs through Store-owned queries; dictionary
  iteration order has no UI meaning.
- `CatalogProjection` owns scope, availability, title, empty-state, and
  detail-refresh generation, while Store executes ordering.
- `CatalogMediaGridState` carries scope, ordered IDs, and the scalar
  detail-refresh generation. Visible values are fetched separately by ID.
- The collection bridge applies identity changes structurally and reconfigures
  existing visible items in place for detail-only changes.
- Views remain passive and do not own catalog cadence or projection work.

### Non-Functional

- Projection's coalesced publication loop is the sole catalog-to-grid cadence.
- Only one diffable structural apply may be in flight; intermediate pending
  states are replaced by the newest state.
- MainActor spans remain below 100 ms and visible cell configuration targets
  less than 5 ms.
- The implementation must provide agent-executable evidence that large-catalog
  startup settles, the main thread returns idle, and memory does not grow
  linearly while idle. Visible repeated scope switching remains the target
  regression scenario but is not delegated to the user as a DoD condition.

### Tooling And Regression

- Logger/signposts cover grid receipt, structural apply, pending replacement,
  completion, visible in-place reconfiguration, layout creation, and slow cell
  setup. Coarse JSONL Projection summaries cover
  publication cause, membership changes, and sorts.
- The deleted media table and per-item `NSHostingView` must not reappear.
- The Settings table remains unchanged.

## Alternatives

### A. SwiftUI LazyVGrid

Pros: fully SwiftUI, small bridge surface, simple declarative code.

Cons: keeps large repeated view identity and AttributeGraph work in the same
framework family implicated by the runaway table; gives less explicit control
over one-in-flight structural updates and visible-only detail refresh.

Failure mode: repeated scope changes can again retain or rebuild a large SwiftUI
view graph without bounded reusable-cell evidence.

### B. NSCollectionView With Flow Layout

Pros: mature reusable cells, bounded visible lifecycle, simpler than a custom
layout.

Cons: six equal responsive columns require manual item-size recalculation during
resizing and layout invalidation.

Failure mode: width bookkeeping drifts from inset/gap requirements or triggers
avoidable layout replacements during live resize.

### C. NSCollectionView With Compositional Layout

Pros: AppKit reuse, explicit six-item fractional groups, native diffable identity,
and no per-item SwiftUI hosts. Structural and detail updates can be separated.

Cons: introduces a narrow AppKit lifecycle and imperative update state machine.

Failure mode: unconstrained diffable applies can queue faster than AppKit can
finish unless pending state is coalesced.

### D. Custom NSView Tiling

Pros: maximum control over allocation and drawing.

Cons: manually recreates virtualization, accessibility, scrolling, reuse, and
layout behavior already provided by AppKit.

Failure mode: a bespoke renderer becomes a larger and less reliable UI system
than the product currently requires.

## Selected Approach

Use Alternative C. The captured table failure is verified evidence that the
SwiftUI-first path cannot meet current responsiveness. A narrow collection view
bridge is the smallest native boundary that supplies reusable viewport-bounded
items, explicit identity updates, and six-column fractional layout without a
custom rendering engine.

## Ownership And Data Flow

1. `CatalogStore` mutates catalog truth and emits a cheap change signal.
2. On the background cadence, or immediately for direct user query intents,
   `CatalogProjection` requests current library rows plus descriptor-ordered IDs,
   filters for availability, and publishes `CatalogWindowState`.
3. `CatalogWindowViewModel` assigns that state on the MainActor.
4. `MediaGridView` renders title/empty state and forwards grid state to the
   collection controller.
5. The collection apply gate chooses no-op, visible in-place refresh, structural
   apply, or newest-pending replacement.

## Concurrency And Cancellation

Store and Projection remain actors outside the MainActor. The ViewModel and
AppKit controller are MainActor-bound. No second timer or worker is added. The
existing projection stream and ViewModel tasks own cancellation; a diffable
apply already in AppKit is allowed to finish, after which only the newest pending
state is processed.

## Persistence Effects

None. Cached ordering is reconstructed in Projection memory after each launch
and is not stored in SQLite.

## Instrumentation And Profiling

- JSONL: coarse Projection membership/detail-change/sort summaries and actual
  run-loop stalls.
- Unified logging/signposts: collection receipt/apply/pending/reconfigure/reload
  outcomes.
- Signposts: Store snapshot, Projection publication/state build, ViewModel state
  assignment, collection layout/receipt/apply/reload, and scan boundaries.
- Runtime: `script/catalog-diagnostics.sh check`, agent-executable 1 Hz process
  RSS/CPU capture, unified logs, and a main-thread sample if any stall appears.

## Tests And Acceptance

- Projection tests prove first sort, direct cache validation, detail
  rematerialization, insertion/deletion/same-count replacement ordering,
  filtering, unknown/unavailable hiding, orphan fallback ordering, and scoped
  value-map isolation.
- Collection state-machine tests prove one in-flight apply, newest pending,
  detail refresh classification, descriptor reset, and same-descriptor
  preservation.
- Content-type tests prove movies are marked while image, audio, unknown, DOCX,
  and source files remain generic.
- Source hygiene proves the AppKit collection/compositional layout exists and
  the media table/`NSHostingView` path does not.
- Automated state-machine tests prove repeated scope inputs are coalesced and
  structural applies cannot overlap. Agent-executable large-catalog startup and
  idle evidence must show bounded memory and an idle main thread.

## Code-Smell Review

- AppKit bridge sprawl: constrained to one controller, one apply gate, and one
  reusable tile implementation.
- MainActor gravity: unavoidable AppKit lifecycle only; sorting/filtering remain
  in Projection.
- State duplication: ordered IDs and the scalar detail-refresh generation answer
  different structural and invalidation questions; visible values are fetched by
  ID and the Store remains sole truth owner.
- Cache validation: direct count and identity membership checks rebuild order on
  every membership mismatch without Store-side invalidation bookkeeping.

## Non-Authoritative Future Ideas

- User-controlled grid zoom.
- User-controlled browser filters beyond scan-time eligibility (for example
  curation or metadata filters).

These are not current requirements and this increment adds no hooks or fields
for them.

## User Verification

User-operated verification is not a DoD condition. Agent-controlled build,
runtime, process, log, diagnostic, and profiling evidence owns increment
verification; any later user-reported failure becomes requirement input for a
new bug-fix increment.

## Verification Outcome

- `script/verify.sh` passed with Xcode 27.0 beta (27A5194q).
- Agent-owned build/start proof passed through
  `script/build_and_run.sh --verify`.
- `build/GridVerification/20260621-agent-owned` contains a 90-sample 1 Hz
  RSS/CPU capture, JSONL diagnostics, diagnostics summary, build/run log, and
  two-second end-state process sample for a catalog of about 24,500 assets.
- RSS varied during launch and scan work, peaked at 207,152 KB, then dropped and
  held at 187,280-187,296 KB for the final ten samples. It did not reproduce the
  previous linear multi-gigabyte growth.
- The end-state sample reported 113.6 MB physical footprint, 159.5 MB peak, and
  found the main thread idle in the event loop for 1,584 of 1,585 samples. No
  `NSTableView`, table hosting, or AttributeGraph runaway stack remained.
- Otos-owned MainActor spans stayed below 100 ms: the maximum structural grid
  apply was 94 ms and maximum window-state assignment was 21 ms. No individual
  cell configuration crossed the 5 ms slow-cell threshold. Spec 0024 later
  removed the explicit visible reload path and uses in-place reconfiguration
  after enrichment made reload reuse visibly blank thumbnails.
- Two startup run-loop delays of 202 ms and 111 ms occurred while initial scans
  and collection updates were active. The process settled afterward; this
  bounded startup jank remains a profiling risk rather than the former permanent
  hang/OOM behavior.
- As supplemental, non-gating evidence, the user reported that visible scope
  switching did not appear to hang.
