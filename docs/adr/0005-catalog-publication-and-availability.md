# ADR 0005: Catalog Publication, Selection Delivery, And Availability

- Status: Accepted
- Date: 2026-06-15
- Last updated: 2026-11-14

## Context

Catalog mutation, UI derivation, and MainActor assignment have different owners.
`CatalogStore` owns SQLite, root runtime catalog state, Store-owned queries, and scans. `CatalogProjection`
owns ordering, scope filtering, availability hiding, empty-state selection, and
the UI publication cadence. `CatalogWindowViewModel` owns the final state that
SwiftUI observes and converts user actions into explicit intents.

Library reachability is transient. A root loaded from SQLite has not been
checked during the current process and therefore cannot truthfully be called
available. A temporarily missing removable or network root must not cause Otos
to delete catalog rows.

## MECE Decision Scope

This ADR owns:

- Store change notifications versus Store-published UI snapshots
- Projection-owned coalesced `CatalogWindowState` publication
- one-in-flight publication and requested-during-await behavior
- explicit sidebar-selection delivery from ViewModel to Projection
- transient `unknown`, `available`, and `unavailable` library availability
- availability-driven filtering and empty states

This ADR references but does not own:

- SQLite schema, filesystem facts, scan reconciliation, and package traversal:
  ADR 0002
- normalized path identity and unsandboxed access: ADR 0003
- permanent single-window UI ownership: ADR 0004
- ViewModel state-consumer lifetime and lossless serial add/remove delivery: ADR
  0004
- AppKit grid rendering: ADR 0006
- precomputed file-name sort keys: ADR 0007
- descriptor query ownership, generated best values, and current two-tier
  publication cadence: ADR 0011

Metadata, thumbnails, manual scans, sandboxing, bookmarks, durable scan IDs, and
media-container import are outside this decision. Coarse running-app FSEvents→rescan
policy is owned by ADR 0002.

## Decision

### Store Truth And Change Signals

`CatalogStore` emits cheap typed change notifications, never a UI-ready catalog.
Ordinary events only invalidate Projection. A successful root removal also
carries its typed path through the lossless event stream. That transient fact is
necessary because remove and same-path add can complete inside one publication
interval, leaving a final queried state whose path membership looks unchanged.
ADR 0010 supersedes the old raw snapshot read: Projection now asks Store for
current root rows and ordered asset IDs, and visible grid cells fault detail by
ID through Store queries.

This keeps UI cadence out of Store mutation paths. SQLite and Store-owned root
runtime state remain catalog truth.

