# Plan 0116: background work that costs what it owes

Status: **revised after due diligence, awaiting the owner's decision** (2026-11-16). Nothing
in this plan is built. The first version recommended a work ledger, derived data in separate
files and search vectors as a mapped file (options A, B, C below). Five pieces of due
diligence (section 6) rejected A and B as written and narrowed C; section 4 is the plan that
survived. The evidence is in `docs/research/2026-11-16-plan-0116-due-diligence.md` and
`docs/research/2026-11-16-stall-reproduction-baseline.md`.

## 1. The defect

On the owner's Mac a sidebar click takes 3 to 15 seconds to paint, on a quiet machine, with no
migration running (installed build 487baebd, 2026-11-15 21:56):

| Click | Click to paint | Where the time went |
| --- | --- | --- |
| Import of 109 photos | 2.8 s | about 2 s waiting for a connection |
| All Media (158,913 shown) | 14.5 s | 8.6 s waiting for a connection, 4.2 s reading |

`op=catalog.store.stall` fired 61 times in the first minute. Every one read `lockMs=0`,
`storeMs=0`, `snapshotMs` 0 to 1, with the interactive pool idle and `connectionMs` up to
23,393: the window's read was waiting for one of the main pool's four reader connections.

## 2. Evidence

### 2.1 Who held the connections (longest single read transaction, first minute)

| Read | Held | What it does |
| --- | --- | --- |
| `readSearchEmbeddings` | 32.8 s | reads every search embedding joined to its asset row |
| `photoDescriptionCandidates` | 23.8 s | walks every asset row, four lookups and two correlated subqueries per row, sorts, takes 16 |
| `renderSignatureCandidates` | 20.6 s, then 8.6 s sixteen times | walks asset rows in key order until 128 match; no cursor, so each page starts at row one |
| `searchEmbeddingCandidates` | 8.8 s | walks every asset row, sorts, takes 16; also asked with LIMIT 1 after every text page |
| `metadataRefreshCandidates` | 8.7 s | keyset pages of 64, but walks the 147,064 Immich rows before filtering them out |
| `samePhotoDetails` | 7.1 s | one point lookup per still in a proposed pair, all in one transaction |
| `samePhotoCandidates` | 6.4 s | walks every asset row |
| `filterOptions` | 6.3 s | the window's own read: every row of the scope |
| `orderedAssetIDs` | 4.2 s | the window's own read: the whole order plus stack candidates |
| `mirrorProbes` | 36 s measured read-only for a library with no mirror | join runs in the wrong order; no statistics exist |
| `peopleSnapshot` | not timed | every face row with its 2 KB embedding, every pass |

### 2.2 Why (code map, 2026-11-16)

1. **No record of what is owed.** Six candidate reads (`renderSignatureCandidates`,
   `searchEmbeddingCandidates`, `searchTextCandidates`, `photoDescriptionCandidates`,
   `samePhotoCandidates`, both `readSearch*`) have no index for what they owe. Each visits
   every `media_asset` row of every root and reads its table row. Four sort the whole owed set
   to take 8 to 128. None keeps a cursor. ADR 0009 chose this: "Scheduling is cursorless."
2. **Owners wake on every change.** Render signatures, preview faces and place names wake on
   every `.changed`; the search index on everything but `.assetsAdded`, doing four or more
   whole-table walks per wake; enrichment emits `.changed(.detail…)` with every flush; the
   render-signature owner's own writes ring it again.
3. **One file, one pool, one priority.** Every background read and every window read except
   tile details and the inspector shares the main pool's four readers. Every background owner
   inherits `.userInitiated` from the main thread. There are two `DatabasePool`s on one file,
   which GRDB's guidance advises against ("Open one single DatabaseQueue or DatabasePool per
   database file"); enrichment's priority claims, the grid preheat and trash snapshots already
   use the "interactive" pool.
4. **Derived data inside the catalog.** `media_asset` rows are 2 to 2.5 KB because each
   carries a 1,024-byte `render_gray` blob and a ~0.5 KB `sort_key`: 545 MB for 166,990 rows,
   about 1.5 rows a page. `search_embedding` is 649 MB (3,072-byte vectors, one row a page),
   `face` 403 MB (2,048-byte embeddings), `asset_metadata` 190 MB. The search index holds
   every embedding in memory as one matrix (about 509 MB, ADR 0048) and re-reads every
   embedding key each pass.
5. **No statistics.** `sqlite_stat1` does not exist. The mirror probe chose the wrong join
   order.
6. **The "needs enrichment" partial indexes are not selective.** 162,294 of 166,990 rows
   qualify, because the predicate includes "has no content hash" and cloud-only files cannot
   be hashed without a download the app does not make in the background.

### 2.3 Outside research (sources in `docs/research/2026-11-16-plan-0116-due-diligence.md`)

