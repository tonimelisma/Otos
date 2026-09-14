# Plan 0103 — Share, Open With, context menus, drag-out, curation undo, and loupe gestures

Opened 2026-09-13 from an ideation pass on how Otos should expose the macOS Share
sheet and "open in the default app" for the current items. The pass surveyed Apple
Photos, Finder, Preview, Lightroom Classic, Lightroom desktop, Capture One, Photo
Mechanic and digiKam against Apple's HIG, and then audited what Otos has today:
one toolbar (`Otos/ContentView.swift:82`), zero context menus on any media surface,
a File menu carrying Reveal in Finder ⇧⌘R, a Quick Look item wired to a responder
chain in which nothing adopts the Quick Look data source, and a ⌘I Get Info item
that reveals the first item in Finder under a false name
(`Otos/ViewModels/CatalogWindowViewModelSelection.swift:177-196`).

## Owner decisions (2026-09-13)

> **Share and Open hand file URLs to the system and read no bytes in Otos.** They
> belong to the ⌘C class ADR 0012 already rules on: the receiving app or the share
> preview downloads a dataless original, and that download is the user's explicit
> act, not an accidental materialization. ADR 0012 is amended to say so.

> **Every new command resolves its targets through the existing current-item
> resolver** (`mediaChoiceTargetIDs(.current)`,
> `Otos/ViewModels/CatalogWindowViewModelCuration.swift:94`): the grid acts on the
> ordered selection, the loupe on the focused asset, compare on the active pane.
> No new selection concept is introduced.

> **Menu placement rule.** The File menu carries file-level acts on the current
> items (Open, Open With, Share, Reveal in Finder). The Photo menu stays catalog
> and curation (Like, Not Rated, Dislike, Move to Trash).

> **Quick Look is removed, not fixed.** Otos's loupe is the peek; Lightroom
> Classic, Capture One and Photo Mechanic have no Quick Look and Apple Photos binds
> Space to its own single view. Space stays unbound. **Get Info is removed** until
> a read-only info overlay exists (increment G); APP-001 declines an inspector and
> a menu item named Get Info that reveals in Finder is a false claim.

> **⌘⌫ stays Move to Trash and gains a confirmation. Plain Delete does nothing.**
> Lightroom's Delete key opens a three-way dialog whose "Remove from catalog"
> branch has no meaning in Otos, where the filesystem is the only truth. The
> confirmation is what Lightroom users expect before anything leaves the library.

> **Full screen is macOS native only.** Lightroom desktop, Adobe's clean-slate
> app, uses only native full screen; Lightroom Classic's Shift-F screen modes,
> Tab panel choreography and Lights Out predate native full screen and are not
> copied. F for a full-screen preview is not built.

> **No export.** The share sheet is not an export path and no export command is
> added.

> **⌘O is reserved** for the roadmap's File ▸ Open… idea (open files *into* Otos,
> `docs/product/roadmap.md` "Temporary Opened Files"). Open in the default app
> takes ⌘E, the Lightroom Classic and Photo Mechanic "edit externally" key.

## What this plan is not

- No export, no "Copy as Image", no transcoding, no pixel pasteboard type.
- No pre-materialization before Share or Open. If a complaint proves the
  receiver's own progress UI insufficient, that is a separate decision.
- No Show in Library / Go to Folder. Reveal in Finder already answers where a
  file is; the All Media case has no demand yet.
- No F full-screen preview, no Shift-F screen modes, no Lights Out.
- No Delete Rejected / Move Disliked to Trash batch command.
- No Delete key binding.

## Increment order

**A → B → C → D → E, F (independent) → G → H.** A removes two misleading items
before a context menu would put them one right-click away. B and C share the
resolver and the ADR 0012 amendment, so B lands the resolver and C reuses it. D
renders B and C in context menus and cannot precede them. E and F touch neither.
G is the largest and touches decode paths, so it goes last while the cheap ones
land. H is a verification-and-rows increment and can land any time after A.

## Increment A — menu hygiene

