# People

Status: approved by the owner in chat, 2026-11-12 (the redesign around auto-tagged faces,
replacing the review of 2026-11-10); built (APP-072). Its rules are DES-109 to DES-111 and
DES-113.

The surfaces for the people in the user's photos (ADR 0047): the **People gallery**, a
**person's photos** (a leaf under People, over every library), the **photo menus**' face acts
and the **Info pane**'s People section. Cites `docs/design/design-system.md` by ID; rules
are not restated.

The owner's direction (2026-11-12): every face is found and goes to its most likely person,
siblings included; named and unnamed people are one kind; a face whose name the user
removes shows the people it most likely is but is never given one again by Otos; faces are
compared with how a person looked at that time; moving photos between people must be
quick; people merge by name; a person's page is a filter; hidden people are seen only in
the gallery; favourites come first.

## Reference

Read 2026-11-12: Immich's People page, person page, asset viewer face editor and search
filters, from its English UI strings and web source (`i18n/en.json`;
`web/src/routes/(user)/people`; `web/src/lib/components/faces-page/PersonSidePanel.svelte`;
`web/src/lib/components/shared-components/search-bar/SearchFilters.svelte`) and
[its facial recognition docs](https://docs.immich.app/features/facial-recognition).

- **Immich:** every cluster is a person; naming one sets a field, and a name another person
  holds asks `Are these the same person?`. The People page shows everyone, with `Show &
  hide people`. A person's page offers the name, birth date, feature photo, hide, merge and
  `Fix incorrect match` (reassign selected photos to another or a new person). The asset
  viewer's `Edit faces` lists each face of the photo, `Unassigned` when it has no person,
  with another person, a new person, or `Delete face`. Search filters by People and Places.
- **Lightroom Classic:** faces in Named People and Unnamed People stacks; `Remove Face
  Region`. Lightroom desktop: one list of people, merge by dragging one onto another.

**What Otos takes:** Immich's one kind of person, its merge on a taken name, a person's
settings, reassigning photos and its per-face editor; Lightroom desktop's drag to merge.
**Where Otos deviates:** a person's photos are a leaf under People in the ordinary
browser, not a page of their own; a face
with its name removed is never given a person again by Otos; Otos ranks the people a face
or a selection of faces could be; no face is drawn by hand (Immich's `Tag People`); nothing
is written into media folders (ADR 0008).

## Terminology

| Term | Means | Not |
| --- | --- | --- |
| **Person** | A catalog row with an optional name, birthday, key photo, favourite and hidden mark, and the faces that are theirs. | "contact", "tag", "cluster" |
| **Face** | One face Otos found in one photo. | "region", "detection", "embedding" |
| **Unidentified** | A face with no person. | "unassigned", "unknown", "unnamed" |
| **Unnamed** | A person without a name: `Unnamed Person` where only text fits, a link-style `Add Name…` where a control fits, so it never reads as someone called Unnamed. | "unknown person", "group" |
| **Key photo** | The face a person is shown by, as Photos calls it. | "feature photo", "cover" |
| **Hidden** | A person the user hid: seen only in the gallery. | "ignored", "removed" |
| **Checked** | A photo whose faces stamp names its current source (ADR 0047; a new analysis revision clears the stamp). | "analysed", "scanned" |

Forbidden in copy (DES-035): embedding, threshold, margin, score, cluster, seed, guess,
confidence, model.

## Sidebar

- **The row:** `People`, SF Symbol `person.crop.square`, a top-level row under
  `On This Day` and before `Places` — the ways to browse the whole library sit together
  (owner decision, 2026-11-12). It exists whenever one fixed library exists (APP-057).
- **No trailing count and no row per person.** The row stays highlighted while the gallery
  shows and while a person's photos under it are open.
- **No progress indicator.** Face reading is background work with no status surface (DES-040).

## People gallery

**L1:** how many people every surface offers, the visible ones: `14 people`, `1 person`,
`No people` (DES-010).

**Bar:** 52 pt in every state (DES-018, DES-053), bar chrome with a hairline below: L1 over
L3 `1,820 photos not yet checked for faces` / `Every photo has been checked`, tabular. No
act.

**The grid:** 128 pt cells, 8 pt gutters, 12 pt inset, on `content` (DES-022, DES-060).
- **Order:** favourites, then most photos, a named person before an unnamed one of the
  same count, then the name in the locale's order. Then, under a `Hidden` header
  (`.headline`), the hidden people in the same order, dimmed to half.
- **A cell:** the key photo's face tile (DES-110), else the newest face; under it the
  name (`.body`) or, for an unnamed person, a link-style `Add Name…`; a secondary
  `heart.fill` before the name of a favourite; `312 photos` (`.subheadline` L3, tabular),
  counting a photo once however many identical copies of it hold the face (ADR 0054).
- **Who is listed:** everyone with a face, and everyone the user named, gave a birthday,
  favourited or hid. A person Otos found is listed once their faces span two days; a face
  matching nobody that is seen on one day only stays unidentified, so strangers do not
  fill the gallery.

**Acts:**

| Act | Result |
| --- | --- |
| Click, ⌘-click, ⇧-click, arrows | Selects people. |
| Double-click, Return, `Show Photos` | Opens the person's photos. A hidden person does not open. |
| `Add Name…` / `Rename…`, `Set Birthday…` | The Person sheet. |
| `Add to Favorites` / `Remove from Favorites` | Undoable. |
| `Merge Into ▸` | With two or more selected: asks first. |
| Drag a person onto another | Asks `Are these the same person?` (`Merge`, `Cancel`), then merges. |
| `Hide` / `Unhide` | Undoable. A hidden person leaves every filter and menu; Unhide is the only act on one. |

**Merging:** the person dragged (or named) is merged into the one dropped on (or holding
the name), which keeps its name, birthday and key photo, taking the other's where it
has none, and is a favourite if either was. Refused, by a disabled act with its reason
(DES-038), when the user's faces or the faces a person was first found from put both in
one photo (`Sam and Ian are both in 3 photos`) or a photo the user gave either predates
the birthday kept. The question is judged when asked; the answer `Merge` is judged by the
catalog when the merge is applied, after any act submitted before it (a birthday saved with
a taken name). Should it refuse there, `Couldn't Merge These People` says why in the same
words, with `OK`, and nothing moves. Until the catalog answers, the person merged away is
still the one shown and filtered, even when the People list without them arrives first; its
confirmation names the person merged into, who takes their place. A redo of a merge is that
merge, and lands the same way.

**Empty states:** one centered L3 sentence under the bar: `People appear here as Otos
finds faces in your photos.`, `People appear here once Otos finds the same face on
different days.`, `Otos found no faces in your photos.`, or the shared `No Available Media`
/ `Checking Libraries` sentence.

## A person's photos

- **What it is:** a leaf under the People row, as an area is under Places: the ordinary
  browser over every fixed library's photos of the person, with the People row still
  highlighted. Every view mode, sort and filter works; the filter set in the gallery is
  kept, and checking people in it narrows to photos with them too. Choosing any other
  sidebar row leaves it.
- **Title:** the person's name.
- **Toolbar:** `Back to People` (`chevron.left`) at the leading edge; it keeps the filter.
  It exists only in this leaf, so it never stands beside Back to Map. Beside it, a menu
  titled with the person's name and
  `person.crop.circle`: `Add Name…`/`Rename…`, `Set Birthday…`, `Add to Favorites`/`Remove
  from Favorites`, `Merge Into ▸` (the other visible people with a name: an unnamed one reads
  `Unnamed Person`, so no row could be told from another), `Hide`.
- **Likeness sort:** `Likeness — Least Like Sam First` and `Likeness — Most Like Sam
  First` in the Sort menu, beside Date, Filename and Size: how like the person each photo's
  face of theirs is, so the faces most likely wrong come first. Disabled, never hidden,
  outside a person's photos (DES-053); the reads then use the default order.
- **Hidden or merged away while shown:** hiding the person returns to the gallery, where a
  hidden person is still seen; merging them into another shows the one they became.

## The People filter

A section of the filter popover, under the file types:
- **Rows:** a checkbox per visible person with a name, in the gallery's order; then
  `Unidentified Faces`. An unnamed person is not offered: every one reads `Unnamed Person`, so no
  row could be told from another (owner, 2026-11-12). The first five people show;
  `Show All 23 People` lists the rest in place and `Show Less` folds it back, and the whole
  list gains `Search People` once there are more than eight. A checked person always shows,
  so the filter never holds a row the user cannot see.
- **Several rows checked** narrow to photos with all of them together: Sam and Ian is
  the photos of the two of them, and with `Unidentified Faces` a face of no one besides
  (owner, 2026-11-12). There is no "any of them".
- **Hidden or merged people** leave the filter when People next publishes.

## The filter's reach

A filter belongs to the sidebar row it was set in (owner decision, 2026-11-12). Choosing
another row starts that row unfiltered; the leaves under a row (a person under People, an
area or a stack under Places, a group under Duplicates) and Back from them keep it, so a
stack's count is what it opens on. This is Lightroom Classic's Library filter with its
lock off; Otos has no lock and remembers no filter per row, since either is a filter
in force that the user did not just set.

## Face acts

A face is one of three: a **named** person's, an **unnamed** person's (a person Otos found
whom the user has not named), or **unidentified**. Every act answers one question, who is
this, and says how many photos it changes (owner, 2026-11-12). An act is a verb phrase, and
a list of people sits under the words its items complete (HIG Menus: `Sort by ▸ Date`), so
`Change to ▸ Sam` reads as the act it is. The same acts, names and rules on every surface
(DES-113), each one undoable intent:

| Act | Offered on | Result |
| --- | --- | --- |
| `Change to ▸` a person | A named person's faces | The faces are that person's, on the user's word. |
| `Assign to ▸` a person | Unidentified faces | The same; across several photos, the face in each most like them. |
| `Someone Else…` | Last under `Change to` and `Assign to` | The Person sheet, which suggests people's names as the user types. Save gives the faces to the person with that name, or to a new person when no one has it. |
| `Name This Person ▸` a person | An unnamed person | The whole person, every photo of them, is that person: a merge, asked first. Otos's grouping is trusted, so naming acts on all of it. |
| `New Name…` | Last under `Name This Person` | The Person sheet names the whole person. A name another person has asks to merge. |
| `This Is Not Sam` | A named person's faces | The faces lose their person and Otos never gives them one again; the people they most likely are stay offered, Sam left out. |
| `Not the Same Person` | An unnamed person's faces, only in that person's own photos | The same act: there the user sees the photos the face was grouped with. Elsewhere an unnamed person is corrected by naming them first, then `This Is Not <name>`. |
| `This Is Not a Face` | Every face | The detection leaves People until the photo's file changes: a face the finder saw in a print, a doll or a pattern. |
| `Make Key Photo for Sam` | A named person, one photo targeted, not a video | That face is Sam's cover in the gallery (Photos' name for it). A video's face is one frame of many, so it is never offered there. |

**The lists** are short enough to read at a glance and need no typing in the usual case:
the five people the faces most likely are, most likely first, filled in gallery order when
fewer are likely; then `Someone Else…` or `New Name…` for everyone else. Only visible people
with a name are listed, since several unnamed people would read alike; the hard rules leave
out anyone the faces cannot be (DES-038): a photo the user already gave them another face
of, two faces of one photo, a photo from before their birthday. Under `Name This Person`,
the rules of a merge apply instead (see Merging).

**Counts** say how many photos an act changes, and name what they hold: `photos`, `videos`
when all are videos, `photos and videos` once both are, `Photos & Videos` in a menu
(owner decision, 2026-11-13). A library's and an Immich account's video faces are People's too, one face per
person per video, its tile cut from the frame it was read in (ADR 0047):
- **An unnamed person:** always every photo of them, since naming acts on all of them:
  `Unnamed Person · 14 Photos ▸`, and `14 photos` under the Info pane's `Add Name…`.
- **A named person with several photos targeted:** how many of those photos hold them:
  `Sam · 3 Photos ▸`. With one photo, no count: the acts change that one face.
- **Unidentified faces across several photos:** `Unidentified Faces · 3 Photos ▸`.

### Photo menus

The grid, filmstrip, loupe and compare context menu, after `Reveal in Finder`:
- **One entry per visible person** with a face in the targeted photos, in the order their
  faces come. One level of submenu (HIG); a list sits under a section header inside it.
  - **Named:** `Sam ▸` (`Sam · 3 Photos ▸` for several photos): `Change to` with the
    people and `Someone Else…`, a separator, `This Is Not Sam`, `This Is Not a Face`, and
    `Make Key Photo for Sam` with one photo.
  - **Unnamed:** `Unnamed Person · 14 Photos ▸`: `Name This Person` with the people and
    `New Name…`, a separator, `This Is Not a Face`.
- **Unidentified:** with one photo, one `Unidentified Face ▸` per face, so every act means
  one face: `Assign to` with the people and `Someone Else…`, a separator, `This Is Not a
  Face`. With several photos, one `Unidentified Faces · 3 Photos ▸` entry, offered only when
  no targeted photo holds more than one unidentified face; otherwise none, since no item
  could say which face it means.
- **One entry only** (a photo with one face, wherever it shows): its acts sit at the menu's
  top level under a section heading with the entry's title, the list as a submenu — `Sam`,
  then `Change to ▸`, `This Is Not Sam`, `This Is Not a Face`, `Make Key Photo for Sam`.
  No other face's acts are there to be mistaken for them, and the heading says whose they
  are. With two or more entries, each is a submenu, in the order the faces come.
- **In an unnamed person's own photos** their entry also offers `Not the Same Person`.

### Face outlines

Highlighting a face item in a photo menu outlines the faces it acts on: a person's entry and
every act under it, that person's faces; a choice, the faces it would give. Two people
without a name both read `Unnamed Person`; the outline is how they are told apart. The
faces are outlined wherever their photos show — the loupe, both compare panes, grid and
filmstrip tiles — whether or not the Info pane is open, in DES-061's 3 pt accent border,
carried through the edit the picture shows (its crop and straighten); a tile still showing
a placeholder draws none. A video's face is never outlined: its box belongs to the frame
it was read in, not to what the video shows (owner decision, 2026-11-13). Closing the menu
clears them.

### Info pane

The first section (DES-088), `People`:
- **One photo:** each face of a visible person or unidentified, in reading order: a 40 pt
  face tile, the name, a link-style `Add Name…` with `14 photos` (L3) for a person without
  one, or `Unidentified` (secondary), and an `ellipsis.circle` menu with the face acts, the
  same words and sections as the photo menu's entry. An unidentified face shows the three
  people the ranking says it most likely is as small bordered buttons, one click each; until
  it is ranked the row keeps the buttons' height empty, so no button names a person only the
  gallery's order put there or moves under the pointer. `No Faces` once the catalog says the
  photo was checked and holds none, `Not Checked Yet` before; `—` while that is unknown, or
  when its only faces are a hidden person's. A photo checked while it is shown says so without
  being reselected.
- **Several photos:** each visible person in them with `12 photos` (an unnamed person: every
  photo of them), and the unidentified faces with `5 photos` and the three people they most
  likely are as buttons, under the photo menu's rule: only when no photo holds more than one.
  With none listed, `—`.
- **Hover:** pointing at a row outlines its faces on their photos (see Face outlines). Another
  target, folding the section or hiding the pane lets go of it.

## Person sheet

`Add Name…`, `Rename…`, `Set Birthday…`, `New Name…` and `Someone Else…` open one sheet
(DES-041).

| String | Level |
| --- | --- |
| Title: the name; `Name This Person` for a person without one; `Name This Face` / `Name These Faces` for `Someone Else…` | L1 |
| `14 photos`: the photos Save changes, over a row of up to eight of the faces, newest first, so the user sees who is being named | L3 |
| `Name` (text field, suggesting the visible named people whose name holds what is typed), `Birthday`: a year field, then `Exact date` with a date picker, disabled, never removed, while unchecked (DES-053, DES-054). A year alone counts from 1 January. | L2 controls |
| Footnote: `Faces from before this date are never given to Sam.` | L3 |

- **Buttons:** `Save` (default) and `Cancel`.
- **Save is disabled** with the reason as its tooltip (DES-038), never pressed for nothing:
  `Enter a name`; `Enter a year, or a full date`; `4 photos of Sam are from before this
  date` (photos the user gave her); for `Someone Else…` with a new name, `2 photos are from
  before this date`; a name a hidden person has, `Ian is a hidden person`; and a taken name
  whose act the hard rules refuse, that act's reason (`Sam and Ian are both in 3 photos`,
  `Sam is already in this photo`).
