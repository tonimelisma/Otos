# A photo's copies: choices, faces, the next reachable copy and mirrors (2026-11-15)

Supports the ADR 0054 and ADR 0042 sections the owner's three decisions of 2026-11-15 added
(review #775: a mirror is never a duplicate; a choice and a face are the photo's; only the next
best reachable copy shows).

## Question

What do the new reads cost — the one-copy test that asks the digest index when the best copy's
library is away, the face tests through a photo's copies, and the Duplicates rule without
external assets — and what does migration v64 cost?

## Method

No owner data was read (owner's rule, 2026-11-15). One owner-shaped catalog, built by a test that
was never committed and deleted afterwards, after `CatalogStore.migrator` to v62:

- 166,000 rows: 16,000 in a library of month folders (one in twenty a RAW) and 150,000 in an
  account, one folder each; capture dates spread over 2011–2026 independently of the keys; every
  row an `asset_metadata` row with a 1.1 KB record. The first 16,000 account rows mirror the
  library: the same SHA-1 and an external path checksum. The other account rows have digests
  of their own. One library row in fifty is Liked.
- Three people of 24, 1,660 and 16,218 faces on account rows, and the same faces on the library
  copy of each mirrored one (both copies are read for faces today).
- Then migrated to v64 (this branch) or left at v62 (`origin/main`, `3853e440`, in a separate
  worktree), and `ANALYZE`d.
- Measures, as `2026-11-15-large-narrow-scopes.md`: the pages a fresh read-only connection with
  no memory map misses on its first read (`SQLITE_DBSTATUS_CACHE_MISS`), and the best of three
  times, for each combined scope's order. Both trees ran at the same time on a machine running
  other sessions' checks, so times are loose; pages are the measure.

## Findings

| read (rows shown) | base pages (ms) | v64 pages (ms) |
| --- | --- | --- |
| All Media (150,000) | 2,363 (377) | 2,066 (227) |
| All Media, library away (150,000) | 2,097 (291) | 3,473 (255) |
| All Media, Liked (320) | 15,427 (199) | 17,822 (130) |
| Person of 24, sought | 117 (0) | 169 (1) |
| Person of 1,660, sought | 3,669 (23) | 5,456 (22) |
| Person of 16,218, walked | 3,807 (241) | 4,626 (156) |
| People (17,899) | 2,964 (169) | 3,800 (148) |
| All Media, People filter of 1,660 | 2,827 (128) | 3,648 (110) |
| Duplicates within each library (0 copies) | 3,649 (86) | 3,325 (53) |
| Duplicates across libraries | 16,349 (1,335), 32,000 copies | 3,325 (69), 0 copies |

- **All Media with every root reachable reads what it did:** the stored best copy decides every
  row in the index; the digest-index question is never asked.
- **With the library away**, each account copy whose best copy is the library's asks the digest
  index for a reachable better copy: 1,400 more pages for 16,000 such rows, and the window shows
  each photo once (base showed the same 150,000 rows, but on a catalog with three copies it
  showed every remaining copy, ADR 0054's finding).
- **The test is two terms.** As one `OR` with a subquery, SQLite tested it after the Liked
  filter's choice, which reads the table, so every hidden copy was read too: 49,450 pages against
  base's 15,427. Split, the index-only half runs first: 17,822.
- **Face tests through copies** cost a table read and a digest seek for a row with a copy that
  holds no face itself, and a seek list a few hundred pages longer for a sought person: 20–50 %
  more pages, no slower.
- **Duplicates across libraries** no longer lists the 16,000 mirror pairs (32,000 copies), and
  the read drops from 16,349 pages to 3,325.
- **Migration v64** took 3.5 s on this catalog (loaded machine): seven index rebuilds and one
  write of each copy row (32,000). Writing every row with a digest, as a first version did, took
  6.3–7.7 s. The page count after it was base's (126,145 against 126,149).

## Conclusions

- Keep the best copy stored; ask the digest index only for rows whose best copy's root is out of
  the scope. A per-scope stored shown copy would write every copy of a library on each mount.
- Keep the one-copy test's index-only half a term of its own.
- Ask the digest-index question only when a library or account root is out of the scope. Asked
  always, its text alone cost a narrow scope's reads their preparation:
  `projection.windowState.mapArea` rose from 64.3 to 66.6 M instructions (+3.6 %, flagged by
  `script/bench.sh compare` against `0b41160d`), with no row of the benchmark catalog asking.
- The window-path costs are measured on every commit by `copies.order.allMedia.of16k` and
  `copies.order.libraryAway.of16k` (ADR 0043).
