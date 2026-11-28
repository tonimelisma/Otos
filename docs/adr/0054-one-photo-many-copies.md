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
  `media_asset.source_path_sha1`). It is never a digest. A mirrored file's asset is one photo
  with the file by the pair below, not by a digest.
- A name and size that match are never treated as proof.

**A mirrored library file is its external asset, by the server's path for it** (owner's
mirror, 2026-11-15; decided by the agent on the owner's delegation, because the other way,
hashing each original, would download every one of them; made a fact of its own on
2026-11-17, below).
- A mirror (`immich_mirror`, schema v80) is the set of server prefixes a library's relative
  paths follow on an account's server: one server can list one library under several paths
  (an external library per mount of the same folders; on the owner's server, two of the
  library's folders under `/srv/a/…` and the other nine under `/srv/b/…`). A prefix is learned
  from one request: `ImmichCatalogSync` takes the first library file, in path order, that no
  pair holds and that has an unpaired external asset of the same name, size and whole-second
  modification time not asked about before (`MirrorGateway.Probe.candidate`), asks the server
  for that asset's `originalPath` (`GET /api/assets/{id}`), and takes the prefix before the
  file's relative path. The asset's own checksum must be the checksum of that prefix plus the
  relative path. The prefix is recorded beside the others (`op=immich.mirror phase=learned
  serverPrefix=`), the walk pairs what it names, and the next round asks about the next
  unexplained file.
- **The probe is bounded by facts, not time** (ADR 0033). Each round asks one path per library
  with a candidate; a library whose candidate taught nothing asks nothing more that pass, and
  another round runs only while the prefixes the last round learned paired files. A candidate
  whose path taught nothing — the server refused to describe the asset (400/404), gave no
  path, a path that does not end with the file's relative path, a prefix that does not give the
  asset's checksum, or a prefix the library already has — is remembered
  (`immich_mirror_asked`, at the asset's path checksum then) and never asked again while that
  path stands; the probe runs only on a pass that owes the walk. Each refusal is logged with its
  reason and the folders it compared, never a file's name (`op=immich.mirror
  phase=candidateRefused reason= serverFolder= fileFolder=`, and `sharedTailComponents=` for a
  path that does not end with the file's).
- **A path matches in either Unicode normal form.** Immich hashes the path its crawl of the
  external library read from the server's own filesystem, byte for byte with no normalisation
  (`library.service.ts`, `path:${assetPath}`), so an accented name is in whatever form that
  disk holds it, and a Mac's library file can hold the same name in the other form (on the
  owner's library, three files in a folder whose name has an `ä`). `ImmichPathChecksum.
  everyForm` is the one rule: the checksums of the path as given, composed and decomposed. The
  walk seeks each, the probe's confirmation accepts any, and the prefix is found by comparing
  characters, which are equal in either form. A path of ASCII alone has one form and one seek.
- **A pair** (`immich_mirror_pair`) is the fact that one library file is one external asset:
  an asset whose path checksum is the checksum of one of the mirror's prefixes plus the file's
  relative path. The sync records it from the listing alone, with no download, no digest and
  no request to the server once the prefix is known. The path checksum is the server's own
  name for the file at that path, so the proof is exact; a name and size are never it.
- **The walk** (`CatalogStore.pairMirroredCopies`) is the pair's one owner. It pages every
  file of each mirrored library, 500 per read. A paired file stands when its asset's own
  checksum is among the file's under the prefixes, with no seek; an unpaired one seeks the
  account's free asset (one no file is paired with) at each of its checksums, the prefixes in
  order. It writes only a batch whose pairs are owed: a file whose path names a free asset
  pairs, and a pair whose file's path no longer names its asset goes (a file renamed on disk
  keeps its pair through the foreign key until that walk). A walk over pairs that all stand
  opens no write. The pair goes with either row by its foreign keys.
- A library file pairs with one asset, and an asset with one file. A library two accounts
  both mirror pairs with the first account's walk; the other account's asset of the same
  file stays its own photo, and so does a second asset of the same file under another prefix.
- The walk runs first, then the probe for the files no prefix explains, then the walk again
  for each prefix learned.
- The walk is owed only when what it reads moved since the last walk that did not fail (ADR
  0032 rule 8): the pass's own listing applied a change, or a library's paths, sizes or dates
  changed (`CatalogStore.libraryNamespaceRevision`, moved by every namespace revision of a
  library and by a library coming or going). A pass with neither reads no mirror and asks the
  server nothing (`op=immich.mirror phase=held`): on the owner's idle session the walk had
  read 56 pages (1,574 ms) and asked the server three paths every five-minute poll with
  nothing listed. A server or Store failure leaves the walk owed; the server refusing to
  describe an asset (400/404) is an answer and does not.

**A pair is one photo while its versions agree** (decided 2026-11-17, on the owner's
delegation). The path says the two rows are the same file; whether they hold the same bytes
is the question every copy answers, and the copies' rule is "identical copies are one photo".
- Both rows have a current digest: they agree when the digests are equal.
- Otherwise the asset must be listed with the file's current size and whole-second
  modification time: rsync's quick check, on the exact path. A file whose digest is not read
  yet — a cloud-only one, whose download for its digest has not come yet (ADR 0009 §12) — agrees
  this way with no byte read.
- While the server has not read the asset, it reports no size, and the asset agrees on its
  whole-second modification time alone (v83, owner, 2026-11-28). An external library's asset
  is listed when the server's scan finds its file and read only when its metadata job runs,
  which on the owner's server waited behind 247,640 others; the size check could never pass
  for it, and 930 photos already shown from the Camera Roll library showed again, as
  placeholders, from the account. The path makes the file exact, and the time the scan read
  names its version; once the server reports the size, the full check holds again, so an edit
  the server reads later still splits them (`docs/research/2026-11-28-immich-unprocessed-assets.md`).
- A pair whose versions differ — the file edited and not yet read again by the server, or a
  digest that disagrees — is two photos, each shown where it is, until a listing or a read
  makes them agree. The pair itself stays: it is a fact about paths, and the next listing of
  the same file's new bytes needs no new walk.

**The copies of a photo share a key, and SQLite keeps it** (schema v79, v80).
- `media_asset.copy_key` is a row's current digest of some bytes in a library or an account;
  for a pair whose versions agree, both rows take one key: the digest either holds, else the
  pair's own key, `pair:<account root id>:<asset path>` as bytes — the pair table's unique key,
  which never equals a 20-byte digest. A path checksum is not that key: two accounts on two
  servers with one server path for two different files would give four rows one key, and one
  photo would be hidden as the other's copy. Every rule of the photo below — the shown copy, `has_copies`, the
  photo's choice, its faces, Info's `Copies` row and the window's held choice — groups by the
  key (`PhotoCopySQL`, `idx_media_asset_copy_key`), so a digest group and a mirror pair are
  one relation, not two.
- The copy triggers set the key in the write that moves what it reads: a row's digest, its
  stamps, its size or mtime, its presence, its path, or its pair's other row's. The pair
  table's triggers do the same when a pair comes or goes. The key is a projection of facts the
  catalog holds and the triggers rebuild in every write; nothing writes it by hand.
- No trigger relies on a conflict clause of its own. SQLite runs a trigger's statements under
  the policy of the statement that fired it whenever that statement has one, and an upsert's
  `DO UPDATE` has ABORT: the scan's and the sync's upserts fire these triggers. So the keys a
  program regroups are held in `copy_key_touched`, a table with no key, where a key put twice
  is no conflict, and a person's photo is added only where `NOT EXISTS` finds none (v81).

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
- `media_asset.has_copies` (v64) is 1 when another present row shares the row's copy key.
- The copy triggers recompute both for the key a write leaves and the one it joins: on an
  insert, a delete, an update of the digest, its stamps, the file's size or mtime, its presence
  or its path, and a pair coming or going. They run in the transaction of every write, so no
  write path can leave them stale and no Swift owner duplicates the rule.
- A scope hides a row when its shown copy's root is in the scope. Only for a row whose shown
  copy's root is not in the scope (its library not available) does the read ask, through the
  copy key's index, whether a copy ranked before it is in the scope. That is a table read for those
  rows alone, so mounting or unmounting a library writes nothing. A scope that holds every
  library and account root (`holdsEveryCopyRoot`, from the root registry) has every best copy
  in reach and does not ask: its read is the one it was before.
- The window's date indexes, the stack candidates' and On This Day's carry both columns (v60,
  v64), so the common test reads no table row.

**A choice and a face belong to the photo, not the copy** (owner, 2026-11-15: "The photo").
The copies are the same relation the shown copy uses: the same copy key, which a digest group
and a mirror pair whose versions agree both give.
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
  own faces and, only for a row with `has_copies`, its present copies' faces through the copy
  key's index. A person's narrow scope seeks its faces' photos and their copies. A person's photo
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
| Pairing a mirror through the file's digest (the asset taking the file's digest, v61 to v78) | The pair waited for the file's bytes, read only after a cloud-only file's download, and the walk read only files with a digest: on the owner's catalog on 2026-11-17, of the 982 files the stored prefix named, 968 had no digest and only 14 were one photo with their asset. The path checksum already names the asset. |
| A second key beside the digest (rows are copies by digest or by pair) | Every rule of the photo — the shown copy, `has_copies`, the choice, faces, Info, the held choice — would ask two relations and close over both; one key makes them one relation. |
| Writing a stand-in digest on the library file | The file's digest says what its bytes are, and Duplicates and enrichment read it so; a path checksum there would be a false fact. |
| Showing a pair as one photo whatever its versions | A file edited and not yet read again by the server is not the photo the account holds. The copies' rule is identical copies; the pair waits for its versions to agree. |
| One prefix per library (v61 to v79) | The owner's server lists his library under two prefixes: 982 files under the stored one, and, of the other 15,955, 15,942 under a second exactly, 3 more once the path's normal form is matched, and 10 not on the server yet (read on 2026-11-17 from the catalog's path checksums and one asset's `originalPath`). With one prefix, a prefix that paired any file was kept and the second was never asked. |
| Asking up to three candidates every owed walk | The same three paths were asked every walk when none confirmed. One request per library per round, with every unanswered candidate remembered, asks each path once. |
| Comparing server and library paths as bytes | A name with an accented letter can be in either normal form on either disk; three of the owner's files never paired. |
| Normalising paths when the catalog stores them | The checksum is of the server's own bytes, which Otos does not choose, and a library path names a file on disk as it is; the one rule belongs where the two are compared. |
| The asset's path checksum as a pair's copy key (v79) | Not unique across servers: two accounts with one server path for different files made them one photo. |
| Listing every asset's `originalPath` (`POST /api/search/metadata`) | It is about 150 requests per resync, and a second record of a path the stream's checksum already names. One path per prefix teaches it. |
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
- Migration v79 adds `immich_mirror_pair`, `copy_key` and its index, and the copy triggers
  over the key; clears the digests v61's pairing wrote on external assets; and gives
  `person_photo` the key in place of the digest. Pairs are recorded at the account's next walk,
  which every launch owes. Its cost on a generated owner-shaped catalog is in
  `docs/research/2026-11-17-mirror-pairs-by-path.md`.
- A walk reads every mirrored file again, a checksum and an index seek each, and writes only
  the pairs that are owed, so a walk over pairs that all stand opens no write transaction
  (`BackgroundOwnersIdleTests`). `CatalogStoreQueryPlanTests.mirrorReadsSeekTheirIndexes`
  holds its reads to index seeks.
- A file renamed on disk unpairs at the next walk and pairs again once the server lists it at
  its new path; one renamed on the server first pairs once the rename reaches the catalog: the
  listing or the library's namespace that moves owes the walk (`ImmichMirrorHoldTests`).
- Migration v80 rebuilds `immich_mirror` with the prefix in its key (its one row per library
  becomes the first of the set), adds `immich_mirror_asked`, makes the copy triggers that spell
  the key again, and rekeys every pair's rows. On the owner's library the account's next owed
  walk — the first pass of every launch — asks the server one path, learns the second prefix
  and pairs about 15,945 more files, so All Media shows about that many fewer items; a further
  request is made only if a file no prefix explains still has a candidate asset, and that one
  is remembered. Its cost on a generated owner-shaped catalog is in
  `docs/research/2026-11-17-mirror-pairs-by-path.md`.
- Migration v81 makes `copy_key_touched` again with no key and the face triggers again with
  `NOT EXISTS` in place of `OR IGNORE`. Before it, an Immich asset listed before the server read
  its size, paired, and listed again with its size aborted its batch in the copy trigger; the
  batch was never acknowledged, so every later pass failed on it and the pair stayed two photos
  (owner's catalog, 2026-11-19: 151 assets). It rewrites one empty table and two triggers.
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
  catalog. It notifies `.copies`, which the combined scopes, People and Duplicates are built
  from, only when it changed which files are copies: where the written row stood before and
  after the write (`DigestStanding`, read in the same transaction) says whether it joined or
  left a copy key another row holds, or its pair's asset took its digest as their key. A digest no other
  copy holds — most of a library's backlog — notifies only `.detail` (the tile's copy digest,
  Info's `Copies` row), and a digest written again unchanged notifies nothing. On the owner's
  library a read-only session that imported and edited nothing announced `.copies` for 226 of
  its 277 changes, one per digest read, and each woke All Media's order, People and Duplicates
  (2026-11-16 scorecard). It notifies `.choices` too when a copy that joined a photo took its
  choice (`choice_sequence.joins`).
