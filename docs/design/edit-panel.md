# Edit panel

The trailing inspector where one photo is edited (DES-092, ADR 0036). It is how the
user changes what a photo looks like everywhere in Otos, without changing the original.

## L1 primary fact

Which photo the controls will change: its file name, or `No Selection` when there is no
single photo to edit.

## Placement and collapse

A SwiftUI `.inspector` on the content pane: a full-height trailing column that
collapses and expands the way the sidebar does, with a draggable width (240–360 pt,
280 by default). Three ways to show or hide it, all calling one intent:
- the toolbar's Edit button (`slider.horizontal.3`, tooltip `Show Edit` / `Hide Edit`);
- View ▸ Show Edit / Hide Edit, named for the panel without the word "panel", as Panels
  asks;
- E, Lightroom desktop's key for Edit (DES-093).

It is shown in every view mode. It edits the current target (the grid's selection, the
loupe's photo, compare's active pane) when that is exactly one image or RAW. The loupe
and compare panes follow a drag live; a grid tile updates when the drag ends.

## Levels

| String | Level |
| --- | --- |
| File name / `No Selection` | L1 (`title2`, semibold, middle-truncated) |
| Histogram | a picture, no text (DES-100) |
| `Revert to Original`, the Show Original toggle's tooltip | L2 (`body`, small control) |
| A RAW temperature's scale labels (`2500`, `4000`, `10000`) | L3 (`footnote`, secondary) |
| Section heading (`Crop`, `Light`, `Color`) | `.title3`, regular, beside the section's symbol |
| Control name, control value field, `Reset`, `Crop` / `Done`, `White Balance`, `Level` and its `Camera` / `Horizon`, `Rotate & Flip`, `Aspect` and its titles | L2 (`body`); values `.monospacedDigit()` (DES-005) |
| A control's name and value while it is at its neutral value | L2 in secondary color |

Four sizes, two weights (DES-004's edit panel deviation): the file name, the section
headings, the controls, and a RAW temperature's scale labels. Photos' section titles are
larger than its controls' names, so a section reads before its controls; the file name
above them stays the largest.

## Zones and height

A header zone, then one zone per section in Lightroom desktop's order, laid out as Photos
lays out its Adjust list. The header is the file name, the histogram (64 pt, DES-100) and a
row with the Show Original toggle (`square.split.2x1`, drawn pressed while on, DES-097's
idiom) on the left and `Revert to Original` on the right, 8 pt apart.

A hairline sits above each section, so where one ends and the next begins reads without
counting whitespace. Each section is a heading row over its controls: the disclosure
triangle, the section's symbol (`crop`, `sun.max`, `paintpalette`, `circle.dashed`,
`triangle.lefthalf.filled`, `camera.aperture`) and its title on the left; on the right a quiet
borderless `Reset` in secondary text (tertiary while there is nothing to reset), so six
headings do not read as six push buttons.
The controls are indented 16 pt under the heading, which puts them under its symbol.

Crop's rows stand in three groups 12 pt apart (rows are 4 pt apart), so the section reads as
one tool with three jobs and not as a list:
- **straightening:** Straighten and Level;
- **turning:** Rotate & Flip;
- **framing:** Aspect and Suggested.

The row labels name the groups, with no sub-headings. This follows Lightroom Classic's Crop &
Straighten panel, one tool with labelled groups, rather than splitting straighten into a
section of its own. Straightening rescales the crop, so the two are one geometry.

Each control is drawn as Lightroom draws it: its name and value on one line, label left
and value right (DES-017), over a small slider at the section's width. A slider's filled
track is the neutral secondary color, not the accent: a slider is a value, not a selection
(DES-024), and most sliders here are neutral at their middle, where a fill from the left
edge would read as an amount. A control at its neutral value draws its name and value in
secondary color, as Lightroom dims an untouched slider, so what was changed stands out.

Spacing is 16 pt padding, 12 pt on either side of a section's hairline, 8 pt between a
heading and its controls, and 4 pt between controls (DES-050).

