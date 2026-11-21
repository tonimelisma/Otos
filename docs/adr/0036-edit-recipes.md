# ADR 0036: A photo's edit is a recipe in its catalog row

- Status: Accepted
- Last updated: 2026-10-25

## Context

Owner decisions (2026-10-25): each photo has one current edit, stored in the catalog,
with no sidecars. Originals are never modified; an edit is a recipe rendered from the
original. Grid, loupe and thumbnails always show the edited photo. The edit panel is a
trailing inspector that collapses the way the sidebar does.

ADR 0035 already renders every still once into a 2560 px preview and a 256 px
thumbnail. An edit has to reach both, and has to follow the overlay lifecycle of
ADR 0008: kept while the photo exists, carried through a move, an import and Move to
Trash's undo, and purged with the row.

Measured (research 2026-10-24): developing a RAW from a `CIRAWFilter` that is already
open takes 20–180 ms per change. Opening it again for every change takes about a second.

## Decision

- **Storage: three columns on `media_asset`.** The additive migration
  `v4_media_asset_edit_recipe` adds them:
  - `edit_recipe_json`: the recipe as sorted-key JSON, NULL when the photo was never
    edited;
  - `edit_revision`: incremented by every save that changes the recipe;
  - `rendered_revision`: the revision the thumbnail and preview were rendered from.

  A recipe is the values of every control the panel offers. A control a stored recipe
  does not mention decodes as neutral, so adding a control needs no migration. Because
  the recipe lives in the row, it has the row's lifecycle with no extra mechanism. It
  moves with the row (ADR 0034), import reuse carries it to the library copy, Move to
  Trash's undo puts it back, and it is purged with the row.
- **Opening the photo.** When the panel's target resolves, the photo is opened,
  downloaded first at interactive priority if it is cloud-only, as Lightroom desktop does
  on Edit. Its facts are published: whether it is a RAW and, for a RAW, its as-shot white
  balance. The controls act only once the facts are known, and are disabled meanwhile
  with the tooltip `Preparing to edit`.
- **Light section.** Exposure applies in the RAW pipeline (`CIRAWFilter.exposure`) for
  a RAW and through `CIExposureAdjust` for any other still. Contrast applies through
  `CIColorControls`, and Shadows and negative Highlights through
  `CIHighlightShadowAdjust`, on the developed image of either. Highlights runs −100…100
  with neutral at its middle like every other tonal control: `CIHighlightShadowAdjust`
  only lowers highlights (an amount above 1 changes nothing, measured 2026-10-25), so a
  positive value lifts the upper tones through a `CIToneCurve` that leaves black, the
  shadows and white fixed. `CIRAWFilter.contrastAmount` is not used: its header
  documents it as local contrast on edges, from 0 to 1, which cannot express global
  contrast in both directions.
- **Color section** (research 2026-10-25, white balance and geometry probes):
  - White balance `temperature` and `tint` are optional; nil means as shot. A RAW holds
    absolute kelvin and tint, applied as `CIRAWFilter.neutralTemperature` and
    `neutralTint`. Its temperature slider moves evenly in mireds, 2000–50000 K, and
    snaps to 50 K. Any other still holds a relative −100…100 applied through
    `CITemperatureAndTint`, one mired and one tint unit per step; zero is stored as nil.
  - Vibrance applies through `CIVibrance`, and Saturation through `CIColorControls`.
  - The white balance picker, armed in the loupe, makes the clicked point neutral. A RAW
    asks `CIRAWFilter.neutralLocation`, which takes a point in the oriented, scaled
    output with a bottom-left origin. Any other still solves numerically for the two
    relative values that render the sampled color gray. Either way the answer is saved
    as ordinary slider values, in one undo step named `White Balance`.
  - Each section's Reset returns only its own controls to neutral, with white balance
    as shot.
