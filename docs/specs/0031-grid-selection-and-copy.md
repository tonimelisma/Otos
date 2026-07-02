# Spec: Grid Selection And Copy To Clipboard

## Classification

- Work type: Feature
- Current requirement IDs: APP-010, APP-011, APP-012, APP-006, APP-009,
  FND-031, FND-044, MED-004
- Future idea or candidate links explicitly requested by the user: none
- ADRs: `docs/adr/0012-media-asset-clipboard-representation.md`

## Problem

Before this selection/copy increment, Otos showed a browsable six-column grid of
cataloged images and videos, but the grid was inert: the user could not select a
tile and could not get an asset out of Otos into another app. The implemented
goal is standard macOS tile selection (click, ⌘ toggles, ⇧ range) plus ⌘C file-URL
copy so selected media can be pasted or attached elsewhere — Messages, Mail,
Finder.

Before implementation, repo inspection found:

- `Otos/Views/MediaAssetCollectionView.swift` is the single AppKit boundary. It
  sets `collectionView.isSelectable = false` and installs no delegate, so there
  is no selection, click handling, or copy path. It owns the diffable data
  source, a newest-value apply gate (`MediaAssetCollectionApplyGate`), viewport
  reporting, and visible-detail faulting through `MediaTileDetailReader`.
- `Otos/Views/MediaAssetTileView.swift` draws one reusable tile. `NSCollectionViewItem`
  already receives `isSelected` from the collection view; nothing reads it, so no
  highlight is drawn. Selection appearance would live here.
- `Otos/Models/CatalogModels.swift` defines `MediaAssetID` as
  `LibraryRootPath` + `MediaRelativePath`. That pair is already the full natural
  filesystem identity, so an asset's absolute URL is derivable from the ID alone
  with no Store round-trip.
- `Otos/Services/EnrichmentCoordinator.swift:274` already builds that URL:
  `id.libraryRootPath.url.appending(path: id.relativePath.rawValue, directoryHint: .notDirectory)`.
  This is the only asset→URL construction in the app; the copy path must reuse it,
  not fork a second one.
- The app is unsandboxed (`ENABLE_APP_SANDBOX = NO`; no entitlements file, no
  security-scoped bookmarks anywhere in app code). A plain file URL written to the
  pasteboard is directly readable by the receiving app, with no bookmark flow.
- `APP-010` in `docs/requirements.md` stated the grid "shall have no
  media selection or activation behavior" and that "clicks, double-clicks,
  previews, Finder actions, drags, and keyboard media actions are absent." This
  feature intentionally changes the selection half of that requirement while
  preserving the grid's descriptor-change scroll-reset behavior.
- `OtosApp.swift` on `main` adds only `CommandGroup(replacing: .newItem) {}`. The
  standard SwiftUI **Edit ▸ Copy** menu item (⌘C) is present by default and routes
  the `copy:` action down the responder chain to the first responder.

## Scope

In scope:

- Single-selection by click, multi-selection by ⌘-click (toggle) and ⇧-click
  (range), and Select All (⌘A) in the media grid.
- A visible selection highlight on selected tiles.
- Selection that is tracked by stable `MediaAssetID` identity and reconciled to
  the collection view after every structural apply, so a background enrichment or
  scan update in the same scope does not lose or shift the selection.
- ⌘C / Edit ▸ Copy writing one original **file URL per selected asset**, in
  display order, to `NSPasteboard.general`, so the selection can be pasted into
  Finder or attached in Messages and Mail.
- Menu-item validation so Edit ▸ Copy is disabled when nothing is selected.
- Consolidating asset→URL construction into one owner
  (`MediaAssetID.fileURL`) reused by both the copy path and
  `EnrichmentCoordinator`.

Out of scope:

- Pixel/image-data representation on the pasteboard (the representation that lets
  an image paste into a browser `contenteditable`). Deferred and additive; see
  ADR 0012.
- A separate "Copy as Image" command, drag-and-drop out of the grid, double-click
  activation, Quick Look, "Reveal in Finder", context menus, and any command that
  writes to or moves the user's files.
- A toolbar Copy button, a selection count UI, or surfacing selection to
  `CatalogWindowViewModel` / SwiftUI. Selection stays ephemeral AppKit state until
  a real second consumer exists.
