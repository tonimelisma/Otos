# Duplicates

The surface for clearing extra copies of photos and videos the libraries already hold
(ADR 0042). Reached from the **Duplicates** row under **Utilities**, the last section of
the sidebar — the header Photos gives its own Duplicates row. The row exists while any
group is active and stays while selected; it is last so that its arrival pushes no row
under the pointer.

The owner's direction (2026-11-04; `docs/research/2026-11-04-duplicates-layout.md`): a
really clean way to choose which photo to keep, and a rule that decides a whole folder of
duplicates at once. So every group shows its copies as photos side by side, as Photos lays
them out, each tagged **Keep** or **Trash**; one click on a photo keeps that one; and each
folder that holds duplicates has one rule row at the top.

## L1 primary fact

How many items have duplicates: `110 videos with duplicates`, `140 photos with
duplicates`, `312 items with duplicates` when the groups hold both or a kind is not yet
read, or `No duplicates`. The sidebar row's count is the same number (DES-017).

## Zones

A list above a fixed-height bar (DES-018, DES-053). Before the groups are first built the
pane draws nothing (APP-044); with no group the bar carries the L1 `No duplicates` and the
list area says why: `Nothing Otos has checked is stored twice.` The window shows no
`Filtered` subtitle here: the list ignores the filter. The list's backdrop is `content`
(DES-022); everything in it shares the 12 pt section inset (DES-060).

**Folders with duplicates** (`.subheadline` L3 caption), first: one row per folder set,
largest first, each with a hairline under it (DES-023):