A change says what a write touched. `.changed(CatalogChangedFacts)` names the kinds of
fact the write changed — which rows are shown (`membership`), capture dates, kinds and
formats, grouping identifiers (Live Photo and burst), the user's choices and stack keys,
locations, place names, faces and who they are, copies (digests, render signatures, copies
kept together), the search labels On This Day reads, and `detail`: what only a tile, a pane
or enrichment reads. The Store names them at the write, the one place that knows what it
changed; an enrichment batch compares what SQLite stored before and after each row. A write
names the kinds it wrote and never more, through one named set per shape of write:
`presence` for which existing rows are shown (a Trash mark or move, a put-back, a source's
hide, a deletion, an attachment's awaiting rows), `fileFacts` for an existing row's file facts
(its presence plus the date and kind they stand for until its bytes are read, the stacks, a
face's tile and Duplicates' facts named beside them), `movedRow` for a row that took another
path (every kind keyed by a row; only place names stay), `edit`, and `settledImport` for an
imported copy. A change that follows no write names the runtime state it reports: a root's
reach is `membership` with no row named (the catalog's load, an attachment), a root's own
state is `membership` with `rows: .none` (a root added with no rows yet, a scan, listing or
removal ending, a detach, the Store's shutdown), and an operation that wrote nothing sends
nothing. Only `.libraryRemoved` stands for every kind: a removed library may have held any
fact. `.assetsAdded` is a scan, device-listing or source-listing
batch that only inserted rows: the type that says so is `ScannedFileUpsert.inserted`,
tallied per write in `CatalogRowChanges`. A new row carries nothing Otos derives — no
metadata, so no Live Photo pairing key, and no digest, rendering, faces, place or
embedding — so only what lists rows has new input: the window publishes it and enrichment
claims it, while Duplicates, People, search, place names, preview faces and render
signatures wait for the enrichment write that gives them something to read. Without the
split, a 147k-asset Immich first sync ran a whole-catalog pass in each derived owner for
every 500-line batch, all competing with the listing's own writes for the page cache and
the disk (`docs/research/2026-11-12-listing-batch-cost.md`).

Rejected: holding back every derived owner while any listing lease is open. A lease
says a source is being read, not that a write left derived facts alone; a resync's
batch can hide or purge rows that carry faces and digests, and enrichment of other
roots keeps changing derived facts during an hour-long sync.

**Every write is announced, and the tests prove it.** A narrowed change can fail in only one
way: an owner stops hearing a write it reads, and its work stays owed with nothing logged.
So every test's Store carries a change-coverage guard (`CatalogChangeCoverage`, reached
through the Store's test seam `CatalogWriteAudit`, nil in the app).

- **What a commit owes.** A GRDB `TransactionObserver` on the Store's writer maps each
  committed transaction's inserts, deletes and updated columns through
  `CatalogChangedFacts.writes` to the kinds it owes. Three writes owe nothing of their own: a
  column written into a row the same transaction inserted (part of the insert), a row
  inserted and deleted again in it, and a row an `ON DELETE CASCADE` deletes with its parent
  (part of the parent's delete).
- **The pairing rule.** A change the Store sends pays, on every commit before it, the kinds
  it names (`.libraryRemoved` every kind, `.assetsAdded` membership). A change sent
  after a commit is what a keyed re-read needs, so one sent at the end of the same operation
  pays, and so does one a later operation sends (`endSourceListing` after a listing's
  batches). A change sent before the commit pays nothing for it.
- **The deadline.** The end of the test: its Stores are shut down, the work each shutdown
  overtook is awaited — the Store's own tasks it cancelled (scans, filesystem passes, the
  reconcile loop), and every write still in flight with what its operation sends after it —
  and every commit still owed fails the test, naming the operation that wrote it, the columns
  and tables, and the kinds no change named. Shutdown's own change pays nothing. A commit
  after shutdown began, or in a write in flight when it began, is one the shutdown overtook
  and is never reported: its operation may abandon it, as a scan batch that finds its lease
  gone does. A change sent after shutdown, by work still finishing, pays.
- **The narrowings it allows** are the Store's own value comparisons and one owner's own
  state, each listed in `CatalogChangeCoverage.Narrowing` with its reason: the enrichment
  overlay's before-and-after comparison; `DigestStanding` and the copy-key triggers; the
  render-signature trigger; On This Day's left-out comparison in a search write; and
  `enrichment_claimed` and `last_synced_at`, each read only by the owner that writes it.

Changes that report runtime state and follow no write (scans, listings, availability) are
not a coverage concern. The observer is a guard, never the source of changes: it cannot see
the value comparisons, and runtime state has no write.

### Projection-Owned Publication

`CatalogProjection` owns one publication loop and two counters. Every Store change
and every sidebar, sort, or filter intent adds to `requested`; a pass records the
`requested` it started from and advances `covered` to it only when its build
succeeds, so work is owed exactly while `requested != covered` and nothing a
finishing pass does can erase a request made while it ran. One consumer task runs
every pass off a `bufferingNewest(1)` doorbell: intents ring it directly, other
Store changes wait for a cadence task that rings it while Projection is behind. On
a pass, Projection asks Store for current root rows plus descriptor-ordered asset
IDs, derives one `CatalogWindowState`, and yields it. ADR 0032 states the rule.

A pass repeats a catalog read only when a change that can alter its answer has happened.
Projection counts each kind of fact a change names (`CatalogFactRevisions`, one revision
per kind, never a flag). It keeps the last answer of each held read — the ordered assets
with their stacks, the stack collapse, the whole-roots stacks, the filter's options, the
import batches (the sidebar's counts, `importBatchInputs`: rows shown, grouping, stacks),
the place-name languages (`placeNameLanguageInputs`: place names) and a shown search's
answer; `CatalogProjectionReads` lists them and a pass logs which it reused (`reused=`) —
with what the read was for
(the resolved descriptor or sidebar row, the available roots, the place-name languages; the order
is for the descriptor without its search, which narrows the order after it is read, so a
search, a change of it and its clear read no order — each read All Media's 164,762 rows again
on the reference catalog — and a scope's collapse is held apart from its last search's) and
the revisions its pass started from (`CatalogProjectionReads`). A pass reuses an answer
while what it was for is unchanged and no kind it depends on moved, and reads it again
otherwise. The order depends on rows shown, capture dates, kinds, formats, grouping and
choices always, and on locations and place names, faces, copies or On This Day's labels
where the scope or the filter is by them (`CatalogChangedFacts.orderInputs(of:)`); the
options depend on rows held, kinds, formats, grouping, locations and place names
(`filterOptionsInputs(of:)`), never on which file is a copy: they are read with every copy
of identical files, which share their kinds, formats and places, so a scope that shows one
copy offers what it would offer with all, and a place's count, which only orders the places,
counts each copy (227 of the 277 changes in a four-minute tour of the reference library named copies, and
each read All Media's options again); the collapse is a pure step over the scoped order, its stacks
and expansions. A shown search's answer is held the same way, keyed also by the search
index's own revision, which only the index moves (ADR 0048); its Store fact matches depend
on rows shown, capture dates, locations and faces (`searchFactInputs`). The filter's options are read beside the order, since neither depends on
the other. Every change still advances `detailRefreshGeneration`, so a pass that reused
every read publishes the refresh the grid's visible tiles read their details by.

The owners of derived products — render signatures, preview faces, place names, the search
index and descriptions — hear the same kinds, and each wakes only on a kind its own candidate
SQL reads. Its inputs are derived, not listed: each prepared statement's GRDB region is
matched against `CatalogChangedFacts.writes`, the one table of which columns each kind's
writes change (`CatalogOwnerInputs`), less the kinds the owner's own writes name, with the
facts its SQL binds rather than reads (which roots are reachable) and, for place names, the
user's locale. A search write names `.searchContent`, the embedding or text reading a
description waits for. `CatalogOwnerInputsTests` proves every column an owner reads is named
by a kind, so a write the table does not name cannot leave an owner unwoken.

Before this, the only distinction was detail-only versus structural, and every enrichment
write that moved a stored date by any amount, every face assignment, every place name and
every digest was structural: on the reference library's 166,555-asset catalog, while faces and Immich
metadata were read, the window re-read the 164k-row order (2–4 s), the options (0.9–1.2 s)
and the collapse (0.4–0.9 s) back to back at over 300% CPU, and 368 of 642 order reads in
three hours returned the order it already showed
(`docs/research/2026-11-14-window-reads-and-launch.md`).

A publication hands on what did not change. At the publication point, off the main
actor, Projection compares the state a pass built with the last one it published and
replaces every library-sized part that is equal — the grid's `CatalogGridContent`, the
map, On This Day, the duplicate groups, People, the filter's options and the import
batches — with the last publication's own, then builds the new content's position index
(`CatalogWindowState.sharingUnchanged(with:)`). The comparison is paid once, here; the
window, the change summary and SwiftUI then tell an unchanged part by identity (ADR 0004).
A grid order of the same query that is not equal is published as an edit of the last
publication's (`CatalogGridContent.Edit.between`): the same walk of the two orders side by
side, which tells the runs they share at either end equal item by item and looks up only the
items between, in an index of that stretch alone, so a read that moved a few photos costs a
few look-ups more than telling the orders equal. Its position index is the last
publication's carried through that edit, as an act's is (below): the publication writes no
table of the order. The 2026-11-18 daily run flagged `window.publish.orderChanged.158k`
(788.8 → 980.2 M instructions) when the walk was added beside a table of the new order,
written whole for every read and read by the walk; carried, the publication costs the walk. A hide, a Put Back and a stack
expanding are already edits of the order they were made from. Each published content keeps
the edit from every earlier order still held, the edits between composed, so the grid takes
any publication of the query in by an edit of the order it shows, whichever publications the
window skipped (ADR 0006). Only a new query's order (another scope, filter, sort or search)
is published whole, and the grid reloads it.

Rejected: a time-based throttle on background passes beyond the existing cadence (ADR
0033: whether a read can have changed is a fact the Store holds), a generic query cache in
the Store (the Store would have to know who reads what; the reader knows its inputs).

**An act's publication is its edit.** A content's position index (`CatalogGridContent`'s
`Positions`) is a table of each identity's position in an order it was made from, the edit
from that order to this one, and this order's inserted items by identity; a position is the
table's, moved past the edit's removals and insertions by two binary searches. An order made
by an edit of an indexed one — a hide, a Put Back, a stack expanding, the acts held on a
read — takes that index with the edit composed onto it (`Edit.followed(by:)`), at the
edit's cost; only an order that is no edit of an indexed one (a new query's) writes a
table, once, off the actor. Once the composed edit names as many positions as the order holds,
carrying it would cost what the table costs, so the table is written whole again
(`Positions.editing(by:into:)`): an index's edit never outgrows its order. A Put Back finds
its neighbours by the index and copies the order's runs between the insertions whole
(`CatalogGridContent.inserting`); it no longer walks the order. Counted at 160,000 photos
(`ActPublicationWorkTests`), a one-photo Move to Trash visited 1 position and wrote 159,999
index entries, and its Put Back visited 159,999 and wrote 160,000; now each visits and writes a
few, the same few as at 16,000. The order's storage is still copied in runs (a Move to Trash
copies 640 KB of identities and 2.5 MB of days at that size, a memory move, not a walk): a
persistent order would spare it at the price of every reader of the order, which reads it as
an array. Rejected: a balanced tree or a rope for the order and its index, for the same reason
and because the measured cost was the table, not the copy; a table written for every read's
publication, which cost the 158,000-photo publication 848 M of its 980 M instructions in the
Debug build while the edit it carried named two positions.

**An act is never queued behind a build.** The projection is one actor, so an act waits for
whatever synchronous step it is running. Every step of a pass that walks the scope leaves the
actor (ADR 0032, rule 6), except a search's narrowing to its matches: the order patch and the
read's arrays held (`holding`, `patching`), the scope's facts, the collapse and the window
state (`scopedFacts`, `collapsed`, `assembled`), and the publication itself
(`preparePublication`): the comparison with the publication shown, the edit from its order
and the index of an order read whole, against the publication shown and the acts held when
the build ended. A Move to Trash, a Put Back or a choice that reaches the projection meanwhile
is applied in its own step to the last publication and published at once, as an edit of the
order the window shows. The pass's publication then follows the rule of ADR 0032 that newer
work never cancels published work: the build is not cancelled, and its publication is applied
on top of the act. In the step that publishes it, when the acts held, the duplicate groups
or People differ from what it was prepared with, the build's own order — indexed — is edited
by the acts held now (`publish`); its edit from the last publication is found through the base
publication both were made from (`CatalogGridContent.edit(from:)`, undoing one side's edits,
`Edit.inverse`), which the pass holds until then, and the publication is linked to the last
one by it, so the grid follows it by the edit whichever of the two it shows. An intent for
another query supersedes the publication's preparation as it does the build. Rejected: taking
acts ahead of the build by a second queue (two owners of the window's state); cancelling the
build for an act (ADR 0032, and an act changes one row of what the build answers); publishing
the build first and the act after (the act would wait for the build it does not need).

**Keyed re-reads.** A change that moved only capture dates, of rows it names
(`CatalogStoreChange.changed(facts, rows:)`), re-reads those rows alone. The projection numbers
the changes it hears with their rows (`CatalogChangeLog`). A held date order keeps each row's
`best_capture_local` and the roots' row IDs (`CatalogOrderKeys`). When every change since the
order was read that moved a fact the order or its stacks depend on moved only capture dates
of named rows, a pass reads those rows by key through the scope's own predicate and sort
(`CatalogStore.orderedAssetIDs(ofRows:for:availableLibraryPaths:)`) and merges them into the
held order: the changed rows leave it, and one walk puts each re-read row where `ORDER BY`
would (`CatalogOrderPatch`). The comparator is the SQL's: capture time in the order's
direction with NULL the least value, then root row ID, then path by its bytes. The SQL still
owns the order; the merge places rows the SQL itself sorted, so there is no second rule.
Anything else is read whole: another kind of fact, a change that names no rows, a stack fact,
more than 5,000 rows, changes older than the 256 kept, and a scope by place, day, batch or
content. The log also counts the changes by kind (`revisions`, what says a held read is stale),
and one `record` keeps both, so a kind can move only with an entry that names its rows. A
write the window learns of from its own act — a Move to Trash's mark, a Put Back's Store work,
a choice — often lands before the Store's change for it reaches the projection; the act's
report records it there as that change would, with the rows it wrote, so the pass that retires
the act's hold reads the write whole instead of patching the held order with no rows. On the
reference catalog, while
a sync brought metadata for 152 rows, the order was read whole 125 times, 33.7 s of reader
time (installed 66153b4a; `docs/research/2026-11-16-window-reads-reference-catalog.md`).

The filter's options are re-read by key the same way. An options read keeps, beside its
answer, what each row of the sidebar row's scope gave it (`CatalogFilterOptionTally`): per
row, its SQLite row id and the indexes of its file type and its map cell in small tables of
the types and cells present, with a count per type and per cell (about 2.2 MB for All Media's
159,000 rows), and, in the catalog's one language, the names of the cells its rows give, each
read by the cell's key once the walk has counted them (never every named cell's: 1,435 on the
reference catalog, more than an import batch's rows); the options are derived
from the counts. When every change since the tally was read that moved a fact the options
depend on moved only locations or file types of named rows, or the cells' names
(`CatalogChangeLog.keyedOptionRows`), the read seeks those rows by key through the scope's own
predicate (`CatalogStore.filterOptionsOfRows`; a row the scope no longer counts gives
nothing), with the names of those rows' cells, and of every cell the tally counts when the names
moved, each by its key, and the projection patches
the held tally in place in the step that applies the read's end, after checking it is still
the tally the read was planned from. A re-read row the tally never counted means the scope's
rows changed under it: the tally is dropped and read whole. A row id names a row while it
exists, and only a membership change removes or adds rows, which reads the tally whole, as do
grouping (a Live Photo pairing can hide a row no change named), a change whose rows are
unnamed, more rows than `rowCapacity`, and a scope a key cannot test (Places, a day, a batch,
a person). The whole read is one walk of the scope's rows with each row's kind, format and
located cell: a wide scope walks `idx_media_asset_stack_candidate`, which holds the kind, the
format, the key and what tests visibility, and finds
each located row's coordinate by its key in the location index. On the reference library a sync
re-read All Media's options whole 92 times while 152 metadata changes arrived.

**An ID is a place in the process's identity table.** `MediaAssetID` is 4 bytes: the place of
its (library root, relative path) pair in `MediaAssetIdentityTable`, which holds each distinct
pair's bytes once, in mapped regions outside the malloc heap, for the rest of the process.
Equal pairs are one place, so IDs compare and hash as integers, and an order, a collapse, a
position index or a stack's members hold no string. An ID that carries its own relative-path
string is 56 bytes, and every read makes a new one per row: after a tour of the reference shape
the window, People and the stacks held 691,102 strings (86 MB) and 40 MB of ID arrays that way
(`docs/research/2026-11-17-asset-identity-memory.md`). The place is never persisted or logged;
the catalog's key and the overlay's identity stay the pair (ADR 0008). Rejected: the catalog's
row id as the in-memory identity. `media_asset` has no `INTEGER PRIMARY KEY`, so `VACUUM`
(the open's compaction) and a table rebuild (v71) renumber its rows, and a deleted last row's
id is handed to the next insert; a held ID would then name another file. Every consumer of a
path would also need a Store read to get it.

**One identity table for the process.** The table is process-wide (`MediaAssetIdentityTable.shared`),
not any owner's state. An ID is made wherever a path is read: the Store's decoding on its read
lanes, the scanner, file events, imports, reorganizations, Immich and camera syncs, view models,
tests. The same pair must be the same ID across all of them, because equality and hashing compare
only the place. A table owned by the Store and handed to whatever makes IDs would need a table at
every one of those sites, many with no Store in reach. And two tables in one process, as every test
that opens its own Store makes, would give one place two meanings: an ID from one would compare
equal to an unrelated ID from the other. An ID that carried its table to tell them apart would no
longer be 4 bytes. So the place is a value-level fact, like an interned string or a Swift type's
metadata, and the table holds no owner's state. Rejected: a Store-owned table passed to the ID's
makers, for the reasons above.

A test that bounds what the table costs makes a table of its own that counts its steps
(`MediaAssetIdentityTable(countingSteps:)`) and uses its IDs only with the owner it makes with
that table (`TileContentStore(identities:)`), so no ID of it meets the process's table; the
process's table counts nothing.

- **Bound.** The table never frees. It holds one entry, about 110 bytes, for each distinct pair the
  process ever names. That is the catalog's rows, plus each path a rename, a reorganization, an
  import or a new Immich asset folder adds for the rest of the process: a reorganization of 165,000
  files adds 165,000 entries, about 18 MB. Every `op=process.memory` sample logs its pairs and
  bytes (`assetIdentities`, `assetIdentityMB`), so a long session's growth can be read from the log.
- **Order without strings.** Each entry keeps its relative path's NFC form, which is the same bytes
  for an ASCII or already-NFC path. `relativePathPrecedes` compares those bytes. Comparing them
  gives exactly `String`'s `<` order, since `<` is the lexicographic order of the NFC scalars and
  UTF-8 preserves that order. `pathPrecedes` and `relativePathThenRootOrder` add the root, and
  `relativePathBytesPrecede` compares the raw bytes, which is SQLite's binary order. Each is one
  acquisition of the table's lock and decodes no string, so no comparator or per-row loop
  decodes a string from the table. Each comparison used to take the lock twice and allocate
  two strings.
- **One lock, held for a rebuild only past the catalog's rows plus a quarter.** Every read and
  every comparison takes the table's lock once, for a copy or one byte comparison, and waits
  behind another caller's lookup or one new entry, because the index is sized at open (below).
  A session that names more pairs than the catalog held at open plus a quarter rebuilds the
  index under the lock each time it fills half: a first Immich sync into an empty catalog
  (147,000 assets) and a reorganization of all 165,000 files are the two that do, each a few
  doublings whose last moves every place made so far. Rejected:
  reading entries without a lock (they never change once published, but the reads go through
  a raw pointer shared across threads, which ARC-042's gate forbids); and a second lock for
  the index alone, which needs every place's key copied beside the index (about 5 MB of heap
  on the reference catalog) to probe without the entries, for a rebuild that sizing at open
  keeps out of every session within the catalog's size; and sizing again before a bulk add
  from its count, since the Immich sync stream announces no total, and a reorganization's
  plan, whose size is known, would still rebuild under the lock at its start, moving every
  place made so far: it moves the pause, it does not remove it.
- **No rebuild within the catalog's size.** The catalog sizes the index when it opens (`reserve`), from its
  rows plus a quarter, before its first read makes their IDs. Making IDs then never rebuilds the
  index. Counted as slots moved in one rebuild: unsized, 20,000 entries move 32,768 at once (at
  165,000, 262,144), against none after sizing (`MediaAssetIdentityTableTests`). A session that
  names more pairs than that doubles the index each time it fills half, and every
  `op=process.memory` sample carries the largest rebuild so far
  (`assetIdentityLargestRebuild`).

**One copy of an order.** A read makes its own arrays, so two reads of one order are two
copies. When an order read again, whole or by key,
comes back equal to the order the slot holds, the projection keeps the held arrays — IDs,
day buckets, coordinates and sort keys, each where it is equal
(`CatalogOrderedAssets.holdingArrays(of:)`) — so the collapse it reuses, the published window
and the order slot hold one copy. Before this, a re-read that changed nothing left the reused
collapse and the window on the first read's copy and the slot on the new one: All Media held
twice, 340,808 path strings for 164,766 paths, about 25 MB on the reference shape. Rejected: a
table of the paths every read hands out, one string each. It held one string per path and
raised the footprint by about 90 MB, because strings that never die, scattered among a
read's freed temporaries, keep those pages in the footprint
(`docs/research/2026-11-16-shared-path-strings.md`).

Before the Store's initial load has applied, its roots are unknown, not absent.
`CatalogStore.loadedLibraries()` returns nil until then, and Projection publishes a
loading state for it — no title, no items, and the `.loadingCatalog` empty state,
which the grid draws as nothing — instead of deriving "No Media" from an empty root
set. The first Store change after a loading publication is the load itself, so it
publishes immediately rather than on the background cadence; leaving the window
blank for a cadence tick after the catalog is already readable was measured at about
one second of a launch that loads its catalog in 120 ms (APP-044).

For the same reason a change of which rows exist (`.membership`) publishes immediately
while the published window shows no item. The cadence spares the main actor the apply of
a shown grid that a background change reorders; a window that shows no item has none, and
what it waits for is its first rows. A newly added library's first scan batch waited
0.9 s for the next tick at the reference library's size
(`docs/research/2026-11-17-a-new-library-at-the-reference-size.md`). Once the window shows
an item, such changes wait for the cadence again (ARC-019).

When Projection receives `.libraryRemoved(path)` for its selected root, it
immediately retains `.allMedia` as selection input and requests a publication. A
same-path replacement therefore remains unselected even when no root-absent
state was published. The path is transient context, not generated identity;
SQLite row IDs remain Store-private.

Only one pass runs at a time, because only the loop task runs passes. Actor reentrancy
lets new input arrive while a pass awaits Store reads; it raises `requested`, the
finishing pass covers only what it started from, and the loop runs again. The one
exception to "one derivation in flight" is a build an intent superseded (below): it may
still be ending its cancelled read while the next pass runs, and it publishes and keeps
nothing.

A user never waits for work answering what they left. A pass runs its build in a task it
waits on; an intent whose descriptor that build does not answer — another scope, filter,
sort or search — cancels it in the step that applies the intent, and an intent for another
sidebar row cancels the options read too. That work is unpublished and can
never be published, because what it answers is no longer asked; GRDB interrupts its
statement. The pass does not wait for the cancelled work to end: a cancelled read ends only
when its statement, or its wait for a connection, does, and the next scope must not wait on
either. The superseded pass publishes nothing, covers nothing and rings the loop at once, so
the new request is built next; whatever a superseded build read, its result is discarded
even if it finished in spite of the cancellation, because a cancelled GRDB read holds
errors, not a catalog, and a superseded build stops before it touches the search reader or
counts a read. On the reference catalog the next pass started 3.2–6.6 s after a People build
was superseded, the pass waiting for that build to end
(`docs/research/2026-11-15-scope-returns-and-superseded-builds.md`). A store change supersedes nothing: the
build in flight is for what is shown, and the next pass takes the change up. Teardown
cancels the loop, and a torn-down pass publishes nothing. On the reference catalog a sidebar
click waited 2–9 s for the All Media build it left, then 1.4 s on the main thread applying
it (`docs/research/2026-11-14-scope-switch-and-background-laps.md`).

The filter's options never hold the window back, nor the pass after it. A pass whose options
are owed publishes the window with the last options read for the same row (none for a row not
read yet: the popover lists every kind, and the types under each arrive with the read), asks
for the options and covers its request. The options are read as their own work, one read at
a time, with their own revision counter: an ask while a read runs for other revisions is read
when it ends, and a read's answer is kept and the window republished with it in the step the
read ends in. An intent on the same row is built while they are read. Waiting for them was
the larger part of the slowest steps on the reference library: a search, a clear and a sort each waited
15–23 s for the options read of the pass before (`docs/research/2026-11-16-window-reads-reference-catalog.md`).
A wide scope's places are read walking its date order index, each located row's cell found
by its coordinate in the location index; starting from the named cells read every located
row of the catalog through its table row (8.4 s against 0.57 s cold for All Media). The People gallery shows people, not items: its window reads no order, stacks, search
or options, and says only what its libraries' state is
(`CatalogWindowPolicy.peopleGalleryLibrariesState`).

The stacks (ADR 0052) are held with the reads: an order read again over the same roots,
while no fact they are built from moved (`CatalogChangedFacts.stackInputs`: membership,
choices and `.stacks`), uses the stacks the last read built instead of reading every stack
candidate again. The Store names `.stacks` only for a write that changes a capture date,
kind or grouping of a still that is or was in a burst, or that shares its folder with a
still it could pair with, so an Immich asset alone in its folder moves its date without a
stack read.

A scope the user returns to paints from what it last showed. The reads are held per
scope slot (`CatalogProjectionReads.Slot`): All Media, where every return to the library
lands, keeps its order and collapse while the user is anywhere else, and every other scope
shares one slot, the last read — so at most two orders and two collapses are held, about
20 MB at owner scale for All Media's, most of it shared with the published window while All
Media is shown. The first pass of an intent (`answerFromHeld`)
answers every read it holds an answer for from that answer, even when a fact the answer
depends on moved since; when one had moved it publishes that window, logs
`op=projection.publish phase=held`, covers nothing, and the next pass reads again whatever
moved and republishes. The window then shows, for the length of one read, what it would
have shown had the user stayed on the scope and waited for the cadence's catch-up; a scope
with nothing held is read before it paints. On the reference catalog, with enrichment moving
capture dates, digests and stacks in the background, a return to All Media re-read the
164,747-row order and every stack candidate and painted after 12.1 s
(`docs/research/2026-11-15-scope-returns-and-superseded-builds.md`). Rejected: holding every
scope's answers (memory in proportion to the scopes visited, for returns that rarely leave
the default scope), and narrowing the facts a background write names further (it shortens
how often a return reads, never the read itself, and a busy machine makes the read seconds).

A failed Store read is not a fact. A pass whose build throws publishes nothing,
logs `op=projection.publish phase=failed`, and leaves `covered` where it was, so
the last published state stands and the next intent or cadence tick retries.
Projection never substitutes an empty value for a read that failed (MED-002).

### Explicit Selection Intents

`CatalogWindowViewModel.selectSidebar(_:)` is the sole UI intent for changing
sidebar scope. The ViewModel owns one `AsyncStream<SidebarSelection>` using
`.bufferingNewest(1)` and one long-lived forwarding task. Rapid user input cannot
create an unbounded task backlog; only the newest pending intent is retained.

Projection may normalize a selected library that no longer exists to
`.allMedia`. After deriving state, Projection also adopts that resolved fallback
as its retained selection when the input used for the build is still current. If
a newer explicit selection arrived during an await, the newer input wins and is
left untouched for the next pass. Applying the resolved selection updates
the ViewModel property directly and does not emit another user intent, so
normalization cannot feed back into the stream or silently resurrect a removed
selection if the same path is later added again.

The ViewModel consumes Projection state through one owned task. That consumer
captures the ViewModel weakly while awaiting another state, so cancellation and
stream termination remain reachable when external ViewModel ownership ends.
Add/remove commands use a separate lossless serial stream owned by ADR 0004;
they do not share selection's newest-value buffering.

### Availability

`LibraryAvailability` is transient and has three states:

- `.unknown`: the root has not yet been checked during this process
- `.available`: the latest pre-scan reachability check succeeded, or a newly
  added root was validated successfully
- `.unavailable`: the latest reachability check failed

A database-loaded library is checked as the catalog loads: one `stat` of its folder
(`LibraryRootKind.availabilityAtLaunch(folderIsReachable:)`) makes it available or
unavailable before the first publication, so a reachable library's rows show at once and
its launch scan only reconciles them (ADR 0008). Waiting for the scan to start was wrong:
the fixed libraries scan one at a time on one lane, so a library queued behind another
showed none of its rows until that scan finished — 11,714 of the reference library's rows arrived in two
later publications (`docs/research/2026-11-14-scope-switch-and-background-laps.md`). A root
added in this process begins unknown until its first check. Availability is never persisted
to SQLite. The pre-scan check still answers it again; a scan failure rechecks the root so
disappearance during traversal can be modeled as unavailable.

Unknown and unavailable roots retain all catalog rows but contribute no assets
to All Media or selected-library grids. Unknown is rendered as `Checking`,
`Checking Library`, or `Checking Libraries`; unavailable is rendered as
`Library Unavailable` or `No Available Media` where applicable. A later scan
opportunity can mark the root available and reconcile normally.

## Alternatives Considered

### A Second Holder Of The Window's Answer

Measured on the reference library and a generated catalog of its shape
(`docs/research/2026-11-16-plan-0116-due-diligence.md`, P3;
`docs/research/2026-11-16-performance-baseline.md`), and rejected:

- **A read model of the window in memory.** Swift would become a second owner of the sort,
  scope, copy and stack rules the SQL owns.
- **A persisted last answer, shown at launch.** A second copy of the catalog's truth, stale
  after any change made while the app was closed.
- **Painting the grid first and the stacks later.** It shows counts that are not true; the
  counts a scope shows are its stacks' (ADR 0052).
- **Reading only part of the order (windowed identity).** The order read touches no table
  row (6,160 pages, 0.07 s warm, 0.44 s cold); the cost was in the stacks and the filter
  options, not the identities.

### Store Publishes Full Snapshots

Pros:

- direct mutation-to-snapshot observation
- simple Store-only tests

Cons:

- Store owns a UI-facing cadence without owning UI derivation
- sidebar changes require a second path
- Projection scheduling and stale-result handling move toward MainActor code

Failure mode: Store and ViewModel grow competing publication schedulers.

### Store Publishes UI-Ready State

Pros:

- one actor performs mutation and publication

Cons:

- persistence and scanning become coupled to presentation and sidebar state
- Store becomes a general app model

Failure mode: UI rules accumulate inside catalog truth ownership.

### ViewModel Starts A Task Per Selection Change

Pros:

- little explicit stream machinery

Cons:

- rapid input creates unordered unstructured tasks
- cancellation and stale completion require additional MainActor bookkeeping

Failure mode: an older selection arrives after a newer one or task count grows
with interaction rate.

### Optimistically Mark Loaded Roots Available

Pros:

- cached media appears immediately

Cons:

- fabricates reachability before the filesystem check
- can briefly expose stale rows for an ejected root

Failure mode: the UI states a domain fact that is not known.

## Consequences

- Store owns truth; Projection owns derived publication; ViewModel owns UI state
  and explicit intents.
- Sorting, filtering, and scope derivation remain off MainActor.
- The ViewModel's owned selection stream and Projection consumer have one
  cancellation point without the consumer retaining its owner indefinitely.
- Projection's retained selection agrees with the fallback state it publishes,
  while newer user input remains authoritative.
- Startup truthfully represents unchecked roots without blocking database load.
- Cached rows survive removable-disk and network availability changes.
- Projection tests require controlled clocks to verify background coalescing and
  immediate user-intent publication.

## Living Documentation Impact

Requirements ARC-005, ARC-010, ARC-016, ARC-020, and ARC-021, and comments at
the Store/Projection/ViewModel
boundaries must describe explicit selection delivery and unknown availability.
Retired selection-generation guards, optimistic availability claims, and ViewModel
selection `didSet` orchestration must not remain in current docs or comments.

## Verification

- Store tests cover the load's availability, unknown for a new root, and available/unavailable transitions.
- Projection tests cover mixed availability filtering and checking empty states.
- ViewModel tests cover rapid selection intents, resolved-selection application
  without feedback, weak state-consumer lifetime, and owned-task cancellation.
- Every test's Store carries the change-coverage guard (`CatalogChangeCoverage`); its
  self-test (`CatalogChangeCoverageTests`) drops one change and sees the write reported.
- Source hygiene rejects retired selection guards and implicit `didSet`
  forwarding.
- `script/verify.sh` supplies the full local gate.
