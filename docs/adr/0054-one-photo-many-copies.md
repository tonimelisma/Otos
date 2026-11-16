# ADR 0054: Identical copies are one photo wherever the libraries and accounts are combined

- Status: Accepted
- Date: 2026-11-14

## Context

The owner's Immich server mirrors OneDrive folders that Otos also has as libraries. All
Media, Places, People, On This Day and search showed every such photo twice: on 2026-11-14,
16,670 of the 16,678 photos in the Camera Roll library had an Immich copy. Duplicates (ADR
0042) never paired them. It groups by Otos's digest, and an account's row had none, because
Otos downloads an account's original only for the user's own work (ADR 0046 §4).

The survey `docs/research/2026-11-14-one-photo-many-copies.md` found that apps which collect
from several sources show one item and keep the copies under it: Google Photos and Immich at
upload, Plex's versions, Mylio. Cleanup is a separate tool. A mirror the user keeps on purpose
is not waste. It is one photo in two places.

The owner decided, on 2026-11-14:

- identical copies show as one photo in the views that combine libraries and accounts, whether
  the copies are in two libraries, in a library and an account, or in one folder;
- a view of one library or folder shows exactly what is on disk there, every file;
- Duplicates still lists identical copies, so they can be cleaned up — within one library or
  account unless the user asks for copies across them (2026-11-15, ADR 0042).

On 2026-11-15, from the review of #756, #762 and #768 (#775), the owner decided:

- a library file and its own Immich mirror are never offered as duplicates ("Never offer
  them");
- a Like, Dislike or named face belongs to the photo, not the copy ("The photo");
- with three or more copies and the preferred library offline, only the next best reachable
  copy shows ("The next best copy only").

## Decision

**A combined scope shows one copy of each set of identical copies.**
- `SidebarSelection.showsOneCopy` names these scopes: All Media, Places and its map areas,
  People and a person, On This Day, and All Imports. Search narrows these scopes, so it shows
  one copy too.
- One library's scope, an import batch's, Duplicates and its groups, and a map stack's named
  members show every file.
- The scope clause, the one choke point every scoped read shares, applies the rule. So order,
  counts, filter options, map cells and On This Day's picks agree.

**Identical means the same current SHA-1** (ADR 0018). An uploaded Immich asset's `checksum`
is the SHA-1 of its original. It arrives with its listing (`SourceListedItem.sourceDigest`)
and is the row's digest, stamped with the facts the same listing wrote. A size the server
reports later, of the same bytes, takes the place of the missing size in the stamp.
- An external library's asset (`libraryId` set) has a checksum of its path, not its bytes:
  the SHA-1 of `path:<its path on the server>` (`ImmichPathChecksum`, stored as
  `media_asset.source_path_sha1`). It takes a digest only as a mirrored library file's copy
  (below), or when its original is downloaded for the user's own work.
- A name and size that match are never treated as proof.

**A mirrored library file names its external-library asset by its path** (owner's mirror,
2026-11-15; decided by the agent on the owner's delegation, because the other way, hashing
each original, would download every one of them).
- A mirror (`immich_mirror`) is the server path a library's relative paths follow on an
  account's server. After every completed sync pass, `ImmichCatalogSync` finds up to three
  library files with an external asset of the same name, size and whole-second modification
  time. It asks the server for one such asset's `originalPath` (`GET /api/assets/{id}`) and
  takes the prefix before the file's relative path, compared as bytes. The asset's own
  checksum must equal the checksum of that prefix plus the relative path. A same-named file
  from another folder confirms nothing, and the next candidate is asked. A stored prefix that
  a candidate still confirms is kept with no request.
- An asset is a library file's copy when its path checksum is that of the prefix plus the
  file's relative path, and the server lists it with the size and whole-second modification
  time that the file's digest was read at. This is rsync's quick check, on the exact path. The
  asset then takes the file's digest, stamped with its own listed facts, so a later listing of
  other bytes makes the digest stale for it.
- `MirrorGateway.pair` is the one rule. The digest write of a library file (enrichment,
  `applyContentHash`, an import's landing) pairs its mirrored assets in the same transaction.
  Each pass pairs every file again, in batches of 500 files per transaction, so an asset
  listed after its file's digest pairs at the end of the pass that lists it. A write path that
  missed the call would only delay a pair to the next pass.
- On the owner's catalog, 16,683 Camera Roll files have an Immich asset with the same name and
  size. Every one of them also has the same whole-second modification time.

**The shown copy is a library's before an account's, then the first by root and path,
among the scope's reachable roots.**
- A library's copy is the one Otos renders itself, can edit in full resolution without a
  download, and can move to the Trash.
- The rule reads only facts that no curation changes. So liking, editing or un-liking a copy
  never swaps the tile under the pointer.
- With three or more copies and the best one's library not available, only the next best
  reachable copy shows (owner, 2026-11-15). When the library is back, its copy shows again.
  Identity is the path, so that is another item: the grid's no-blank rule holds for each
  path, and the returning copy's tile paints its own thumbnail as any newly shown item does.

**Which copy is best is stored, and SQLite keeps it.**
- `media_asset.shown_copy_root_id` is the root of the best present copy ranked before a row,
  in any root, NULL for the best copy itself. It counts only present copies in a library or an
  account.
- `media_asset.has_copies` (v64) is 1 when another present copy shares the row's digest.
- Three triggers recompute both for the digest group a write leaves and the one it joins: on
  an insert, a delete, and an update of the digest, its stamps, the file's size or mtime, its
  presence or its path. They run in the transaction of every write, so no write path can leave
  them stale and no Swift owner duplicates the rule.
- A scope hides a row when its shown copy's root is in the scope. Only for a row whose shown
  copy's root is not in the scope (its library not available) does the read ask, through the
  digest index, whether a copy ranked before it is in the scope. That is a table read for those
  rows alone, so mounting or unmounting a library writes nothing. A scope that holds every
  library and account root (`holdsEveryCopyRoot`, from the root registry) has every best copy
  in reach and does not ask: its read is the one it was before.
- The window's date indexes, the stack candidates' and On This Day's carry both columns (v60,
  v64), so the common test reads no table row.

**A choice and a face belong to the photo, not the copy** (owner, 2026-11-15: "The photo").
The copies are the same relation the shown copy uses: the same current SHA-1 in a library or
an account, a mirror pair included.
- **A choice is written on every copy.** A Like, Dislike or un-choice on any copy is written on
  all its copies, whatever their presence, in the same transaction (trigger
  `media_asset_choice_made`). So the order, the counts, the Liked filter, On This Day's
  ranking and exclusion, the stacks, the tile badge and Info all read the shown copy's own
  column, unchanged, and agree.
- **The latest act wins when copies meet.** `media_choice_sequence` orders every choice act in
  the catalog (`choice_sequence`), an act order rather than a clock. When a copy joins a photo —
  its digest is read, its mirror pairs, its listing names it — every copy takes the choice of
  the latest act among them. Choices made before v64 have no act: they rank before every act,
  Liked before Disliked before Not Rated, and v64 gave each photo one choice by that rule.
- **Undo** writes the previous choice back on the copy it named, which is an act, so every copy
  takes it.
- **Overlay keeps one lifecycle.** Each copy holds the photo's choice in its own row, so a
  proven deletion of one copy purges that row alone and the photo's choice lives on the others.
- **A face on any copy is the photo's.** Faces are read from each copy's own preview and stay
  on the copy (`PhotoFaceSQL`). A person's photos, People and the People filter test a row's
  own faces and, only for a row with `has_copies`, its present copies' faces through the digest
  index. A person's narrow scope seeks its faces' photos and their copies. A person's photo
  count counts each photo once (`PeopleSnapshot.photos`).
- **Every copy shows the photo's people.** Info's People section and the photo menus list the
  shown file's own faces, then each visible person named only on another present copy, with
  that copy's face; its box is of that copy's pixels, so it is outlined only where that copy
  shows, and an act on it acts on that copy (ADR 0047, `CatalogPeopleState.faces(of:)`).
  The Person sheet's row shows each photo once, a likeness never compares a photo with its own
  copy, and the unchecked tally counts a photo once (ADR 0047).
- Edits stay on the copy they were made on.
- **Within one library**, two files with the same digest are one photo in the combined scopes:
  All Media shows one tile, the first by path. The library's own view shows both files, and
  Duplicates lists them as one identical group to clean up, within their library (ADR 0042).
  A Like or Dislike on either is written on both, and each shows the other's named faces.
  Duplicates' keeper rule therefore never meets two identical copies with different choices.

**The window shows a held choice on every copy it holds** (APP-086). Each tile's detail carries
the digest its copies share (`MediaTileDetail.copyDigest`, the trigger's own `isCopy` test), and
a choice is held in `MediaChoiceOverlay` for the act's targets and every tile the tile store
holds with the same digest, under the act's one command: they show it in the step that applies
the act, a read retires it on each as on the target, and a failed write withdraws it from each.
A copy the window does not hold yet is read from the catalog when it comes into view; read
before the write lands, it shows the choice one pass later.

**Info names where the other copies are.** The File section's `Copies` row lists the library
or account of each other present copy, in the order copies are shown in. It reads `None` when
there is none, and `Not Checked Yet` while the item's digest is owed, so a copy not found yet
is never reported as none.

## Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| Deciding the shown copy inside each read (`NOT EXISTS` over the digest index) | 17–33 s for All Media on the owner's catalog. The order index does not hold the digest, so every row costs a table read. |
| Computing the hidden set once per window pass | 0.6–1.3 s per pass at owner scale, repeated on every catalog change. |
| A Swift owner that recomputes the column after writes | Every write that moves a digest, a presence or a path would have to call it, and a missed path leaves a photo hidden. The triggers cover every write by construction. |
| Matching by name and size | A guess. Names repeat every 10,000 iPhone photos, and OneDrive's camera upload renames and converts. |
| Trusting an external library's checksum as a digest | It is the SHA-1 of `path:<path>`, which no library file's bytes can match. It names the asset a mirrored file's path points at instead. |
| Downloading every external-library original to hash it | About 147k downloads on the owner's account, against ADR 0046 §4: an account's original is downloaded only for the user's own work. |
| Matching a mirror by name, size and date alone | A guess across folders. The path checksum makes the path exact, and the size and date only say the bytes are the same version. |
| Listing every asset's `originalPath` (`POST /api/search/metadata`) | It is about 150 requests per resync, and a second record of a path the stream's checksum already names. One path per library teaches the prefix. |
| Showing the copy with the user's work (edited, liked) first | Liking or un-liking would swap which file the tile is, under the pointer. |
| Keeping a choice on its copy and resolving the photo's choice in each read | Every read that tests a choice — the order under a Liked filter, counts, On This Day, the stacks, the tile badge, Info — would need a digest lookup per row; the order index cannot hold the digest, so it is the per-row table read that took 17–33 s. A conflict between copies would also be decided in each read. |
| Propagating faces to every copy | Faces are read from each copy's own preview, by two pipelines that draw a photo differently (ADR 0042); there is no face-to-face correspondence to copy along, and a copy read later would need it again. |
| Reading faces from one copy per photo | The copies are not the same pixels: a library's file is read from Otos's 2560 px rendering, its Immich copy from a 1440 px short-edge preview drawn by libvips, which find different faces and boxes (ADR 0047). The face read from one copy cannot be outlined on the other's pixels, the copy read would change with availability, and the user's acts would have to be carried between readings of different pixels. |
| Showing another copy's unidentified faces on the shown copy | They are the shown copy's own faces detected again from other pixels; listing both would show each unnamed face twice. |
| A wall-clock time for each choice | Which act came last is a fact the catalog can hold as an order; a clock can step back (ADR 0033). |
| Storing the shown copy per scope's reachable roots | Every mount or unmount would rewrite every copied row of the library (16,000 on the owner's catalog). |
| Electing the shown copy in every read | The 17–33 s per-row read above. The stored best copy answers every row whose best copy is reachable. |
| Keeping XXH3 and adding SHA-1 beside it | Two digests answering one question. Immich speaks SHA-1, so one digest serves both. |
| Collapsing copies in one library's or folder's view | The owner wants that view to show exactly what is on disk (2026-11-14). |
| Taking identical copies out of Duplicates | Duplicates is where copies are cleaned up; only an external library's asset, which holds no bytes of its own, is left out (ADR 0042). |

## Consequences

- Migration v60 clears every digest. Every library row owes its digest again, read from its
  bytes once, downloading an evicted cloud file under the free-space floor (ENR-008). Every
  Immich account owes a full resync, which lists each asset with its checksum.
- Until a row's digest is read, its copies are not known, and a copy shows beside it.
- Migration v61 adds `source_path_sha1` and `immich_mirror` and owes every Immich account a
  full resync, so each external asset is listed with its path checksum. A library's mirror is
  learned from the server once, with one asset request, and pairing a whole library is a
  pass's batched writes. A mirror goes with either root.
- Every pass pairs every mirrored file again. On a generated library of 16,000 paired files
  (`immich.mirror.pass.of16k`), that pass costs about 3.6 G instructions and 0.4 s, off the
  main actor, and writes nothing. `CatalogStoreQueryPlanTests.mirrorReadsSeekTheirIndexes`
  holds its reads to index seeks.
- A file renamed on one side but not yet on the other pairs again once both sides list it at
  the same path.
- Duplicates never lists a file and its mirror (ADR 0042, owner 2026-11-15): an external
  library's asset is never a copy there, so nothing can keep it and send the only bytes to the
  Trash.
- Migration v64 adds `has_copies`, `media_choice_sequence` and `choice_sequence`, rebuilds the
  digest index and the six indexes that carry the tested columns, recomputes every row with a
  digest, and gives each photo whose copies disagree one choice. Its cost on a generated
  owner-shaped catalog is in `docs/research/2026-11-15-photo-level-copies.md`.
- Faces are read from every copy, so a mirrored photo's faces are read and assigned twice: on
  the owner's shape, 16,000 more preview readings than photos, once each (the readings are
  stamped and never repeat). The photo counts once in every count People shows.
- A digest write recomputes its group in the same transaction, about 0.7 ms on the owner's
  catalog. It notifies `.copies`, which the combined scopes and People depend on, and
  `.choices` too when a copy that joined a photo took its choice (`choice_sequence.joins`).