- **Crop section and geometry** (research 2026-10-25, white balance and geometry probes):
  - The recipe holds clockwise quarter turns, a horizontal and a vertical flip,
    straighten in degrees clockwise (−45…45), and a crop: a rectangle in fractions of
    the straightened frame.
  - They apply last and in that order. Turns and flips act in the displayed frame, so
    turning a once-flipped photo right is a left turn under the flip, and a flip
    reverses the straighten angle. The crop turns and mirrors with the photo.
  - The frame these act on is the original's upright size as the decoder that opens the
    photo reports it (`OpenedEditPhoto`), never the catalog row's: the catalog can record
    a HEIF turned by its `irot` property at its stored, unrotated size, and a crop built
    on that has the wrong shape.
  - `EditGeometry` expresses all of it as one affine transform plus a crop.
    - Straighten rotates about the frame's center and scales by
      `cos|θ| + sin|θ| · max(W/H, H/W)`, the least that keeps the frame covered, so no
      empty corner ever shows.
    - `CIStraightenFilter` does the same visibly, but its scale is not exposed. The
      explicit transform can be inverted, which the white balance picker needs to find
      the developed pixel under a click on a turned, straightened or cropped photo.
  - Auto straighten and Auto crop are tool intents that write the same recipe fields as a
    drag: a straighten and a crop. ADR 0045 owns what they read with:
    - Auto straighten: the camera's gravity reading, else a confident GeoCalib roll.
    - Auto crop: FocalNet's crop of the frame as saved.

    Both set their field outright rather than adding to it. A level reading levels the upright,
    unflipped photo, so it is negated when the recipe flips the photo once. Nothing is stored
    but the straighten or crop it produced.
  - The straighten line's turn is pure geometry on the canvas (`StraightenLine`).
  - A crop is developed from a frame large enough for the crop itself to reach the
    requested size: the RAW scale factor or the decode size is divided by the crop's
    share of the frame's long edge. A cropped preview therefore stays 2560 px, and the
    loupe's 100% means native pixels of the edited photo (the pane's native size
    passes through the geometry).
  - The crop tool is a mode of the loupe. It shows the photo edited with everything but
    its crop, with the crop drawn over it. Dragging the crop renders nothing, because
    the frame under it does not change; letting go saves it as one `Crop` undo step.
  - The aspect choice is tool state, not part of the edit: Original, Custom (free),
    1 × 1, 4 × 5, 5 × 7, 2 × 3, 4 × 3 and 16 × 9, with Rotate Aspect.
- **Effects, Detail and Optics** (probes 2026-10-25, `CIVignetteEffect` and `CIRAWFilter`):
  - **Vignette.** Amount −100…100, with negative darkening as in Lightroom.
    `CIVignetteEffect`'s positive intensity darkens: at intensity 1 a mid-gray corner
    measured 0.007. Midpoint and Feather run 0…100 with a default of 50. It applies to
    the edited photo after its crop, as an ellipse fitted to the frame: the photo is
    scaled to a square, vignetted, and scaled back.
  - **Sharpening and Noise Reduction** apply to every still.
    - For a RAW they are `CIRAWFilter.sharpnessAmount` and
      `luminanceNoiseReductionAmount`.
    - For any other still they are `CISharpenLuminance` and `CINoiseReduction` (its own
      sharpening off).
    - Nil means the default: the RAW decoder's own amount (on one Sony ARW under RAW9:
      sharpness 1.0, luminance noise 0.33), or none for any other still. That default is
      read when the photo opens and set back explicitly on the open filter, as white
      balance is.
  - **Color Noise, Detail and Moiré** are offered only where the decoder supports them,
    which is RAW8. RAW9 reports them unsupported.
  - **Optics** is `CIRAWFilter.isLensCorrectionEnabled`, shown only for a RAW with a lens
    profile, with nil meaning the decoder's default (on).
  - A section or control a photo cannot use is left out for that photo.