- SQLite: readers and writers do not block each other; a long read transaction holds back
  checkpoints and lets the WAL grow; each database file has its own WAL and write lock; a
  commit across attached WAL files is atomic per file, not across files.
- GRDB: one pool per file; QoS is per pool; a second pool on the same file is outside the
  author's guidance.
- digiKam (core, thumbnails, similarity, faces), Lightroom Classic, Capture One, darktable and
  Apple Photos (Photos.sqlite, psi.sqlite, mediaanalysis.db, analysis in daemons) keep derived
  data in stores separate from the catalog.
- Immich finds work by per-asset status rows (`asset_job_status`, `NOT EXISTS smart_search`),
  streamed; the queue carries ids only.

## 3. Options considered

| | Option | Removes | Main cost |
| --- | --- | --- | --- |
| A | A work ledger: what each asset owes, maintained with the write that changes its inputs; owners take the next N by index and wake on their own entries | the six scans; cross-waking | every input's writer must keep it right; backfill; drift needs a rebuild path |
| B | Derived data in its own files, each with its own pool, writer and priority | shared connections, writer, page cache; catalog size | no cross-file atomicity; explicit orphan cleanup; cross-store queries redesigned |
| C | Search vectors as a memory-mapped file | the 33 s load and ~509 MB of heap | custom format and crash design; no documented precedent |
| D | In-memory read model for the window | every database wait on a click | Swift becomes a second owner of sort, scope, copy and stack rules |
| E | Analysis in a helper process | model memory and crashes from the app | IPC; needs its own store (after B); evidence is suggestive only |
| F | Scheduling rules: background priority, one class at a time, statistics | priority inversion, blind plans | alone it leaves the scans |
| G | One file, more pools and indexes | the window's waits | each feature adds another scan and index; second pool stays unsupported |

## 4. The plan that survived

The holders in section 2.1 are slow because of how their queries and wakes are written, not
because the storage has the wrong shape. Every stage below keeps one catalog file, atomic
commits and the foreign-key cascades that carry derived rows with their asset (ADR 0008).

**Stage 1: every background read costs what it owes.**
- Each candidate read walks an index, per root, with a keyset cursor (`root = ? AND path > ?`;
  a cursor over `root IN (…)` seeks only on the root and re-walks it). No whole-set sort.
- One drain is one walk. Today a drain re-runs the candidate query for every page of 8 to 128.
- Covering indexes on the derived tables' `(library_root_id, relative_path, source)` and on the
  asset columns each product's stamp reads; a partial index for render signatures, whose stamp
  is already in the row. About nine indexes, about 170 MB, about 13 s to build (measured on a
  generated catalog; the migration states its cost per ADR 0002).
- Pinned with `INDEXED BY` and plan tests: even after `ANALYZE` the planner left the covering
  index for the wide table.
- The mirror probe's join order is pinned (`CROSS JOIN`): over 75 s to 0.16 s on the owner's
  catalog. Metadata refresh takes root ids, not a join to `library_root`.

**Stage 2: an owner wakes on what it reads.**
- `RenderSignatureRefresher`, `PreviewFaceReader`, `PlaceNameReader` and `PhotoSearchIndex`
  get the `inputs` set `PhotoDescriptionWriter` and `PeopleAssignment` already have. No owner
  is rung by its own writes.
- The per-page `searchEmbeddingCandidates(limit: 1)` becomes a revision counter (ADR 0032
  rule 2). The search index stops ringing the description owner on every text page.

**Stage 3: a window read never queues behind background reads.**
- Everything the window needs for a click or a paint (order, stacks, filter options, import
  batches, counts, tile detail, inspector) reads on connections background owners cannot be
  handed, enforced by the type of reader each owner holds.
- Background reads are admitted with a cap before they enter GRDB's pool, whose queue is
  first-in first-out, and run on a pool at lower QoS. Task priority alone changes nothing:
  GRDB's reader queues run at user-initiated whatever asks.
- The truncating checkpoint's barrier must not stall the window behind a long reader.

**Stage 4: the search index loads once, in pages.**
- The reconcile's currency check reads the `(key, source)` index: 317k pages to 6.9k, 6.9 s
  cold to 0.04 s. Today it re-reads the whole 680 MB table every wake.
- The first load streams key, vector and labels in bounded pages straight into the matrix,
  with labels parsed when needed (about 2 s of the load is label parsing).

**Stage 5: the window's own reads.** All Media's first visit costs about 5 s with no waiting:
stack candidates 0.9 to 2.5 s, the order read, the collapse and a 190 ms equality. Small
scopes are 16 to 29 ms once the wait is gone. This is its own item, and nothing in stages 1
to 4 changes it. People's full re-read of every face embedding per rebuild is re-measured
after stages 1 and 2.