- Any persistence of selection.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance is restated as precise requirements for user
      verification.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas and unimplemented requirement candidates are separated from
      `docs/requirements.md`.
- [x] Roadmap, planning, or idea documents are ignored unless explicitly
      requested.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed.
- [x] At least three alternatives are compared.
- [x] Refactor retirement proof is defined (APP-010 change; `url(for:)`
      consolidation; selection-absence test assertions).
- [x] A repository-wide stale-document audit is defined.
- [x] A code-comment accuracy audit is defined.
- [x] Performance/jank evidence is defined.
- [x] Open questions are answered or out of scope.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| SEL-click | Functional | Clicking a tile selects it and shows a highlight; clicking another tile replaces the selection. | Current | `docs/requirements.md` APP-010 (changed) |
| SEL-multi | Functional | ⌘-click toggles a tile in/out of the selection; ⇧-click extends a contiguous range; ⌘A selects all. | Current | `docs/requirements.md` APP-010 (changed) |
| SEL-persist | Architecture | Selection is tracked by `MediaAssetID` and survives same-descriptor structural updates; assets that disappear are dropped from the selection, and descriptor changes clear selection. | Current | `docs/requirements.md` APP-011 |
| COPY-url | Functional | ⌘C / Edit ▸ Copy copies one original file URL per selected asset, in display order, so the media can be pasted into Finder or attached in Messages/Mail. | Current | `docs/requirements.md` APP-012 |
| COPY-empty | Functional | Edit ▸ Copy is disabled when the selection is empty. | Current | `docs/requirements.md` APP-012 |
| COPY-refs | Non-functional | Copy writes file references only; it reads no image/video bytes and does not itself materialize a dataless cloud original. | Current | `docs/requirements.md` APP-012, ADR 0012 |
| COPY-noPixels | Architecture | The MVP copies file URLs, not image pixels; a pixel representation is a deferred, additive follow-up. | Current | ADR 0012 |

## Architectural Alternatives

Two orthogonal decisions: (1) what to put on the pasteboard, owned by ADR 0012 and
summarized here; (2) where selection state lives, owned by this spec.

### Alternative A — File URLs on the pasteboard, selection owned by the AppKit view controller (selected)

Selection is a `Set<MediaAssetID>` on `MediaAssetCollectionViewController`, synced
from `NSCollectionView` selection via the delegate and reconciled to the
collection view after each structural apply. ⌘C writes file URLs.

Pros:

- Copy needs only identities, which the controller already has; no Store query, no
  `MediaAsset` detail, no ViewModel round-trip.
- File URLs are tiny and lossless, work in Finder/Messages/Mail, and are the only
  representation that works for video.
- Reconciling by identity is robust against the frequent background structural
  applies the grid already performs.
- Smallest correct surface: no new SwiftUI state, no new actor, no new module.

Cons:

- A file URL does not paste as an image into a browser `contenteditable`.
- Selection is not visible to SwiftUI, so a future toolbar Copy button needs a
  follow-up to surface it.

Failure modes:

- If selection were tracked by index path instead of identity, a background apply
  could shift or drop it. Mitigated by identity tracking + post-apply reconcile.

### Alternative B — Full image pixel data on the pasteboard (Preview-style)

Copy decodes each selected image and writes `public.tiff`/`public.png`.

Pros:

- Pastes as an image into browsers and rich-text targets.

Cons:

- Uncompressed TIFF of a large photo is huge (tens to hundreds of MB); reading
  and decoding originals on copy is real byte I/O and would materialize dataless
  cloud placeholders — a direct conflict with the filesystem-source-of-truth and
  no-accidental-materialization principles.
- No sensible representation for video.
- Requires main-actor-safe decode scheduling for what is meant to be an instant
  command.

Failure modes:

- Copying a multi-GB video selection is impossible; copying many large photos
  stalls or bloats the pasteboard.

### Alternative C — Selection modeled in `CatalogWindowViewModel` (SwiftUI-owned)

Selection flows up to the ViewModel as observable state; copy is a ViewModel
intent.

Pros:

- Selection is available to SwiftUI (toolbar button, count) immediately.

Cons:

- Adds MainActor round-trips per click and a second source of truth for something
  the AppKit collection view already tracks natively; speculative flexibility with
  no current second consumer (violates the repo's "narrowest correct scope" and
  "no speculative flexibility" rules).

