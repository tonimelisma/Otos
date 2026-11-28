# Duplicates

GOVERNS: `OtosKit/Views/DuplicatesView.swift`, `OtosKit/Views/DuplicatesPresentation.swift`

The surface for clearing extra copies of photos and videos the libraries already hold
(ADR 0042). Reached from the **Duplicates** row, alone under **Utilities**, the last
section of the sidebar — the header Photos gives its own Duplicates row; it is upkeep, not
a way to browse, so it does not sit with People and Places. The row exists while any
group is active and stays while selected; it is last so that its arrival pushes no row
under the pointer.

The direction (`docs/research/2026-11-04-duplicates-layout.md`): a
really clean way to choose which photo to keep, and a rule that decides a whole folder of
duplicates at once. A second direction (
`docs/research/2026-11-14-duplicates-by-attention.md`): the list is ordered by the
attention a group needs, not by date, and it shows what differs — photos where the
pictures differ, names where only the names do. So the list is three sections; a click on
a photo or a name keeps that copy; and each folder that holds exact copies is one header
carrying its rule, over the groups the rule decides.

## L1 primary fact

What will happen: `221 copies go to the Trash · 53.9 GB` — the count the button repeats
and the bytes it does not carry. While nothing would move, how many items have
duplicates: `6 photos with duplicates`, `110 videos with duplicates`, `312 items with
duplicates` when the groups hold both or a kind is not yet read, or `No duplicates`. The
count of items with duplicates is the bar's L3 while something would move, and the
sidebar row's count is that number (DES-017).

## Who comes here, and for what

| Visitor | Wants | What answers it |
| --- | --- | --- |
| Reclaiming space | The total, one button, the biggest first | The bar; each folder's `… in extra copies`; exact copies largest first |
| Fixing a double import | That folder, in one decision | The folder's header and its rule |
| Consolidating two folders or a backup library | One side, once | The two-folder header: `Keep the copies in` |
| Reviewing with care | Each group, which copy stays and why | Every group's line; photos tagged Keep or Trash, names marked by a checkmark or a trash can |
| Arriving from the sidebar count | What this is, and whether it is safe | Each section's one sentence; the bar's consequence and its legend |
| Settling what only they can | Just those groups | `Only you can choose`, first |

## Zones

A list above a fixed-height bar (DES-018, DES-053). Before the groups are first built the
pane draws nothing (APP-044); with no group the bar carries the L1 `No duplicates` and the
list area says why: `Nothing Otos has checked is stored twice.` The window shows no
`Filtered` subtitle here: the list ignores the filter. The list's backdrop is `content`
(DES-022); everything in it shares the 12 pt section inset (DES-060).

**Sections.** Three, in this order, each present only while it holds a group. A section's
header is its title in `.headline` (DES-011) with its count beside it (`.subheadline` L3,
`6 photos`: its groups not kept), over one L3 sentence that says what its groups are — a
description, not an instruction: the copies show they can be clicked (below), and the bar's
legend is the screen's one instruction. A hairline and space above every header but the
first.

| Section | Holds | Its sentence | Drawn as |
| --- | --- | --- | --- |
| `Only you can choose` | Groups whose copies hold work that cannot be combined: two edits, two with `.xmp` / `.srt` files, a like and a dislike (only between files of one photo: identical copies share one choice) | `Their edits, ratings or .xmp files conflict.` | Photos |
| `Different files of one photo` | Files of one capture whose pixels, format or bytes differ | `Otos keeps the best file of each.` | Photos |
| `Exact copies` | The same bytes stored more than once | `The same file stored more than once.` | Folders, then names |

A group's section is a fact about its copies, never about what the user has done to it: a
group stays where it is when a copy is clicked, when a rule changes and when it is kept
whole, so nothing moves out from under the pointer.

**A group of photos** (the first two sections), newest first by capture date, undated
last, a hairline between groups:

- **The header**: the capture date, `.body` (`October 4, 2026`; `No Date` when none is
  known), then `.subheadline` L3 one line, middle-truncated: the folder when every copy
  shares one, then why the group keeps what it keeps — `Keeping the camera original`,
  `Keeping the file with the most pixels`, `Keeping the largest file` (the keeper rule's
  deciding criterion, ADR 0042); `You chose this one`; or, for a group that waits, `The
  copies have different edits: click the one to keep`. When a copy in an Immich account
  stays though another was chosen, the line ends `Otos never removes copies in “Family”`;
  when nothing moves, it reads that alone. A kept group (Keep All Copies) reads `Kept both
  copies` with a `Review Again` link, and shows no photos.
- **The photos**: one per copy, 8 pt apart (DES-060), wrapping only when the pane is
  narrower than the group. A group's cells take the group's own aspect, from its kept
  copy's upright pixel size (the first copy whose size is known), the longer side 180 pt
  and the shorter in proportion — square when no size is known — so the picture fills its
  cell and its caption sits directly under it (DES-107's recorded deviation from
  DES-060A's uniform cells). The thumbnail is still aspect-fit in the cell, never cropped,
  radius 4, edged with a DES-023 hairline.
  - Top left, its fate as a tag, word and glyph (DES-029): **Keep** with a checkmark on
    the accent colour, or **Trash** with a trash can on black 55 % edged by a white 30 %
    hairline (`DesignPalette.badgeEdge`), so it reads on a dimmed picture over the dark
    backdrop. A copy that goes is
    drawn at 40 % opacity, so a group's keeper reads at a glance, in grayscale too. A group
    that waits tags nothing until a click.
  - Over the bottom of the picture, each on DES-062's badge (black 55 %, radius 3,
    `.footnote` white), so they stay legible on a dimmed light picture: the size centred
    (at the precision that tells the group's copies apart, `39.13 MB`; DES-005A) and the
    Like or Dislike glyph at the left.
  - Tags and badges appear only once the picture has painted (DES-062); the DES-063 kind
    glyph stands in the cell before then, and its slash variant once a decode has failed.
  - Under each photo, `.subheadline` L3, up to two lines, the cell's width: what else differs, and the work the
    copy holds — the dimensions and the format when the group's files differ in them,
    `Camera original` when not every file is one, then `Liked` / `Disliked`, `Edited in
    Otos`, `Has an .xmp or .srt file` (`6192 × 4128 · Camera original`). What the choice
    turns on is read without a hover.
  - When the group's copies sit in more than one folder, under that its folder, `folder`
    glyph and `.subheadline` L3, one line middle-truncated.
  - The file's location and every fact are its tooltip (`Camera Roll ▸
    2026/10/IMG_1.HEIC`, then `6192 × 4128 · 39.13 MB · File created … · Camera original ·
    Liked · Edited in Otos`).

**Exact copies** are listed by where they sit. One header per folder set, the set with
the most groups first; then `In three or more folders`, last, for groups no folder rule
could decide. A header is closed until clicked, so the folders read as a list — open when
it is the only one. A selection made elsewhere (Show, Undo) opens the header that holds it.

- **A folder's header**, with a hairline under it (DES-023): a disclosure chevron; `folder`
  (`folder.badge.questionmark` for two folders); `.body` the folder, or `2026/08 and
  Imports/Aug 2026` (each name its folder inside the library, with the library's name
  first when the list spans libraries); then L3 lines:
  - how many and how much: `412 photos in both · 31 GB in extra copies`, `38 photos saved
    twice in this folder · 1.2 GB in extra copies` (the bytes its groups would move; left
    out while nothing would), `Every copy kept` when every group is kept;
  - why, for the folder as a whole: one reason when its groups share it (`Keeping the
    original name`), else the two most common, counted (`96 keeping the original name ·
    14 keeping the older file · 5 more`; `3 chosen by you`). A folder is trusted by
    reading one line, not three hundred.
  - Closed, after the text, up to five 28 pt pictures of its first groups — each group's
    kept copy, aspect-filled squares at radius 4 like a group's picture below — so a closed
    folder shows what it holds; open, none, since its groups show it.
  - Trailing, the folder's rule: L3 `Keep the copies in`, 7 pt to the left of a small
    pop-up menu (DES-017, DES-054) showing only the current choice, offering `2026/08`,
    `Imports/Aug 2026` and `Otos decides` (`Both` when the folders are in different
    libraries, since the keeper rule then keeps each library's copy); or, for one folder,
    `Keep the` beside `Best copy`, `Original name`, `Oldest` and `Largest`.
- **An Immich account's copies** are never moved (ADR 0046 §8). The account counts as one
  folder, named by the account, since its folders are asset IDs. A set with a library
  folder offers only the account's side and `Both`: keeping the library's side would move
  the account's copies. Its line says why: `412 photos in both · Otos never removes copies
  in “Family”`. A set that is all account copies has a header and no rule: no rule could
  move anything.
- The rule applies at once to every exact-copy group under the header; their names re-tag
  as it changes. A click on one name still outranks the rule for that group. A folder's
  rule never reaches the other two sections: files of one photo differ in their pixels and
  are decided by their own photos, and no rule chooses between two people's work.
- **A group under an open header**, largest first, then newest, kept groups in their place,
  a hairline under each, indented past the chevron — a pair is two lines tall:
  - one picture, a 40 pt square, the kept copy's thumbnail aspect-filled at radius 4 (DES-107's
    recorded crop) — the copies are one picture, and two of it say nothing one does not;
  - **one line per copy**, at one left edge so the names compare down a column: a 20 pt
    glyph column — an accent `checkmark` for the copy kept, an L3 `trash` for one that goes,
    blank while the group waits — then what tells it from the others — its file name when
    the copies share a folder, its folder when they share a name, else `folder ▸ name` — in
    `.body`, label colour for the copy kept and L3 for one that goes; then the work it
    holds, L3 (`Liked · Edited in Otos`);
  - at the trailing edge of the first line, L3: the capture date, the size the copies share
    and why the group keeps what it keeps (`October 4, 2026 · 4.1 MB each · Keeping the
    original name`; `…, as the folder rule says`, `You chose this one`). A kept group is
    one line, its date and `Kept both copies` with `Review Again`, and lists no names.

**A copy shows it can be clicked.** Under the pointer a photo or a name shows the pointing
hand, and a highlight: a photo's edge becomes a 2 pt secondary border, a name's line a
rounded tertiary fill — so the affordance is seen without reading.

**A click keeps that copy** — a photo or a name — and tags every other copy of its group
Trash. It also selects it: a photo with DES-061's 3 pt accent border; a name the way a macOS
list draws its selected row — the system's selected-content fill at radius 4 behind the
whole line, with its glyph and words in the selected text colour, while the list has focus
in the key window, and the unemphasized selection gray otherwise.
A double-click opens the group. Context menu: `Keep This Copy`, `Keep All Copies`, then
`Move to Trash Now` — the ordinary act on this one copy, now. An Immich account's copy is
always tagged **Keep**. Its `Move to Trash Now` is disabled, its tooltip adds `Removed only
in Immich`, and its location reads `Family ▸ IMG_1.HEIC`, with no asset folder.

**Bar.** Three zones at one fixed height (DES-018, DES-053):

| Zone | Content |
| --- | --- |
| What | L1, as above — `221 copies go to the Trash · 53.9 GB` — over L3 the count, `312 photos with duplicates`. While nothing would move, L1 is the count (`6 photos with duplicates`, `No duplicates`) and L3 is blank space at the same height (DES-053). |
| Middle, behind a hairline | One of three, never blank: the **receipt** of the last move, `221 copies moved to the Trash · 53.9 GB`, written once the Store has hidden the copies, with `Undo` while that move is the window's last change, over `Empty the Trash in Finder to free the space`, until a click or rule changes, a later move replaces it, or the user leaves the list; else the **choices**, `6 photos need your choice` with `Show`, while any group waits (Show selects its first photo); else the **legend**, `Click a photo or a name to keep it, or set a rule for a whole folder.` |
| Act | `Move 221 Copies to Trash`, a plain bordered button with no Return equivalent (DES-052's deviation), tooltip `Moves every copy tagged Trash to the Trash. Edit ▸ Undo puts them back.` Disabled, it reads `Move Copies to Trash`. No confirmation (DES-076): every Keep and Trash is on screen before the click, the act is undoable, and the receipt says what happened. |

Moved copies go to the Trash through the ordinary Move to Trash, carrying their likes and
edits onto the kept copy that lacks them; `.xmp` / `.srt` files go with their copy.

## Defaults

Before a click or a rule, every group keeps what the keeper rule picks (ADR 0042):

- **Copies are compared within each library or account.** A copy in another library or an
  uploaded Immich copy is no duplicate until Settings ▸ General ▸ `Find duplicates across
  libraries and accounts` is on. A file and its mirror — the asset an Immich external library
  lists for that very file — are one photo and never a duplicate, with the setting on or off:
  the list never shows the mirror, so nothing can keep it in the file's place.
- **Each library keeps its own copy**, when copies across libraries are listed.
- **The best copy is kept:** one with `.xmp` / `.srt` files; for files of one photo —
  whether or not they name their capture — the camera original, then the most pixels,
  then the largest file in bytes; an edited copy, then one with a choice; the name without
  a ` copy` / ` (1)` / `_001` suffix; the earliest-born, at whole seconds; path order.
- **Work moves with the act.** A moved copy's choice or edit goes onto the kept copy that
  lacks it, and Undo takes it back.
- **Only work that cannot be combined waits**, tagging nothing until a click.

Clicks and rules are window state, a decision in progress: a click is forgotten once its
copy leaves the group.

## Keyboard and VoiceOver

Copies are the selection, as photos or as names. The folder headers and their rule pop-ups
are Tab stops, as are `Show`, `Undo` and the bar's button; the copies and the
`Review Again` links are not (DES-080).

**Commands**, on the selected photo: **Photo ▸ Keep This Copy**, **Keep All Copies**,
**Review Again**, and **Move Duplicates to Trash** (the bar's act). There are no bare-key
equivalents: P, U and X already mean curation.

**Keys.**
- **←** and **→** select the previous and next copy in the list's order, across groups.
  Among photos, **↑** and **↓** select the copy at the same place in the previous and next
  group; among an exact-copy group's names, the line above and below. The keys walk what
  is on screen: a closed folder's groups are skipped. The list scrolls the selected copy's
  group into view.
- **Space** keeps the selected copy, as a click does.
- **Return** opens the selected photo's group in Compare (two copies) or Loupe, with the
  group as the filmstrip. **Back to Duplicates** returns.
- **⌘⌫** (Photo ▸ Move to Trash) moves the selected groups' copies tagged Trash — never a
  kept one — so Select All then ⌘⌫ is the bar's act for what is selected.

**VoiceOver.**
- A section's header reads its title, its count and its sentence; a folder's header its
  name, its lines and `expanded` or `collapsed`. A group's header — for an exact-copy group
  the facts at its first line's trailing edge — reads its date and why it keeps what it
  keeps, before the group's copies.
- A copy is one button reading its file name, its fate (`keep`, `goes to the Trash`,
  `not chosen yet`), then its facts (DES-082); its action keeps it.

## Undo

- **Move to Trash** is the ordinary `Undo Move to Trash`, from Edit ▸ Undo or the
  receipt's `Undo`; on this list it selects the copies it brings back, whose groups
  rejoin at their dates (HIG Undo: show the result), and takes back the carried likes and
  edits.
- **Keep All Copies** and **Review Again** are undoable by their own names.
- A click and a rule are not undoable acts: another click or rule changes them back, and
  nothing on disk changes until Move to Trash.
