# ADR 0042: Duplicates are a projection over digests and authored overlay

- Status: Accepted
- Date: 2026-10-31

## Context

Libraries collect extra copies of the same files: a second import of one card, a Finder
duplicate, a backup library that mirrors another, a download saved twice. Otos already
holds a content digest for every library file it has read (ADR 0018) and everything the
user authored per copy: curation, edit recipes, and `.xmp` / `.srt` companions. The
design study `docs/research/2026-10-31-duplicate-detection.md` and its two adversarial
reviews set the product rules, and plan 0109 the increments.

## Decision

**A duplicate group is a projection, not a record.** Copies are one group when their
current digests match (`DuplicateGroupID.identical`). A copy belongs only while it is
visible: in an available fixed library, not waiting for or in the Trash, not a Live Photo's
movie (a member of its still's item, ADR 0041), with a digest current for its file's size
and mtime. The Store reads the copies (`CatalogStore.duplicateCopies`, through
`idx_media_asset_content_hash`). The keeper rule is a pure function
(`DuplicateGroupPolicy`) that `DuplicatesProjection` runs off the MainActor. Projection
publishes the groups as `CatalogWindowState.duplicates` in every scope, so the sidebar's
Duplicates row exists exactly while a group is active.

**The groups have their own owner.** They are a fact about the whole catalog, not about
what the window shows, so `DuplicatesProjection` owns them with its own loop (ADR 0032).
`CatalogProjection` asks it for a build after a publication that took up a catalog change,
so builds follow catalog changes no faster than the window's cadence for them, and a
change of scope, filter or sort never starts one. The window never waits for a build: it
publishes with the groups last built, and a build whose groups changed republishes it.
When the build ran inside each window pass, choosing a card in the sidebar took 1,995 ms
to paint, queued behind a 1.5 s same-photo build (2026-11-01 log). `duplicates` is nil
until the first build: the row has no count and the list draws nothing until then, rather
than claiming "No duplicates".

**Every group has a default, and no default loses work** (owner, 2026-11-01, Plan 0111).
The copies to keep are chosen and the rest marked; the user can change any mark.

- **Each library keeps its own copy.** Nothing across libraries is preselected, so a group
  whose copies span libraries keeps the best copy in each. Groups spanning exactly two
  libraries are summarized per library pair, with Keep Both Libraries and `Keep Only
  <Library>`, which marks every copy the pair holds in the other library.
- **Work is carried, not chosen between.** When the act moves a copy whose curation or edit
  the kept copy lacks, the kept copy takes it (`DuplicatesSession.carries`). The Store
  writes the carry in the transaction that hides the moved copy, only where the kept copy
  still lacks the work, and records what it replaced under the command's batch; Undo of
  that Move to Trash puts it back for every moved copy that came back. Companion files are
  another app's files and never move onto another copy.
- **Only work that cannot be combined waits:** two edited copies, two with companions, or
  two different choices, within one library. Those groups have no default and say
  `Choose a copy to keep`.
- **The best copy is kept**, in this order:
  1. a copy with companion files, since they cannot move;
  2. for versions of the same photo, whether or not they name their capture, the camera
     original (it names its capture), then the most pixels, then the largest file in
     bytes — the list shows sizes at whatever precision tells the files apart;
  3. an edited copy, then one with a choice, so the common case carries nothing;
  4. the name without a Finder, browser or import copy suffix (` copy`, ` copy 2`, ` (1)`, and
     `_001`, the collision suffix Otos's own import gives a second copy, ARC-050);
  5. the earliest birth time;
  6. path order.
- **Keep Only This Copy** keeps a row's copy and marks the rest of its group. A waiting
  group's rows offer it as `Keep This Copy`, so the first click on such a group means
  keep.
- **The default says why.** `DuplicateDefault` records the criterion that separated the
  kept copy from the copy it beat last (birth times compared at whole seconds, the
  precision the list shows), that each library keeps its own, or which work conflicts and
  in which library; the list states it in words, computed, never stored
  (`docs/design/duplicates.md`). Groups are listed versions first, then identical copies,
  each newest first by the kept copy's capture date.

**The one durable fact is Keep All Copies,** remembered per pair of paths in
`duplicate_kept_pair` (schema v11). It is overlay on both copies:

- `ON UPDATE CASCADE` carries it through Otos's own moves and witnessed moves.
- `ON DELETE CASCADE` ends it with either copy's proven deletion or its library's
  removal.

A group whose every pair is kept stays in its place in the list as one quiet card, `Kept
both copies`, and is counted nowhere; a card that vanished on Keep Both read as a deletion.
A later copy of copies kept together is the only one offered as extra. Keep All is
undoable, delivered on one ordered intent stream (ADR 0032 rule 5); Review Again forgets a
kept group's pairs on the same stream, undoable by its own name, so a kept group is never a
dismissal without a way back.

**Marks are window state.** The user's Keep / Move marks live in `DuplicatesSession`, owned
by the view model; a mark is forgotten once no group holds its copy. The list always shows
every active group: one found while the user looks joins at once, and one that resolves or
vanishes leaves at once. The act moves exactly the marked copies the bar counts, through the
one Move to Trash path (`moveMediaToTrash`): its download question
(APP-045), its queue, and its undo are the ordinary ones; the bar then shows the act's
receipt with Undo until a mark changes or the user leaves the list. A group always keeps
one copy: the mark refuses the last kept copy of three or more, and in a pair unkeeping
the kept copy keeps the other. On the list, ⌘⌫ (the ordinary Move to Trash) moves the
selected groups' extra copies and never a kept one, so Select All then ⌘⌫ cannot empty a
group; a row's `Move to Trash Now` moves that one copy, kept or not, after which the group
re-derives without it.

**Scopes.** `.duplicates` is every copy in a group, presented as the duplicates list, so the
list's rows are the ordinary media selection — Photo commands, ⌘⌫ and Undo's reveal read
it. `.duplicateGroup(id)` is the leaf under it, one group's copies in the ordinary
Compare, Loupe or grid, reached by Return and left by Back to Duplicates. Both resolve
through `CatalogScopePredicate.ContentConstraint`. A group is never named by its digest
outside the catalog: no digest is logged or persisted in preferences (ADR 0018), so a
browser place saved in a leaf reopens on the list, which has one presentation: the view
mode saved with it is not restored.

**Empty files are never duplicates.** Every file of zero bytes shares the digest of no
bytes, so a copy counts only with content (`byte_size > 0`). An empty file is a broken
file, not a copy of another.

## Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| A duplicate-group table with IDs | A second identity for facts the digests already state; it would go stale with every scan. |
| Preselect across libraries by sidebar order | Empties a mirror library in one unread bulk act (review finding 1). A library goes only when the user names it in `Keep Only <Library>`. |
| Let groups with authored work, or versions of the same photo, wait without a default | Nothing in the act's count until the user decides each group; competitors default every group (Photos, Lightroom web, PhotoSweeper, Mylio). Carrying the work makes a default safe (owner, 2026-11-01). |
| Persist per-copy marks | A decision in progress, not a fact about the files; it would outlive the groups it described. |
| Hold groups found mid-visit behind `N more found · Show` | A second answer to "which groups exist", besides the published state. It snapshotted the catalog before its first load at launch and hid every group behind `0 photos · 164 more found`. The owner wants the list to show every duplicate, always (2026-11-01). |
| Return as the bulk act's key | Return opens a group; a bulk move must not be one keystroke from a list. |
| A confirmation before the bulk act | Photos confirms a merge, which is not undoable; this act is the ordinary Move to Trash, undoable and recoverable, and the HIG reserves alerts for uncommon acts that cannot be undone (DES-076). |
| A checkbox meaning "move to Trash", the category's convention | The kept set is what the rule explains and what a group must never empty; a positive mark reassures where a destructive one warns. |
| Single-letter shortcuts for Keep and Move | P, U and X already mean curation choices; one key never means two things. |

## Consequences

- Duplicates appear as digests arrive, because enrichment hashes libraries in the
  background (ENR-013). A library whose files are not yet hashed shows no groups for
  them, and the list claims nothing about them.
- The bar shows file sizes, as the trash bar does. Whether a move needs a download is
  asked at act time by APP-045, not predicted in the bar.
## Same photo

Versions of one photo — resized, re-encoded, metadata stripped — are different bytes of one
capture. They are found by pixels, confirmed by pixels, and kept apart from separate
captures by capture metadata (`SamePhotoPolicy`):

1. **Capture metadata decides first.** Two files that both name a camera and an instant
   are one capture only if all of these agree:
   - the camera model;
   - the whole-second instant;
   - where both files carry them, the EXIF sub-seconds, the body serial and Apple's burst
     identifier (MediaMetadata 0.9).

   This gate is what separates a still-scene burst. On the owner's library, 5 % of
   same-second burst pairs are as pixel-close as true copies, and every checked pair
   differed in sub-seconds (`docs/research/2026-10-31-duplicate-calibration.md`).
2. **The pixels must match almost exactly.** Each still's **render signature** — a 64-bit
   difference hash and a 32 × 32 grayscale render of its *stored thumbnail* — is the
   measure. A hash within 10 bits proposes a pair; a mean absolute difference below 4 (of
   255) confirms it. Vision's feature print was measured and rejected: on real 256 px
   renders it does not separate copies from burst frames.
3. **A file without capture metadata joins only the one original clearly closer than every
   other.** If two are about as close, it could be either frame, and it joins none.

Other rules:
- A RAW is never grouped with a processed file.
- Copies already in an identical group are left to that group.
- Same-photo groups keep the camera original by the keeper rule above. Keep All Copies sets
  them aside by the same per-pair memory.
- Candidates are blocked by kind, display aspect and whole-second instant, so a library is
  never compared all against all. Pairs are proposed from column facts alone, read as
  pairing facts only (`SamePhotoCandidate`). The copy a group lists, the grayscale
  render, the sub-seconds and the burst identifier — the last two live in the stored
  metadata record — are read only for the stills a proposed pair names
  (`SamePhotoDetail`). Building every still's copy and decoding every record was most of
  a build: on 2026-11-01 the owner's library had 14,201 stills, of which 2,462 were in a
  proposed pair.

`RenderSignatureRefresher` is the one producer of signatures:
- It reads stored thumbnails only, so it never opens an original or downloads one.
- It records the thumbnail each signature came from (`render_signature_source`: path,
  rendered revision, enrichment stamps). A re-rendered thumbnail makes the signature stale
  with no write site having to know.
- It is one loop woken by the Store's change notifications (ADR 0032).

MediaMetadata 0.9's new fields are backfilled the way new library fields always are
(ADR 0039): migration v12 clears the EXIF families' extraction revisions, and
`MetadataRefresher` re-reads them from local bytes only.

- `DuplicateGroupID.samePhoto` names a group by its members, and its leaf scope selects
  them explicitly (`ContentConstraint.members`).
