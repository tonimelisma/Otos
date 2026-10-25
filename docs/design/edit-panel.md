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
- the toolbar's Edit button (`slider.horizontal.3`, tooltip `Show Edit Panel` /
  `Hide Edit Panel`);
- View ▸ Show Edit Panel / Hide Edit Panel;
- E, Lightroom desktop's key for the Edit panel.

It is shown in every view mode. It edits the current target (the grid's selection, the
loupe's photo, compare's active pane) when that is exactly one image or RAW. The loupe
and compare panes follow a drag live; a grid tile updates when the drag ends.

## Levels

| String | Level |
| --- | --- |
| File name / `No Selection` | L1 (`title3`, semibold, middle-truncated) |
| Section heading (`Light`) | `.headline` group heading (DES-003) |
| Control name, control value, `Reset` | L2 (`body`); values `.monospacedDigit()` (DES-005) |

Three sizes, two weights (DES-004).

## Zones and height

One zone per section, in Lightroom desktop's order. Each section is a heading row
(title on the left, `Reset` on the right) over its controls. Each control is its name
and value on one line, label left and value right (DES-017), over a slider at the full
panel width. Spacing is 16 pt padding, 20 pt between the title and the section, 12 pt
between controls, and 4 pt between a control's line and its slider (DES-050).

Sections, in order, as they are built (plan 0108):

| Section | Controls |
| --- | --- |
| Light | Exposure (−4.00…+4.00 stops, 0.05 steps), Contrast (−100…+100), Highlights (−100…0), Shadows (−100…+100) |

The panel's controls never appear or disappear between states (DES-053). With no photo
to edit, every control and `Reset` stays in place, disabled, with the tooltip
`Select one photo to edit` (DES-038). `Reset` is also disabled while the section is
already neutral. Values show their sign (`+0.50`, `-20`); neutral reads `0.00` / `0`.

## Behavior

- Dragging a slider renders the photo live in the loupe or compare pane. Letting go
  saves the change as one undo step, named for the control (`Undo Exposure`).
- A keyboard or accessibility step on a focused slider saves at once.
- `Reset` returns every control in its section to neutral as one step
  (`Undo Reset Light`).
- Edit ▸ Undo and Redo move the panel's values with them when they change the photo it
  shows.

## Accessibility

The file name and section heading are headers. Each slider is labelled with its control
name and reads its formatted value. The name-and-value line is hidden from VoiceOver,
because the slider already says both. Tab moves through `Reset` and the sliders in
reading order (DES-080). Focus rings are the system's own (DES-081). No motion is added
(DES-070).
