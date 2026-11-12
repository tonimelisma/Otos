# People

Status: approved by the owner in chat, 2026-11-12 (the redesign around auto-tagged faces,
replacing the review of 2026-11-10); built (APP-072). Its rules are DES-109 to DES-111 and
DES-113.

The surfaces for the people in the user's photos (ADR 0047): the **People gallery**, a
**person's photos** (the People filter over the libraries), the **photo menus**' face acts
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
**Where Otos deviates:** a person's photos are a filter, not a page of their own; a face
with its name removed is never given a person again by Otos; Otos ranks the people a face
or a selection of faces could be; no face is drawn by hand (Immich's `Tag People`); nothing
is written into media folders (ADR 0008).

## Terminology

| Term | Means | Not |
| --- | --- | --- |
| **Person** | A catalog row with an optional name, birthday, feature photo, favourite and hidden mark, and the faces that are theirs. | "contact", "tag", "cluster" |
| **Face** | One face Otos found in one photo. | "region", "detection", "embedding" |
| **Unidentified** | A face with no person. | "unassigned", "unknown", "unnamed" |
| **Unnamed** | A person without a name. | "unknown person", "group" |
| **Hidden** | A person the user hid: seen only in the gallery. | "ignored", "removed" |
| **Checked** | A photo that has a current face reading (ADR 0009 stamp and model revision). | "analysed", "scanned" |

Forbidden in copy (DES-035): embedding, threshold, margin, score, cluster, seed, guess,
confidence, model.

## Sidebar

- **The row:** `People`, SF Symbol `person.crop.square`, first under `Utilities`, before
  `Places` and `Duplicates`. It exists whenever one fixed library exists (APP-057).
- **No trailing count and no row per person.** The row stays highlighted while the gallery
  shows; a person's photos highlight the library or All Media row they show.
- **No progress indicator.** Face reading is enrichment (DES-040).

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
- **A cell:** the feature photo's face tile (DES-110), else the newest face; under it the
  name (`.body`) or, for an unnamed person, a link-style `Add Name…`; a secondary
  `heart.fill` before the name of a favourite; `312 photos` (`.subheadline` L3, tabular).
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
the name), which keeps its name, birthday and feature photo, taking the other's where it
has none, and is a favourite if either was. Refused, by a disabled act with its reason
(DES-038), when the user's faces or the faces a person was first found from put both in
one photo (`Sam and Ian are both in 3 photos`) or a photo the user gave either predates
the birthday kept.

**Empty states:** one centered L3 sentence under the bar: `People appear here as Otos
finds faces in your photos.`, `People appear here once Otos finds the same face on
different days.`, `Otos found no faces in your photos.`, or the shared `No Available Media`
/ `Checking Libraries` sentence.

## A person's photos

- **What it is:** the ordinary browser over every fixed library (All Media, or the one
  library) with the People filter set to the person. Every view mode, sort and filter works.
