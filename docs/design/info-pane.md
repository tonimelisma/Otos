# Info pane

The inspector pane that says what Otos knows about the current item (DES-088, APP-041,
ADR 0050). It shares the trailing column with the Edit pane and is laid out the way the
Edit pane is (`edit-panel.md`), so pressing I and E in turn changes the content of the
column, not its shape.

## Reference

Photos' Info window puts the date first, then a camera block with the exposure line, then
a small map. Preview's inspector groups General, Exif, GPS and IPTC into folding sections.
Lightroom desktop's Info panel is a short fixed list (file, date, camera, exposure line,
location); Lightroom Classic switches metadata presets. Otos takes Photos' order of
interest (when, how, who, where, what file), Preview's folding sections, and the Edit
pane's heading and indent, so both panes repeat one pattern.

## L1 primary fact

Which item the facts describe: its file name, `No Selection`, or `3 Items`.

## Levels

| String | Level |
| --- | --- |
| File name / `No Selection` / `3 Items` | L1 (`title2`, semibold, middle-truncated) |
| The description (`Jamie holds Tyler by the fence…`) | L2 (`body`), selectable |
| `Written by Apple Intelligence`, `No Description`, `Not Written Yet` | L2 in secondary color (`body`) |
| When it was taken (`Saturday, November 7, 2026 at 3:42 PM UTC+02:00`) | L2 in secondary color (`body`) |
| Section heading (`Description`, `People`, `In This Photo`, `Location`, `File`, `Camera`, `Exposure`, `Video`) | `.title3`, regular, beside the section's symbol |
| A scene label (`Pool`, `Blue sky`) | L2, a small bordered button (`.bordered`, `.controlSize(.small)`), as People's suggestions are |
| `Text` over the recognised lines | L2 in secondary color, then the lines L2 (`body`), selectable |
| Row label (`Shutter Speed`) | L2 in secondary color (`body`) |
| Row value (`1/250 s`, `Unknown`, `—`) | L2 (`body`, `.monospacedDigit()`) |

Three sizes, two weights (DES-004).

## Zones and height

A header zone (name over date, 4 pt apart), then one zone per section, 12 pt either side
of each section's hairline. A section's heading is the disclosure triangle, its symbol
(`text.quote`, `camera`, `camera.aperture`, `film`, `person.2`, `viewfinder`, `mappin.and.ellipse`, `doc`) and its
title; its rows sit 8 pt below, indented 16 pt so they start under the symbol, 4 pt apart.
Labels share one leading edge; a long value wraps beside its label rather than under it.

| Section | Rows |
| --- | --- |
| Description (a still) | what the model wrote, then `Written by Apple Intelligence` |
| People | each face of the targeted photos, with the face acts (`docs/design/people.md`, DES-113) |
| In This Photo | the scene labels Vision is confident of, as buttons wrapping in rows, most confident first; then `Text` and the lines Vision is certain of |
| Location | a 140 pt still map with one pin (when located), Place, Coordinates, Altitude |
| File | Kind, Dimensions, Size, Folder, Original, Created, Modified, Imported, Companions, Copies (where its identical copies are, ADR 0054), Edits, Stack |
| Camera | Camera, Lens, Serial Number |
| Exposure (a still) | Shutter Speed, Aperture, ISO, Focal Length, Compensation, Program, Metering, Flash, White Balance |
| Video (a movie) | Duration, Frame Rate, Codec |

The order puts first what the user reads — the description (owner decision, 2026-11-14) —
then what they act on and look for — who is in the photo, what is in it, where and which file
it is — and the capture's own facts after (owner decision, 2026-11-12). A movie has no
Description.

Which sections show depends only on the kind, so every still has the same rows and every
movie the same rows (DES-053). With no single item the still layout shows with every
value `—`. The map is the one element that comes and goes: it is there only when the item
has a location to show, as a control whose subject does not exist is omitted (DES-053).

## States

- **Description, one still:** the text and `Written by Apple Intelligence`; `No Description`
  when the model declined; while owed, `Not Written Yet`, `Not Written Yet — Apple
  Intelligence isn’t ready.`, `Turn on Apple Intelligence in System Settings to describe
  photos.` or `This Mac can’t describe photos.`; with no single item, `—`. A description
  written while the pane shows its photo fills in without the photo being reselected.

- **One item:** every value the catalog holds, `Unknown` for one it lacks. The place name
  reads `Unknown` until MapKit names the coordinate.
- **No item / several items:** `No Selection` or the count, every value `—` but People,
  which lists the people in the selected photos and their unidentified faces, `—` when it
  lists none.
- **People, one photo:** its faces; with none listed, `No Faces` once the catalog says the
  photo was checked and holds none, `Not Checked Yet` before, and `—` while unknown or when
  its only faces are a hidden person's. A photo checked while it is shown fills in without
  being reselected.
- **In This Photo:** `Not Checked Yet` until search has read the item's thumbnail;
  `Nothing Recognized` only when both readings are made and found no confident label and no
  certain text (only a still's preview is read for text, so a movie has only its labels to
  read); otherwise the labels, then `Text` and its lines when there are any, or `Text` over
  `Not Checked Yet` while the still's preview is unread (text is read after every picture's
  labels). A thumbnail or preview that does not decode stays `Not Checked Yet`. With no single item, `—`. A photo read while it is shown fills
  in without being reselected.
- **A read failed:** the pane keeps what it showed for the same item, or empties for
  another, and the next refresh reads again (APP-041).

## Description

What Apple's on-device model wrote about the still (ADR 0053): two or three sentences naming
the people at their faces, written again whenever a fact it was written from changes. The
owner chose it for the top of the pane and asked for no editing (2026-11-14), so it has no
Edit, Retry or Revert control. Generated text is identified, as the HIG asks
(`Written by Apple Intelligence`). It stays in the inspector, never over the photo: Photos
for Mac shows a caption only in its Info window, and text over a photo needs a dimming layer
or glass that covers the picture under review (DES-060A).

## In This Photo

What search recognised in the photo, the two readings it already makes (ADR 0048): Vision's
scene labels and the text in it. The owner asked for both to be listed, and for text to be
shown only as far as Vision is sure of it (2026-11-12).

- **Labels** are named in the Mac's language (`SceneLabelNames`, ADR 0050), or in English
  where no checked name exists, each name once. A label is a button: clicking it searches for
  that label itself, whatever the Mac's language, and the toolbar field shows its name; its
  tooltip says `Search for “pool”`. A chip is never wider than the pane: a long name
  truncates on its one line.
- **Text** is the lines Vision read with full confidence, in reading order, selectable so a
  line can be copied. No line is shown that Vision was unsure of; search still matches those.
- There is no sidebar row for text (owner, 2026-11-12): finding photos by their text is the
  search field's.

## Keyboard and motion

Each section heading is a button: Tab reaches it, Space folds it, and VoiceOver reads it
as a header with `expanded` / `collapsed`. Folding fades the rows in place, 0.25 s, or
0.15 s under Reduce Motion (DES-070, DES-075).
