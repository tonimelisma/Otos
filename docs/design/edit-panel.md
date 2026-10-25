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
| File name / `No Selection` | L1 (`title3`, semibold, middle-truncated) |
| Section heading (`Crop`, `Light`, `Color`) | `.headline` group heading (DES-003) |
| Control name, control value field, `Reset`, `Crop` / `Done`, `Aspect` and its titles | L2 (`body`); values `.monospacedDigit()` (DES-005) |

Three sizes, two weights (DES-004).

## Zones and height

One zone per section, in Lightroom desktop's order. Each section is a heading row
(title on the left, `Reset` on the right) over its controls. Each control is its name
and value on one line, label left and value right (DES-017), over a slider at the full
panel width. Spacing is 16 pt padding, 20 pt between the title and the section, 12 pt
between controls, and 4 pt between a control's line and its slider (DES-050).

A slider's filled track is the neutral secondary color, not the accent. A slider is a value,
not a selection (DES-024), and most sliders here are neutral at their middle, where a fill
from the left edge would read as an amount.

Sections, in order, as they are built (plan 0108):

| Section | Controls |
| --- | --- |
| Crop (a tool above the sections) | `Crop` / `Done` (Return while on), Aspect menu (Original, Custom, 1 × 1, 4 × 5, 5 × 7, 2 × 3, 4 × 3, 16 × 9), Rotate Aspect; Straighten (−45.0…+45.0°, 0.1° steps, positive clockwise); Rotate Left, Rotate Right, Flip Horizontal, Flip Vertical (icon buttons) |
| Light | Exposure (−4.00…+4.00 stops, 0.05 steps), Contrast (−100…+100), Highlights (−100…0), Shadows (−100…+100) |
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
in the heading. The crop tool's section stays open while the tool is on. Folding fades the
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
