# Duplicates layout: how competitors lay out a group

Date: 2026-11-04. A second pass on the Duplicates list after the owner rejected the
2026-11-02 design (`docs/research/2026-11-02-duplicates-review-ux.md`) on sight. That pass
compared competitors' *controls* — who uses a checkbox, who states the keeper's reason —
and never their *layout*. It borrowed the file tools' controls (dupeGuru, Mylio) and laid
them out as a file list. This pass compares the layout, and it is what
`docs/design/duplicates.md` follows.

Labels: **[D]** documented by the vendor; **[E]** reported by reviewers; **[M]** measured on
the owner's screen.

## What the rejected design put on screen [M]

The owner's screenshot, 2026-11-04, a group of six Sony ARW files:

- **One row per copy.** Each row was about 120 pt tall, so six copies filled the window
  and one group of 166 was all that showed.
- **About 60 % of the width was empty**, between the file name and the checkbox.
- **Six small identical thumbnails, one per row.** They said nothing that one would not.
- **The only fact that differed was raw bytes** (`39,133,184 bytes`, `39,100,416 bytes`).
  The reader had to compare eight-digit numbers.
- **The fate was said twice**, as a `Keep` checkbox and then `Stays` / `Moves to Trash`.
  The kept copy's box was disabled and drew dimmed, so the copy that stays looked inert.
- **The header was indented 76 pt** past the thumbnails' edge, by a blank well.
- **The bar needed a sentence explaining the checkboxes.**

The group was a burst, not one photo. That is a separate correctness defect, fixed in
#576 (ADR 0042, gate 1).

## Competitors

| App | Layout of a group | The mark |
| --- | --- | --- |
| Lightroom Classic (June 2026) [D] | No separate screen: the Library grid filtered to duplicates, each group a stack with a count badge, the original on top; expanding the stack shows the copies as grid cells | Stack position; `Set as Original` from the context menu |
| Apple Photos, Utilities ▸ Duplicates [D/E] | One row per group, the copies' thumbnails side by side at a large size, with size and date under each | None per copy; `Merge N Items` per row |
| PhotoSweeper [D] | Groups as boxes of thumbnails, plus a large Face-to-Face preview | A trash badge on the marked thumbnail |
| Gemini 2 / Gemini Photos [D/E] | Large image cards, the copies in a horizontal strip | A check on the copies to remove; one tagged `Best Result` |
| Mylio DeDupe [D] | A list of sets, each a horizontal strip of thumbnails, with an Info panel | A checkbox per copy; differences highlighted in yellow |
| Excire Foto [D] | A results grid of groups that expand | Pick and reject flags set by an assistant |

What every one of them does, and the rejected design did not:

1. **The copies sit side by side as photo-sized tiles.** None stacks them vertically, one
   per row.
2. **The mark sits on the copy's tile**, as a badge, a check or a stack position.
3. **Metadata comes second**: one short line under the tile, or an Info panel. A
   difference is shown so it can be read (Mylio's highlight), not as raw bytes.

## First decision (superseded by the owner follow-up below)

The design follows Lightroom Classic, Otos's reference idiom, as far as a review surface
allows.

- **A group is a header over a strip of tiles**, one tile per copy, every tile one size
  (184 × 138 pt face), 8 pt apart. Six copies read as one row of six.
- **The header** keeps the 2026-11-02 rule, now able to work: what the copies share once
  (kind and count, shared facts, the decision in words). It starts at the tiles' left
  edge, with no blank well.
- **Each tile** carries its own picture, what differs about it (the file name, then the
  differing facts on one line), and the `Keep` checkbox. A copy that moves is drawn at
  40 % opacity, Lightroom's dimmed reject, so every group's keeper reads at a glance.
  The checkbox stays: the HIG names it for an on/off setting, and with the face carrying
  the consequence, the separate `Stays` / `Moves to Trash` words go.
- **Sizes that tie at the shown precision** get the fewest decimals that tell them apart
  (`39.13 MB`), not raw bytes.
- **Tiles are the selection** through the grid's one selection model (`GridSelection`,
  via `applyGridClick`): click, ⌘-click and ⇧-click behave as in the grid, and the arrow
  keys walk the tiles.

Rejected:

- **A trash badge on the face** (PhotoSweeper). DES-062 places badges bottom-right only
  after a thumbnail paints. A control that disappears on a failed decode would leave that
  copy's fate unreachable by pointer.
- **Selection by group** (Apple Photos' one row per group). It would remove the per-copy
  commands the Photo menu already offers on the selection: Keep This Copy, Keep Only
  This Copy, and ⌘⌫ on the extra copies.
- **Reusing the media grid itself** (Lightroom). The grid's tiles carry curation hover
  controls, day sections and no per-group header. The review needs a header and a mark
  per copy, so it shares the grid's geometry and selection model instead.

## Sources

- [Adobe: Find and manage duplicate photos (Lightroom Classic)](https://helpx.adobe.com/ca/lightroom-classic/desktop/organize-photos-in-lightroom-classic/find-and-manage-duplicate-photos.html)
- [Apple Photos guide: duplicates](https://support.apple.com/en-la/guide/photos/pht5a3157c1d/8.0/mac/13.0)
- [MacRumors: find duplicate photos on Mac](https://macrumors.com/how-to/find-duplicate-photos-mac)
- [MacMost: Finding duplicate photos in the Photos app](https://macmost.com/finding-duplicate-photos-in-the-photos-app.html)
- [PhotoSweeper on the App Store](https://apps.apple.com/us/app/photosweeper/id463362050)
- [Cisdem: PhotoSweeper review](https://www.cisdem.com/resource/photosweeper-review.html)
- [Gemini 2 user guide](https://cdn2.macpaw.com/manuals/Gemin-2-User-Guide-29062021.pdf)
- [Mylio: Photo DeDupe](https://support.mylio.com/find-duplicate-photos-photo-dedupe)
- [Excire: duplicate finder](https://excire.com/en/tutorials/excire-search/duplikatefinder/)

## Owner follow-up, 2026-11-04

A Photos-style Merge was built next ("just like Photos.app") and rejected before merging:
it hides which copy stays and offers no clean way to choose it. The owner asked for "a
really clean way to choose which photo to keep", and for acting on a whole folder of
duplicates at once by a rule. The design that followed, in `docs/design/duplicates.md`:

- Photos' layout kept: the copies side by side as photos, the size over each.
- Each photo tagged **Keep** or **Trash**, the leaving copy dimmed (Lightroom's reject);
  one click on a photo keeps it.
- One rule row per folder set: two folders that mirror each other (keep the copies in one),
  or one folder with files saved twice (keep the original name, the oldest, the largest).
- The act names itself, `Move N Copies to Trash`, and asks nothing: every fate is on
  screen first.
