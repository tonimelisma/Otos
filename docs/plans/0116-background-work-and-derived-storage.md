# Plan 0116: background work that costs what it owes, and derived data out of the catalog

Status: **proposed, under due diligence** (2026-11-16). Nothing in this plan is built. The
owner asked for the plan written down, its soft spots named, and experiments run on the risky
assumptions before any of it is accepted. Section 7 is filled in as the experiments report.

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

### 2.3 Outside research (sources in `docs/research/2026-11-16-…`, written with section 7)

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

## 4. The recommended plan

A, then B, then C inside B's search store, with F's rules written into ADR 0002/0032 as they
apply. Not D. E only if the on-device model still stalls the app after the rest, measured.

**Stage A: the work ledger.**
- One table (working name `owed_work(product, library_root_id, relative_path, …)`) or one
  status row per asset; which of the two is experiment P1's question.
- Maintained in the same transaction as any change to a product's inputs. Triggers are the
  candidate mechanism, so that no writer needs to know who consumes what (ADR 0009's rule).
- Each owner reads its next N by index seek with a cursor, in bounded read transactions, and
  wakes on its own ledger's change, not on every Store change.
- "Owed and doable now" is distinct from "owed, but only once the file is local".
- A rebuild path derives the ledger from the source stamps, which stay the truth.
- `ANALYZE`/`PRAGMA optimize` on a stated occasion.

**Stage B: stores by lifecycle.**
- The catalog keeps what is authoritative and what the window's queries read: assets,
  authored overlay, the metadata the window sorts and filters on, face *assignment*.
- A search store (embeddings, text, descriptions), a face-embedding store, and render
  signatures out of the asset row. One pool per file. Background stores at background QoS.
- The second same-file pool is retired; the window has the catalog's readers to itself.
- A derived row whose stamp does not match its asset reads as stale, as it does today; that
  is what makes a torn cross-file commit harmless. Deletion reaches the other files
  explicitly.

**Stage C: vectors as a mapped file.** The search matrix is the file. No load at launch, no
second copy in the heap.

**Acceptance.** Click to paint under one second at any time, including the first minute after
launch, on the owner's catalog (read-only launch) and in the reproduction test of section 6.
Each background pass visits rows in proportion to what it owes.

## 5. Soft spots, risks and unknowns

Ordered by how much each could change the plan.

**S1. Is A sufficient without B?** If the scans go, the connections may simply be free. B is
the largest and riskiest stage; if A alone meets acceptance, B is justified only by catalog
size, migration time and memory, and should be argued on those. *Unknown until measured.*

**S2. Is G (a correct pool rule plus cursors and indexes) enough without A?** I called it the
patch option. That is a judgment, not a measurement. If a window-only pool plus keyset paging
meets acceptance, the honest plan is smaller. *Unknown until measured.*

**S3. Can a ledger be kept correct?** Staleness today is `source IS NOT identity(asset)`,
where identity is a string built from several asset columns plus a revision constant in code.
A description's source also depends on the photo's faces, the people's names, place names,
its text reading and its embedding. A trigger-maintained ledger must fire on every one of
those inputs across five tables, and a code-side revision bump invalidates every row at once.
Risks: a missed input (silent staleness, the worst kind), write amplification on enrichment's
hot path, and a ledger rebuild at each revision bump that is itself a library-sized write.
*This is the plan's largest correctness risk.*

**S4. Is a persistent ledger even the right shape?** Alternatives not yet weighed: (a) owners
are told which assets changed (the Store's change notifications carry ids) and keep an
in-memory work list, with one catch-up walk per launch at background priority; (b) each
owner remembers the fact revisions at which it last finished a full walk and re-walks only
when its inputs moved; (c) Immich's shape, a status row per asset with a timestamp per
product and a partial index per product. *Each trades durability and complexity differently.*

**S5. Cross-store queries.** The person scope and People filter join `face` to `media_asset`
inside the window's order read; Places joins `asset_metadata`; search facts join metadata and
faces; the description owner joins four derived tables. If a table moves, each such query
needs a new home. With `ATTACH`, the attached file shares the connection and so the pool,
which gives back the independence B is for. *The split line may not be where I drew it.*

**S6. Cross-file consistency.** No atomic commit across WAL files. Enumerate and test: crash
between catalog and store commit in each direction; an asset deleted while its derived rows
survive (orphans, and a later asset at the same path inheriting them); a store file deleted
or older than the catalog (restore from backup); ADR 0008's rule that overlay is purged in
full on proven deletion.

**S7. The one-time moves.** Relocating ~1.1 GB and shrinking the catalog needs `VACUUM` or a
rebuild: time on a cold 2.5 GB file, twice the disk space while it runs (the owner's disk has
been at 96 to 98 % full), and a window where a crash must not lose anything. The owner sat
through 43 s of silent migration on 2026-11-15; a move of this size cannot run inside
`open`.

**S8. Mapped vectors.** Unknown: half precision's effect on search ranking; update and delete
semantics (append, tombstone, compact); whether Accelerate over mapped memory is as fast as
the heap matrix; behaviour under memory pressure (page-ins on the search path); the crash
window between file and id table. ADR 0048 chose the in-memory matrix deliberately.

**S9. Wake discipline.** Changing "wake on every change" to "wake on my ledger" must not
lose a wake (an owed item that nobody processes). ADR 0032's request counters exist for this;
the ledger's doorbell must use them.

**S10. Priorities.** Background QoS on the stores creates inversions where the user waits on
background output (opening a photo whose preview is owed; a typed search needing an
embedding). Each such path needs an explicit escalation.

**S11. The window's own reads.** `orderedAssetIDs` 4.2 s and `filterOptions` 6.3 s are the
window's, not background's. Part of that was waiting; part is a 167k-row read. Neither A nor
B changes them. Holding (#774) covers returns, not first visits.

**S12. What the plan does not explain.** The 2026-11-15 19:54 launch showed the whole process
going quiet for 10 s around the first on-device model request. That may be memory pressure
unrelated to connections. If it is, this plan does not fix it (option E might).

**S13. Size of change.** Three stages touch the Store, every background owner, the schema and
six ADRs. Regression risk is real in a week where fast parallel work already introduced
defects. Each stage must be independently shippable and reversible.

**S14. The repo's own rule.** "Do not add caches, pools, background pipelines, generalized
abstractions, split schemas, or scale machinery … before measurement or a verified
requirement proves the simple path insufficient." Section 2 is the measurement for A. It is
not yet a measurement that B and C are needed (see S1).

## 6. Due diligence

Experiments measure inside ordinary tests on a generated catalog shaped like the owner's
(section 2's sizes, widths, root split and backlog), and read-only on the owner's catalog
where real data matters. No benchmarks. Throwaway code on branches, not merged.

| | Question | Experiment | It changes the plan if |
| --- | --- | --- | --- |
| P0 | Does the stall reproduce without the owner's Mac? | The reproduction test and baseline (in progress) | it does not reproduce: every later number is suspect |
| P1 | S2, S1: what does each of G, A and A+B buy? | On the reproduction: (G) window reads on connections background cannot use, cursors, statistics; (A) a ledger for two products; then measure window waits and background rows visited per pass under each | G meets acceptance (plan shrinks) or A does not (plan is wrong) |
| P2 | S3, S4: can a ledger be kept correct, and which shape? | Implement trigger-maintained ledger for the embedding (simple inputs) and the description (five-table inputs); differential test against the scan predicate under random mutations; measure write overhead, backfill time, and a revision-bump rebuild; compare with the in-memory work list (S4a) and status-row (S4c) shapes | drift is found, or write overhead is material, or a simpler shape matches it |
| P3 | S5, S6, S7: where is the split line, and what does moving cost? | Classify every query that joins a derived table; move `search_embedding` to a second file on the generated catalog; time the move and the `VACUUM`, measure disk headroom needed; test the crash and orphan cases | the window's queries need a moved table, or the move cannot be made safe and resumable |
| P4 | S8: do mapped vectors work? | Read-only on the owner's real embeddings: rank agreement of half against full precision for sample queries; brute-force time over mapped memory with Accelerate; a format with append, delete and crash recovery, fuzzed | ranking changes visibly, or it is slower, or the format cannot be made crash-safe simply |
| P5 | The plan as a whole | An independent reviewer reads this plan and the code and argues against it: missing options, wrong assumptions, a smaller correct design | it finds one |

## 7. Findings

*To be written as P0 to P5 report: what held, what broke, and whether the recommendation
stands.*