Failure modes:

- Selection state in two places (collection view + ViewModel) can drift.

## Selected Approach

Alternative A. Selection is ephemeral AppKit state owned by
`MediaAssetCollectionViewController`; the pasteboard carries original file URLs
(ADR 0012). This is the simplest design that satisfies every verified
requirement, reuses the one existing asset→URL construction, honors the unsandboxed
+ originals-read-only + no-accidental-materialization principles (copy never reads
bytes), and leaves the browser-image case as a clean additive follow-up rather
than a rework.

## Interfaces, Ownership, And Data Flow

- `MediaAssetID.fileURL: URL` (new, in `CatalogModels.swift`): the single
  asset→absolute-URL construction. `EnrichmentCoordinator.url(for:)` is retired in
  favor of it (one implementation path).
- `MediaGridSelection` (new, pure `enum`, `nonisolated`): testable selection
  policy —
  - `pruned(_ selected: Set<MediaAssetID>, to ordered: [MediaAssetID]) -> Set<MediaAssetID>`
  - `orderedSelection(_ selected: Set<MediaAssetID>, in ordered: [MediaAssetID]) -> [MediaAssetID]`
- `MediaGridClipboard` (new, `enum`): `write(_ ids: [MediaAssetID], to pasteboard: NSPasteboard) -> Int`
  clears the pasteboard and writes one `NSURL` file URL per id in order; returns
  the count. Pure enough to test against an isolated `NSPasteboard(name:)`.
- `MediaAssetCollectionViewController` (changed):
  - enables `isSelectable`, `allowsMultipleSelection`, `allowsEmptySelection`;
    becomes the collection view `delegate`.
  - owns `private var selectedAssetIDs: Set<MediaAssetID>`; the ordered ID list it
    already tracks via the apply gate is the display order used for pruning and
    copy order.
  - `collectionView(_:didSelectItemsAt:)` / `didDeselectItemsAt:` sync
    `selectedAssetIDs` from `collectionView.selectionIndexPaths`.
  - after `applyStructure`, prune `selectedAssetIDs` to the new ordered IDs and set
    `collectionView.selectionIndexPaths` from the survivors (programmatic
    selection does not re-enter the delegate, so no feedback loop).
  - `@objc func copy(_ sender: Any?)` writes `MediaGridClipboard.write(orderedSelection, to: .general)`.
  - `validateUserInterfaceItem(_:)` returns `!selectedAssetIDs.isEmpty` for
    `copy:`. The controller sits in the responder chain between its scroll view
    and the window, so both the action and its validation reach it; no
    `NSCollectionView` subclass and no `keyDown`/`performKeyEquivalent` override
    are added (one action path: the standard Edit ▸ Copy item).
- `MediaAssetCollectionItem.isSelected` (changed): `didSet` forwards to
  `MediaAssetTileView.setSelected(_:)`.
- `MediaAssetTileView.setSelected(_:)` (new): toggles a selection ring using
  `layer.borderWidth`/`borderColor` (`NSColor.controlAccentColor`), independent of
  the tile's `backgroundColor` tint so `configure` and reconfigure never clobber
  it; `prepareForReuse` clears the ring.

Actor isolation: everything is MainActor (the controller and views already are).
Copy is synchronous, allocation-only (building URL values), no I/O, no Task, no
cancellation surface. No `Sendable` boundary changes. Privacy: file URLs are already loggable
diagnostics in this repo; copy logs a count and the scope, not full path lists.

## Retirement Proof

- `docs/requirements.md` APP-010: rewrite from "no selection/activation" to the
  new selection behavior while preserving the descriptor-change scroll-reset clause;
  mark `Changed`. Add APP-011 (selection identity/persistence) and APP-012 (copy).
- `EnrichmentCoordinator.url(for:)`: removed; all call sites use
  `MediaAssetID.fileURL`. Grep proof that no `url(for:` remains in
  `EnrichmentCoordinator.swift`.
- Test assertions encoding APP-010's "no selection": `OtosTests/MediaAssetCollectionTests.swift`
  and `OtosTests/SourceHygieneTests.swift` are inspected; any assertion that
  `isSelectable == false` or that no delegate/selection exists is updated to the
  new behavior.
