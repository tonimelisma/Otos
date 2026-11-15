# One photo, many copies: how Otos finds and shows copies across libraries and accounts

- Date: 2026-11-14
- Relied on by: ADR 0054, ADR 0018, migration v60

## Question

The owner's Immich server mirrors the OneDrive folders Otos also has as libraries, so every
photo there showed twice in All Media. What do other apps do, which fact can pair a library
file with an Immich asset without downloading the asset, and what does showing one copy cost
on the owner's catalog?

## The owner's catalog (read-only, 2026-11-14)

Read from the installed app's catalog, opened read-only (`mode=ro`).

| Root | Rows | Has an Immich asset with the same name and byte size |
| --- | --- | --- |
| OneDrive › Camera Roll (library) | 16,678 | 16,670 |
| OneDrive › Summer Photos (library) | 788 | 0 |
| Immich account | 147,051 | — |

- All 17,466 library rows had an XXH3 digest. Only 2 Immich rows did, because Otos downloads
  an account's original only for the user's own work (ADR 0046 §4). So the Duplicates feature,
  which groups by digest, never paired them.
- 983 sets of Immich assets share a name and a byte size within the account itself.

## What other apps do

- **Google Photos and Immich (uploads):** an upload that is byte-identical to an asset the
  account holds is skipped, so the library holds one item. Immich's external libraries are
  left out of this check: a file both mounted as an external library and uploaded shows twice
  (Immich discussion 6714; r/immich, "can external libraries be deduped").
- **Lightroom Classic:** at import, "Don't Import Suspected Duplicates" compares the original
  file name, the EXIF capture time and the file size, within one catalog. There is no view
  across catalogs.
- **Mylio:** has a dedupe tool across linked sources, for exact copies (same type, size and
  resolution). It merges keywords onto the copy kept (Mylio support, "find duplicate photos").
- **Plex / Emby:** show several files of one movie as one item with versions and a count
  badge, merged automatically when they match one metadata ID. Plex merges only within one
  library (Plex support, "Merging Items").

So apps that collect from several sources show one item and keep the copies under it. Cleanup
is a separate tool. A mirror the user keeps on purpose, such as Immich of OneDrive, is not
waste to clean. It is one photo held in two places.

## Which fact pairs a library file with an Immich asset

- **Immich's `checksum`.** It is sent for every asset in the sync stream, Base64 of 20 bytes
  (a live 3.3.6 line: `"checksum": "MDO/p/AKSxrbhRCQnjVUzGGH/i0="`).
  - For an **uploaded** asset it is the SHA-1 of the original's bytes (`ChecksumAlgorithm.sha1File`).
  - For an **external-library** asset it is the SHA-1 of the text `path:<original path>`
    (`ChecksumAlgorithm.sha1Path`), set in `LibraryService.processEntity` on main, and never
    replaced with a content hash.
  - The sync DTO (`SyncAssetV2Schema`) carries `checksum` and `libraryId` but no algorithm. An
    asset with `libraryId` set is an external library's, and its checksum names no content.
  - Sources: `immich-app/immich` main, `server/src/services/library.service.ts`,
    `server/src/enum.ts` (`ChecksumAlgorithm`), `server/src/schema/tables/asset.table.ts`,
    `server/src/dtos/sync.dto.ts`, read 2026-11-14.
- **Name and size.** These matched 99.95% of Camera Roll here, but they are not proof. iPhone
  file names repeat every 10,000 photos, and OneDrive's camera upload can rename a file or
  convert HEIC to JPEG. Lightroom uses them only to *suspect* a duplicate. Otos never hides one
  photo behind another on a guess.

**Conclusion:** Otos's digest becomes SHA-1. A library file's SHA-1 is read from the bytes
enrichment already reads, and an uploaded Immich asset's SHA-1 arrives with its listing, so
the two compare with no download. An external-library asset has no content digest until its
original is downloaded for the user's own work.

## SHA-1 throughput (this Mac, M1 Pro, CryptoKit, 512 MiB in 1 MiB updates)

| Digest | Throughput |
| --- | --- |
| `Insecure.SHA1` | 1.6–2.0 GB/s |
| `SHA256` | 1.9–2.2 GB/s |

A 3 MB HEIC hashes in about 1.5 ms and a 50 MB RAW in about 25 ms, against tens to hundreds of
ms to read and render each, so the digest is not what sets enrichment's pace. XXH3 was not
measured here.

## Showing one copy: query cost on a copy of the owner's catalog

Measured on a scratch copy made with `.backup` (2.5 GB, 164,517 rows in the three roots), never
opened by Otos. Immich rows were given their library twin's digest where name and size matched
(17,651 rows), else a random one. The query is All Media's date order (`idx_media_asset_best_capture_global_desc`).
The Mac was heavily loaded (95% full disk, other sessions building), so wall times vary 2–3×
between runs. Read the ratios.

