# Duplicates

The surface for clearing extra copies of photos and videos the libraries already hold
(ADR 0042). Reached from the **Duplicates** row at the end of the sidebar, which exists
while any group is active and stays while selected.

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
  - a trailing `Keep All`.
- **Each copy** is a row:
  - a 48 pt aspect-fit thumbnail;
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
    - `6 need your choice` with `Show`.
  - `12 more found` with `Show` beside it while groups found during the visit are held
    back.
- **Act:** `Move 312 Items to Trash`, a plain bordered button with no Return equivalent.
  Disabled, it reads `Move Marked Items to Trash`, with the reason in its tooltip.

## Defaults

Otos marks copies only in a group whose copies are identical, all in one library, with
at most one copy carrying curation, an edit or a sidecar. That copy is kept. Failing
that, the keeper is the copy without a ` copy` / ` (1)` suffix, then the earliest-born,
then path order. Everything else waits, with nothing marked.

## Keyboard and VoiceOver

Rows are the selection. The state control is not a Tab stop.

**Commands.** These act on the selected rows:
- **Photo ▸ Keep This Copy**
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