- **Video trim.**
  - A video's recipe holds `trimStart` and `trimEnd` in seconds; nil is the video's own
    start or end.
  - Photo ▸ Trim Video… (⌘T, QuickTime's key; Otos styles no text, so the standard Show
    Fonts has no use) shows `AVPlayerView`'s own trim UI on the loupe video.
  - On Trim, the range it leaves on the player item's `reversePlaybackEndTime` and
    `forwardPlaybackEndTime` is saved as one `Trim` step. This is where AVKit's trimming
    reports it (WWDC 2013, "Moving to AVKit"); the header leaves it unstated. A prepared
    video plays only its trimmed range, and undo and redo move the player's range with
    the recipe.
  - A video's thumbnail and poster do not carry its trim. Saving a video's recipe
    therefore marks its products current in the same transaction, so nothing renders,
    and no launch reconciliation downloads it again.
- **One renderer for live edits.** `LiveEditRenderer` is an actor on its own serial
  queue. It keeps the photo being edited open between renders, along with a
  `CIContext` that caches intermediates. While a control is dragged it renders the
  draft at preview size. When a drag ends, a keyboard step is taken or Reset is
  pressed, the window's edit session (`EditSession`) saves the recipe, and the same renderer renders the saved
  recipe's preview and thumbnail.
- **Products are promoted only for the current save.** `applyRenderedEditProducts`
  promotes the staged files only while the row's `edit_revision` is still the one they
  were rendered from. It also requires the row's size and mtime to still match those
  recorded when the recipe was saved. A superseded or mismatched render is discarded.
  Enrichment's results carry the edit revision they rendered, and are refused under
  the same rule.
- **Enrichment is the fallback renderer.** Enrichment renders every still with its
  current recipe. When the edit panel cannot render a save (the download fails or the
  original is unreadable), and at every launch, the enrichment stamps of photos whose
  `rendered_revision` lags their `edit_revision` are cleared, so enrichment claims them
  again.
- **The pane never steps back.** A live render stays on screen until the pane's stored
  preview carries the save (`PanePreview.renderedRevision`). The grid tile's image key
  includes `rendered_revision`, so the edited thumbnail replaces the painted one
  (APP-015).
- **Undo.** Each save registers its exact inverse on the window's one undo manager,
  named for the control (`Undo Exposure`, `Undo Reset Light`). Undo and redo travel
  the same ordered save lane as the user's own saves.

- **Show Original and Revert to Original.** Show Original renders the open photo with the
  neutral recipe on the live lane, as a render of its own purpose, and shows it in the
  loupe until the edit changes or the photo or mode does; it never saves. Revert to
  Original saves the neutral recipe as one undo step through the same lane as every
  edit, so it is undone like any other; for a video it clears the trim. Both are one
  intent each behind a menu item, a key and a panel control.
- **The keyboard's selected adjustment.** Lightroom Classic's `,` `.` `=` `-` choose and
  step one control; each step is the same `setEditValue` a slider's keyboard step calls,
  so it saves at once as one step. The selection is panel state on the edit session, not
  part of the recipe.
- **The histogram.** It describes the edit as the live lane last rendered it for the
  target: the saved edit's render when the photo opens, then each live render of the
  draft. Show Original's render is a glance at what the edit replaced and is not counted. It is counted
  off the main actor (`EditHistogram.count`, `@concurrent`) on a 256 px reduction and
  published under its own sequence, so an open's count never replaces a newer render's.

## Consequences

- Editing needs the original's bytes locally. A cloud-only photo downloads at
  interactive priority on its first live render, and the commit costs no extra download.
- A save rewrites the photo's thumbnail and preview files (about 0.4 MB) in place of
  the old ones. Edits add no storage beyond the recipe text.
- The edit lives only in the catalog. If the catalog is lost, the edit is lost; the
  original never changed (decision 2).

## Rejected

- **A separate recipe table.** It would be one row per photo with the photo's own
  lifecycle, so it would duplicate the keying, move, import and purge mechanics that
  the asset row already has.
- **Edit history (a stack of recipes per photo).** The owner decided on one current
  edit. Undo covers the session.
- **Rendering the products on every slider change.** That would write two files per
  frame. The live render is shown from memory, and only the save is written.
- **A fresh `CIRAWFilter` per render.** About a second per change instead of tens of
  milliseconds.
- **Sidecar XMP.** The owner ruled it out (2026-10-25), and AGENTS.md forbids it.
