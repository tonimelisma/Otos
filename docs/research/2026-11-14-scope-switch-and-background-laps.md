# Scope switches and background laps at reference-library scale (2026-11-14)

## Question

On the reference catalog (164,517 assets: three libraries and an Immich account enriching in
the background) the installed app at `72dfc9b8` took 10–11 s from a sidebar click to paint,
re-read the window every 2–3 s for as long as enrichment ran, and logged a planning wake and
a WAL sample for every enrichment batch. Which reads does a scope switch wait for, which
reads repeat without a fact they depend on moving, and what do they cost?

## Method

- **Logs.** A 20-minute sample of the installed app (`op=` lines quoted below by
  count and timing only; no paths).
- **A copy of the catalog.** An APFS clone of the read-only backup
  `build/catalog-backups/catalog-v53-before-v55.sqlite` (166,737 rows; roots 6 and 7 are
  libraries, 15 the Immich account) in the worktree's `build/`, given the v54, v55 and v57
  indexes by hand (v56 redefines a generated column and changes no plan), opened only by
  `sqlite3` with the app's `cache_size` and `mmap_size`, and deleted afterwards. Every read
  was timed twice or more. The machine ran other sessions' checks throughout (load average
  36–50 on 8 cores), so wall times are I/O-bound and loose; `user` CPU times are given where
  they show the work itself.
- **Code.** The mechanism of each item, read in `CatalogProjection`, `CatalogStore`,
  `ImportSessionMachine`, `EnrichmentCoordinator` and `MaterializationCoordinator`.

## Findings

### 1. A sidebar click waited for the build of the scope it left

`CatalogProjection.pass` awaited one build at a time and a newer intent never cancelled it
(ADR 0005 as it stood). Clicking People at 19:52:55.314 waited for the All Media build in
flight (its filter options 5.3 s, its order 2.8 s), which was then applied on the main thread
for 1.4 s though nobody wanted it. People's own build then read a 70,223-item order, the
25,720 stack candidates and the People row's filter options (8.9 s), and painted at
19:53:06.5. A person's photos took 10.0 s the same way, waiting on People's options (8.8 s).

What a scope switch must wait for: nothing that answers the scope left. The build and the
owed options read of a pass now run in a task the pass waits on; an intent whose descriptor
that work does not answer cancels it, GRDB interrupts its statement, and the pass ends
unpublished and rings the loop. The People gallery reads nothing but its libraries' state.
The filter's options are read after the window publishes.

### 2. The People row's filter options walked the table

```
SEARCH media_asset USING INDEX idx_media_asset_stack_candidate (library_root_id=? AND best_kind>?)
SEARCH face EXISTS USING INDEX idx_face_assigned_photo (library_root_id=? AND relative_path=?)
```

The face check needs each row's `relative_path`, which `idx_media_asset_stack_candidate` did
not hold, so every row reached cost a read of its 3.3 KB table row.

| Read | Before (v57) | After (v59: `relative_path` in the index) |
| --- | --- | --- |
| People row's types | 17.1, 20.8 s; 30.4, 41.7 s under heavier load (user 0.6–0.95 s) | 0.31, 0.18 s (user 0.13 s) |
| `idx_media_asset_stack_candidate` size | about 10 MB | 19.0 MB |

All Media's types read 0.6–1.2 s warm and 3.0–7.3 s cold on the copy (user 0.10–0.13 s), the
Live Photo test reading the table for each of the account's 18,342 videos. That read is now
off the window's path and repeated only when a fact it depends on moves.

### 3. Every lap read the stack candidates

The order read built the stacks in its own transaction every time it ran: 25,720 candidates,
`stackReadMs` 305–548 and `stackRuleMs` 178–233 of an order read of 0.9–1.0 s, 69 times in 20
minutes, including for Duplicates (226 items) and one person (1,048). Every lap read the
order because enrichment moved capture dates; none of those dates was a stack candidate's.
The candidates' read alone took 1.0 s on the copy.

The stacks are now held with the window's reads, keyed by the roots they span and the
revisions of their inputs (`CatalogChangedFacts.stackInputs`: membership, choices,
`.stacks`). The Store names `.stacks` only for a write that moves a capture date, kind or
grouping of a still that is or was in a burst, or that shares its folder with a still it
could pair with (one probe of the index). The account's assets each sit alone in their
asset's folder — 10,906 of its rows are RAWs and 3 carry a burst identifier — so its reads
leave the stacks standing.

