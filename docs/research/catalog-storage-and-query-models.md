# Catalog Storage And Query Models Research

Status: non-authoritative research note.

Date: 2026-06-29

How production photo/media-library applications store and query their catalog, and
whether they hold the catalog in memory or query a database. This is design input
for the Otos catalog grid architecture; it does not describe current Otos behavior
and is not a commitment to implement.

## Question

Otos targets one media view scaling toward roughly a million items, with order that
changes continuously as metadata-driven sort keys arrive, and (later) metadata
filter/search. Should the catalog be a hand-maintained in-memory model, a database
queried per view, or a hybrid? What do shipping apps actually do?

## Findings

### Shipping apps are database-backed and query for sort/filter

- **Adobe Lightroom Classic** — the catalog is a set of SQLite databases (the main
  `.lrcat` has ~116 tables). Lightroom does not load the catalog into memory; it
  reads and writes "thousands of tiny pieces of data" for every action, and
  sorting/filtering are database queries rather than operations over an in-memory
  copy. The consequence is that performance is storage-latency bound and
  effectively requires an SSD; the built-in "Optimize Catalog" rebuilds indexes to
  keep queries fast.
- **Apple Photos / Core Data** — metadata lives in a SQLite store; the UI uses
  faulting plus `fetchBatchSize`. `NSFetchedResultsController` sends the sort
  descriptors and predicate to SQLite and receives lightweight references, faulting
  full objects into memory only as cells access them, with a bounded row cache of
  recently used objects. It is explicitly designed not to hold the whole library
  resident; sort and filter run in the database.
- **digiKam** — SQLite back-end (with a separate, wavelet-compressed thumbnail
  database), recommends enabling WAL for large databases, and recommends the SQLite
  backend only below roughly 100k images; beyond that it points users to a server
  database (MySQL/MariaDB). The scaling answer is to scale the database engine,
  never to move the whole catalog into application memory.

Cross-cutting: none of these hold a hand-maintained, full in-memory model of every
asset's data. The dominant pattern is database-as-truth, query for
sort/filter/selection, and keep only the current view's identifiers plus a bounded
cache of recently used detail in memory. The all-in-memory model is the
small-library pattern.

### "The database can't be in memory" is not how SQLite behaves

A disk-backed SQLite database keeps its hot pages in RAM through the page cache and
memory-mapped I/O:

- SQLite stores content in fixed-size pages and maintains an in-memory page cache;
  `cache_size` bounds it.
- With `mmap` enabled and `mmap_size` at least the active page set, reads become
  near-memory-speed (cached memory access on the order of 100 ns versus 80–120 µs
  for an NVMe read), with the OS managing the mapped pages as process memory.
- Indexed reads are fast on cached pages. A missing index is the cliff: it turns a
  roughly 1 ms read into a full scan.
- WAL mode allows concurrent readers alongside a single writer.

So querying SQLite repeatedly is not a disk seek per operation: the working set
lives in RAM, managed by SQLite and the OS rather than by an application
dictionary. The in-memory speed of a hand-maintained model is largely preserved by
the page cache, without maintaining a duplicate model.

### Costs and limits of the database-backed model

- It is storage-latency sensitive (benign on the SSDs modern macOS targets ship).
- It depends on declared indexes for every sort and filter; an un-indexed query is
  a full scan.
- SQLite itself strains for very large, query-heavy catalogs. digiKam's ~100k
  guidance is a real signal that beyond some scale the answer is a stronger database
  engine, not an in-memory catalog.
- A concurrent read path (WAL plus a reader pool) is needed so view reads do not
  serialize behind writes.

## Implications for Otos (non-authoritative)

- The database-backed model is the evidenced choice for the stated ~1M target. The
  all-in-memory model is what Otos has today and is appropriate only up to roughly
  the ~100k range.
- Sort, filter, and "what needs enrichment" become indexed queries, which at scale
  are simpler and cheaper than the current full-map scans, not harder.
- Querying the database preserves in-memory speed through the page cache: size
  `cache_size`/`mmap_size` to the working set, run WAL, and declare indexes.
- Single ownership is preserved only if every query stays behind one owner (the
  Store); no other layer may touch the database directly. The architecture document
  builds on this conclusion.

## Sources

- Lightroom:
  [Points in Focus — the Lightroom catalog](https://www.pointsinfocus.com/learning/digital-darkroom/the-lightroom-catalog-and-develop-history-states/),
  [Imagen AI — fixing a slow Lightroom catalog](https://imagen-ai.com/valuable-tips/lightroom-large-catalog-slow-fix/),
  [Seachess — dive into Lightroom catalogues](https://www.seachess.net/notes/dive-into-lightroom-catalogues/)
- Apple Photos / Core Data:
  [Core Data Performance Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/Performance.html),
  [Faulting and Uniquing](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/FaultingandUniquing.html)
- digiKam:
  [Database Settings](https://docs.digikam.org/en/setup_application/database_settings.html)
- SQLite:
  [phiresky — SQLite performance tuning](https://phiresky.github.io/blog/2020/sqlite-performance-tuning/),
  [Oldmoe — turn on mmap support for your SQLite connections](https://oldmoe.blog/2024/02/03/turn-on-mmap-support-for-your-sqlite-connections/)
- Related Otos docs:
  [media-grid-best-practices.md](media-grid-best-practices.md),
  [process/performance.md](../process/performance.md)
