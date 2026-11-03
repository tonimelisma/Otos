# Duplicates

The surface for clearing extra copies of photos and videos the libraries already hold
(ADR 0042). Reached from the **Duplicates** row under **Utilities**, the last section of
the sidebar — the header Photos gives its own Duplicates row. The row exists while any
group is active and stays while selected; it is last so that its arrival pushes no row
under the pointer. Why it looks like this, and the reviews that shaped it:
`docs/research/2026-11-02-duplicates-review-ux.md`.

## L1 primary fact

How many items have duplicates: `110 videos with duplicates`, `140 photos with
duplicates`, `312 items with duplicates` when the groups hold both or a kind is not yet
read, or `No duplicates`. The sidebar row's count is the same number (DES-017). Groups
under a library pair count like any other.

## The one rule

**The header says what the copies share; the rows say what differs; the fate and its
reason are stated in words on every group.** A fact shown twice must be compared; a fact
shown once can be trusted. Everything below follows from it.

## Zones

A list of groups above a fixed-height bar (DES-018, DES-053). Before the groups are first
built the pane draws nothing (APP-044); with no group it draws `No duplicates` as an empty
state over the bar. The window shows no `Filtered` subtitle here: the list ignores the
filter.

**List.** Files of one photo first — the groups that need eyes — then identical copies,
each newest first by capture date (the kept copy's), the grid's order, undated groups
last, kept groups in their place among them. A group found while the user looks joins at
its date at once; one that resolves leaves at once. Selection is by copy, so a group
joining above the selection does not move it; a group leaving takes its rows out of the
selection and selects nothing in their place. The list's backdrop is `content` (DES-022);
a hairline (DES-023) separates groups and is never drawn above the first, and the list
begins 8 pt below its top edge rather than at the platform inset.

- **Library pairs first.** Two libraries that share identical items get one summary
  section each, before the groups: `.headline` `Backup and Photos share 29,870 photos`;
  `.subheadline` what the pair's marks will do — `Each library keeps its own copy. Nothing
  moves.`, or `29,870 copies in Backup move to the Trash` after a pick; a trailing
  `Keep Only…` pull-down whose items are `Keep Only Photos`, `Keep Only Backup`, and
  `Keep One Copy in Each Library` (the marks back to their default); and `Keep Both
  Libraries`, which sets aside everything the two share, tooltip `Sets aside everything
  these libraries share. Nothing moves.` Set aside, the row reads `You kept both
  libraries' copies` with `Review Again` in place of both controls. A disclosure chevron
  shows the shared groups under it; they are collapsed by default, since the decision is
  the libraries'. A group spanning three or more libraries has no pair and lists like any
  group.

- **Each group** is a card over its rows, three lines beside a 64 pt well:
  1. `.headline`: `2 identical videos`, `3 identical photos`, `2 identical items` when a
     kind is not yet read; `2 files of one photo` for versions of one capture — "files",
     since to a Lightroom user a version is an edit.
  2. `.subheadline`, the shared facts, at the precision the list shows (DES-005A):
     `Captured Aug 2, 2026 at 12:56 AM · 134 MB each · MP4 · 3840 × 2160 · Camera Roll ▸
     2026/08` — the kept copy's capture date in the Info pane's format and word
     (`PhotoInfo`), then the size (first: it is the fact a reader uses), format and
     dimensions when every copy shares them (`each` on a shared size, since one file is
     not the group; the size leaves the card when the shown figure hides a difference in
     bytes, which the rows then show), then the location: within one library, the
     deepest folder every copy is in or under (`Camera Roll` alone when that is the
     library's top); across libraries, nothing. A fact the catalog lacks is left out,
     never `Unknown`. This is a line of looked-up facts, not a status string (DES-034): up
     to five facts a middot apart.
  3. `.body`, label colour (L2): the decision (below) — the verdict, the one line that
     says what the act will do, so it is not read as one more fact.
  - **The well** holds one aspect-fit thumbnail, edged with a DES-023 hairline so a dark
    picture reads on the dark backdrop, when one picture stands for every copy: every
    identical group, and a group of files of one photo whose dimensions, format and bytes
    agree. It is blank when the rows carry the pictures — files of one photo whose
    dimensions, format or size differ, where one picture must never stand for two files
    the screen knows apart — so every card's text shares one left edge (DES-016). The
    DES-063 kind glyph stands in the well before the thumbnail decodes, and its slash
    variant once a decode has failed.
  - Every card line is one line, middle-truncated.
  - Trailing, `.small`: `Compare` (the group's first two side by side, the group as the
    filmstrip; tooltip `See the first two side by side, at full size.`) for files of one
    photo — identical copies have one picture, which Return and double-click open — then
    `Keep Both Copies` for two copies or `Keep All Copies` for more. These are not Tab stops (DES-080): the Photo menu's Keep All Copies
    and Review Again, and Return, act on the selected group.
  - **A kept group** (Keep Both Copies, Keep All Copies) stays in its place as one quiet
    card with no well, no rows and no decision: `.headline` `Kept both copies` (`Kept all
    3 copies`), the shared facts with the kind in them (`Captured … · 2 identical videos ·
    Camera Roll ▸ 2026/08`), and `Review Again` trailing, which forgets the kept pairs and
    returns the group's rows with its default. A card that vanished on Keep Both read as a
    deletion; one that stays, quiet, reads as kept.

- **Each copy** is a row: what differs, then its fate beside its mark:
  - leading, a 128 pt-wide aspect-fit thumbnail (the stored 256 px thumbnail at 2×) when
    the pictures are what differ, its height the picture's own (a landscape row is no
    taller than its picture; every row of a group shares the aspect, so the group keeps one
    pitch); otherwise the card's well, left blank, so the row's L2 shares the card text's
    left edge (DES-016). The row's selection highlight passes behind a thumbnail, the
    platform's list norm rather than DES-061's tile border.
  - L2 (`.body`): the part of the location the header did not state — the file name when
    the copy is in the header's folder (`20260801_175635.mp4`); the rest of its path when
    it is under it (`Day 1/IMG_0001.JPG`); library, folder and file when the group spans
    libraries (`Backup ▸ 2024/IMG_0001.JPG`). Middle-truncated.
  - L3 (`.subheadline`): the facts that differ within the group, in this order — the
    format, dimensions and size, each only when the copies' differ at the precision the
    list shows (the shared ones are on the card), the size as `11,400,000 bytes` when the
    shown figure ties but the bytes do not; `File created Aug 2, 2026 at 12:56 AM` when
    birth times differ (with seconds when two copies share a minute; the keeper rule
    compares birth times at whole seconds and sizes in bytes, and the rows show each at
    the precision that tells the copies apart, so the rows and the rule never disagree) —
    then the copy's own marks: `Camera original` or `Not the camera original` (only when
    not every copy is one, and for every row, so no row is blank beside a fact about its
    sibling), `Liked` or `Disliked`, `Edited in Otos`, `Has an .xmp or .srt file`. On a copy that moves, a mark says where its work goes: `Liked. Its Like
    moves to the kept copy` and `Edited in Otos. Its edits move to the kept copy` when the
    act carries it (the kept copy lacks it); `Edited in Otos. Its edits move to the Trash
    with it` when it cannot (the user chose between two edits); `Its .xmp or .srt file
    moves to the Trash with it` always, since those files never carry. Every row of a
    group takes the group's shape: when any row has an L3, all have the line, so the
    checkboxes sit at one pitch and nothing reflows when a mark changes.
  - trailing, at one width in every state (DES-053): the `Keep` checkbox whose own title
    is its meaning — control and consequence as one control, so clicking the words
    toggles too — a symbol and a word (DES-029): `Stays` with `checkmark.circle` when
    checked, `Moves to Trash` with `trash` when not, both in label colour (a grey `Stays`
    read as switched off). VoiceOver reads the row, not the box, and the box is not a Tab
    stop: rows are the selection. In a pair,
    unchecking the kept copy keeps the other — one click swaps the keeper, since a group
    always keeps one and there is only one other. With three or more copies the last
    checked box is disabled, tooltip `A group always keeps one copy.`. A copy of a waiting
    group offers `Keep This Copy`, a `.small` button that keeps it and marks the rest (Keep
    Only This Copy), so the first click means keep, never un-keep — such a row has no
    checkbox.
  - Return or Space on a selected row, and double-click on any row, open that row's group.
  - Context menu: `Keep This Copy`, `Don't Keep This Copy`, `Keep Only This Copy`, then
    `Move to Trash Now` — the ordinary act on this one copy, now, for a user who wants to
    try one before the bar's act; "Now" because it acts where the fate word only states.

