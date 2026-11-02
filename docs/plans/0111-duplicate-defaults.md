# Plan 0111: every duplicate group has a default

Opened 2026-11-01. The owner compared Duplicates with Photos, Lightroom Classic 15.4,
Lightroom on the web, PhotoSweeper, Gemini 2 and Mylio, and asked for a default in every
group: the act should work without a decision per group. Today a group waits, with nothing
marked, when its copies span libraries, when more than one copy carries authored work, and
for every "Same photo" group.

## Owner decisions (2026-11-01)

- **Every group has a default.** The copies to keep are chosen and the rest marked; the
  user can change any mark.
- **Authored work is carried, not lost** (Photos' Merge, Mylio). When the act moves a copy
  whose curation or edit the kept copy lacks, the kept copy takes it, in the same catalog
  write; Undo restores both. Companion files (`.xmp`, `.srt`) are another app's files and are
  never moved onto another copy.
- **Only work that cannot be combined still waits:** two edited copies, two copies with
  companions, or two different curation choices.
- **"Same photo" groups keep the best version:** the camera original (capture metadata),
  then the most pixels, then the largest file.
- **Across libraries the default is to keep both.** Preselecting across libraries stays
  rejected (ADR 0042: it empties a mirror library in one unread act). The library pair row
  offers `Keep Only <Library>`, which marks every copy the pair holds in the other library.
- **Keep Only This Copy** on a row (Photo menu and the row's context menu): keeps it and
  marks the rest of its group.
- **"Same photo" groups are shown side by side at a large size**, because they are judged by
  their pixels; identical copies stay a list led by location.

## Increments

1. **Defaults, carry, Keep Only.** One keeper rule for both group kinds; a group waits
   (`defaultKeep == nil`) only for work that cannot be combined; the act carries curation and edits in the same
   Store write that hides the moved copies, with an undo that restores the kept copy; the
   pair row's `Keep Only <Library>`; Keep Only This Copy. ADR 0042, `duplicates.md`,
   APP-060, APP-061.
2. **Same photo side by side.** The group's versions as large thumbnails in one row, with
   their facts and state under each. `duplicates.md`, DES-107.