Sections, in order (Lightroom desktop's order, ADR 0036):

| Section | Controls |
| --- | --- |
| Crop (a tool above the sections) | `Crop` / `Done` (Return while on); Straighten (−45.0…+45.0°, 0.1° steps, positive clockwise); `Level`: `Camera` and `Horizon` (small push buttons) and the straighten line's ruler (`ruler`, a toggle drawn pressed while armed); `Rotate & Flip`: Rotate Left, Rotate Right, Flip Horizontal, Flip Vertical (borderless icons, as Lightroom's); `Aspect`: its menu (Original, Custom, 1 × 1, 4 × 5, 5 × 7, 2 × 3, 4 × 3, 16 × 9) and Rotate Aspect; `Suggested`: `Subject` and `Thirds` (small push buttons) |
| Light | Exposure (−4.00…+4.00 stops, 0.05 steps), Contrast (−100…+100), Highlights (−100…+100), Shadows (−100…+100) |
| Color | White Balance picker; Temperature (a RAW: 2000–50000 K, even in mireds, 50 K steps, shown `5600 K`; another still: −100…+100), Tint (a RAW: −150…+150; another still: −100…+100), Vibrance (−100…+100), Saturation (−100…+100) |
| Effects | Vignette (−100…+100, negative darkens), Midpoint (0…100), Feather (0…100) |
| Detail | Sharpening (0…100), Noise Reduction (0…100); for a RAW whose decoder offers them, Color Noise, Detail, Moiré (0…100). A RAW's value starts at its decoder's own amount |
| Optics | Lens Correction (a checkbox), for a RAW with a lens profile only |

The panel's controls never appear or disappear between states (DES-053). With no photo
to edit, every control and `Reset` stays in place, disabled, with the tooltip
`Select one photo to edit` (DES-038). While the photo is being opened (downloaded if it is
cloud-only), the tooltip is `Preparing to edit`. `Reset` is also disabled while its section
is already neutral. Values show their sign (`+0.50`, `-20`); neutral reads `0.00` / `0`. A
RAW's temperature reads in kelvin; as shot, it reads the camera's value.

The Color section's first row is `White Balance` with the picker button at its trailing
edge: `eyedropper` at rest, `eyedropper.full` while armed, never color alone (DES-029). It
is enabled only in the loupe, with the tooltip `Open the photo in the loupe to pick a neutral
point` elsewhere.

## Sections fold

Each section heading is a disclosure triangle with the section's name: pointing in from
the leading edge while folded, down while open (Disclosure controls). Sections start open.
Which ones a person folds is remembered across launches. A folded section keeps its Reset
in the heading. The crop tool's section stays open while the tool is on; its heading keeps
its full contrast then, because the section in use must not read as unavailable. Folding
fades the
section's controls in or out (0.25 s, 0.15 s under Reduce Motion; DES-070, DES-075).

## Values can be typed

Each control's value is a field that reads like the value. Clicking or tabbing into it
lets the exact number be typed, with a sign, a degree mark or a kelvin unit as shown.
Return or leaving the field saves it as one step, named for the control. An out-of-range
number clamps, text that is not a number is put back, and Escape puts back the shown value.
While a field is being edited, Edit ▸ Cut, Copy, Paste and Select All act on its text
(DES-093).

## Crop tool

`Crop` in the panel, Photo ▸ Crop and C turn it on. If needed they first show the panel
and switch to the loupe, as Lightroom desktop does. The loupe then shows the whole frame
(the photo with every edit but its crop), fitted inside a 20 pt inset, with the crop over
it:
- outside the crop, a scrim of black at 55%, the same scrim as the tile badges
  (DES-062);
- the crop's edge as a white 1 pt line, with a rule-of-thirds grid at 45% white;
- eight handles, L-shaped at the corners and bars on the edges, white over a dark
  outline so they read on any photo, each with a 28 pt hit area (DES-051);
- a frame-resize pointer over each handle, and a grab pointer inside the crop.

The Aspect menu sits on its own row after an `Aspect` label, so its options read without
opening it (Pop-up buttons).

Dragging inside moves the crop. A corner handle resizes about the opposite corner, and an
edge handle about the opposite edge, staying centered across it. Under a constrained
aspect the crop keeps its shape and shrinks to stay in the frame. With Custom, Shift
during a handle drag keeps the shape the crop had when the drag began (Keyboards).

While the tool is on, the canvas holds the keyboard, with a focus ring (DES-081). The
arrow keys move the crop one pixel of the frame, ten with Shift, and a held key saves as
one step on release. Escape ends the tool. When it ends, the keyboard goes back to where
it was, usually the filmstrip. Choosing an aspect
fits the largest crop of that shape around the current crop's center. Rotate Aspect turns
the shape. The Aspect menu and Rotate Aspect are enabled only while the tool is on.

