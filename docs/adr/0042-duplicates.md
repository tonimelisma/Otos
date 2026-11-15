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

**Duplicates compares copies within each library, unless the user widens it** (owner,
2026-11-15). A library the user keeps a second time on purpose — an Immich server that
indexes the same OneDrive folders Otos has as a library — is a mirror, not waste, and its
pairs buried the copies worth clearing (16,001 groups on the owner's catalog). So by default
a group's copies are all in one library or one account (`DuplicatesReach.withinEachLibrary`):

- an identical group is a digest in one library, `DuplicateGroupID.identical(_, library:)`,
  and the same digest in two libraries is two groups or none;
- versions of the same photo are proposed only within one library, so no group joined
  through pairs spans two.

Settings ▸ General ▸ `Find duplicates across libraries and accounts` widens it
(`.acrossLibraries`, `library: nil`), and then the rules below for groups that span
libraries apply. The preference is the window view model's (`duplicates.acrossLibraries`),
handed to the Store as the first command on its mutation stream and on every change. The
Store holds the one current value and every reader uses it: the copies read, the Duplicates
scope (`ContentConstraint.duplicated(reach)`) and the build, which groups by the reach the
copies read used. `DuplicatesReachSQL.shared` is the one definition of "another row shares
this digest": within each library it groups by digest and root, the digest index's own
order. A change of reach is a change of which files are copies (`.copies`), so the groups
and the Duplicates scopes are read again. A build the catalog's load lets run before the
handoff is followed by another.

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
The default is what a group keeps until the user clicks a photo or sets its folder's
rule.

- **Each library keeps its own copy.** Nothing across libraries is preselected, so a group
  whose copies span libraries keeps the best copy in each, until the folder rule for those
  two folders keeps one side.
- **Work is carried, not chosen between.** When the act moves a copy whose curation or
  edit the kept copy lacks, the kept copy takes it (`DuplicateResolution.carries`). The Store
  writes the carry in the transaction that hides the moved copy, only where the kept copy
  still lacks the work, and records what it replaced under the command's batch; Undo of
  that Move to Trash puts it back for every moved copy that came back. Companion files are
  another app's files and never move onto another copy.
- **Only work that cannot be combined waits:** two edited copies, two with companions, or
  two different choices, within one library. Those groups have no default and tag
  nothing until a click settles them.
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
- **The default records why.** `DuplicateDefault` records the criterion that separated the
  kept copy from the copy it beat last (birth times compared at whole seconds), that each
  library keeps its own, or which work conflicts and in which library; a waiting group's
  header names the conflict.

**The list is laid out by the attention a group needs** (owner, 2026-11-14,
`docs/research/2026-11-14-duplicates-by-attention.md`). `CatalogDuplicatesState` publishes
the groups as a `DuplicatesLayout`, built once per build, off the main actor:

- groups whose copies hold work that cannot be combined, newest first by the kept copy's
  capture date;
- versions of one photo, newest first;
- identical copies in a bucket per folder set (`DuplicateFolderPlace`): the set with the
  most groups first, groups in three or more folders in one last bucket, and inside a
  bucket the largest first.

A group's section is read from its copies (`DuplicateGroup.section`), never from the
session or from Keep All Copies, so no act of the user's moves a group in the list. A
folder rule decides the identical copies of its folder set and nothing else: versions of
one photo differ in their pixels, the list shows them as photos for that reason, and a rule
set on a header must not change what a photo in another section keeps.

**The one durable fact is Keep All Copies,** remembered per pair of paths in
`duplicate_kept_pair` (schema v11). It is overlay on both copies:

- `ON UPDATE CASCADE` carries it through Otos's own moves and witnessed moves.
- `ON DELETE CASCADE` ends it with either copy's proven deletion or its library's
  removal.

A group whose every pair is kept stays in its place in the list as one quiet header, `Kept
both copies`, and is counted nowhere; a group that vanished on Keep Both read as a deletion.
A later copy of copies kept together is the only one offered as extra. Keep All is
undoable, delivered on one ordered intent stream (ADR 0032 rule 5); Review Again forgets a
kept group's pairs on the same stream, undoable by its own name, so a kept group is never a
dismissal without a way back.

**Choosing what stays: one click, or one rule for a folder** (owner, 2026-11-04). Every
group shows its copies as photos tagged Keep or Trash. What a group keeps is
`DuplicateResolution`, pure, so what a photo shows, what the bar counts and what the act
moves are one computation, resolved in this order:

1. the copy the user clicked (`DuplicatesSession.picks`), which keeps that copy alone;
2. the rule the user set for the group's folder set (`DuplicatesSession.rules`): for two
   folders that mirror each other, keep the copies in one of them (the best of them by the
   keeper rule when a folder holds more than one); for one folder with files saved twice,
   keep the original name, the oldest, or the largest;
3. the group's default.

A group whose copies hold work that cannot be combined is decided only by a click: no rule
chooses between two people's work. A folder set is the sorted set of (library, folder) the
group's copies sit in; sets of three or more folders get no rule. Picks and rules are
window state, a decision in progress; a pick is forgotten once its copy leaves the group.
The one act, `Move N Copies to Trash`, moves every group's copies tagged Trash through the
one Move to Trash path (`moveMediaToTrash`): its download question (APP-045), its queue and
its undo are the ordinary ones, and the bar shows its receipt with Undo until a click or
rule changes or the user leaves the list. It asks nothing (DES-076): every fate is on
screen before the click. A group always keeps one copy. On the list, ⌘⌫ moves the selected
groups' copies tagged Trash and never a kept one; a photo's `Move to Trash Now` moves that
one copy, kept or not, after which the group re-derives without it.

**Scopes.** `.duplicates` is every copy in a group, presented as the duplicates list, so the
list's photos are the ordinary media selection — Photo commands, ⌘⌫ and Undo's reveal read
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
| Listing copies across libraries by default (2026-11-14 to 2026-11-15) | A mirror the user keeps on purpose filled the list with pairs nobody wants removed, and hid the copies within a library that are waste (owner, 2026-11-15). |
| Leaving mirrors out by recognising them (a folder set whose every file has a twin) | A guess about intent; a backup library the user is consolidating looks the same. One stated preference decides it. |
| Keeping the reach in the window's query request | The Duplicates scopes and the build would each need it threaded through; the Store already answers what a duplicate is for both. |
| A duplicate-group table with IDs | A second identity for facts the digests already state; it would go stale with every scan. |
| Preselect across libraries by sidebar order | Empties a mirror library in one unread bulk act (review finding 1). A library goes only when the user picks it in its folder rule. |
| Let groups with authored work, or versions of the same photo, wait without a default | Nothing in the act's count until the user decides each group; competitors default every group (Photos, Lightroom web, PhotoSweeper, Mylio). Carrying the work makes a default safe (owner, 2026-11-01). |
| One list of every group, newest first, with the folder rules in a block above it (2026-11-04 to 2026-11-14) | Date is a browsing order: the few groups that need a person sat among hundreds that need nobody, a rule sat a scroll away from what it decided, and identical copies drew the same picture twice with the one thing that differed, the name, in a tooltip. |
| A folder rule that also decides versions of one photo in that folder | The rule's control sits on the exact copies' header; reaching into another section is action at a distance, on the groups whose files differ most. |
| A Keep checkbox per copy (the 2026-11-02 design) | Shipped as a list of rows, then as tiles; the owner rejected both on sight. A tag on the photo and a click on it say the same thing with nothing to read. |
| Photos' Merge (built 2026-11-04, never merged) | It hides which copy stays and offers no way to choose it short of a context menu; the owner asked for a clean way to choose. |
| Library pair summary rows | A folder set covers them: two folders in two libraries are one of its cases, with `Both` as the default. |
| Hold groups found mid-visit behind `N more found · Show` | A second answer to "which groups exist", besides the published state. It snapshotted the catalog before its first load at launch and hid every group behind `0 photos · 164 more found`. The owner wants the list to show every duplicate, always (2026-11-01). |
| Return as the bulk act's key | Return opens a group; a bulk move must not be one keystroke from a list. |
| A confirmation before the act | Every Keep and Trash is on screen before the click, the act is the ordinary undoable Move to Trash, and the HIG reserves alerts for uncommon acts that cannot be undone (DES-076). |
| Rules that apply across the whole library at once | A folder is the unit a user knows ("my imports folder", "the backup"); a library-wide rule would decide groups the user has not looked at in folders they did not name. |
| Single-letter shortcuts for Keep | P, U and X already mean curation choices; one key never means two things. Space keeps the selected photo. |

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
   are one capture only if all of these hold:
   - the camera model agrees;
   - the whole-second instant agrees;
   - the body serial agrees, where both files carry one;
   - both records carry the EXIF sub-seconds, and they agree.

   This gate is what separates a still-scene burst. On the owner's library, 5 % of
   same-second burst pairs are as pixel-close as true copies, and every checked pair
   differed in sub-seconds (`docs/research/2026-10-31-duplicate-calibration.md`). So
   sub-seconds are the proof, and a missing value is unknown, not agreement: a record may
   lack them because the file has none or because it was read before the reader reported
   them. Treating a missing value as agreement grouped a Sony ILCE-6700 burst of six RAW
   frames in one second, and proposed five of them for the Trash: the camera writes
   sub-seconds, but the six records predated the reader reporting them, and the files were
   cloud-only, so no re-read had backfilled them. A version whose sub-seconds were stripped
   is left ungrouped rather than risk a burst frame. Apple's burst identifier is not a
   test: every frame of one burst shares it, so it can separate bursts but never prove
   one frame, and sub-seconds already separate them.
2. **The pixels must match almost exactly.** Each still's **render signature** — a 64-bit
   difference hash and a 32 × 32 grayscale render of its *stored thumbnail* — is the
   measure. A hash within 10 bits proposes a pair; a mean absolute difference below 4 (of
   255) confirms it. Vision's feature print was measured and rejected: on real 256 px
   renders it does not separate copies from burst frames.
3. **A file without capture metadata joins only the one original clearly closer than every
   other.** If two are about as close, it could be either frame, and it joins none.

Other rules:
- A RAW is never grouped with a processed file.
- A thumbnail an Immich account drew (ADR 0046 §7) is never paired with one made on this
  Mac. The two pipelines draw one photo differently enough to break gate 2, so a pair is
  proposed only within one (`SamePhotoCandidate.drawnBy`).
- Copies already in an identical group are left to that group.
- Same-photo groups keep the camera original by the keeper rule above. Keep All Copies sets
  them aside by the same per-pair memory.
- Candidates are blocked by kind, pipeline, display aspect and whole-second instant, so a library is
  never compared all against all. Pairs are proposed from column facts alone, read as
  pairing facts only (`SamePhotoCandidate`). The copy a group lists, the grayscale
  render and the sub-seconds — which live in the stored metadata record — are read only for the stills a proposed pair names
  (`SamePhotoDetail`). Building every still's copy and decoding every record was most of
  a build: on 2026-11-01 the owner's library had 14,201 stills, of which 2,462 were in a
  proposed pair.
- The build is written for the Debug build the app is installed as (ADR 0030), where every
  collection call costs. A still without capture metadata is tested against its aspect
  bucket in loops over unsafe buffers of hashes. Gate 3 collects each such file's edges in
  one walk over the confirmed pairs instead of walking every pair for every file. The
  candidates read takes its columns by position. On the benchmark library (ADR 0043) this
  took a build from 7.5 G to 4.3 G instructions, the pairing step from 2.0 G to 0.46 G.

`RenderSignatureRefresher` is the one producer of signatures:
- It reads stored thumbnails only, so it never opens an original or downloads one.
- It records the thumbnail each signature came from (`render_signature_source`: path,
  rendered revision, enrichment stamps, and a source-drawn thumbnail's source-products
  stamp). A re-rendered thumbnail makes the signature stale with no write site having to
  know, and so do a changed file's new source images, which land at the same path.
- It is one loop woken by the Store's change notifications (ADR 0032).

MediaMetadata 0.9's new fields are backfilled the way new library fields always are
(ADR 0039): migration v12 clears the EXIF families' extraction revisions, and
`MetadataRefresher` re-reads them from local bytes only.

- `DuplicateGroupID.samePhoto` names a group by its members, and its leaf scope selects
  them explicitly (`ContentConstraint.members`).