**Stage 6, the owner's choice: slimmer tables in the same file, and one compaction.**
- `render_gray` (1 KB a row) and the face embedding (2 KB a row) move to their own tables
  with cascades. The asset table goes from 1.0 to 3.0 rows a page; `face` from 403 MB to
  18 MB.
- One `VACUUM` at a stated moment. The owner's asset table is 1.2 % sequential on disk; on a
  synthetic table that made a cold scan 7 times slower. Estimated 45 to 60 s and about 3.4 GB
  of temporary disk on the owner's file (not measured on it). It cannot run inside `open`.
- The catalog would go from 2.56 GB to about 1.0 GB. If `sort_key` and its two indexes prove
  unused (grep and plans say so; not proven), about 0.7 GB.
- This helps background scans, migrations and backup size. It does not help clicks: the
  window's reads use indexes and never touch the wide rows.

**Stage 7, later and only if measured need remains: search vectors as a mapped file.**
Proven feasible on the owner's real vectors (section 6, P4): half precision, append-only,
6 MB of footprint against 491 MB, searchable 0.2 s after launch. Its case is memory. It is
worth building if, after stages 1 to 5, memory pressure still stalls the app (the unexplained
whole-process pause around the first on-device model request, S12).

**Not doing, and why.**
- A trigger-maintained ledger (A). It can be kept correct, but costs 28 triggers, a 4.7 times
  slower enrichment write, 0.8 to 4.7 s holds of the single writer on a person rename or a
  language switch, and a migration at every revision bump. Stage 1 removes about 95 % of the
  pages with no new state. Revisit at about ten times the library.
- Separate files (B). Measured hazards: a new file at an old path appears in the old person's
  view; 60 of 150 crashes leave two files out of step even under one `ATTACH` transaction;
  cascades and renames stop following. Nothing measured needs it.
- `ANALYZE` / `PRAGMA optimize`. It changes plans across a catalog the code pins on purpose.
- A read model for the window (D) and a global scheduler.

**Acceptance.**
- `StallReproductionTests.windowReadsAreAnsweredWhileEveryBackgroundOwnerRuns` passes with
  its `withKnownIssue` removed: window reads within 250 ms of their quiet time, no stall line,
  every background read visiting at most four rows per row returned.
- On the owner's catalog, by a read-only launch: no `op=catalog.store.stall` line in the first
  three minutes, and a small scope painting in under one second at any time.
- All Media's first visit has its own target, set when stage 5 is measured.

**Order and reversibility.** Stages 1 to 4 are separate, individually revertible PRs, each
with plan tests and one check run. Stage 1's indexes are one migration, measured first. Stage
6 is the only one-way step and needs the owner's go.

## 5. Soft spots that remain

- **The first All Media visit** (stage 5) has no design yet.
- **The whole-process pause around the first on-device model request** is unexplained. This
  plan does not address it unless stage 7 turns out to.
- **Index write cost.** Stage 1's indexes add 26 % to an enrichment flush (34 to 43 ms),
  measured on one connection with a warm cache, not under concurrent readers.
- **Scale.** A narrow walk is about 1.3 s cold at 167k assets when little is owed. At ten
  times the library a ledger starts to pay.
- **Two pools on one file** stays outside GRDB's written guidance. Measured cross-pool waits
  were at most 228 ms; the known cost is a truncating checkpoint returning busy and retrying.
- **The reproduction is a tenth of the owner's magnitude.** It lacks OneDrive latency, the
  models, memory pressure and a cold file. The owner's catalog, read-only, is the final check.
- **Half precision was tested on single-word text queries and image queries,** not on real
  translated multi-word queries or judged recall.
- **A defect found on the way, independent of this plan:** On This Day's exclusion reads
  `search_embedding.confident_labels` with no stamp check, so a new file at an old path is
  wrongly excluded.

## 6. Due diligence, and what each piece found

| | Question | Result |
| --- | --- | --- |
| P0 | Does the stall reproduce without the owner's Mac? | Yes, at about a tenth of the magnitude; merged as the acceptance test (#798). |
| P2 | Can a ledger be kept correct, and which shape? | It holds (0 drift in 8,000 random operations, 24 of 28 triggers proven load-bearing) and is not the smallest correct design. Indexes plus keyset cursors remove about 95 % of the pages. |
| P3 | Where is the split line, and what does moving cost? | Drop separate files. Split tables inside the file and compact once. |
| P4 | Do mapped vectors work? | Yes at half precision, append-only; most of the 33 s is table layout and contention, not storage. |
| P5 | Independent critique | Rejected A, B and C as the next step; proposed stages 1 to 5. Its two strongest numbers were re-run and confirmed for one (the mirror probe). |

P1 (measuring G, A and A+B side by side on the reproduction) was not run: P2 and P5 answered
its question from measurements on the owner's catalog and a generated one.
