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
changed; an enrichment batch compares what SQLite stored before and after each row, and a
write that changes facts of many kinds at once (a scan, a root added or removed, a Trash
move, an import) names `.all`. `.assetsAdded` is a scan, device-listing or source-listing
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
(the resolved descriptor or sidebar row, the available roots, the place-name languages) and
the revisions its pass started from (`CatalogProjectionReads`). A pass reuses an answer
while what it was for is unchanged and no kind it depends on moved, and reads it again
otherwise. The order depends on rows shown, capture dates, kinds, formats, grouping and
choices always, and on locations and place names, faces, copies or On This Day's labels
where the scope or the filter is by them (`CatalogChangedFacts.orderInputs(of:)`); the
options depend on rows shown, kinds, formats, grouping, locations and place names
(`filterOptionsInputs(of:)`); the collapse is a pure step over the scoped order, its stacks
and expansions. A shown search's answer is held the same way, keyed also by the search
index's own revision, which only the index moves (ADR 0048); its Store fact matches depend
on rows shown, capture dates, locations and faces (`searchFactInputs`). The filter's options are read beside the order, since neither depends on
the other. Every change still advances `detailRefreshGeneration`, so a pass that reused
every read publishes the refresh the grid's visible tiles read their details by.

Before this, the only distinction was detail-only versus structural, and every enrichment
write that moved a stored date by any amount, every face assignment, every place name and
every digest was structural: on the owner's 166,555-asset catalog, while faces and Immich
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

Rejected: a time-based throttle on background passes beyond the existing cadence (ADR
0033: whether a read can have changed is a fact the Store holds), a generic query cache in
the Store (the Store would have to know who reads what; the reader knows its inputs), and
patching the order incrementally from the changed rows (a second ordering path beside the
SQL that owns it).

Before the Store's initial load has applied, its roots are unknown, not absent.
`CatalogStore.loadedLibraries()` returns nil until then, and Projection publishes a
loading state for it — no title, no items, and the `.loadingCatalog` empty state,
which the grid draws as nothing — instead of deriving "No Media" from an empty root
set. The first Store change after a loading publication is the load itself, so it
publishes immediately rather than on the background cadence; leaving the window
blank for a cadence tick after the catalog is already readable was measured at about
one second of a launch that loads its catalog in 120 ms (APP-044).

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

A user never waits for work answering what they left. A pass runs its build, and the
filter's options it owes, in a task it waits on; an intent whose descriptor that work does
not answer — another scope, filter, sort or search for a build; another sidebar row for the
options — cancels it in the step that applies the intent. That work is unpublished and can
never be published, because what it answers is no longer asked; GRDB interrupts its
statement. The pass does not wait for the cancelled work to end: a cancelled read ends only
when its statement, or its wait for a connection, does, and the next scope must not wait on
either. The superseded pass publishes nothing, covers nothing and rings the loop at once, so
the new request is built next; whatever a superseded build read, its result is discarded
even if it finished in spite of the cancellation, because a cancelled GRDB read holds
errors, not a catalog, and a superseded build stops before it touches the search reader or
counts a read. On the owner's catalog the next pass started 3.2–6.6 s after a People build
was superseded, the pass waiting for that build to end
(`docs/research/2026-11-15-scope-returns-and-superseded-builds.md`). A store change supersedes nothing: the
build in flight is for what is shown, and the next pass takes the change up. Teardown
cancels the loop, and a torn-down pass publishes nothing. On the owner's catalog a sidebar
click waited 2–9 s for the All Media build it left, then 1.4 s on the main thread applying
it (`docs/research/2026-11-14-scope-switch-and-background-laps.md`).

The filter's options never hold the window back. A pass whose options are owed publishes
the window with the last options read for the same row (none for a row not read yet: the
popover lists every kind, and the types under each arrive with the read), then reads the
options and republishes the window with them; it covers its request only once they are
read. The People gallery shows people, not items: its window reads no order, stacks, search
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
with nothing held is read before it paints. On the owner's catalog, with enrichment moving
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
showed none of its rows until that scan finished — 11,714 of the owner's rows arrived in two
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
- Source hygiene rejects retired selection guards and implicit `didSet`
  forwarding.
- `script/verify.sh` supplies the full local gate.