**The fault.** `toggleQuickLook()` sends `togglePreviewPanel:` up a responder chain
in which nothing implements `acceptsPreviewPanelControl(_:)` or a
`QLPreviewPanelDataSource`; Space is a bound key that shows nothing.
`showInfoForSelection()` calls `activateFileViewerSelecting` on the first item;
⌘I "Get Info" is Reveal in Finder wearing the wrong title. Neither has a
requirements row; both arrived with the baseline-menus increment (`0986a50`).

**The change.** Delete both menu items (`Otos/OtosApp.swift:137-147`), both
intents, and the `QuickLookUI` import. Reveal in Finder ⇧⌘R keeps its place. The
File group becomes Reveal in Finder alone until B adds to it.

**Tests.** None to add; remove any that named the deleted intents.

**Docs.** No row exists to change. The PR states the removal and why.

## Increment B — Open in the default app, and Open With

**The change.** Three File-menu items above Reveal in Finder:

- `Open in Preview` — the title carries the live default app's display name for
  the current targets (`NSWorkspace.urlForApplication(toOpen:)`, name via
  `FileManager.displayName(atPath:)`), shortcut ⌘E. Mixed kinds (an image and a
  video) fall back to the title `Open` and open each target in its own default
  app, which is Finder's ⌘O behavior. Disabled with no target (DES-053).
- `Open With ▸` — apps from `NSWorkspace.urlsForApplications(toOpen:)`, which
  already returns the best match first; for several distinct types the submenu is
  the intersection. App icon and display name per item, a separator, then
  `Other…` (an `NSOpenPanel` on `/Applications`, applications only). Opening
  uses one `open(_:withApplicationAt:configuration:)` call for the whole target
  list. `urlsForApplications(toOpen:)` returns an empty list only when the file
  does not exist; a dataless placeholder exists, so cloud originals populate the
  menu without a byte read.
- Both items resolve targets through `mediaChoiceTargetIDs(.current)` and build
  URLs through `MediaAssetID.fileURL`; no Store round-trip, no byte read, no
  materialization request.

**Owner.** One `CatalogWindowViewModel` extension, `…OpenWith.swift`, holding
`openTargetsInDefaultApp()`, `openTargets(with appURL:)`, and a pure
`OpenWithMenuModel` (app URLs + display names + default) computed off the
MainActor when the target set changes, so the menu body never queries
LaunchServices during layout. One `OtosLog.ui.notice("op=ui.open …")` per call
carrying count and the app bundle identifier.

**Tests.** `OpenWithMenuModel`: default first; intersection for mixed types;
empty target set yields a disabled model; the title rule for mixed kinds. Open
calls go through an injectable `WorkspaceOpening` boundary so the test asserts
which URLs were handed to which app and that no `FileMaterialization` request
was made.

**Docs.** New `APP-035` (Open / Open With: menu location, ⌘E, target resolution,
multi-selection semantics, mixed-kind rule, reads no bytes). ADR 0012 gains an
"Adjacent decisions" resolution: Open, Open With and Share hand URLs to another
process under the same rule as Copy. `docs/architecture.md` where-to-change table
gains the row.

## Increment C — Share

**The change.** The share sheet from three surfaces, one resolver:

- **Toolbar.** A `ShareLink(items:)` over the target URLs at the trailing edge,
  after the zoom control, disabled when there is no target (DES-053). The
  system's own `square.and.arrow.up` glyph and `Share` title.
- **File ▸ Share…** presents `NSSharingServicePicker(items:)` anchored to the
  key window's content view, trailing edge. No keyboard shortcut; Finder, Preview
  and Photos define none and the HIG's standard-shortcut table has no Share row.
- **Context menus** (increment D) use
  `NSSharingServicePicker.standardShareMenuItem(items:)`, Apple's replacement for
  the deprecated `sharingServices(forItems:)`.

The Otos-owned path is one function, `shareableFileURLs()`, over the current
targets. The three presenters are the platform's own API shape for each surface;
this is a deliberate, recorded bend in the one-path rule, chosen over bridging an
`NSToolbar` into a SwiftUI toolbar to unify them.

