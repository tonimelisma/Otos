# Scope returns and superseded builds (2026-11-15)

## Question

On the installed build 3b5142ab (reference catalog: 164,747 assets, 4,829 day sections, three
libraries and an Immich account enriching in the background, load average 60–104 on 8 cores)
a sidebar click painted the library-sized scopes far over a second:

| Scope | Click → first state applied |
| --- | --- |
| All Media, first visit after launch | 22.0 s (order `execMs=12021`, `stackReadMs=9542`) |
| All Media, return from People | 12.1 s (3.2 s before the pass started, order `execMs=5977`, `stackReadMs=3932`, collapse 519 ms) |
| Places (70,372 located items shown) | 7.5 s (order `execMs=6452`, stacks held) |
| People (gallery) | 3.75 s; `ui.sidebarSelectionToPaint` never logged `finish` |
| On This Day (143), Duplicates (2), an import batch (111) | 1.17 s, 0.2 s, 0.11 s |

Three questions: why does a return re-read everything; what does the loop wait for between
`op=projection.publish phase=superseded` and the next `phase=start`; and why is a click on a
scope that is not drawn by the grid never measured?

## Method

- The log excerpts of the reference session quoted in the brief, and, before the rule
  against reading the installed app's log arrived, one `log show` of the same session
  (12:09–12:17) for the lines around them. Nothing else was read from the installed app or
  its catalog; the file was deleted.
- The code of `CatalogProjection`, `CatalogProjectionWindowStateBuild`,
  `CatalogProjectionReads` and `readFreeingConnection`.
- Tests that deliver the competing event at the exact suspension, and the benchmark catalog
  (ADR 0043) for instructions.

## Findings

### A return re-read because facts had moved, and the projection held one order

- `CatalogProjectionReads` held one order and one collapse: the last read. The People gallery
  reads no order, so All Media's answer was still the one held on the return; it was read
  again because facts it depends on had moved while the user was in People. In that session a
  metadata refresh wrote `facts=captureDate,grouping,detail,mediaRecord,stacks` (12:11:18.948)
  and enrichment applied 53 digests (`.copies`, which All Media's one-copy rule reads,
  ADR 0054). Every one of those moves the order's inputs, and the `.stacks` write moves the
  stacks' (`stackInputs`), so `stacks=read` and `reused=none` were correct by the rules as they
  stood. The held whole-roots stacks of #750 were dropped by that write, not by the scope
  change or by a keyed scope's stacks (those are never held, #765).
- So under background enrichment almost every return finds a moved fact, and narrowing what a
  write names shortens how often a return reads, never the read itself, which a busy machine
  makes seconds long.
- **Design.** A return paints what the scope last showed, and reads again only after:
  - All Media keeps its order and collapse while the user is elsewhere; every other scope
    shares one slot, the last read (`CatalogProjectionReads.Slot`). Two orders and two
    collapses at most: All Media's is about 165,000 IDs (each two path strings and a
    fingerprint), some 20 MB with its collapse, most of it shared with the published window
    while All Media is shown. All Media is the slot of its own because every return to the
    library lands there; holding every visited scope would cost memory in proportion to the
    scopes visited.
  - The import batches and the place-name languages are held like the other reads; the
    place-name languages were read on every pass before, People's included. The held set
    is one list (`CatalogProjectionReads`), and the pass's `reused=` field names each
    member it answered from, `importBatches` and `placeNameLanguages` included, and `held`
    when an answer was used although a fact it depends on had moved.
  - The first pass of an intent answers each read it holds an answer for from that answer,
    even when a fact it depends on moved (`answerFromHeld`, `CatalogProjectionReuse.held`).
    When one had moved it publishes that window (`op=projection.publish phase=held`), covers
    nothing and rings the loop; the next pass reads what moved and republishes. A scope with
    nothing held is read before it paints.
- **Places** draws every located item's coordinate as clusters, so its first paint needs the
  70,372-row order: there is no read it waits on that it does not show. Its order with stacks
  held read for 6.4 s cold and 1.8 s when read again 20 s later (with every stack candidate
  read), so the cost was the cache, not the plan; its plan was not changed. A return to Places
  is answered from the "other" slot when Places was the last other scope read.
- **People's first state** read the import batches (re-read whenever rows, grouping or
  stacks moved, as scans and enrichment do) and the place-name languages on every pass, both
  from the main reader pool. Every People pass of that session took 0–7.5 s for those two
  reads alone. They are now held, so its first pass reads nothing.

### The pass waited for the build it superseded

- `supersedable` cancelled the build and then awaited `task.value`. A cancelled read ends only
  when its statement is interrupted or, if it is still waiting for a connection, when it
  gets one: `readFreeingConnection` resumes its continuation only from GRDB's `asyncRead`
  callback, which runs once a reader is free. So the next pass started when the superseded
  People build's read ended, 3.2 s (6.6 s on the first visit) after the supersede.
- Which wait held that read is the reader wait #773 and the separate reader-wait
  investigation own; this work does not touch the pools or `readFreeingConnection`. What it
  proves: the People passes of that session took 0–7.5 s for two small reads, and each of the
  slow ones ended within 50 ms of a visible tile's detail read on the other pool that had
  waited as long (12:10:53, 12:11:15, 12:12:36, 12:12:45, 12:13:17, 12:13:27), which points at
  a wait both pools share rather than either pool's holders. Not proven.
- **Fix in the projection:** the pass waits for its work to end *or* to be superseded,
  whichever is first (`WorkWaiter`). A superseded build is cancelled and left to end alone; it
  publishes nothing, and it checks its cancellation before it touches the search reader.
  `anIntentNeverWaitsForTheBuildItSuperseded` parks a build that ignores its cancellation and
  shows the new scope published while it is parked.

### Click-to-paint was measured only for the grid

`ui.sidebarSelectionToPaint` ended only at a structural apply of the grid, so People, Places,
On This Day and Duplicates were measured only when abandoned by the next click
(`abandoned ms=154530`). The same interval now ends at the state apply that hands the pane
drawn in the grid's place what it draws (`CatalogWindowState.detailSurface`; People and
Duplicates once their owners have built), with `surface=` on the line.

## Benchmarks

`projection.windowState.allMedia.returnHeld` measures the first pass of a return to All
Media after a capture date and a stack fact moved: every read answered from what was held.
Instructions are in the PR's DoD report. A case for "a scope switch while a build is in
flight" was not added: what it would measure is how long the pass waits for parked work,
which is now nothing by construction, and the test above pins it.

## Not established

- The first visit after launch (22 s) and what holds reads for seconds on a busy machine are
  left to the reader-wait work.
- Nothing was verified on the installed app after this change.
