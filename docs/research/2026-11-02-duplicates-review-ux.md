# Duplicates review: what a user needs to decide, and how to show it

Date: 2026-11-02. A research pass and design study for the Duplicates list's second
design. It starts from the first design on screen with the owner's own library (166
groups, all pairs of identical videos imported twice), what competitors show, and the HIG,
and ends in the spec at `docs/design/duplicates.md`. The adversarial reviews that shaped
the spec are recorded at the end.

Labels: **[D]** documented by the vendor or Apple; **[E]** reported by users or reviewers;
**[M]** measured on the owner's library; **[U]** inferred.

## What the first design put on screen

A screenshot of the shipped list, 2026-11-02, on the owner's Camera Roll:

- Every group header read `Identical · 2 copies`, 166 times. Nothing in a header told one
  group from the next: no picture, no date, no size.
- Every row led with `Camera Roll ▸ 2026/07` at L2 — the same string on both rows of
  every group, because every one of the owner's pairs sits in one folder. The one fact
  that told the copies apart, the file name, sat at L3 in secondary colour.
- Each row carried its own 48 pt thumbnail of the same frame. Two identical thumbnails
  say nothing a single one does not, and 48 pt of a 4K frame shows little either way.
- The fate control was a borderless button reading `Keep` or `Move to Trash`. The kept
  row's `Keep` was disabled (a group always keeps one copy), so it drew dimmed, while
  `Move to Trash` drew enabled: the row that was staying looked inert and the row that
  was leaving looked like a live button. A reader could take `Move to Trash` for an act
  rather than a mark.
- `Keep All` sat in every header, 166 times, as the loudest control on the surface.
- Nothing said why a copy was kept. Apple Photos' hidden keeper is the category's most
  cited complaint (`docs/research/2026-10-31-duplicate-detection.md`), and this list
  repeated it.
- The bar read `166 photos with duplicates` over a list of videos.
- The window subtitle read `Filtered` while the list ignores the filter.

Profile of the owner's duplicates in the dev catalog, 2026-11-02 **[M]**: 110 groups, all
pairs, all in one folder of one library; 204 video copies and 16 image copies; no copy
with an edit, a choice or companions. Pairs are the same bytes under names seven hours
apart (`20260801_175635.mp4` / `20260802_005635.mp4`: one import named in UTC, one in
local time), seconds apart (`20260816_151736.mp4` / `20260816_151753.mp4`), or a
OneDrive conflict suffix (`… 1.png` / `….PNG`). Most pairs have the same birth time to
the second, so the keeper rule reaches path order.

## What the user decides

The user's one decision per group is *which file stays*, and it is made of four questions:

| Question | What answers it |
| --- | --- |
| Are these really the same thing? | Identical: the word, and one picture. Versions: the pictures side by side. |
| Which one stays, and why that one? | The kept row, and the rule that picked it, in words. |
| Does anything of mine leave with the other one? | Edits, choices and sidecar files on the leaving copy, and where they go. |
| What happens when I press the button? | The count, the bytes, and that it is the Trash. |

The situations the policy produces (ADR 0042), and what each needs on screen:

| Situation | Where it comes from | What the decision needs |
| --- | --- | --- |
| **Twin in one folder** (the owner's whole library today) | A card imported twice; a double save | One glance: one picture, the shared facts once, the two names, which stays. Nothing else. |
| **Copy elsewhere in one library** | Finder duplicate, a download saved twice, a reorganized folder | The two locations and names; which carries the ` copy` / ` (1)` suffix; which is older. |
| **A mirror across two libraries** | A backup library | A library-level decision. The groups under it are noise until the user opens them. |
| **Versions of one photo** | An export, a resize, a stripped copy | The pictures; dimensions, size, format; which is the camera original. Compare. |
| **Work on the leaving copy** | A like or edit made on the copy that is not kept | That the like or edit moves to the kept copy, and that undo brings it back. |
| **Work that cannot be combined** | Two edits, two sets of sidecars, a like and a dislike | *What* conflicts, named, so the user can choose. |
| **Kept groups** | Keep All | A place to see them, and a way back. |

The rule that follows: **the header says what the copies share; the rows say what differs;
the fate and its reason are stated in words on every group.** A fact shown twice is a fact
the user has to compare; a fact shown once is a fact the user can trust.

## Competitors

Sources and the full survey: the 2026-10-31 study, plus a 2026-11-02 pass on the review
screens themselves.

| App | Group presentation | Per-copy facts | Fate control | Default explained? | Differences shown? |
| --- | --- | --- | --- | --- | --- |
| Apple Photos (macOS 27) [D] | One row per group, copies side by side, listed by date; Duplicates row under Utilities, present only with content | File size overlaid on the thumbnail; the rest in the Info window | None; `Merge N Items`, then the same button in a dialog; extras go to Recently Deleted for 30 days | No. "One original remains"; the pick is undocumented and the most cited complaint [E] | No |
| Lightroom Classic 15.4+ [E] | Stacks in the grid; the "Original" on top | Ordinary grid badges; reviewers set the cell label to Folder to see locations | Positional: top of the stack; `Set as Original` to change | Earliest added to the catalog, unstated on screen | No |
| PhotoSweeper [D/E] | Group list left; Face-to-Face, One by One, All-in-One previews | Info sidebar with full metadata, quality badges | A trash badge on the marked copy; Auto Mark by reorderable rules; `Trash Marked` with a warning | Rules are the user's own; a newer Quality Score claims to show reasons | Face-to-Face |
| Gemini Photos [D] | Cards; swipe through a set | — | A red checkmark on copies marked for removal | One copy labelled `Best Result`, no reasons; favorites never auto-selected | No |
| Mylio DeDupe [D] | One set at a time | Info panel: size, resolution, metadata, location | A checkbox per copy; Auto-Check by a user-ordered list (Edited, Has XMP, Rating, Flagged, folder, name, date); `Move Checked` / `Delete Checked` | The user's own order | No |
| dupeGuru [D] | A group list; the reference first, duplicates indented | Configurable columns | A checkbox on duplicates; the reference cannot be marked; Space toggles | Reference = reference folder, else "usually the biggest" | **Delta values**: numeric columns show the difference from the reference, and differing values draw in orange |
| digiKam [D] | A reference thumbnail with item count and average similarity | A per-item similarity column in table view | `Remove Duplicates` deletes every non-reference | A setting: older or larger, a folder, newest | Similarity % |

What recurs:

- **The platform's own shape is a list of groups, by date, with a per-group act** and a
  bulk act whose title carries the count. Apple also confirms the bulk act in a dialog;
  the HIG says a common, undoable act needs none, and Otos's Move to Trash is one.
- **A checkbox per copy** is the control every tool with per-copy marks uses (Mylio,
  dupeGuru, Gemini). Nobody draws the fate as a button.
- **Nobody states the reason for the default.** Lightroom's and Apple's reviewers tell
  users to check folders by hand. dupeGuru's orange delta values are the one documented
  attempt to show what differs. This is the gap Otos fills: the reason in words, and only
  the differing facts on the rows.
- **Favorites are protected** (Gemini) and **work is carried** (Mylio's metadata merge,
  Apple's merge). Otos carries curation and edits onto the kept copy (ADR 0042) and must
  say so where it happens.

## HIG

Read from Apple's HIG JSON feed on 2026-11-02 (the rendered pages are script-built).

- **Toggles.** "To present a single setting that can be on or off, prefer a checkbox." A
  checkbox is a mark, not an act, so it cannot be mistaken for one. A switch is "for
  settings that you want to emphasize", and a row's fate is not a setting to emphasize.
  Radio buttons present mutually exclusive choices, but a group may keep more than one
  copy (one per library), so Keep is a set, not a choice of one.
- **Color.** "Avoid relying solely on color to differentiate between objects, indicate
  interactivity, or communicate essential information." The leaving copy says so in a
  word and a symbol.
- **Buttons.** "Don't assign the primary role to a button that performs a destructive
  action, even if that action is the most likely choice." The bulk move stays a plain
  bordered button (DES-052's recorded deviation).
- **Alerts.** "Avoid displaying alerts for common, undoable actions, even when they're
  destructive." Move to Trash asks nothing beyond the download question (DES-090).
- **Undo.** "Show the results of an undo or redo." Undo selects the group it brings back.
- **Lists and tables.** Where text might clip, "an ellipsis in the middle … preserves both
  the beginning and the end." Paths truncate in the middle.
- **Image views.** "Image views are typically not interactive." The group's picture is a
  view; Return and Compare open the group.
- **Focus.** "Avoid changing focus without people's interaction." A group leaving the
  list does not move the selection.
- **Layout.** "Avoid placing controls or critical information at the bottom of a window."
  Otos's status surfaces sit at the bottom of the content pane by DES-040, as the import
  and trash bars do; the bar is the one surface in the app that does, and this list
  follows the app rather than deviating alone.

## Design

Recorded in full in `docs/design/duplicates.md`. The decisions, and why:

1. **A group is a card: picture, shared facts, the decision, then the rows.** For
   identical copies one thumbnail (64 pt) stands for the group, since there is one picture.
   Versions of one photo keep a thumbnail per row (128 pt), since the pictures are the
   difference. The header's first line names the kind and count — `2 identical videos`,
   `3 versions of one photo` — so the noun is honest and the count is in it.
2. **Shared facts once, in the header.** Kind, capture date, dimensions and size for
   identical copies; kind and capture date for versions. The location is shared as far as
   every copy shares it: a group whose copies all sit in `Camera Roll ▸ 2026/07` names the
   folder once in the header, and each row names only the file. A group across folders
   names the library once and each row its folder and file. A group across libraries
   names nothing in the header and each row its library, folder and file. So what differs
   is always at L2 on the row, whatever differs.
3. **The decision in words, on every group.** The header's last line says what Otos will
   do and why: `Keeping the older file`, `Keeping the original name`, `Keeping the camera
   original`, `Keeping the copy with sidecar files`, `Keeping the edited copy`, `Keeping the
   copy you rated`, `Keeping one copy in each library`, or, when nothing separates the
   copies, `The copies are alike in every way. Keeping the first by name.` After the user
   changes a mark: `Keeping the copy you chose`. A group that waits says what conflicts:
   `Both copies are edited. Choose one to keep.` The reason is the keeper rule's deciding
   criterion against the strongest other copy, computed, never a stored string.
4. **Keep is a checkbox.** `Keep` checked is the kept copy; unchecked, the row says
   `Moves to Trash` with a trash symbol at its trailing edge. The last checked box in a
   group is disabled, with the reason in its tooltip. The checkbox is not a Tab stop: rows
   are the selection, and the Photo menu's Keep This Copy / Move This Copy to Trash act on
   them, as VoiceOver custom actions do.
5. **Work that moves is said where it moves.** A leaving row with a like or an edit
   reads `Liked, carried to the kept copy`. A leaving row with sidecar files reads
   `Sidecar files move to the Trash with it`, since companions never carry.
6. **The bar's three zones (DES-018).** What: `110 videos with duplicates` over `110 items
   marked for the Trash · 14.9 GB`. Choices: `6 need your choice · Show`, present only
   while any group waits, blank otherwise. Act: `Move 110 Items to Trash`.
7. **Groups are listed newest first**, by capture date, the order the grid and Photos
   use, so a group found while the user looks joins at its date rather than at the end.
8. **Kept groups stay reachable** under a collapsed `Kept` section, each with `Review
   Again`, which forgets the kept pairs through the same intent undo uses. A kept group
   with no way back is a dismissal the user cannot audit.
9. **The subtitle is honest.** The duplicates list ignores the filter, so the window
   shows no `Filtered` under it.

Rejected:

| Alternative | Why |
| --- | --- |
| Copies side by side in one row, as Photos draws them | Identical copies differ by text, and text compares down a column, not across; versions get Compare. |
| The fate as a two-segment control per row | Two segments per row over hundreds of rows; the HIG's checkbox is the control for one setting that is on or off. |
| A checkbox meaning "move to Trash", the category's convention | Otos's model is which copies are kept, the kept set is what the rule explains, and a positive mark reassures where a destructive one warns (design principles). |
| The reason on the kept row rather than in the header | The reason compares the kept copy with the others, so it belongs to the group; and it is one line the eye reads once per group. |
| A thumbnail per row for identical copies | Two pictures of one frame say nothing one does not, and double the height of every group. |
| Return as the bulk act's key | Unchanged from ADR 0042: Return opens a group. |

## Adversarial reviews

Recorded as they ran. Each review read the spec and a rendering cold, in persona.

### Round 1 — the spec and an HTML rendering

Two cold reviews: a persona walk-through ("Dana", 58, OneDrive folders, Finder and Photos,
never Lightroom, cautious) and a Lens C review against the `DES-*` rules and the HIG.
Findings taken, and the design's answer:

| Finding | Answer |
| --- | --- |
| A waiting group drew every box checked under `Choose one to keep`, so the first click un-kept the copy the user wanted. | A waiting row has no checkbox; it offers `Keep This Copy` (Keep Only), so the first click means keep. |
| The fate was the quietest thing on the row, in L3 grey at the far right, on a line that also said `Keep`. | The checkbox title is hidden; the trailing zone states the fate for every row, `Kept` in L3 colour and `Moves to Trash` in label colour, symbol and word. |
| `Keep` as the checkbox's title dimmed on the kept row of every pair (the last box is disabled). | Only the 14 pt box dims; the row's `Kept` label is a separate text. |
| `marked`, `carried`, `sidecar`, `path order` are model words (DES-035). | `14.9 GB in extra copies`; `Its Like moves to the kept copy`; `.xmp or .srt file`, the names Finder shows; `Keeping the first by name`. |
| The bar said `110 videos with duplicates` over `110 items marked for the Trash` and the button `Move 110 Items to Trash`: one count three times, three nouns, and 110 over 110 read as "all my videos go". | L1 keeps the sidebar's count and noun; L3 owns the bytes only; the button owns the count: `Move 110 Extra Copies to Trash`. |
| `Keep Only ▾` on a library pair had no object and no stated consequence, beside a `Keep Both Libraries` that read as the current state. | Items read `Keep Only Backup`; the pair's L3 states what the marks do (`29,870 copies in Backup move to the Trash`); `Keep One Copy in Each Library` takes a pick back; `Keep Both Libraries` carries a tooltip saying it sets the pair aside and nothing moves. |
| Three decision lines could be false: `first by name` across folders; `the copy you rated` hiding a dislike; `the older file` over two rows showing the same second. | `first by folder and name` when the header names no shared folder; `you liked` / `you disliked`; the rule compares birth times at whole seconds. |
| Two-sentence decision lines (DES-034). | One clause each: `Choose which edited copy to keep`. |
| A cross-library group with an in-library conflict had no line. | `Choose which edited copy in Photos to keep`. |
| Middle truncation could delete the one differing folder (`Day 1` / `Day 2`). | The header names the deepest folder every copy is in or under; rows name the rest. |
| Rows of different heights in one group; version headers at a different left edge. | Every row of a group takes the group's shape; the 64 pt well is reserved for every card and the checkbox sits at its trailing edge. |
| Every card's buttons as Tab stops put the bar 220 Tabs from the list (DES-080). | Card buttons are not Tab stops; the Photo menu's Keep All Copies and Review Again and Return act on the selection. |
| VoiceOver headers all began `2 identical videos`; the date tells groups apart (DES-082). | Headers read the date first, with words for `×` and `▸`. |
| `Kept · 3` said nothing; `Edited` named no app; `Created` beside the header's date looked like a second capture date. | `Kept all copies · 3`; `Edited in Otos`; `Captured …` in the header and `File created …` on the row. |
| No way to try one copy before the bar's act. | The row's context menu carries the ordinary `Move to Trash`. |
| `Camera original` on the row restated the decision line. | Shown on the row only when the line does not name it. |
| `Review Again` had no keyboard path. | Photo ▸ Review Again on the selected kept groups. |

Taken under advisement, not changed:

- **A confirmation before the bulk act.** Dana expects Photos' dialog. The HIG's rule for
  a common, undoable act is no alert (DES-076, ADR 0042), and the act is undoable and the
  Trash recoverable; the button's tooltip says so. Photos confirms a merge, which is not
  undoable.
- **A group joining above the viewport moves rows.** The owner wants every group listed at
  once (ADR 0042); a List keeps its selection by identity, and joins are rare after the
  first build.
- **What Trash means for a OneDrive file.** Otos cannot verify what OneDrive does with a
  trashed file, so it says nothing (design principle: honest or nothing).
- **The dimmed checkbox on every pair's kept row.** The honest state of a control that
  cannot be used; its tooltip is the only meaning it carries, and swapping a pair's keeper
  is check the other, then uncheck this one.

### Round 2 — the built screen on the owner's library

Four captures from the dev build (`OTOS_SMOKE_SELECT_ROOT=duplicates`, dark and light,
top and scrolled), reviewed by two personas — Dana again, and "Marcus", 34, impatient,
40,000 items, wants the space back today — and a Lens C pass with measurements. Findings
taken, and the design's answer:

| Finding | Answer |
| --- | --- |
| Select All then ⌘⌫ moved every copy, kept ones included, and the empty list read as success. | ⌘⌫ on the list moves the selected groups' extra copies only; a kept copy moves now only by its row's `Move to Trash Now`. |
| Nothing said what the act did, or that the Trash is not the space. | The bar's middle zone shows the receipt — `178 extra copies moved to the Trash` with Undo while it is the window's last change, over `Empty the Trash to free the space`. |
| The middle zone was blank with a lone hairline, and a first visit had no sentence saying what the marks mean. | Never blank: the receipt, the groups that wait, or the legend `Checked copies stay. The rest go to the Trash; Undo brings them back.` |
| Files of one photo printed `6192 × 4128 · 39 MB` on both rows — facts that did not differ, against the surface's own rule — under two 128 pt pictures of the same frame, 400 px per group, 2.5 groups a screen. | Format, dimensions and size go on the card when every copy shares them at the shown precision, and on the rows only when they differ; the rows carry pictures only when the pixels or the format differ, else one picture in the card's well. |
| "Versions" means edits to a Lightroom user. | `2 files of one photo`. |
| The checkbox sat 1,000 pt from the word that explained it, and the kept row's dimmed box read as switched off; `Kept` (past) beside `Moves to Trash` (present) asked whether something had already happened. | The checkbox moved to the trailing zone beside its meaning, `Stays` / `Moves to Trash`; in a pair, unchecking the kept copy keeps the other, so no pair has a dimmed box. |
| `Keep Both Copies` made the card vanish into a section at the end of 155 groups; a cautious user read it as a deletion. | A kept group stays in its place as one quiet card, `Kept both copies`, with `Review Again`. |
| The bar's 155 and 178 sat at opposite ends with nothing linking them. | L3 `178 extra copies · 53.2 GB`: the count the button repeats, beside the bytes. |
| The decision line was the dimmest text on the card. | It is the verdict: `.body` in label colour. |
| Two groups of one shot, an ARW pair and a HEIF pair, were told apart only by their rows; `2.6 GB` on an identical group could be one file or both. | The format joins the shared facts; a shared size reads `2.6 GB each`. |
| A full-contrast `Divider` at the list's seam; the first card led with a hairline that separated nothing; the list's backdrop was the platform's, not DES-022's; landscape pictures were letterboxed in a square; a photo glyph stood for a video and never showed failure; card buttons were still Tab stops (`focusable(false)` on a container); a second `No duplicates` in the empty state. | Fixed each: a DES-023 hairline; no seam above the first card; `content` backdrop; a row's picture at its own aspect; the DES-063 kind glyph and its slash variant; `focusable(false)` on each control; the empty state describes, the bar carries L1. |
| `Camera original` on both rows of a pair of originals told nothing apart. | Shown only when not every copy is one. |
| "Keeping the original name" read as the camera original. | `Keeping the original file name`. |
| `items` for a mixed list. | `photos and videos` once every kind is read. |
| `Move to Trash` in the context menu was one letter from the fate word `Moves to Trash`. | `Move to Trash Now`. |
| Space was a dead key. | Space opens the group, as Return does: Lightroom's Loupe toggle. |
| Double-click opened the selection's first group, which could be another group's. | Double-click opens the group of the row clicked. |

Taken under advisement, not changed:

- **A confirmation dialog.** Both personas still half-expect Photos' dialog; the receipt
  with Undo answers the fear it serves (DES-076, HIG Alerts).
- **Sort by size.** Marcus could not find the 0.5 GB videos under newest-first. The
  toolbar's sort control is the place for it, and that is a change to the toolbar's
  contract, not this list; recorded for the owner.
- **The kind headline over the date.** Lens C would lead the card with the date, the fact
  that tells groups apart. The sameness is what the user must trust, so the kind stays the
  headline and VoiceOver leads with the date.
- **⌫ as Don't Keep.** Plain Delete is unbound throughout the app (APP-027).
- **Group-jump keys (⌥↑ / ⌥↓).** Not in Lightroom's map; rows are the selection.

### Round 3 — the built screen after round 2

The same three reviewers on fresh captures. Findings taken, and the design's answer:

| Finding | Answer |
| --- | --- |
| Two screenshots of 116 KB and 108 KB read `Keeping the older file` while the next card read `Keeping the largest file` for 35 and 34 MB: the pixel and size criteria were gated on capture metadata, which screenshots lack. | The keeper rule compares pixels and bytes for every group of files of one photo, metadata or not; sizes compare in bytes, and the rows show bytes when the shown figure ties. |
| `11 MB each` on the card over rows that differed in nothing: the card's rounding hid the difference the rule used. | A size whose shown figure hides a difference in bytes leaves the card; the rows show `11,489,280 bytes`. |
| One picture stood for two files whose sizes differ — a burst looks exactly like that. | The rows carry the pictures when dimensions, format or bytes differ. |
| The card's `Captured` date was the newest copy's, which for a file without capture metadata is its birth time, so a card could date itself after the file it keeps. | The card's date is the kept copy's. |
| "The rest go to the Trash" was unbounded. | `Unchecked copies go to the Trash`. |
| A grey `Stays` read as switched off; the fate words beside the box did not toggle it. | Both fates in label colour, and the words are the checkbox's own title. |
| `Keeping the first by name` stated a tie-break as a merit. | `Alike in every way, so keeping the first by name`; `Nothing told them apart, so …` for files of one photo. |
| A blank L3 under the copy that is not the camera original. | `Not the camera original`. |
| `Compare` on identical copies promised a difference that cannot exist. | `Compare` only on files of one photo; Return and double-click still open an identical group. |
| The receipt dropped the bytes the user came for. | `178 extra copies · 53.2 GB moved to the Trash` over `Empty the Trash in Finder to free the space`. |
| Groups that need eyes were interleaved with groups that do not. | Files of one photo list first, identical copies after, each newest first. |
| Dark pictures vanished on the dark backdrop; the platform's list inset left a band above the first card; the card-to-row gap exceeded the row pitch. | A hairline edge on the picture; an 8 pt top margin; the card's bottom padding removed. |
| `178 extra copies` and the button's count still needed reconciling. | `178 extra copies to move · 53.2 GB`. |

Taken under advisement, not changed: a confirmation dialog (both personas now accept
Undo and the receipt); sort by size and group-jump keys (the toolbar's and the key map's
contract, recorded for the owner); ⌫ as a mark (unbound app-wide, APP-027); dimming the
shared prefix of file names (a refinement for a later pass); naming OneDrive (Otos cannot
verify what a provider does with a trashed file).

Verdicts: Dana, "close, not yet" before the size and picture fixes, which were the ones
she named; Marcus, "would use this instead of Finder, and it is not close", with the same
three fixes between "I'd run it" and "I'd run it on everything".