- Tile comment in `MediaAssetCollectionView.swift` stating selection is off is
  updated.

## Living Documentation And Comment Audit

- `docs/requirements.md`: APP-010 changed; APP-011, APP-012 added (see above).
- `docs/adr/0012-media-asset-clipboard-representation.md`: new ADR.
- `docs/index.md`: add ADR 0012 and spec 0031 rows.
- `docs/onboarding.md`: the grid section (~line 238–241) that describes the AppKit
  collection view gains a short note on selection ownership and the copy path.
- Code comments: `MediaAssetCollectionView.swift` file guide gains a focused
  section on selection ownership, identity reconciliation after apply, and the
  responder-chain copy path; `MediaAssetTileView.swift` documents the selection
  ring; `MediaGridSelection`/`MediaGridClipboard` get focused guides. No syntax
  narration, no increment history.
- Stale-document audit: sweep ADRs/specs/process/index/onboarding/templates/scripts
  for other claims that the grid has no selection; record findings in the DoD.

## Instrumentation And Performance

- OSLog category `UI` (existing `OtosLog.ui`) + `OtosSignpost.ui`:
  - selection change: debug log + `MediaGridSelectionChanged` event with the
    selected count.
  - copy: info log + `MediaGridCopyInvoked` event with the copied count.
- No JSONL tasks (honors FND-041): high-frequency UI telemetry stays on unified
  logging/signposts.
- Budget: selection and copy are MainActor, allocation-only, and must stay far
  below the 100 ms hang threshold; copy cost is O(selection) string building,
  independent of file size. No profiling artifact is required because no I/O,
  decode, or byte read is introduced; `script/logs.sh UI` can confirm the two new
  events fire.

## Code-Smell Review

- MainActor gravity: acceptable here — selection and pasteboard writes are
  inherently main-actor UI work, and no byte I/O or decode is placed on Main.
- State duplication: avoided by making `selectedAssetIDs` the single source of
  truth and reconciling the collection view from it, rather than keeping a second
  copy in the ViewModel.
- AppKit bridge sprawl: contained — copy lives on the existing controller via the
  standard responder chain; no new NSView/NSCollectionView subclass.
- Stringly typed domain facts: avoided by adding `MediaAssetID.fileURL` instead of
  string path math at the call site.
- Test coupling: tests target observable behavior (`MediaGridSelection` results,
  pasteboard contents) not private fields.

## Acceptance Criteria

- Clicking a tile selects exactly it and draws an accent ring; clicking a
  different tile moves the selection; clicking empty space clears it.
- ⌘-click toggles individual tiles; ⇧-click selects a contiguous range; ⌘A
  selects all currently listed assets.
- With a selection, ⌘C (and Edit ▸ Copy) places one file URL per selected asset on
  `NSPasteboard.general` in display order; pasting in Finder yields the files and
  pasting/attaching in Messages attaches them. With no selection, Edit ▸ Copy is
  disabled.
- A background enrichment/scan update in the same descriptor preserves the selection
  and its highlight; a selected asset that disappears is dropped from the selection;
  a descriptor change, including a sidebar scope, sort, or filter change, clears the
  selection and resets scroll.
- No image/video bytes are read on copy; `MediaAssetID.fileURL` is the only
  asset→URL construction.

## Verification

- Local checks: `script/verify.sh` (Xcode 27 build + full test suite + lint).
- Focused tests: `MediaGridSelectionTests` (pruned, orderedSelection, fileURL) and
  `MediaGridClipboardTests` (writes file URLs in order to an isolated
  `NSPasteboard(name:)`, returns count, clears prior contents); updated
  `MediaAssetCollectionTests` / `SourceHygieneTests` for the changed APP-010
  behavior.
- Performance/log evidence: `script/logs.sh UI` shows `MediaGridSelectionChanged`
  and `MediaGridCopyInvoked`; no new JSONL. No hitch trace required (no I/O added).
- Stale-document audit: recorded in the DoD across ADRs/specs/requirements/process/
  index/onboarding/templates/scripts/backlinks.
- Code-comment accuracy audit: recorded in the DoD for the changed AppKit boundary
  files and the two new helpers.
- CI expectations: fast remote gate (checkout sanity, YAML, hygiene, lint); Xcode
  27 build/test proof is the local `script/verify.sh` run.
