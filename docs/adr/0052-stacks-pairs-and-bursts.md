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
- iPhone bursts stack by their identifier; camera bursts were to stack by the drive mode the
  camera records in each frame, never by timing (owner, 2026-11-13, after
  `docs/research/2026-11-13-camera-burst-detection.md` found no timing threshold in the owner's
  library). The frame number alone cannot bound one burst (below), so camera bursts do not
  stack until a fact that does is read.

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
- **A burst:** in one root, two or more frames whose stills carry the same burst identifier
  (an iPhone's). A pair is one frame of the burst; its two files expand as a pair inside the
  expanded burst.
- **Not a burst: a camera's continuous frames.** MediaMetadata reports the number a Sony body
  records for each frame of a continuous sequence (`continuousShootingFrame`), and the stored
  metadata record keeps it. It says where a frame stands in its sequence, not which sequence:
  once the user deletes a burst's leading frames, its frame 3 after the previous burst's frame
  2 rises like the next frame of that burst, whatever day or folder it is in, and a collapsed
  stack would hide it and Move to Trash would take it. Nothing else the a6700 records bounds a
  sequence: its `ShutterCount` counts the mechanical shutter only and stands still under the
  electronic shutter, and ExifTool documents no shot counter for it
  (`docs/research/2026-11-13-camera-burst-detection.md`). A wrong stack hides photos, so camera
  frames do not stack; a fact that names the sequence, read by the library, would let them.

The identity of a stack is the derived key (`PhotoStackID`: kind, root, stem key or burst
identifier). The Store
reads every candidate still — each present RAW and processed image in a folder that holds a
present RAW and another present still, and every present still carrying a burst identifier —
whatever the scope or filter, so a filter that hides one file never unpairs the
other — in the transaction that reads the order. A folder with one still can hold no pair: an
Immich account stages each asset in its own folder, and its lone RAWs were 10,906 of the
owner's 25,944 candidates (`docs/research/2026-11-16-window-reads-owner-catalog.md`). From the candidates
the pure `PhotoStackRule` decides the stacks in Swift, through the same stem key companions use. Nothing about the stack is stored. `media_asset.burst_identifier` becomes a column, written with every metadata record
like `content_identifier` and backfilled from the stored metadata JSON.

**The stem key has one owner.** Companion pairing, import naming bundles and stacks compare
stems through one key that follows the volume's case and normalization (ARC-056's
`FilesystemNameKey` semantics), replacing the unconditional `lowercased()` the first two used.

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
expanded. A stack is collapsed only while two of its units are present in the scope: a pair's
files, a burst's frames, an expanded pair's two files counting as one frame. A collapsed burst's tile stands for the burst; on an expanded burst's band a pair frame
is still a collapsed pair with its own badge.

**Collapsing and expanding.** The Store reads the full order with each row's stack key. A pure
projection pass after search collapses each stack to its key member, keeping the full order
for reuse, so the grid, day sections and their counts, On This Day, the map and the empty
state all see the collapsed list. Expanding is a window intent that names stack keys,
held outside the query descriptor, so it never re-queries and never clears the selection: the
projection re-collapses the order it last read, with its day buckets and map coordinates,
which it keeps while no fact the order depends on changes (ADR 0005); and a pass whose
order, stacks and expansions are those of the last collapse reuses that collapse. An
expanded stack's members are ordinary tiles, in capture order, on one band.

**Actions.** Anything that uses the picture uses the key member: view, compare, story, edit,
crop and rotation, curation, copy, share, open with, drag, export, Info's picture facts.
Curation being the key's, a collapsed stack is Liked or Disliked as its key is
(`PhotoStack.keyChoice`): a surface that judges photos by their choice judges a stack by its
key, so On This Day, which leaves Disliked photos out, leaves out every file of a stack whose
key is Disliked, and a Disliked RAW behind a JPEG key leaves the JPEG. That is one answer
(`OnThisDayPicks.shows`), asked by the cards and by the years-or-months match alike, so a year
whose only photos are such a stack is not offered (ADR 0049).
Anything that changes files acts on every member of a collapsed stack: Move to Trash, Reveal in
Finder, import and reorganization. A member of an expanded stack is an ordinary photo for every
action, Move to Trash included: it trashes that one file. Each member keeps its own overlay;
nothing is moved between members when the key changes.

**Counting.** A stack counts once: day counts, On This Day's item counts, a person's photo
count, a map stack's count, an import batch's count in the sidebar and All Imports (the
stacks that hold its rows, collapsed over its rows alone, so a pair split across two
batches is a file in each, as each batch's grid shows it; counted only for the batches the
window shows, since stacking every batch costs hundreds of milliseconds a pass) and search results. A filter or search narrows a stack's members
first: a stack collapses only when two or more of its units match, and its tile is the key
member when that matches, else its first matching member; a single matching member shows as
an ordinary photo. The duplicates scope never collapses.

## Rejected alternatives

- **Hide members in the scope SQL, as Live Photos are.** Counts would be right for free, but
  expanding would need a new query and a scope change, which clears the selection.
- **Store stacks as rows.** A stack is a fact of file names and capture metadata; storing it
  would make a second source of truth that drifts from the files.
- **Evaluate the pair rule in SQL, as `LivePhotoSQL` is.** SQLite's `lower()` folds ASCII
  only, so SQL could not apply the volume's own stem equality; the rule runs in Swift over
  candidates SQL reads, cutting each candidate's stored name key (ARC-056).
- **Show the RAW by default, as Lightroom Classic does.** The owner chose the camera JPEG, as
  Apple Photos shows it.
- **A separate burst view (Apple, Google).** A second browser duplicates every action; expanding
  in place keeps one path per action.
- **Apple's "Use RAW as Original".** "Original" already names a photo without its edit in Otos.
- **Group camera bursts by time.** The owner's library shows no gap that separates burst frames
  from quick single shots: stacking at 0.15 s joins 0.8 % of shots, at 0.5 s 29.4 %. A wrong
  stack hides photos, and the camera already records what it did.
- **Bound a camera burst by its file numbers.** Otos's import naming removes the camera's
  counter, and its `_NNN` suffix or a counter reset makes frames of two bursts satisfy the
  rule; the a6700 records no serial Otos reads (`docs/research/2026-11-13-camera-burst-detection.md`).

## Consequences

- The grid shows 5 338 fewer tiles on the owner's library, and On This Day stops doubling.
- Every count reads stacks, so a consumer that counts asset IDs directly (People's photo count)
  changes to count stack keys.
- Migration v32 adds the key-choice stamp; v37 adds `burst_identifier`, filled from the
  stored metadata, and the burst's key-choice stamp; v42 added `continuous_shooting_frame`,
  which v46 drops with its index, restoring `idx_media_asset_burst`.
- A camera's burst shows frame by frame, as before it was read.
- The stem key change can pair a companion or naming bundle that differs only in Unicode
  normalization on a case-insensitive volume, where Finder already treats the names as equal.