| Approach | All Media order |
| --- | --- |
| Today's query, no collapse | 0.22–0.71 s |
| `NOT EXISTS` probe per row on the digest index | 19–24 s |
| Same, with a covering index for the probe | 17–33 s |
| Shadowed set computed once (window function), `NOT IN` | did not finish in 10 min |
| Digest as a virtual generated column in the order index | 4.8–16.5 s |
| **Stored `shown_copy_root_id`, in the order index** | **0.35–0.48 s** |

The probe is slow because the order index does not hold the row's digest. Each of 164k rows
costs a random read of its 3 KB table row, the cost v55 removed from these reads. A stored
column the order index carries reads nothing from the table.

Computing the shadowed set alone took 0.57–1.31 s, too slow to repeat on every window pass.

Keeping the stored column current with SQLite triggers, measured as 5,000 single-row digest
writes:

| | 5,000 digest writes |
| --- | --- |
| Without triggers | 2.4–2.6 s |
| With the copy triggers | 5.9 s (the first version, whose `OR rowid` arm scanned, took 17.8 s) |

So the triggers add about 0.7 ms per digest write, which rides enrichment's transaction for a
file that takes tens of ms to read. Filling the column for every row at once took 87 s cold.
The migration does not need to: it clears every digest, so the column starts NULL everywhere
and fills one write at a time.

With the stored column, All Media's 164,517 rows show as 146,755. The 17,762 hidden rows are
the Immich twins of library files, plus duplicates inside the account.

## Migration v60 and the triggers at owner scale

Measured on a `VACUUM INTO` snapshot of the installed catalog (2.4 GB). `.backup` kept
restarting while the running Otos wrote to the catalog, so it could not produce a copy.
The same loaded Mac as above.

- **The migration** (every statement of v60, in order) took **47.9 s**. Its cost is the
  index rebuilds:
  - the four claim indexes, 2.5–3.2 s each;
  - the five tested indexes, 2.2–13.8 s each;
  - clearing every XXH3 digest, 4.0 s.

  It runs once, at the first launch of the build.
- **Filling every digest through the triggers**, as re-reading the libraries and the account's
  full resync will:
  - the 17,468 library rows in one statement: 13.6 s;
  - the 147,051 account rows one at a time, committed in batches of 500 like a listing:
    570 s (3.9 ms each), while two builds ran beside it.

  Afterwards 17,651 account rows named a library copy as shown, the same 17,651 the
  name-and-size count found.
- **The triggers' own share**, 3,000 single-row digest writes each, on the same file under
  the same load:

  | | Per write |
  | --- | --- |
  | With the triggers | 1.05–1.81 ms |
  | Without | 0.70 ms |

  So the triggers add about 0.4–1.1 ms per digest write, one to three minutes over a full
  resync of the owner's account. The recompute's plan is index seeks only:
  `idx_media_asset_content_sha1` for the group, the root's primary key for its kind.

## Every digest at once: Duplicates and a virtual column

Once every row has a digest, scans over all of them have to be answered from an index.
SQLite never serves a virtual generated column from an index: an index on
`current_content_sha1`, the first form of v60, left Duplicates' copies read at **40–98 s**,
and its group subquery read all 164k table rows. Testing the stored digest and its stamps
directly, through an index that holds them (`idx_media_asset_content_sha1`,
`ContentDigestSQL`), makes the group subquery covering:

| Duplicates' group subquery over 164k digests | Time |
| --- | --- |
| Virtual column, its own index | 14–30 s |
| Stored columns, `idx_media_asset_content_sha1` | 0.09–0.35 s |

The copies read itself now returns 32,903 copies in 16,001 groups, where it had none of the
account's before. It took 4.0–6.2 s, warm. Its index columns alone take 0.3–0.7 s; reading the
copies' table rows adds 1–2 s, and the `asset_metadata` join for pixel sizes adds 3–4 s.
`DuplicatesProjection` builds off the main actor in its own loop, and the window never waits
on it (ADR 0042).

With the column in the date index, All Media's order reads 0.8–1.3 s whether or not it shows
one copy, alternating runs on the same copy: the test of `shown_copy_root_id` costs nothing
measurable.

## Conclusions

1. Combined scopes (All Media, Places, People, On This Day, search within them) show one copy
   of each set of identical copies. One library's scope, an import's and Duplicates show every
   file.
2. The digest is SHA-1, so an uploaded Immich asset's checksum is its digest without a download.
3. Which copy is shown is a stored column kept by triggers, carried by the window's indexes,
   and decided per scope by whether the shown copy's root is in the scope.
