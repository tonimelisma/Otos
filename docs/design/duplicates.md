# Duplicates

The surface for clearing extra copies of photos and videos the libraries already hold
(ADR 0042). Reached from the **Duplicates** row under **Utilities**, the last section of
the sidebar — the header Photos gives its own Duplicates row. The row exists while any
group is active and stays while selected; it is last so that its arrival pushes no row
under the pointer.

## L1 primary fact

How many photos have duplicates: `140 photos with duplicates`, or `No duplicates`. The
sidebar row's count is the same number (DES-017).

## Zones

A list of groups above a fixed-height bar (DES-018, DES-053).

**List.**
- **Library pairs first.** Two libraries that share identical items get one summary row
  each — `Backup and Photos share 29,870 photos` — with `Keep Both Libraries`. A chevron
  shows the shared groups under it.
- **Each group** is a section:
  - header (`.headline`): `Identical · 3 copies`, or `Same photo · 2 versions` for versions
    of one capture (resized, re-encoded, metadata stripped), which are never preselected;
  - `.subheadline`: `Choose a copy to keep` when it waits (`Choose the version to keep`
    for same photo);
  - a trailing `Keep All`, and before it, for same photo, `Compare`: the group's first two
    versions side by side in Compare, the group as the filmstrip. Versions sit in rows,
    not side by side in the list, because rows are the selection.
- **Each copy** is a row:
  - an aspect-fit thumbnail: 48 pt for an identical copy, which its location tells apart;
    128 pt for a version of the same photo, which only its pixels tell apart (the stored
    256 px thumbnail at 2×);
  - the location first, at L2 (`Photos ▸ 2024/Holiday`) — it is what tells identical
    copies apart;
  - then filename · dimensions · size, at L3;
  - its curation, edit and sidecar marks;
  - its state, `Keep` or `Move to Trash`, as a symbol and text (DES-029).
- **Kept groups** sit in a collapsed `Kept` section at the end.

**Bar.**
- **What:**
  - L1, as above.
  - One L3 clause:
    - `312 items marked · 4.2 GB` (file sizes, the trash bar's convention); or
    - `6 need your choice` with `Show`, for groups whose work cannot be combined.
- **Act:** `Move 312 Items to Trash`, a plain bordered button with no Return equivalent.
  Disabled, it reads `Move Marked Items to Trash`, with the reason in its tooltip.

The list is every active group, always: a group found while the user looks joins at once.

## Defaults

Every group has a default (ADR 0042, Plan 0111):

- **Each library keeps its own copy.** A group spanning libraries keeps the best copy in
  each; its library pair row offers `Keep Only <Library>` beside `Keep Both Libraries`.
- **The best copy is kept:** one with sidecar files; for same photo, the camera original,
  then the most pixels, then the largest file; an edited copy, then one with a choice; the
  name without a ` copy` / ` (1)` suffix; the earliest-born; path order.
- **Work moves with the act.** A moved copy's choice or edit goes onto the kept copy that
  lacks it, and Undo takes it back.
- **Only work that cannot be combined waits** — two edits, two sets of sidecars, two
  different choices — with nothing marked and `Choose a copy to keep`.

## Keyboard and VoiceOver

Rows are the selection. The state control is not a Tab stop.

**Commands.** These act on the selected rows:
- **Photo ▸ Keep This Copy**
- **Keep Only This Copy** (also the row's context menu)
- **Move This Copy to Trash**
- **Keep All Copies**
- **Move Marked Items to Trash**

There are no bare-key equivalents: P, U and X already mean curation.

**Keys.**
- **Return** opens the selected group in Compare (two copies) or Loupe, with the group as
  the filmstrip. **Back to Duplicates** returns.
- **⌘⌫** is the ordinary Move to Trash.

**VoiceOver.**
- A row reads location, filename, state, then marks: `Photos ▸ 2024, IMG_0001.JPG, kept,
  liked`.
- It offers Keep This Copy and Move This Copy to Trash as custom actions (DES-085).
- Group headers are headers.

## Undo

- **Move to Trash** is the ordinary `Undo Move to Trash`.
- **Keep All Copies** and **Keep Both Libraries** are undoable by their own names. Undo
  selects the group it brings back.