**Bar.** Three zones at one fixed height (DES-018, DES-053):

| Zone | Content |
| --- | --- |
| What | L1, as above, over one L3 clause: `178 extra copies to move · 53.2 GB` — the count the button repeats, so the two numbers on the bar are seen to be one, and the bytes it does not carry (file sizes, the trash bar's convention; `at least 53.2 GB` when some sizes are unknown); blank space while nothing moves. |
| Middle, behind a hairline | One of three, never blank: the **receipt** of the last act, `178 extra copies · 53.2 GB moved to the Trash` with `Undo` while that act is the window's last change, over `Empty the Trash in Finder to free the space`, until a mark changes or the user leaves the list; else the **choices**, `6 photos need your choice` with `Show`, while any group waits (Show selects the first); else the **legend**, `Checked copies stay. Unchecked copies go to the Trash; Undo brings them back.` — the sentence a first visit needs, since the act asks nothing. |
| Act | `Move 178 Extra Copies to Trash`, a plain bordered button with no Return equivalent (DES-052's deviation), tooltip `Moves the extra copies to the Trash. Edit ▸ Undo, or the Trash, puts them back.` Disabled, it reads `Move Extra Copies to Trash`, tooltip `Uncheck Keep on a copy, or choose a copy to keep in a group that waits.` No confirmation (DES-076, HIG Alerts): the act is undoable and the Trash recoverable, and the receipt says what happened. |

## The decision line

One clause per group, the header's last line, computed from the keeper rule (ADR 0042)
and the session's marks — never a stored string.

| State | Line |
| --- | --- |
| Default, decided by an `.xmp` / `.srt` file | `Keeping the copy with its .xmp or .srt file` (`file` for files of one photo, throughout) |
| … by the camera original (versions) | `Keeping the camera original` |
| … by pixels (versions) | `Keeping the file with the most pixels` |
| … by file size (versions) | `Keeping the largest file` |
| … by an edit | `Keeping the copy edited in Otos` |
| … by a choice | `Keeping the copy you liked` / `Keeping the copy you disliked` |
| … by a copy suffix | `Keeping the original file name` |
| … by birth time | `Keeping the older file` |
| … by path order | A tie-break is not a merit, so the line says why it does not matter: `Alike in every way, so keeping the first by name` for identical copies, `Nothing told them apart, so keeping the first by name` for files of one photo; `… by folder and name` when the card names no folder every copy is in |
| Default across libraries | `Keeping one copy in each library` |
| The marks differ from the default | `Keeping the copy you chose` (`copies` when more than one is kept); marks changed back are the default again |
| Waits: more than one edited | `Choose which edited copy to keep` (`… edited copy in Photos …` when the group spans libraries and names the library that conflicts) |
| Waits: more than one with an `.xmp` / `.srt` file | `Choose which copy with an .xmp or .srt file to keep` |
| Waits: different choices | `Choose the liked or the disliked copy to keep` |
| Kept | none: the card reads `Kept both copies` |

The deciding criterion is the one at which the kept copy beats the other copy it beats
last in the rule's order, so the line names the rule that was needed, not the first one
that happened to apply; with three or more copies the rows' L3 shows the fact that beat
each one. A waiting group keeps every copy and counts nothing until `Keep This Copy` on
one of its rows decides it.

## Defaults

Every group has a default (ADR 0042, Plan 0111):

- **Each library keeps its own copy.** A group spanning libraries keeps the best copy in
  each; its library pair row offers `Keep Only <Library>` beside `Keep Both Libraries`.
- **The best copy is kept:** one with `.xmp` / `.srt` files; for files of one photo —
  whether or not they name their capture — the camera original, then the most pixels,
  then the largest file in bytes; an edited copy, then one with a choice; the name without
  a ` copy` / ` (1)` / `_001` suffix; the earliest-born, at whole seconds; path order.
- **Work moves with the act.** A moved copy's choice or edit goes onto the kept copy that
  lacks it, and Undo takes it back.
- **Only work that cannot be combined waits** — two edits, two with `.xmp` / `.srt` files,
  two different choices — with everything kept and the conflict named.

## Keyboard and VoiceOver

Rows are the selection. The `Keep` checkbox and the cards' buttons are not Tab stops;
`Show`, `Undo` and the bar's button are, so the bar is at most two Tabs from the list.

**Commands.** These act on the selected rows:
- **Photo ▸ Keep This Copy**
- **Don't Keep This Copy**
- **Keep Only This Copy** (also the row's context menu)
- **Keep All Copies**
- **Review Again**
- **Move Extra Copies to Trash**

There are no bare-key equivalents: P, U and X already mean curation, and Space is
Lightroom's Loupe toggle.

**Keys.**
- **Return** and **Space** open the selected group in Compare (two copies) or Loupe, with
  the group as the filmstrip (Space is Lightroom's Loupe toggle). **Back to Duplicates**
  returns.
- **⌘⌫** (Photo ▸ Move to Trash) moves the selected groups' extra copies — the rows that
  read `Moves to Trash` — and never a kept one, so Select All then ⌘⌫ is the bar's act for
  what is selected, not the loss of every copy. A kept copy moves now only by its row's
  `Move to Trash Now`.

**VoiceOver.**
- A group header is a header and leads with what tells one group from the next (DES-082):
  `Captured Aug 2, 2026 at 12:56 AM, 2 identical videos, 3840 by 2160, 134 MB, Camera Roll,
  folder 2026/08, Keeping the older file`.
- A row is one element reading what differs, then its fate, then its facts:
  `20260802_005635.mp4, moves to Trash, File created Aug 2, 2026 at 12:56 AM`
  (`stays` for a kept copy); a waiting row reads `waiting for your choice`.
- It offers Keep This Copy, Keep Only This Copy and Don't Keep This Copy as custom actions
  (DES-085).

## Undo

- **Move to Trash** is the ordinary `Undo Move to Trash`.
- **Keep All Copies**, **Keep Both Libraries** and **Review Again** are undoable by their
  own names. Undo selects the group it brings back.