**Tests.** `shareableFileURLs()` returns display-order URLs for each view mode
and an empty list with no target; no byte read, no materialization request.

**Docs.** New `APP-036` (Share: three surfaces, no shortcut, target resolution,
reads no bytes). ADR 0012 amendment shared with B.

## Increment D — context menus everywhere media is shown

**The gap.** The only `.contextMenu` in the app is on a Settings library row.
Grid tiles, filmstrip tiles, the loupe pane and both compare panes have none. The
HIG expects every main-menu act on an item to be reachable by Control-click, and
Lightroom Classic, Capture One and Photo Mechanic all put Open/Edit With, Show in
Finder and the curation acts on the thumbnail's context menu.

**The change.**

- One menu definition, `MediaItemCommands`, an ordered value listing each
  command's title, enablement and intent. It is rendered twice: as an `NSMenu`
  from `menu(for:)` on `MediaGridCollectionView` (grid and filmstrip), and as a
  SwiftUI `.contextMenu` on the loupe and compare panes. Adding a command is one
  edit.
- Order, mirroring the menu bar and showing no shortcuts (HIG): `Open in
  Preview`, `Open With ▸`, `Share…`, separator, `Reveal in Finder`, separator,
  `Like`, `Not Rated`, `Dislike`, separator, `Move to Trash`.
- Right-click on a tile outside the selection routes through `applyGridClick`
  with no modifiers first, so the clicked item becomes the sole target,
  Finder-style; right-click inside the selection keeps the selection. Right-click
  in the loupe or a compare pane targets that pane through the existing
  `.item`/`.compare` targets.
- Curation items call `submitMediaChoice(_:target:origin:)` with a new
  `MediaChoiceOrigin.contextMenu`, so the log distinguishes the surface.

**Design review C.** The L1 fact of a context menu is the clicked item's title
set; every string is a title-case verb phrase (DES-037); enablement, not
appearance, changes between states (DES-053); DES-085's VoiceOver custom actions
remain the accessibility path and the menu adds no Tab stop.

**Tests.** `MediaItemCommands` ordering and enablement per view mode and
availability; right-click outside the selection collapses selection to the hit
before the menu builds; right-click inside keeps it; the AppKit renderer and the
SwiftUI renderer produce the same title list.

**Docs.** New `APP-037` (context menus: surfaces, contents, right-click selection
rule). `APP-027` and the curation row gain the context-menu origin.

## Increment E — drag out of the grid and filmstrip

**The change.** `collectionView(_:pasteboardWriterForItemAt:)` returns the item's
file URL as an `NSURL`; the drag carries the whole selection in display order
when the dragged tile is selected, or the single tile otherwise. Files already
exist, so no `NSFilePromiseProvider`. Drop targets receive the same
`public.fileURL` list ⌘C writes, so Finder copies, Mail attaches, Messages sends.
No byte read in Otos; a dataless original is downloaded by the receiver.

**Docs.** New ADR 0028 (drag-out representation), as ADR 0012 required. New
`APP-038` row. ADR 0012's "adjacent decisions" list is updated.

**Tests.** The pasteboard writer for a selected tile yields the ordered selection;
for an unselected tile, that tile alone; the writer requests no materialization.

## Increment F — curation undo

**The gap.** `CommandGroup(replacing: .undoRedo) {}` removes Undo wholesale. A
mis-keyed X on a fifty-item selection has no ⌘Z.

**The change.** Restore the Undo group. `MediaChoiceCommand` already snapshots
the target set; it gains the prior choice per asset, read at submit time, so the
inverse command is data. One `UndoManager` owned by `CatalogWindowViewModel`
(there is exactly one window) registers the inverse after `completeMediaChoice`
applies; undo resubmits through `submitMediaChoice` with origin `.undo`, so the
stream ordering and stale-navigation rules are unchanged. Move to Trash is not
registered; Finder's Put Back is its undo (ADR 0022).

