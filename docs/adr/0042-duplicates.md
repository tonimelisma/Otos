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

**Marks are window state.** The user's Keep / Move marks and which groups are on screen
live in `DuplicatesSession`, owned by the view model. Groups found while the user is
looking are held back behind `N more found · Show`, so the button's count and the rows
under the pointer do not move. The act moves exactly the marked copies of the groups on
screen, through the one Move to Trash path (`moveMediaToTrash`): its download question
(APP-045), its queue, and its undo are the ordinary ones. A group always keeps one copy:
the mark refuses the last kept copy, and ⌘⌫ on a kept row is the ordinary Move to Trash,
after which the group re-derives without it.

**Scopes.** `.duplicates` is every copy in a group, presented as the duplicates list, so the
list's rows are the ordinary media selection — Photo commands, ⌘⌫ and Undo's reveal read
it. `.duplicateGroup(id)` is the leaf under it, one group's copies in the ordinary
Compare, Loupe or grid, reached by Return and left by Back to Duplicates. Both resolve
through `CatalogScopePredicate.ContentConstraint`. A group is never named by its digest
outside the catalog: no digest is logged or persisted in preferences (ADR 0018), so a
browser place saved in a leaf reopens on the list.

## Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| A duplicate-group table with IDs | A second identity for facts the digests already state; it would go stale with every scan. |
| Preselect across libraries by sidebar order | Empties a mirror library in one unread bulk act (review finding 1). |
| Persist per-copy marks | A decision in progress, not a fact about the files; it would outlive the groups it described. |
| Return as the bulk act's key | Return opens a group; a bulk move must not be one keystroke from a list. |
| Single-letter shortcuts for Keep and Move | P, U and X already mean curation choices; one key never means two things. |

## Consequences

- Duplicates appear as digests arrive, because enrichment hashes libraries in the
  background (ENR-013). A library whose files are not yet hashed shows no groups for
  them, and the list claims nothing about them.
- The bar shows file sizes, as the trash bar does. Whether a move needs a download is
  asked at act time by APP-045, not predicted in the bar.
- Same-photo groups, found by pixels rather than bytes, extend `DuplicateGroupID` and the
  same policy (plan 0109 increment 5).