`Done`, Return, C, Escape, leaving the loupe, another photo, or hiding the panel ends the
tool. The loupe then shows the cropped photo. Rotate Left (⌘[), Rotate Right (⌘]), Flip
Horizontal and Flip Vertical (Photo menu, and the panel's buttons) work with the tool on
or off; Straighten too.

`Level` names each way of levelling by what it levels by, as Lightroom names its level
corrections (Upright's `Level`, `Vertical`). A lone `Auto` would hide which one it is.
- **`Camera`** straightens by the camera's own gravity reading at capture, as one
  `Level to Camera` step. It is enabled only when the opened photo carries a reading
  MediaMetadata trusts: an iPhone back camera held within about 45° of level. Otherwise its
  tooltip says the camera recorded no level for this photo.
- **`Horizon`** straightens by the horizon Vision finds in the picture, as one
  `Level to Horizon` step. Its tooltip warns that a photo without a horizon may come out
  tilted: Vision states no confidence and reads tilts into photos with no horizon, so it is
  offered only as the person's choice. Where it finds none, the photo is left as it is.
- **The ruler** is the third way.

The straighten line is Lightroom Classic's Angle tool. ⌘-drag anywhere on the photo with the
tool on, or drag after arming the ruler (which turns the tool on), draws a line, white over a dark
outline like the handles, under a crosshair pointer. Letting go turns the photo so that line
is level, or plumb when it was drawn nearer vertical than horizontal, as one `Straighten`
step, and disarms the ruler. A drag shorter than 8 pt is a click and draws nothing.

`Suggested` places a crop by the subject Vision finds in the frame the tool shows (objectness
saliency, else attention saliency), keeping the chosen aspect or the frame's own when it is
Custom.
- **`Subject`** is the smallest such crop that holds the subject with a margin of up to 15% on
  each side. The margin goes only where the frame has room, so a subject that fills the frame
  or touches an edge is still cropped in.
- **`Thirds`** is the largest such crop whose rule-of-thirds point (where the crop grid's
  lines cross) lands on the subject's center, on the subject's side of the frame. It is
  smaller than the whole frame whenever the center is not already on a third, since only
  a smaller crop can move the center there. Each is one `Suggested Crop` step. Neither Photos nor Lightroom suggests
crops, so the row follows the panel's own idiom: a label, then its acts. Both are enabled
only while the tool shows the frame the photo is cropped from, so a turn, flip or straighten
still rendering waits. Where Vision finds no subject, the crop is left as it is.

## Show Original and Revert to Original

Show Original (View ▸ Show Original / Show Edited, \\, the header toggle) shows the loupe's
photo without its edit until it is turned off, the edit changes, another photo is chosen
or the loupe is left. It is enabled only in the loupe, on an edited photo, with the crop
tool off; elsewhere its tooltip says `Open an edited photo in the loupe to show its
original`. The loupe marks it (DES-098).

Revert to Original (Photo ▸ Revert to Original, ⌘⇧R, the header button) removes the whole
edit — adjustments, crop, turns and flips — as one step (`Undo Revert to Original`), as
Photos does; on a trimmed video in the loupe it removes the trim. ⌘⇧R is Lightroom
Classic's Reset key, so Reveal in Finder takes Lightroom's ⌘R.

## The selected adjustment

Lightroom Classic's Develop keys move one control at a time: `,` and `.` (Photo ▸ Select
Previous / Next Adjustment) choose a control in panel order, wrapping, and `=` and `-`
(Increase / Decrease Adjustment) move it by its keyboard step (0.05 stop for Exposure, 1°
for Straighten, about 50 K for a RAW's temperature, 5 otherwise), each press one undo step
named for the control. The control last dragged becomes the selected one. The selected
control's row carries a light accent tint with its name in semibold, so it reads without
color (DES-024, DES-029), and scrolls into view. Double-clicking a control's name resets
that control alone (`Undo Reset Shadows`), as in Lightroom; VoiceOver offers the same as
the slider's `Reset` action.

A RAW's temperature slider, even in mireds, carries periodic labels under its track at
2500, 4000 and 10000 K, centered where the knob sits at those values (Sliders:
label a non-linear scale; `hig-validation.md` F-17).

## Behavior

- Dragging a slider renders the photo live in the loupe or compare pane. Letting go
  saves the change as one undo step, named for the control (`Undo Exposure`).
- A keyboard or accessibility step on a focused slider saves at once.
- `Reset` returns every control in its section to neutral as one step
  (`Undo Reset Crop`, `Undo Reset Light`, `Undo Reset Color`). White balance returns to as
  shot; Crop's Reset also clears turns, flips and straighten.
- Letting go of a crop drag saves it (`Undo Crop`); an aspect choice saves its fitted
  crop (`Undo Crop Aspect`); a turn or flip saves at once (`Undo Rotate Right`,
  `Undo Flip Horizontal`).
- With the picker armed, the loupe cursor is a crosshair, and one click makes that point
  neutral (`Undo White Balance`) and disarms the picker. Escape disarms it before
  Escape's other loupe meanings.
- Edit ▸ Undo and Redo move the panel's values with them when they change the photo it
  shows.

## Accessibility

The file name and section heading are headers. Each slider is labelled with its control
name and reads its formatted value. The name-and-value line is hidden from VoiceOver,
because the slider already says both. Tab moves through `Reset` and the sliders in
reading order (DES-080). Focus rings are the system's own (DES-081). No motion is added
(DES-070).