- **Two folders that mirror each other** (an import folder and the dated folder, a backup
  library and the main one): leading `folder.badge.questionmark`; `.body` `2026/08 and
  Imports/Aug 2026` (each name its folder inside the library, with the library's name
  first when the list spans libraries); `.subheadline` L3 `412 photos in both`; trailing,
  L3 `Keep the copies in` beside a segmented control: `2026/08` | `Imports/Aug 2026` |
  `Otos decides` (`Both` when the folders are in different libraries, since the keeper
  rule then keeps each library's copy).
- **One folder with files saved twice in it** (`Blue.heic` and `Blue_001.heic`): leading
  `folder`; `.body` the folder; L3 `38 photos saved twice in this folder`; trailing `Keep
  the` beside `Best copy` | `Original name` | `Oldest` | `Largest`.
- A group whose copies sit in three or more folders has no row: it is decided by its own
  photos.
- **An Immich account's copies** are never moved (ADR 0046 §8). The account counts as one
  folder, named by the account, since its folders are asset IDs. A set with a library
  folder offers only the account's side and `Both`: keeping the library's side would move
  the account's copies. Its L3 says why: `412 photos in both · Otos never removes copies
  in “Family”`. A set that is all account copies has no row: no rule could move anything.
- The rule applies at once to every group in that set; the photos re-tag as it changes.
  A click on one photo still outranks the rule for that group. A group whose copies hold
  work that cannot be combined (two edits, two with `.xmp` / `.srt` files, a like and a
  dislike) is never decided by a rule: Otos will not choose between two people's work on
  someone's behalf.

**Groups**, then: files of one photo first, then identical copies, each newest first by
capture date, undated last, kept groups in their place among them. A hairline separates
groups, never above the first.

- **The header**: the capture date, `.headline`, long style (`October 4, 2026`; `No
  Date` when none is known), then `.subheadline` L3 one line, middle-truncated: the
  folder when every copy shares one, then why the group keeps what it keeps — `Keeping
  the original name`, `Keeping the older file`, `Keeping the camera original` (the keeper
  rule's deciding criterion, ADR 0042); `Keeping the original name, as the folder rule
  says`; `You chose this one`; or, for a group that waits, `The copies have different
  edits: click the one to keep`. When a copy in an Immich account stays though another was
  chosen, the line ends `Otos never removes copies in “Family”`; when nothing moves, it
  reads that alone. A kept group (Keep All Copies) reads `Kept both copies`
  with a `Review Again` link, and shows no photos.
- **The photos**: one per copy, 8 pt apart (DES-060), wrapping only when the pane is
  narrower than the group. Each is a 180 pt square cell with the copy's own thumbnail
  aspect-fit in it (DES-060A), radius 4, edged with a DES-023 hairline.
  - Top left, its fate as a tag, word and glyph (DES-029): **Keep** with a checkmark on
    the accent colour, or **Trash** with a trash can on black 55 %. A copy that goes is
    drawn at 40 % opacity, so a group's keeper reads at a glance, in grayscale too. A group
    that waits tags nothing until a click.
  - Over the bottom of the picture, white over a soft shadow as Photos draws them: the
    size centred (at the precision that tells the group's copies apart, `39.13 MB`;
    DES-005A) and the Like or Dislike glyph at the left.
  - Tags and badges appear only once the picture has painted (DES-062); the DES-063 kind
    glyph stands in the cell before then, and its slash variant once a decode has failed.
  - When the group's copies sit in more than one folder, under each photo its folder,
    `folder` glyph and `.subheadline` L3, one line middle-truncated: which folder a copy
    is in is what a folder rule chooses between, so the photos say it without a hover.
  - No file name on screen: where a copy is and what else differs is its tooltip
    (`Camera Roll ▸ 2026/10/IMG_1.HEIC`, then `6192 × 4128 · 39.13 MB · File created … ·
    Camera original · Liked · Edited in Otos`).
  - **A click keeps that copy** and tags every other copy of its group Trash. It also
    selects the photo (DES-061's 3 pt accent border). A double-click opens the group.
  - Context menu: `Keep This Copy`, `Keep All Copies`, then `Move to Trash Now` — the
    ordinary act on this one copy, now. An Immich account's copy is always tagged
    **Keep**. Its `Move to Trash Now` is disabled, its tooltip adds `Removed only in
    Immich`, and its location reads `Family ▸ IMG_1.HEIC`, with no asset folder.

**Bar.** Three zones at one fixed height (DES-018, DES-053):

| Zone | Content |
| --- | --- |
| What | L1, as above, over one L3 clause: `221 copies go to the Trash · 53.9 GB` — the count the button repeats and the bytes it does not carry; blank space while nothing would move. |
| Middle, behind a hairline | One of three, never blank: the **receipt** of the last move, `221 copies moved to the Trash · 53.9 GB`, written once the Store has hidden the copies, with `Undo` while that move is the window's last change, over `Empty the Trash in Finder to free the space`, until a click or rule changes, a later move replaces it, or the user leaves the list; else the **choices**, `6 photos need your choice` with `Show`, while any group waits (Show selects its first photo); else the **legend**, `Click a photo to keep it, or set a rule for a whole folder above.` |
| Act | `Move 221 Copies to Trash`, a plain bordered button with no Return equivalent (DES-052's deviation), tooltip `Moves every copy tagged Trash to the Trash. Edit ▸ Undo puts them back.` Disabled, it reads `Move Copies to Trash`. No confirmation (DES-076): every Keep and Trash is on screen before the click, the act is undoable, and the receipt says what happened. |

Moved copies go to the Trash through the ordinary Move to Trash, carrying their likes and
edits onto the kept copy that lacks them; `.xmp` / `.srt` files go with their copy.

## Defaults

Before a click or a rule, every group keeps what the keeper rule picks (ADR 0042):

- **Each library keeps its own copy.**
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

Photos are the selection. The rule rows' segmented controls are Tab stops, as are `Show`,
`Undo` and the bar's button; the photos and the header links are not (DES-080).

**Commands**, on the selected photo: **Photo ▸ Keep This Copy**, **Keep All Copies**,
**Review Again**, and **Move Duplicates to Trash** (the bar's act). There are no bare-key
equivalents: P, U and X already mean curation.

**Keys.**
- **←** and **→** select the previous and next copy in the list's order, across groups;
  **↑** and **↓** the copy at the same place in the previous and next group. The list
  scrolls the selected photo into view.
- **Space** keeps the selected photo, as a click does.
- **Return** opens the selected photo's group in Compare (two copies) or Loupe, with the
  group as the filmstrip. **Back to Duplicates** returns.
- **⌘⌫** (Photo ▸ Move to Trash) moves the selected groups' copies tagged Trash — never a
  kept one — so Select All then ⌘⌫ is the bar's act for what is selected.

**VoiceOver.**
- A header reads its date and why it keeps what it keeps.
- A photo is one button reading its file name, its fate (`keep`, `goes to the Trash`,
  `not chosen yet`), then its facts (DES-082); its action keeps it.

## Undo

- **Move to Trash** is the ordinary `Undo Move to Trash`, from Edit ▸ Undo or the
  receipt's `Undo`; on this list it selects the copies it brings back, whose groups
  rejoin at their dates (HIG Undo: show the result), and takes back the carried likes and
  edits.
- **Keep All Copies** and **Review Again** are undoable by their own names.
- A click and a rule are not undoable acts: another click or rule changes them back, and
  nothing on disk changes until Move to Trash.
