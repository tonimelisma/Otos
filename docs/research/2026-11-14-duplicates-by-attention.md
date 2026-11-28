# Duplicates by attention: who visits the list, and what each needs first

Date: 2026-11-14. An evaluation of the Duplicates list as built on 2026-11-04
(`docs/research/2026-11-04-duplicates-layout.md`), read from its spec, its two research
passes and its code, and the layout that followed. The evaluation came first, then
the design it ended in; `docs/design/duplicates.md` records that design.

Labels: **[M]** measured earlier on the reference library; **[U]** inferred.

## Who visits, and what they want

| Visitor | Trigger | Wants | Served by the 2026-11-04 list |
| --- | --- | --- | --- |
| Reclaiming space | A full disk | The total, one button, the biggest first | Partly: the button and the bytes, no order by size |
| Fixing an accident | A card imported twice | That folder, in one decision | Yes, by a rule row a scroll away from its groups |
| Consolidating | An import folder beside a dated one; a backup library | One side, once | Yes, the same way |
| Reviewing with care | Fear of losing the good one | Each group, which stays and why | Yes: the list was built for this visitor |
| Arriving from the count | The sidebar row appeared | What this is, and whether it can be left alone | One legend sentence |
| Settling conflicts | `6 photos need your choice` | Just those six | `Show` reached the first; the rest were scattered by date |

All but one of these visitors **[U]** want to approve a class of decisions and look at
instances only on doubt. The list served the one who wants every instance.

## What was wrong

1. **Ordered by date, a browsing order.** The groups that need a person sat among those
   that need nobody.
2. **Identical copies drew one picture twice and hid what differed.** The reference library
   was 110 identical pairs in one folder **[M, 2026-11-02]**: same picture, same size, and
   the file name, the one differing fact, in the tooltip. The 2026-11-02 pass had the rule
   (the header says what the copies share, the rows say what differs); the 2026-11-04
   layout, right for files whose pixels differ, dropped it for files whose names differ.
3. **Trust was audited one group at a time.** Nothing said `96 keep the original name, 14
   the older file`.
4. **A rule sat apart from what it decided.**

## The layout

- **Three sections, by attention:** what only a click decides; files of one photo; exact
  copies. A group's section follows its copies, never what the user did, so a click never
  moves a group out from under the pointer.
- **Photos where pictures differ, names where names do.** The first two sections keep the
  2026-11-04 tiles, with what else differs under each. An exact-copy group is one picture
  and a line per copy, the names at one left edge.
- **A folder's header is its rule and its summary:** how many, how much, why by count,
  and the segmented rule, over the groups it decides. Closed until clicked, so the folders
  read as a list and a folder is trusted by one line.
- **Largest first inside a folder**, for the visitor who came for space.
- **A folder rule decides exact copies only.** Files of one photo are shown as photos
  because their pixels differ; a control on another section's header must not re-tag them.

Kept from 2026-11-04: a click keeps a copy; every fate is on screen before the act; the
bar, its receipt and Undo; no confirmation.

## Not verified here

The built screen was not seen while this was written: the smoke capture refuses to start
beside a running Otos, and screen access was declined. The layout is checked by its
presentation tests and by a capture taken in the increment that built it.