- **A name another visible person has** is otherwise not refused: for a person, Save keeps
  the birthday typed, then asks `Are these the same person?` and merges on `Merge`; for
  `Someone Else…`, the faces go to that person, and a birthday other than theirs is refused
  with `Clear the birthday to give these faces to Sam`.
- **`Someone Else…` with a new name** makes one new person with the name and birthday typed:
  one act, one undo.

## Appearance and accessibility

- **Light and dark (DES-022):** backdrops `content`, bars bar chrome, hairlines DES-023;
  the accent only on selection, the face outline and focus rings (DES-024).
- **Grayscale (DES-029):** selection is a border; a favourite is a glyph; a hidden person
  is dimmed and under its own header.
- **Keyboard (DES-080, DES-081):** in the gallery the arrows move — Up and Down keep the
  column within the visible people's rows and the hidden people's, crossing the `Hidden`
  header into the nearest row — Return opens, Escape clears the selection, and the gallery
  draws its focus ring. The context menu's acts for the selected person (the one the keys
  last reached) are also at the end of the menu bar's Photo menu, in the same words, with no
  keys of their own, disabled with `Select a person in People` while none is selected; every
  face act is in a menu reachable from the keyboard.
- **VoiceOver:** a cell reads `Sam, 312 photos` with `favorite` or `hidden` when so, opens
  as its default action, and offers the context menu's acts as its actions (`Merge Into
  Sam` for each merge); the Info pane's face menu is `Actions for Sam`.
- **Reduce Motion (DES-075):** nothing on these surfaces translates.

## Undo

Every act goes on the window's one undo stack (APP-039), named by the item that made it and
how many photos it changed: `Undo Name 3 Photos` (Change to, Assign to, Someone Else…, and
naming an unnamed person with Add Name… or New Name…; `Name This Person ▸` a person is
`Undo Merge`), `Undo This Is Not Sam`, `Undo Not the Same Person`, `Undo This
Is Not a Face`, `Undo Make Key Photo for Sam`, `Undo Edit Person`, `Undo Merge`, `Undo
Hide`, `Undo Unhide`, `Undo Add to Favorites`, `Undo Remove from Favorites`. An undo writes
back exactly what the act changed, and a redo writes back the state the act left, so a person
the act created returns as themselves and the acts after it redo too; undoing several acts
and redoing one keeps the rest to redo. The guesses that followed are rebuilt by assignment
(ADR 0047). Entries live for the session.

## Owner decisions

- 2026-11-12 (face menus): every act says who and how many: `Change to ▸` / `Assign to ▸`
  with the five likeliest people and `Someone Else…`; an unnamed person is named as a whole
  (`Name This Person ▸`, `New Name…`, with every photo of them counted), is corrected only
  in their own photos (`Not the Same Person`), and gets no key photo; several photos offer
  unidentified faces only when each holds at most one; faces are outlined on the loupe and
  compare whether or not Info is open.
- 2026-11-13 (videos): a library's videos are read for faces from six frames, one face per
  person per video, downloading each video once; counts say `photos and videos` once both are;
  a video's face is never outlined and offers no `Make Key Photo`.
- 2026-11-13 (Immich videos): an Immich account's videos are read for faces too, in byte
  ranges from the server, never downloaded.
- 2026-11-12 (one face): a photo menu with one face entry, wherever it opens, puts its acts at
  the top level under a heading naming whose they are; the person whose photos are shown is
  not moved first or flattened beside other faces (two faces flattened together read as one
  list).
- 2026-11-12: a person without a name never reads as a name (`Add Name…` where a control
  fits, `Unnamed Person` elsewhere) and is offered naming first; the face acts take Photos'
  words where they fit (`This Is Not Sam`, `This Is Not a Face`, key photo) and HIG title
  case.
- 2026-11-12: auto-tagged faces, named and unnamed one kind, no review; a removed name is
  never filled again by Otos; corrections move the guesses chained through them; people
  seen on one day stay out of the gallery until named; the likeness sort; hidden people
  only in the gallery, with no `Show Hidden` toggle; favourites first; the Info pane's
  sections People, Location, File first; a Places filter in the same filter popover (its
  own increment).
- 2026-11-10: merges ask first; a birthday may be a year alone.