The order itself is still read again when a capture date moves. Maintaining it from the
changed rows was declined: the order is SQL's (`ORDER BY` over the scope, the filter, the Live
Photo rule and On This Day's picks), and a Swift merge of N changed rows would be a second
owner of every one of those rules, for a read whose own work is 0.6–0.9 s.

### 4. The import coordinator woke for every enrichment batch of the account

`CatalogStore.bumpNamingRevision` advanced `namingRevision` and emitted a planning change for
every batch that moved a capture wall, on any root: 573 in 20 minutes on the Immich account,
each one a `readSourcesSnapshot` in the coordinator. No import reads an account (it is
neither a source nor a destination), a library's naming is read by no import plan (a
destination's names are its files'), and `bumpPlanRevision` woke the coordinator although no
import reads `planRevision`. Now `recordNamingChange` advances `namingRevision` and wakes the
coordinator only for an import source (a card or camera), `planRevision` only for a root that
can be reorganized, and nothing for an account; namespace changes wake it only for a root an
import plans against.

### 5. The WAL sample said the same thing 586 times

`boundWAL` logged the WAL file's size after every bulk write; it read 57,675,912 bytes each
time, under the 64 MiB budget. A log SQLite keeps resetting is reused from its start and its
file keeps its size, so the line said nothing new; checkpoints were not failing (the file
stayed at its high-water mark, below the budget, so no truncation was due). It is now logged
only when the file grows past the largest size logged since the last truncation.

### 6. Launch hid two libraries until their scans started

A saved library loaded `.unknown` (`LibraryRootKind.availabilityAtLaunch`) and became
`.available` only when its scan started (`startNextScanIfNeeded`), and the fixed libraries
scan one at a time on one lane. Until then `CatalogWindowPolicy.availablePaths` left its rows
out: the first publication held 147,051 items, then 10,926 and 788 more arrived as each
library's scan started. A `stat` of the folder answers availability; it is now asked as the
catalog loads, so the first publication holds every row of a reachable library and the scans
only reconcile.

`op=catalog.start phase=coalesced` ×3 is three callers joining the one load in flight, as
designed. `claimsMs=287` is the write clearing the claims a previous process left (28 rows on
the copy), through `idx_media_asset_enrichment_claimed`; each cleared row is a row rewrite.

### 7. Background work asked for originals the account never sends it

When the account did not serve a row's ranges (no reader for it at that moment), enrichment
routed the row by `locality(of:)`, which said `.fetchable`, demanded a background download,
and the executor refused it (`immich.original phase=refused reason=notUserWork`) and logged a
failure: 36 times in 20 minutes. Locality now says `.fetchableForUserWork` for an account's
unstaged original; enrichment and `ensureLocal` never ask for it at background or device
priority. The 40 readiness lines that "routed nothing" were rows routed as `remoteReady`,
which the line did not print; it now prints every count, `remoteReady`, `userWorkOnly` and
`notDue` included.

### 8. Visible tiles' details queued behind background reads

`op=catalog.store.query.tileDetail waitMs=2472..4462 execMs=0`: the wait is GRDB's reader
pool (four readers), held for seconds at a time by the window's order and options,
enrichment's claims and the derived owners' builds. The visible tiles' details now read from
a second, read-only pool of two readers that no background read uses.

### 9. Text reading's failure

No new reproduction was run: one reading takes 100–650 s under this load
(`2026-11-14-vision-text-reading-breaks-for-its-process.md`). Otos's own use is one request
per reading on one serial queue, with no request shared or reused. A failed recognition is no
reading: `SearchTextReader` returns no result, the still stays owed and is read again in a
later pass or process; a test now delivers `CRImageReaderError` code 1 and checks that, and
that an empty reading is stamped as no text.

## Conclusions

- A user intent cancels the unpublished work of what it left; a store change never does.
- The window never waits for the filter's options; the People gallery reads no items.
- The stacks are read when a fact they are built from moves, not when any date moves.
- v59 puts `relative_path` in `idx_media_asset_stack_candidate` (+9 MB) for the People row's
  options (17–41 s to 0.2–0.3 s on the copy).
- Planning wakes, naming revisions and WAL lines move only when a reader's fact moved.
- Saved libraries' rows show at launch; background work never asks an account for originals;
  visible tiles' details have their own readers.
