# ADR 0052: A RAW+JPEG pair and a burst are stacks, one photo until expanded

- Status: Accepted
- Date: 2026-11-13

## Context

A camera set to RAW+JPEG writes each shot twice: `DSC01234.ARW` and `DSC01234.JPG` side by
side. Otos catalogs every image as its own row, so the grid, On This Day, People, Places and
search show each such shot twice; the owner's library holds 5 338 such pairs. An iPhone burst
writes one file per frame, all carrying Apple's burst identifier; a burst shows as a run of
near-identical tiles. The survey `docs/research/2026-11-13-stacks-pairs-and-bursts.md`
compares Apple Photos, Lightroom Classic and desktop, Google Photos, Immich, digiKam and
Capture One.

The owner decided, on 2026-11-13:

- RAW+JPEG pairs and bursts are each one photo everywhere, not only in On This Day;
- the shown file of a pair is the camera JPEG by default, as in Apple Photos, and switching to
  the RAW is prominent, not a menu item alone: in the edit panel and the loupe, and from the
  grid;
- a pair expands like a burst when its badge is clicked;
- a burst expands in place in the grid, as in Lightroom Classic, not in a separate view;
- Move to Trash on a collapsed burst trashes every frame, as Apple Photos does;
- Move to Trash on one file of an expanded pair trashes only that file;
- switching an edited pair's shown file keeps each file's own edit;
- iPhone bursts stack by their identifier; camera bursts stack only after timing is measured
  on the owner's library.

ADR 0041 already makes a Live Photo one item: the motion movie is hidden by an SQL rule
evaluated where it is used, and Move to Trash takes both files.

## MECE Decision Scope

This ADR owns: what makes a stack; the key member and the stored choice of it; collapsing and
expanding; which member each action uses; how a stack counts; and the stem key.

It references but does not own: Live Photos (ADR 0041), which stay one item that never
expands, because the movie is not a photo to choose; duplicates (ADR 0042), which group copies
and never stacks; the overlay lifecycle (ADR 0008); the tile and loupe surfaces
(`docs/design/design-system.md`).

## Decision

**What makes a stack.** A stack is derived from facts, never authored:

- **A pair:** in one root and one folder, one file of kind RAW and one processed still whose
  stem keys match, and no third still with that stem key. Any other count pairs nothing.
- **A burst:** in one root, two or more stills carrying the same burst identifier. A pair whose
  processed file carries the identifier is one frame of the burst; its two files expand as a
  pair inside the expanded burst.

The identity of a stack is the derived key (`PhotoStackID`: kind, root, stem key). The Store
reads every candidate still — each present RAW and processed image in a folder that holds a
present RAW, whatever the scope or filter, so a filter that hides one file never unpairs the
other — in the transaction that reads the order, and the pure `PhotoStackRule` decides the
stacks in Swift, through the same stem key companions use. Nothing about the stack is stored. `media_asset.burst_identifier` becomes a column, written with every metadata record
like `content_identifier` and backfilled from the stored metadata JSON.

**The stem key has one owner.** Companion pairing, import naming bundles and stacks compare
stems through one key that follows the volume's case and normalization (ARC-056's
`FilesystemNameKey` semantics), replacing the unconditional `lowercased()` the first two use
today.

**The key member.** A collapsed stack shows its key member:

- a pair's default key is the processed file (the camera JPEG);
- a burst's default key is its first Liked frame, else its first frame in capture order;
- the user's choice, Make Key Photo, outranks the default.

The choice is overlay on the member it names: `media_asset.stack_key_chosen_at_unix_ms`, so a
move carries it and a deletion purges it with its row (ADR 0008), with no stack table that
could outlive its files. The latest stamp among a stack's members wins; Make Key Photo stamps
the chosen member and clears the others, and undo writes the previous stamps back. When the
chosen member is gone, the default applies again. A burst's choice is its own column,
`media_asset.burst_key_chosen_at_unix_ms`: a frame can be a pair, and one stamp for both would
make switching a frame's `JPG`/`RAW` choose the burst's key, and choosing a key frame clear the
other frames' pair choices.

**Two levels.** A pair is one frame of a burst, so the projection collapses pairs first and then
bursts over what remains, and each tile carries its pair and its burst with whether each is
expanded. A collapsed burst's tile stands for the burst; on an expanded burst's band a pair frame
is still a collapsed pair with its own badge.

**Collapsing and expanding.** The Store reads the full order with each row's stack key. A pure
projection pass after search collapses each stack to its key member, keeping the full order
for reuse, so the grid, day sections and their counts, On This Day, the map and the empty
state all see the collapsed list. Expanding is a window intent that names stack keys,
held outside the query descriptor, so it never re-queries and never clears the selection. An
expanded stack's members are ordinary tiles, in capture order, on one band.

**Actions.** Anything that uses the picture uses the key member: view, compare, story, edit,
crop and rotation, curation, copy, share, open with, drag, export, Info's picture facts.
Anything that changes files acts on every member of a collapsed stack: Move to Trash, Reveal in
Finder, import and reorganization. A member of an expanded stack is an ordinary photo for every
action, Move to Trash included: it trashes that one file. Each member keeps its own overlay;
nothing is moved between members when the key changes.

**Counting.** A stack counts once: day counts, On This Day's item counts, a person's photo
count, a map stack's count and search results. A collapsed stack matches a filter or search
when any member matches, and shows its key member. The duplicates scope never collapses.

## Rejected alternatives

- **Hide members in the scope SQL, as Live Photos are.** Counts would be right for free, but
  expanding would need a new query and a scope change, which clears the selection.
- **Store stacks as rows.** A stack is a fact of file names and capture metadata; storing it
  would make a second source of truth that drifts from the files.
- **Evaluate the pair rule in SQL, as `LivePhotoSQL` is.** SQLite's `lower()` folds ASCII
  only, and the stored path key does not follow every Otos move, so SQL could not apply the
  volume's own stem equality; the rule runs in Swift over candidates SQL reads.
- **Show the RAW by default, as Lightroom Classic does.** The owner chose the camera JPEG, as
  Apple Photos shows it.
- **A separate burst view (Apple, Google).** A second browser duplicates every action; expanding
  in place keeps one path per action.
- **Apple's "Use RAW as Original".** "Original" already names a photo without its edit in Otos.
- **Group camera bursts by time now.** No pixel threshold separates burst frames, and timing is
  not yet measured on the owner's library; a wrong stack hides photos.

## Consequences

- The grid shows 5 338 fewer tiles on the owner's library, and On This Day stops doubling.
- Every count reads stacks, so a consumer that counts asset IDs directly (People's photo count)
  changes to count stack keys.
- Migration v32 adds the key-choice stamp; v37 adds `burst_identifier`, filled from the
  stored metadata, and the burst's key-choice stamp.
- The stem key change can pair a companion or naming bundle that differs only in Unicode
  normalization on a case-insensitive volume, where Finder already treats the names as equal.
