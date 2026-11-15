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

**The shown copy is a library's before an account's, then the first by root and path.**
- A library's copy is the one Otos renders itself, can edit in full resolution without a
  download, and can move to the Trash.
- The rule reads only facts that no curation changes. So liking, editing or un-liking a copy
  never swaps the tile under the pointer.
- Curation, edits and faces stay on the copy they were made on. The copy not shown keeps its
  overlay, visible in its own library's or account's scope.

**Which copy is shown is stored, and SQLite keeps it.**
- `media_asset.shown_copy_root_id` is the root of the copy shown in a row's place, NULL for
  the copy that is shown. It counts only present copies in a library or an account.
- Three triggers recompute it for the digest group a write leaves and the one it joins: on an
  insert, a delete, and an update of the digest, its stamps, the file's size or mtime, its
  presence or its path. They run in the transaction of every write, so no write path can leave
  it stale and no Swift owner duplicates the rule.
- A scope hides a row only when its shown copy's root is in the scope. While a library is not
  available, its copies are not in any scope, and the next copy stands in.
- The window's date indexes and the stack candidates' carry the column (v60), so the test
  reads no table row.

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
| Keeping XXH3 and adding SHA-1 beside it | Two digests answering one question. Immich speaks SHA-1, so one digest serves both. |
| Collapsing copies in one library's or folder's view | The owner wants that view to show exactly what is on disk (2026-11-14). |
| Taking identical copies out of Duplicates | Duplicates is where copies are cleaned up. A mirror's pairs across libraries are listed only when the user asks for them (ADR 0042), and an account's copy is never moved (ADR 0046 §8). |

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
- Duplicates lists a mirror's pairs only while the user has it compare across libraries
  (ADR 0042). Then an account's copy is never tagged Trash (ADR 0046 §8), and by default
  each library and account keeps its own, so nothing moves unless the user chooses it. On
  the owner's catalog that is 16,001 groups, and a copies read of 4–6 s, off the main actor.
- A digest write recomputes its group in the same transaction, about 0.7 ms on the owner's
  catalog. It notifies `.copies`, which the combined scopes now depend on.
