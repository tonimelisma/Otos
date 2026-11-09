# People

Status: approved by the owner in chat, 2026-11-10, with the changes noted as owner decisions.

The surfaces for finding and naming the people in the user's photos (ADR 0047, plan 0113
increment 5). Three views share one sidebar row: the **People list**, a **person's scope**
(that person's photos in the ordinary browser), and the **review**, where suggestions are
confirmed, rejected, merged and split, grouped by year. Cites `docs/design/design-system.md`
by ID; rules are not restated. Proposed new rules are marked **[proposed DES-108]** to **[proposed DES-111]**. The
owner's answers to the spec's questions (2026-11-09) are folded in and listed at the end
under **Owner decisions**; items still open are marked **[Q n]**.

The owner's direction (2026-11-07, 2026-11-09): recognition only *suggests*, and nothing is
named until the user confirms it. The hard case is the owner's own children across years,
where siblings at the same age look alike, so correcting a wrong sibling must take one
keystroke or one click, never a hunt.

## Reference

Read 2026-11-09. Adobe's help pages refused automated fetches (HTTP 403), so their content
below comes from search-result extracts of those pages, and the third-party pages were read
directly.

- **Lightroom Classic**
  ([Adobe: Face recognition](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/face-recognition.html);
  [Lightroom Killer Tips](https://lightroomkillertips.com/finding-people-in-lightroom-classic/);
  [Peachpit](https://peachpit.com/articles/article.aspx?p=2337458)):
  - The People view (View ▸ People, **O**) has two areas, **Named People** and **Unnamed
    People**. Unnamed faces come as *stacks* of similar faces, each with a `?`. Typing a name
    under a stack names every face in it, and the stack moves to Named People.
  - Suggested names appear under faces. A checkmark confirms one; retyping or a
    circle-with-slash clears it.
  - Opening a person shows **Confirmed** faces over **Similar** ones.
  - **S** expands or collapses a stack. ⌘-click selects several faces. **⇧O** names the
    selection.
  - A face's context menu has `Find Similar Faces` (⌘F), `Move to Unnamed People` and
    `Remove Face Region`.
- **Lightroom desktop**
  ([Adobe: People view](https://helpx.adobe.com/lightroom/desktop/organize-photos/people-view.html);
  [LRKT: People](https://lightroomkillertips.com/?p=16574);
  [LRKT: merging](https://lightroomkillertips.com/?p=16587)):
  - The People tab shows one cluster per person, with its cover photo and photo count.
  - `Add Name` and `Rename` are on the context menu.
  - Dragging one cluster onto another asks `Are these the same person?`, with `Merge`.
  - `Remove photo from Person` takes a wrong photo out of a person.
  - When new photos arrive, Lightroom asks whether a face belongs to an existing person
    (Yes / No).
  - `Hide Person` and `Show and Hide People` hide people. `Sort By` offers first name, last
    name or count.

**What Otos takes.** Lightroom desktop's single list of people, each with a cover face and a
count, and its context-menu names (`Add Name…`, `Rename…`). Dragging one person onto
another merges them. Lightroom Classic's typed name with completion, ⇧O to name the
selection, and its Confirmed/Similar split, which Otos uses as the list (confirmed) and the
review (suggestions).

**Where Otos deviates, and why:**
- **The review is grouped by year.** Neither Lightroom groups by year. A child's face is
  matched mainly against that child's faces within about two years (ADR 0047), so a year is
  the unit in which a suggestion is right or wrong, and the unit in which siblings at the
  same age sit side by side.
- **No collapsed stacks, and no S.** Every suggested face is shown. A wrong sibling inside
  a collapsed stack is exactly the error the owner needs to see.
- **Merging asks first,** as Lightroom desktop does: `Are these the same person?` with
  `Merge` and `Cancel` (owner decision, 2026-11-10). The merge is also undoable.
- **No face regions drawn by hand, and no keywords.** Lightroom writes person keywords into
  photos' metadata. Otos writes nothing into media folders (ADR 0008): names are overlay.
- **A suggestion is shown only when one person clearly wins.** Lightroom suggests freely.
  Otos follows ADR 0047's margin rule.
- **O is not adopted**, pending [Q 9].

## Terminology

| Term | Means | Not |
| --- | --- | --- |
| **Person** | A named catalog row (name, optional birthday) and the faces confirmed as theirs. | "contact", "tag", "keyword" |
| **Face** | One face Otos found in one photo. | "region", "detection", "embedding" |
| **Suggestion** | A face Otos thinks is one person's, not yet confirmed. | "match", "guess", "candidate" |
| **Unnamed group** | Faces that look alike and match no person. Shown only in the review [Q 1]. | "cluster", "stack" |
| **Checked** | A photo that has a current face reading (ADR 0009 stamp and model revision). | "analysed", "scanned", "processed" |

Forbidden in copy (DES-035): embedding, threshold, margin, score, cluster, revision, chain,
model.

## Sidebar

- **The row:** `People`, SF Symbol `person.crop.square`, directly under `Places`, as a
  top-level row. It exists whenever one fixed library exists, like Places (APP-057).
- **No trailing count** [Q 2]: library rows and Places carry none.
- **No row per person** [Q 1]: a person opens from the People list. While a person's
  scope or the review is open, the People row stays highlighted, as Places does for an area.
- **No progress indicator.** Face reading is enrichment, not an operation with a surface
  (DES-040).

## People list

### L1 primary fact

How many people are named: `14 people`, `1 person`, or `No people` (DES-010).

### Zones

A bar above the list, in the day bar's position. It is 52 pt in every state (DES-018,
DES-053, as DES-105), drawn on the bar chrome with a hairline below.

| Zone | Content |
| --- | --- |
| What | L1 as above, over one L3 clause: `1,820 photos not yet checked for faces`, `1 photo not yet checked for faces`, or `Every photo has been checked`. Both counts are tabular (DES-005). |
| Act | `Review Suggestions`, a plain bordered button (30 pt, DES-051). It is disabled when the review would be empty, with the tooltip `Nothing to review` (DES-038, DES-053). |

The L3 count is the photos in the fixed libraries that are not yet checked. A photo that
cannot be read is not counted, matching the enrichment state that marks it unreadable
(APP-006). Immich photos depend on [Q 7]. The count is a live tally, never a denominator,
and nothing on the surface reads `M of N` or a percentage (*Honest numbers, or none*).

**The list.** The list is a grid of people on the `content` backdrop (DES-022), with the
12 pt section inset and 8 pt gutters (DES-060). It is ordered by photo count, most first,
ties by name in the locale's comparison (owner decision). Counts change only when faces are
confirmed, merged or removed, never while photos are checked, because a person's count is
of confirmed faces: a cell moves only after the user's own act. Each person is one cell:

- **The face:** a 128 pt square face tile (**[proposed DES-109]**) of the person's newest
  confirmed face, so a child looks as they do now; there is no cover picker (owner
  decision).
- **The name:** under the face, `.body` L2, one line, tail-truncated.
- **The count:** under the name, `.subheadline` L3 `312 photos`, tabular. It counts photos
  with a confirmed face of this person, in every library the list spans.

Selection is DES-061's 3 pt accent border on the face, never on the label. The list ignores
the toolbar filter, and the window shows no `Filtered` subtitle here, as with Duplicates.

**Empty states.** The bar is always drawn above them, and the list area holds one centered
L3 sentence, never a `.title2` title. The bar's L1 is the surface's one primary fact
(DES-010), and a title would compete with it and add a fourth size (DES-004).

| State | Bar L1 | List area |
| --- | --- | --- |
| Catalog not loaded | nothing (APP-044) | nothing |
| Nothing checked yet, no person | `No people` | `People appear here as Otos finds faces in your photos.` |
| Faces found, none named | `No people` | `Name the faces Otos found in Review Suggestions.` |
| Every photo checked, no face found | `No people` | `Otos found no faces in your photos.` |
| Libraries offline or being checked | `No people` | the shared `No Available Media` / `Checking Libraries` sentence |

**Acts on the list:**

| Act | Result |
| --- | --- |
| Click | Selects the person. |
| Double-click, or Return | Opens the person's scope. |
| Drag a person onto another | Asks `Are these the same person?` (`Merge`, `Cancel`), then merges the dragged person into the target, which keeps its name and birthday (Lightroom desktop's gesture and alert; owner decision). `Merge Into ▸` asks the same. |
| Context menu | `Rename…`, `Set Birthday…`, `Merge Into ▸` (the other selected people; present only when two or more are selected), `Remove Person`, then `Review Suggestions`. |
| Remove Person | Undoable. The person is gone; every face that was theirs returns to the review as unnamed, and their rejections are forgotten (owner decision). Nothing on disk changes. |

**Merge rules (ADR 0047's hard rules), enforced by disabling the act (DES-038):**
- If the two people have confirmed faces in one photo, `Merge Into ▸` and the drop are
  refused. The tooltip says `Sam and Ian are both in 3 photos`.
- If the target's birthday comes after some of the other person's confirmed photos, the
  merge is refused. The tooltip says `9 photos of Ian are from before Sam's birthday`.

## A person's scope

### L1 primary fact

Whose photos these are: the person's name as the window title, `Sam`. This proposes that
the window title is the ordinary browser's L1, as a library's name already is. No bar is
added: the ordinary browser carries no status surface.

### Content

- **The browser:** the ordinary one (grid, loupe, compare, filter, sort, zoom, day sections
  under Date sort, DES-069). It holds every photo, in the fixed libraries, that has a
  **confirmed** face of the person.
- **Suggestions are not shown here.** A person's photos are only the photos the user
  confirmed (**[proposed DES-110]**).
- **Back:** `Back to People` (`chevron.left`) sits at the toolbar's leading edge, as `Back
  to Map` does. It returns to the list as it was left.

**Correcting a person.** Each photo holds at most one face per person (ADR 0047's
same-photo rule), so a selected photo names one face exactly. On the selected photos:
- **`Not Sam`** removes the name from that face: the face stays a face, returns to the
  review as unnamed, and Otos remembers the rejection, so it never suggests that face as
  Sam again (ADR consequence 1). The photo leaves the scope. Lightroom desktop calls this
  act `Remove photo from Person`.
- **`Not a Face`** removes the face itself: a detection that is not a person's face (a
  poster, a pattern) leaves People entirely, is never suggested or grouped again, and is
  remembered until the photo's file changes. It is a separate act from removing a name
  (owner decision). Lightroom Classic calls it `Remove Face Region`.
- **`This Is ▸`** opens a submenu:
  - every other person who may hold that face, people already in the photo and people
    born after it excluded;
  - a separator;
  - `New Person`.

  The face moves to the chosen person. `New Person` is **split**: the selected faces become
  one new unnamed person, who opens in the review for naming.

**Empty states:** the shared `No Matching Media` with `Clear Filters` when a filter leaves
nothing. If every confirmed face has been taken away, the person shows `No Photos of Sam`
with L3 `Confirm faces of Sam in Review Suggestions.` A person is never removed
implicitly [Q 6].

## Review

### L1 primary fact

The review is two lists, shown one at a time (owner decision, 2026-11-10): **Suggestions**,
where one person clearly beats the runner-up or faces form an unnamed group, and
**Unsure**, where the best two people are too close for Otos to suggest either. Decided and
undecided faces are never mixed, so each can be worked through on its own.

The L1 is the shown list's count: `236 faces to review`, `1 face to review` or `Nothing to
review` in Suggestions; `41 faces to decide`, `1 face to decide` or `Nothing to decide` in
Unsure.

### Zones

A list above a fixed-height bar at the bottom of the content pane, the duplicates bar's
layout and height (DES-018, DES-053).

| Zone | Content |
| --- | --- |
| What | L1 as above, over L3 `1,820 photos not yet checked for faces` / `Every photo has been checked` (the same tally as the list's bar; the two are never on screen together). |
| List | A segmented control at the bar's leading edge, `Suggestions 236` · `Unsure 41`, each segment's count tabular L3 (DES-005). It is the one control that picks the list; ⌘1 and ⌘2 choose a segment. A segment whose list is empty stays, reading `0`, so the control never changes width (DES-053). |
| Middle, behind a hairline | One of two, never blank. The **receipt** of the last act is `Confirmed 12 faces as Sam`, `3 faces are not Sam`, `Moved 2 faces to Ian`, `Named 14 faces Tyler` or `Merged Sam (2) into Sam`, with `Undo` while that act is the window's last change. Otherwise the **legend**: `Select faces and press Return to confirm, or Delete if it isn't them.` |
| Act | `Confirm 12 Faces`, the one prominent button, which Return fires (DES-052). The count is the subset the user selected (DES-036). Disabled, it reads `Confirm Faces`; its tooltip names the reason when a rule blocks it (below). |

No confirmation alert: every act is undoable, and nothing on disk changes (ADR 0008).

### The list

The list is grouped by year (**[proposed DES-108]**), on the `content` backdrop. Its order
is the year of each face's photo capture date, newest first (owner decision). Faces with no
capture date go last, under `No Date`. The whole review is one scrolling list.

- **Year header:** `.headline` `2023`, then `.subheadline` L3 `48 faces to review`. The
  header separates years with a DES-023 hairline, never above the first. It is not sticky:
  the review has no day bar.
- **A person row:** one per person with suggestions in that year. Rows go in the People
  list's order, then unnamed groups. A hairline separates rows.
  - **Row header:** `.body` L2 the name, then `.subheadline` L3 `12 faces · like Sam in
    2024`. The second clause names the year of the confirmed face the suggestion rests on.
    When that year differs from the row's year, the row is a link across years (ADR 0047's
    chaining), and the clause says so in the user's terms. At the header's trailing edge, a
    link-style `Confirm All` confirms the row's faces.
  - **Reference face:** at the leading edge, the confirmed face the suggestion rests on,
    as a 96 pt face tile with no selection, a hairline frame, and its date as L3 under it.
    It is the evidence: telling a sibling apart needs that year's face beside the suggested
    one. It is not a Tab stop and not selectable.
  - **The faces:** 96 pt face tiles (**[proposed DES-109]**), 8 pt apart, wrapping. They
    go in capture order, newest first, each with its date as `.subheadline` L3 under it,
    for example `Mar 4`.
- **An unnamed group row:** the same layout, with no reference face. The header reads L2
  `Unnamed` and L3 `14 faces`, with link-style `Add Name…` and `Ignore` at the trailing edge
  in place of `Confirm All`. Only groups with faces from at least two different days are
  shown (owner decision), so a stranger caught once never enters the review.
- **Faces that could be two people** live in the **Unsure** list, never in Suggestions
  (owner decision): a face where no person beats the runner-up is not a suggestion
  (ADR 0047). Unsure is grouped by year like Suggestions, one row per pair of candidates:
  - **Row header:** L2 `Sam or Ian?`, L3 `6 faces`. No `Confirm All`: there is no answer
    to confirm.
  - **Reference faces:** both candidates' nearest confirmed faces from that year (or the
    nearest year), side by side at the leading edge, each with its name and date as L3, so
    the siblings are compared at the same age.
  - **Acts on a face:** `This Is ▸` lists the two candidates first, then other eligible
    people and `New Person`; ⌘[ and ⌘] confirm the face as the row's first or second
    candidate, Return does nothing; Delete is `Not Sam or Ian` (the face becomes an
    unnamed face again and neither is suggested for it); `Not a Face` and ⇧O as in
    Suggestions.
  - After an act the face leaves Unsure, and the selection moves on, so ⌘[ / ⌘] / Delete
    walk a row from the keyboard.

**Rules the review enforces, each by a disabled act with a tooltip (DES-038):**
- **Same photo:** a face cannot be confirmed as a person already confirmed in its photo.
  Tooltip: `Sam is already in this photo`.
- **Two in one photo:** a selection holding two faces of one photo cannot be confirmed as
  one person. Tooltip: `2 of these faces are in the same photo`.
- **Birthday:** `This Is ▸` and the name completion list only people born on or before
  the photo's capture date. A face with no capture date cannot be excluded this way, so it
  is offered to everyone.

### Acts

All of these, from buttons, menus, keys, drags and VoiceOver, call one owner intent each on
`CatalogWindowViewModel`.

| Act | Pointer | Key | Result |
| --- | --- | --- | --- |
| Select | click, ⌘-click, ⇧-click; a click on a row header selects its faces | arrows (below), ⌘A | — |
| Confirm | bar button; `Confirm All` on a row | Return | The faces become the suggested person's and leave the review. |
| Reject the name | context menu `Not Sam` (`Not This Person` in an unnamed group) | Delete | The face leaves the suggestion and is never suggested as that person again. It may then reappear as someone else's suggestion. |
| Remove the face | context menu `Not a Face` | — | The detection leaves People entirely and is never grouped or suggested again (owner decision: removing a face is a separate act from removing its name). |
| Ignore a group | `Ignore` at an unnamed row's trailing edge, beside `Add Name…` | — | The group leaves the review and its faces are never grouped or suggested again; undoable, remembered (owner decision). |
| Move to a person (sibling fix) | context menu `This Is ▸` with the runner-up first, other eligible people, a separator, `New Person`; or drag faces onto another row in the same year | — | Confirms the faces as the chosen person. `New Person` splits them into a new unnamed person. |
| Name | `Add Name…` on an unnamed row; context menu `Name…` | ⇧O | A popover anchored to the selection with one field that completes eligible names. Return commits: an existing name confirms the faces as that person, which is how an unnamed group merges into a person (Lightroom Classic's rule: the same name merges), and a new name creates the person. Escape cancels. |
| Open the photo | double-click | Space | Opens the face's photo in Loupe, with the row as the filmstrip. `Back to Review` returns. |

**Keys.**
- **← / →:** the previous and next face in reading order, across rows and years.
- **↑ / ↓:** the face at the same position in the previous and next row.
- **After an act:** the selection moves to the face after the last one acted on, so
  Return, Return, Delete, Return walks a row without the pointer.
- **⌘⌫ is disabled here,** with the tooltip `Select photos in a person to move them to the
  Trash`. Delete means "not this person", so ⌘⌫ must never move a photo to the Trash from
  one key away (the reasoning of DES-052's duplicates deviation).

In **Unsure**, ⌘[ and ⌘] confirm the selected faces as the row's first or second candidate,
and Return confirms nothing.

**[proposed DES-111]** extends DES-093's Lightroom keys with ⇧O (Name…) in the review.
**[deviation:** a key without ⌘, which DES-093 already allows for Lightroom's own keys;
the source is Lightroom Classic**]**. Return and Delete are ordinary keys.

**How the list changes under the user.** When faces are confirmed, the next year's
suggestions may arrive, because a confirmed face is new evidence for chaining. New rows
join in their place. The viewport keeps the item at its top edge at the same offset, as
APP-033 anchors the grid. A row whose last face leaves closes up. Moves animate position
only (DES-074). A face tile that has painted is never blanked while it stays on screen,
the grid's no-blank rule applied to faces.

**Empty states.** The list area holds one centered L3 sentence, as on the People list:

| State | Bar L1 | List area |
| --- | --- | --- |
| Nothing found yet, photos not yet checked | `Nothing to review` | `Suggestions appear here as Otos finds faces.` |
| Nothing to review, photos not yet checked | `Nothing to review` | `More suggestions may appear as photos are checked.` |
| Nothing to review, every photo checked | `Nothing to review` | `Every face Otos is sure about has been reviewed.` |

## Person sheet (naming and birthday)

`Rename…` and `Set Birthday…` open one sheet (DES-041), focused on the row the command
names.

| String | Level |
| --- | --- |
| Title: the name, or `New Person` | L1, as DES-095's sheet title |
| `Name` (text field), `Birthday`: a year field, empty when the year is unknown, then a checkbox `Exact date` beside a date picker, disabled, never removed, while unchecked (DES-053, DES-054). A year alone is enough (owner decision, 2026-11-10): it counts from 1 January, and sets the age from which the person's faces are compared across all years. | L2 controls, `.callout` field labels on one label column (DES-016) |
| Footnote: `Faces from before this date are never suggested as Sam.` | L3 |

- **Buttons:** `Save` (default) and `Cancel` (cancel action).
- **Save is disabled** when the name is empty, with the tooltip `Enter a name`. It is
  also disabled when the birthday comes after some of the person's confirmed photos, with
  the tooltip `4 confirmed photos of Sam are from before this date`. A saved birthday
  never silently drops a confirmed face.
- **Duplicate names:** a name that another person already holds is refused, with the
  tooltip `Another person is named Sam. Merge them instead.`

## Levels, summarised

| Surface | L1 | L2 | L3 | Sizes |
| --- | --- | --- | --- | --- |
| People list | `14 people` | names, `Review Suggestions` | `1,820 photos not yet checked for faces`, `312 photos`, empty-state sentences | 15, 13, 11 |
| Person's scope | window title `Sam` | the ordinary browser | the ordinary browser | as the browser |
| Review | `236 faces to review` (Suggestions) or `41 faces to decide` (Unsure) | person names, `Unnamed`, `Confirm All`, `Add Name…`, receipt, `Undo`, `Confirm 12 Faces` | year counts, `12 faces · like Sam in 2024`, face dates, the legend, empty-state sentences | 15, 13 (`.headline` year, `.body` rows), 11 |
| Person sheet | the name | fields | footnote | as the export sheet |

Two weights at most per surface (DES-004).

## Face tiles [proposed DES-109]

- **The crop:** a square, aspect-filled from the photo's stored preview (ADR 0035), about
  the face box enlarged by 1.6 and clamped to the photo, at radius 4.
- **[deviation from DES-060A]:** a face tile is a crop by definition, since its content is
  the face rather than the frame. DES-103's Places stacks already aspect-fill for the same
  reason.
- **Before the first decode:** the DES-063 glyph `person.crop.square` at tertiary
  strength, and its slash variant when the preview cannot be read.
- **Once painted:** a tile is kept for the same face (the no-blank invariant).
- **No badges** on a face tile.
- **Selection:** DES-061's 3 pt accent border.

## Appearance and accessibility

- **Light and dark (DES-022):**
  - backdrops are `content`;
  - both bars are bar chrome;
  - hairlines follow DES-023 and DES-084;
  - the accent appears only on selection, the prominent `Confirm` and focus rings
    (DES-024).
- **Grayscale (DES-029):** no state on these surfaces is carried by colour.
  - Selected faces carry a border.
  - The reference face is told apart by position, frame and date, not tint.
  - A suggestion and a confirmed face are never on one surface: a person's scope holds only
    confirmed photos, and the review only suggestions.
- **Keyboard only (DES-080, DES-081):**
  - **The People list:** Tab reaches the bar's button, then the list. In the list, the
    arrows move and Return opens.
  - **The review:** Tab reaches the list, `Undo` and `Confirm`. The row links are reached
    by VoiceOver actions, not Tab, as in Duplicates.
  - **Everywhere:** Escape clears the selection and closes the name popover. Focus rings
    are never suppressed.
- **VoiceOver (DES-082, DES-083, DES-085):**
  - A person cell reads `Sam, 312 photos`.
  - A review face is one button reading `March 4, 2023, suggested as Sam` (or `in an
    unnamed group`). Its custom actions are `Confirm`, `Not Sam`, `This Is…`, `Name…` and
    `Open Photo`.
  - A row header reads `Sam, 12 faces, like Sam in 2024`.
  - The bar's L1 is a live region announced when it changes between zero and not zero,
    never on each count change.
- **Reduce Motion (DES-075):** rows closing up and arriving cross-fade in 0.15 s, and
  nothing translates. The name popover appears without its zoom.

## Undo

Every act goes on the window's one undo stack (APP-039), named by the act, for example
`Undo Confirm`, `Redo Confirm`, `Undo Not Sam`, `Undo Move to Ian`, `Undo Split`,
`Undo Name`, `Undo Merge`, `Undo Rename`, `Undo Set Birthday`, `Undo Not a Face`,
`Undo Ignore` and `Undo Remove Person`. Undo is also reachable
from the review receipt's `Undo`.

- **What undo restores:**
  - an undone confirm returns the faces to the review as suggestions;
  - an undone reject forgets the rejection;
  - an undone merge restores both people with their own faces, names and birthdays;
  - an undone split returns the faces to the person they left.
- **Undo shows what it changed:** an undo whose faces are off screen selects them and
  scrolls to them, or opens the person's scope that holds them (HIG Undo, `hig-validation.md`
  F-18).
- **Suggestions that depended on an undone confirm** leave with it. They were never facts.
- **Lifetime:** undo entries live in memory for the session. Confirmations are catalog
  writes and persist.

## Proposed design-system rows

- **DES-108 (People surfaces):** a 52 pt list bar, L1 the people count, L3 the tally of
  photos not yet checked. A person's scope is the ordinary browser of confirmed photos,
  with `Back to People`. The review is grouped by year over the duplicates bar's layout,
  L1 the faces to review, its one prominent act `Confirm N Faces` on Return.
- **DES-109 (face tiles):** the face tile above, with its deviation from DES-060A.
- **DES-110 (suggestions are never facts):** a suggested name appears only in the review,
  always as a suggestion. It never appears in a person's scope, the Info pane, a tile or a
  count of a person's photos.
- **DES-111 (review keys):** Return confirms, Delete rejects, ⇧O names, Space opens the
  photo, ⌘1/⌘2 pick Suggestions or Unsure, ⌘[ / ⌘] pick an Unsure row's first or second
  candidate, and ⌘⌫ is disabled in the review. The ⇧O part is a deviation extending DES-093.

## Consequences for ADR 0047 (to amend before code)

1. **Rejections are stored.** A `Not Sam` must persist as a (face, person) exclusion.
   Otherwise the same suggestion returns at the next grouping pass. ADR 0047's `face` row
   holds only an assigned person.
2. **Unnamed groups need a rule.** ADR 0047 compares new faces with *confirmed* faces only.
   With no person confirmed, nothing is ever suggested, so something must group unconfirmed
   faces among themselves for the first naming. The research labelling did this with
   model-built groups. The policy (threshold, margin, the same-photo rule, other days) is a
   grouping decision, not a design one.
3. **Unnamed people.** `New Person` (split) creates a person with no name until the user
   names them. ADR 0047's person row needs its name to be optional, or split must ask for a
   name at once [Q 6].

## Verification

- **The window capture:** the People UI increment adds `people` and `people-review` to
  `script/smoke-run.sh`'s selectable roots (beside `places` and `duplicates`). With
  `--verify` and the appearance and capture variables, it writes the window's rendering in
  light and dark. A grayscale pass is made on one capture (DES-029).
- **The tiles:** face tiles are SwiftUI images inside the list and come through the
  capture.
- **Logs:** counts and acts are checked from `op=people.*` log lines, carrying the people
  count, the faces to review and each act's face count.

## Not in this spec

- Face boxes drawn on the loupe, and drawing a face region by hand.
- People in the Info pane, and searching or filtering by person.
- Reading or writing face regions in files' XMP, or names into exported copies: never
  (owner decision, 2026-11-10).
- Pets.
- Hiding a named person (an unnamed group can be ignored; a named person can be removed).

## Owner decisions (2026-11-09)

1. **Sidebar:** one `People` row; no row per person; unnamed groups only in the review.
2. **People list order:** most photos first, ties by name.
3. **Cover face:** the newest confirmed face; no picker.
4. **Review order:** newest year first, all years in one scrolling list.
5. **Unsure faces:** shown in their own list, **Unsure**, separate from Suggestions, grouped
   by year as `Sam or Ian?` rows with no suggested answer, so the user dispositions them
   apart from the decided ones (2026-11-10).
6. **Strangers:** only unnamed groups seen on at least two days are shown, and `Ignore`
   (undoable, remembered) dismisses one.
7. **Removing:** `Remove Person` exists (undoable); a split creates an unnamed person named
   later; removing a name from a face (`Not Sam`) and removing a face (`Not a Face`) are
   separate acts.
8. **Immich:** Immich photos are read for faces. How (from originals downloaded for it, or
   from the preview Immich already supplies) is decided on measurement in plan 0113 [Q 7].

**Defaults taken, not yet confirmed by the owner:** no count on the `People` row (as Places);
no bare `O` key; no per-person review (the review is one surface).

## Open questions for the owner

Each has a recommended default; nothing below is decided until the owner answers.

1. **Do people appear as sidebar rows?** This covers named people under `People`, and
   whether unnamed groups appear anywhere outside the review. *Default:* no per-person rows,
   because the sidebar would grow by dozens of rows and Places sets the pattern of one row
   with a detail; unnamed groups appear only in the review.
2. **Does the `People` row carry a count, and of what?** The faces to review, or the
   people. *Default:* none, matching Places and the library rows.
3. **What order is the People list in?** By name, by photo count, or by most recent photo.
   *Default:* by name. A count order would move cells under the pointer while photos are
   checked.
4. **Which face is a person's cover?** *Default:* the newest confirmed face, so a child
   looks as they do now, with no way to choose another. Lightroom desktop lets the user set
   a cover; offering that would be a new affordance.
5. **How is the review ordered and paged?** Newest year first or oldest first, and all
   years in one list or one year at a time. *Default:* newest first, all years in one
   scrolling list. The user names a child's current face first, and chaining then reaches
   back a year at a time.
6. **Can a person be removed, and must split name the new person at once?** *Default:*
   offer `Remove Person` (undoable; its faces return to the review as unnamed). Split
   creates an unnamed person, named later from the review.
7. **Are Immich photos read for faces?** Their originals are downloaded only for the
   user's own work (APP-067), so they are never checked in the background. *Default:*
   exclude them from People and from the not-checked tally, so the tally can reach zero.
   Otherwise the owner decides to allow background downloads for faces.
8. **Which unnamed groups are shown, and can a stranger's group be dismissed?** Without a
   dismiss, strangers' faces keep the review from ever reaching `Nothing to review`.
   *Default:* show only groups with faces from at least two different days, and offer
   `Ignore` (remembered and undoable). Lightroom desktop's `Hide Person` is the reference.
9. **Should bare O go to People,** as Lightroom Classic's People view key? *Default:* no
   bare key. A bare O would be a second deviation beyond ⇧O, for a row one click away.
10. **Are faces that could be either of two people shown?** These are faces where the best
    person does not clearly beat the runner-up, the sibling case. *Default:* show them per
    year in a last row, `Sam or Ian?`, with no suggested answer and no `Confirm`. Only
    `This Is ▸` and ⇧O act on them. This keeps the margin rule (nothing is *suggested*)
    while making the sibling cases findable. The alternative is never showing them.
11. **Does a person's scope offer reviewing only that person's suggestions?** *Default:*
    no. The review is one surface, grouped by year.