- **Title:** the person's name; with several people filtered `Sam and Ian`, `Sam,
  Ian and 2 Others`; with `Unidentified Faces`, that is named too.
- **Toolbar:** `Back to People` (`chevron.left`) at the leading edge while the browser shows
  the people it was opened on from the gallery; it clears the People filter it set. Beside
  it, while exactly one visible person is filtered, a menu titled with their name and
  `person.crop.circle`: `Add Name…`/`Rename…`, `Set Birthday…`, `Add to Favorites`/`Remove
  from Favorites`, `Merge Into ▸`, `Hide`.
- **Likeness sort:** `Likeness — Least Like Sam First` and `Likeness — Most Like Sam
  First` in the Sort menu, beside Date, Filename and Size: how like the person each photo's
  face of theirs is, so the faces most likely wrong come first. Disabled, never hidden,
  unless one person is filtered (DES-053); the reads then use the default order.

## The People filter

A section of the filter popover, under the file types:
- **Rows:** a checkbox per visible person, favourites first; `Unidentified Faces`; a
  `Search People` field once there are more than eight people. A checked person always
  shows, so the filter never holds a row the user cannot see.
- **`Show Photos With`:** `Any of Them` or `All of Them`, disabled until two rows are checked.
- **Hidden or merged people** leave the filter when People next publishes.

## Face acts

The same acts, names and rules on every surface (DES-113), each one undoable intent:

| Act | Result |
| --- | --- |
| `This Is ▸` a person | The faces are that person's, on the user's word. The named people the faces most likely are come first, then every other named person the hard rules allow. An unnamed person is not offered, since several would read alike: naming them in the gallery makes them a choice. |
| `This Is ▸ New Person…` | The Person sheet; Save makes a person of the faces. A name another person has gives the faces to them. |
| `Not Sam` | The face loses its person and is never given one by Otos again; the people it most likely are stay offered, Sam left out. |
| `Not a Face` | The detection leaves People until the photo's file changes. |
| `Set as Feature Photo` | With one photo targeted: the person's cover in the gallery. |

**The hard rules** leave a person out of `This Is ▸` (DES-038): a photo the user already
gave them another face of, two faces of one photo, a photo from before their birthday.

### Photo menus

The grid, filmstrip, loupe and compare context menu, after `Reveal in Finder`:
- **One entry per visible person** with a face in the targeted photos, in the order their
  faces come: `Sam ▸`, holding a `This Is` section header with the people, a separator,
  `New Person…`, then `Not Sam`, `Not a Face` and `Set as Feature Photo`. One level of
  submenu (HIG).
- **`Unidentified Face ▸` / `Unidentified Faces ▸`:** the same, without `Not <name>`. This
  Is gives the person, in each targeted photo, the unidentified face most like them.
- **With the filter on one person,** their entry's acts sit at the menu's top level:
  `This Is ▸`, `Not Sam`, `Not a Face`, `Set as Feature Photo`.

### Info pane

The first section (DES-088), `People`:
- **One photo:** each face of a visible person or unidentified, in reading order: a 40 pt
  face tile, the name or `Unidentified` (secondary), and an `ellipsis.circle` menu with the
  face acts. An unidentified face shows the three people it most likely is as small
  bordered buttons, one click each. `No Faces` once checked with none, `Not Checked Yet`
  before.
- **Several photos:** each visible person in them with `12 photos`, and the unidentified
  faces with `5 faces`, the three people they most likely are as buttons.
- **Hover:** pointing at a face outlines it on the loupe's photo in DES-061's 3 pt accent
  border, mapped through the photo's saved crop and straighten.

## Person sheet

`Add Name…`, `Rename…`, `Set Birthday…` and `New Person…` open one sheet (DES-041).

| String | Level |
| --- | --- |
| Title: the name, `Unnamed`, or `New Person` | L1 |
| `Name` (text field), `Birthday`: a year field, then `Exact date` with a date picker, disabled, never removed, while unchecked (DES-053, DES-054). A year alone counts from 1 January. | L2 controls |
| Footnote: `Faces from before this date are never given to Sam.` | L3 |

- **Buttons:** `Save` (default) and `Cancel`.
- **Save is disabled** with the reason as its tooltip: `Enter a name`; `Enter a year, or a
  full date`; `4 photos of Sam are from before this date` (photos the user gave her).
- **A name another person has** is not refused: Save asks `Are these the same person?` and
  merges on `Merge`.

## Appearance and accessibility

- **Light and dark (DES-022):** backdrops `content`, bars bar chrome, hairlines DES-023;
  the accent only on selection, the face outline and focus rings (DES-024).
- **Grayscale (DES-029):** selection is a border; a favourite is a glyph; a hidden person
  is dimmed and under its own header.
- **Keyboard (DES-080, DES-081):** in the gallery the arrows move, Return opens, Escape
  clears the selection; every face act is in a menu reachable from the keyboard.
- **VoiceOver:** a cell reads `Sam, 312 photos` with `favorite` or `hidden` when so; the
  Info pane's face menu is `Actions for Sam`.
- **Reduce Motion (DES-075):** nothing on these surfaces translates.

## Undo

Every act goes on the window's one undo stack (APP-039): `Undo This Is`, `Undo New Person`,
`Undo Not This Person`, `Undo Not a Face`, `Undo Edit Person`, `Undo Merge`, `Undo Hide`,
`Undo Unhide`, `Undo Add to Favorites`, `Undo Remove from Favorites`, `Undo Set Feature
Photo`. An undo writes back exactly what the act changed; the guesses that followed from it
are rebuilt by assignment (ADR 0047). Entries live for the session.

## Owner decisions

- 2026-11-12: auto-tagged faces, named and unnamed one kind, no review; a removed name is
  never filled again by Otos; corrections move the guesses chained through them; people
  seen on one day stay out of the gallery until named; the likeness sort; hidden people
  only in the gallery, with no `Show Hidden` toggle; favourites first; the Info pane's
  sections People, Location, File first; a Places filter in the same filter popover (its
  own increment).
- 2026-11-10: merges ask first; a birthday may be a year alone.