**Tests.** Like then ⌘Z restores each asset's prior choice, including a mixed
prior set; redo reapplies; undo of a command whose assets left the catalog is a
no-op that logs.

**Docs.** New `APP-039` (curation undo scope). ADR 0022 gains one sentence
stating that Trash is not on the app undo stack.

## Increment G — loupe zoom and pan, and the read-only info overlay

**The gap.** The loupe pane draws the fit-to-pane preview with no zoom, pan or
gesture recognizer of any kind; the grid already routes pinch through one
column-count intent (`Otos/Views/MediaGridZoom.swift`).

**The change.**

- The loupe image sits in an `NSScrollView` with `allowsMagnification`, wrapped
  the way the grid is bridged, so pinch and spread about the cursor, two-finger
  pan when zoomed, smart magnify, and ⌘= / ⌘− come from the platform. Range is
  fit to 100 percent, or to a floor that fills the pane for small images.
- Double-click toggles fit and 100 percent at the click point; Z does the same
  from the keyboard (Lightroom's key). Escape at any zoom returns to fit before
  it leaves the loupe.
- View ▸ Zoom In / Zoom Out keep their titles and shortcuts; the mode decides
  the target — grid column count in grid, image scale in loupe. One intent per
  mode, both behind the same menu item.
- Two-finger horizontal swipe at fit scale is left to the system; the filmstrip
  arrows already step.
- 100 percent needs the real image, not the embedded preview. The full-size
  decode is a second `PreviewImageLoader` request keyed by scale tier, behind the
  same materialize-then-recheck gate (ARC-034); the DES-086 indicator covers the
  wait. The fit preview stays painted until the full decode arrives (the no-blank
  rule applies to the loupe as it does to the grid).
- **Info overlay.** I toggles a read-only overlay over the loupe pane: file
  name, capture date, dimensions, kind and format, byte size — every value a
  `MediaTileDetail` or the enriched metadata already holds, nothing fetched for
  the overlay. Unknown values render as unknown (APP-001). Also View ▸ Show Info
  in the menu bar. This is the return of Get Info removed in A, under an honest
  name.

**Evidence.** Pinch and pan spans on the MainActor stay well under 100 ms; a
`script/profile.sh` trace of a 60 s zoom-and-pan session on a 60 MP RAW is
attached to the PR.

**Tests.** Scale clamps; double-click toggle at a point; ⌘= in loupe changes
scale and not column count; the fit preview is not blanked while the full decode
is in flight; the overlay renders unknown for missing facts.

**Docs.** New `APP-040` (loupe zoom/pan contract) and `APP-041` (info overlay).
DES rows for the overlay's level assignment and zone. `docs/architecture.md`
gains the loupe scroll bridge.

## Increment H — trash confirmation and full-screen verification

**The change.**

- Photo ▸ Move to Trash and ⌘⌫ present a confirmation before
  `moveTargetedMediaToTrash()` runs: title `Move 12 Items to Trash?`, one
  sentence stating the items go to the system Trash and can be put back, buttons
  `Move to Trash` (destructive, default) and `Cancel` (DES-036: no `OK`). The
  confirmation is the same SwiftUI `.confirmationDialog` whichever surface fired
  the command, and the intent runs only from its confirm action. Plain Delete
  stays unbound.
- Native full screen is verified at runtime: the window's green button and View ▸
  Enter Full Screen with the system shortcut. If AppKit does not supply it for the
  `Window` scene, the fix is the window's collection behavior, nothing more.

**Tests.** ⌘⌫ with a selection sets the pending-confirmation state and does not
call the coordinator; confirm calls it once; cancel clears the state.

**Docs.** `APP-027` gains the confirmation. New `APP-042` row for native full
screen once verified.

## Deferred

- Pre-materializing before Share or Open with the DES-086 indicator, if the
  receiver's own progress proves insufficient.
- Show in Library for All Media items.
- F full-screen preview of the current item.
- A Move Disliked to Trash batch command.
- Export.

## Closure

Each increment is one PR with its own DoD report. The plan is deleted when H
lands and every new `APP-*` row points at a green test.
