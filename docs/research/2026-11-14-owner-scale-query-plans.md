# People, stacks, search, Duplicates and On This Day reads at owner scale (2026-11-14)

## Question

The reads added for People (ADR 0047), stacks (ADR 0052), search (ADR 0048), Duplicates
(ADR 0042, #739, #740) and On This Day (ADR 0049) were checked with `EXPLAIN QUERY PLAN` on a
20,000-row catalog only. What do their plans and times look like on the owner's catalog?

## Method

- **Catalog:** an APFS clone of the owner's backup
  (`build/catalog-backups/catalog-v51-before-second-fixes.sqlite`: 166,555 rows, 147,024 of
  them one Immich account's, 91,558 faces, 82,085 with a person, 14,614 for the most
  photographed person, 165,217 search embeddings, 11,025 text readings), opened by
  `CatalogStore` so the current migrations brought it to head. It was deleted afterwards.
- **Reads:** every Store read those features issue, called with the arguments the app passes
  (the libraries the Store reports available, the most photographed person, today and
  4 July for On This Day, a 2024 span and Helsinki for search facts), through a temporary
  test that traced each statement with GRDB's profile trace, printed its `EXPLAIN QUERY PLAN`
  and timed each read twice. The test was never committed.
- **Limits:** the two OneDrive libraries (17,458 rows) read as unavailable in the test
  process, so reads covered the account's root; the account's rows have no digest, so no
  duplicate group formed. The machine ran other agents' builds and tests throughout
  (`memory_pressure`: 17.5 M pageouts), so wall times of whole-library reads swing several-fold
  between runs; `sqlite3`'s CPU time is given where it separates plan from paging.

## Defects found and fixed

| Read | Before | After |
| --- | --- | --- |
| A person's photos (`SidebarSelection.person`; the same `EXISTS` serves the People filter, the likeness sort and a person named in a search) | `face` searched by `idx_face_person (person_id=?)` once per row of the scope: every face of the person walked for every row. 2,000 of the 147,024 rows did not finish in 15 minutes; the person's photos never opened | `idx_face_person_photo (person_id=? AND library_root_id=? AND relative_path=? AND is_not_face=?)`, covering: the person's 11,580 photos counted in 2.2 s cold, 0.12 s warm (0.10 s CPU); the window's order read 1.3–15 s under the load above |
| Duplicates copies (`DuplicatesGateway.duplicateCopiesSQL`) | every row of the roots walked by `idx_media_asset_stack_candidate`, digests grouped in a temporary B-tree: 14.5 s cold, 1.4 s warm (2.4 s CPU cold) | both reads through `idx_media_asset_content_hash`, no temporary B-tree: 0.67 s cold, 0.04 s warm (0.13 s CPU); 11 ms in the Store |
| Duplicates scope (order and counts) | its group subquery walked every row of the roots with a temporary B-tree for the GROUP BY: 12.5 s | through the digest index, no temporary B-tree: 0.53 s |

Schema v54 replaces v19's `idx_face_person` with `idx_face_person_photo`; building it took
13.7 s on the clone and the whole migration 17.8 s at the Store's open. Every read of a
person's faces by `person_id` alone still uses it by its prefix.

## Every read measured

Times are the second run, wall clock, on the loaded machine. "Index walk" means no `SCAN` of
a large table and no temporary B-tree over one.

| Feature | Read | Plan | Time |
| --- | --- | --- | --- |
| People | `peopleSnapshot` | every face by `face`'s key (by design: assignment reads every embedding), photo by key; the stacks candidates; the owed counts through v50's partial indexes | 3.5–16 s (face read 1.3 s) |
| People | `uncheckedForFaces` | owed-faces partial indexes | 0.03–0.06 s |
| People | `previewFaceCandidates(limit: 32)` | index walk | < 1 ms |
| People | `namedPeople` | `SCAN person` (one row per person) | < 1 ms |
| People | order of `.people` | date index, `face` by key per row | 14–25 s, dominated by reading each `media_asset` row of the order (the all-photos order read's own cost, 2–8 s here) |
| People | order of `.person` | fixed above | see above |
| People | `visibleAssetCount` / `catalogedAssetCount` of `.person` | `idx_face_person_photo` | 0.5–10 s |
| People | `facesRead`, `faces(of:)`, `photoInfoOverlay` | by key | < 25 ms cold |
| Search | `searchFactMatches` person / 2024 / Helsinki | person by `idx_face_person_photo`; date and place by index | 0.25 / 0.08 / 0.06 s |
| Search | `searchEmbeddingCandidates(16)`, `searchTextCandidates(8)` | index walk with `LIMIT` | < 10 ms |
| Search | `searchEmbeddingPendingCount` | every row of the roots, `search_embedding` by key | 16–28 s on the loaded machine; read by the window only when a search finds nothing |
| Search | `currentSearchEmbeddingIDs`, `currentSearchEmbeddings()` | every embedding by key, its row by key (the index's load: 165,217 vectors) | 13–16 s; the search index's own background owner |
| Search | `currentSearchTextIDs`, `currentSearchTexts` | by key | < 0.12 s |
| Duplicates | `DuplicatesProjection.build` | copies fixed above; same-photo candidates by root (every row with a picture signature, by design) | 1.1 s (candidates 1.1 s) |
| Duplicates | order and count of `.duplicates` | fixed above | 0.5–3.9 s |
| On This Day | order and counts of today and of 4 July | capture-time index, left-out rows by key | 0.2–0.65 s |
| Stacks | candidates read inside every order read | RAW folders by `idx_media_asset_stack_candidate`, bursts by `idx_media_asset_burst`; the temporary B-trees sort only those candidates | 0.12–1 s |
| Context | all-photos order, `filterOptions(.allMedia)` | index walks (another session's work) | 1.9–7.9 s, 0.5–3.9 s |

## Conclusions

- The person read was a defect on a path the window waits on: opening a person never
  finished on the owner's catalog. v54's index makes it one seek per row; the plan is pinned
  by `CatalogStoreQueryPlanTests.whetherARowHoldsAPersonIsOneSeekByPersonAndPhoto`.
- The Duplicates copies read and the Duplicates scope grouped every row of their roots in a
  temporary B-tree; both now walk the digest index alone, pinned by
  `CatalogStoreQueryPlanTests.duplicatesGroupThroughTheDigestIndex`.
- No other read scans a large table or sorts one in a temporary B-tree. The slow whole-library
  reads (`peopleSnapshot`, the embeddings load, the pending count, the `.people` order) read
  every row by design and are paging-bound on this machine (`sqlite3`: 0.6 s CPU of 16 s wall
  for the `.people` face checks). The `.people` scope's face checks drop from 14 s to 0.6 s
  with a partial index on named faces' photos, but its order read stays about 20 s on the
  same machine from reading every `media_asset` row of the order, which belongs to the order
  query's own work; that index is not added here.
