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
(`DuplicateGroupPolicy`) that Projection runs off the MainActor on every publication.
Projection publishes the groups as `CatalogWindowState.duplicates` in every scope, so the
sidebar's Duplicates row exists exactly while a group is active.

**Otos preselects only where the choice cannot lose anything.** A group gets a default
keeper only when:

- its copies are identical;
- every copy is in one library;
- at most one copy carries authored work (curation other than Not Rated, an edit, or
  companions).

That copy is kept. Failing that, the keeper is chosen in this order:

1. the copy whose name has no Finder or browser copy suffix (` copy`, ` copy 2`, ` (1)`);
2. then the earliest birth time;
3. then path order.

Every other group waits: `spansLibraries` when its copies are in more than one library,
and `differingAuthoredWork` when more than one copy carries work. Groups spanning exactly
two libraries are summarized per library pair, with Keep Both Libraries.

**The one durable fact is Keep All Copies,** remembered per pair of paths in
`duplicate_kept_pair` (schema v11). It is overlay on both copies:

- `ON UPDATE CASCADE` carries it through Otos's own moves and witnessed moves.
- `ON DELETE CASCADE` ends it with either copy's proven deletion or its library's
  removal.

A group whose every pair is kept is listed under Kept and counted nowhere else. A later
copy of copies kept together is the only one offered as extra. Keep All is undoable,
delivered on one ordered intent stream (ADR 0032 rule 5).

**Marks are window state.** The user's Keep / Move marks live in `DuplicatesSession`, owned
by the view model; a mark is forgotten once no group holds its copy. The list always shows
every active group: one found while the user looks joins at once, and one that resolves or
vanishes leaves at once. The act moves exactly the marked copies the bar counts, through the
one Move to Trash path (`moveMediaToTrash`): its download question
(APP-045), its queue, and its undo are the ordinary ones. A group always keeps one copy:
the mark refuses the last kept copy, and ⌘⌫ on a kept row is the ordinary Move to Trash,
after which the group re-derives without it.

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
| Preselect across libraries by sidebar order | Empties a mirror library in one unread bulk act (review finding 1). |
| Persist per-copy marks | A decision in progress, not a fact about the files; it would outlive the groups it described. |
| Hold groups found mid-visit behind `N more found · Show` | A second answer to "which groups exist", besides the published state. It snapshotted the catalog before its first load at launch and hid every group behind `0 photos · 164 more found`. The owner wants the list to show every duplicate, always (2026-11-01). |
| Return as the bulk act's key | Return opens a group; a bulk move must not be one keystroke from a list. |
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
- Same-photo groups are never preselected (`DuplicateGroupWait.samePhoto`). Keep All Copies
  sets them aside by the same per-pair memory.
- Candidates are blocked by kind, display aspect and whole-second instant, so a library is
  never compared all against all. Grayscale renders are read only for proposed pairs.

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
