# Mirror pairs by path: why the mirror's one-copy rule paired nothing, and what pairs it

- Date: 2026-11-17
- Relied on by: ADR 0054 ("A mirrored library file is its external asset", "A pair is one photo
  while its versions agree", "The copies of a photo share a key"), migrations v79 and v80

## Question

ADR 0054 shows a library file and its Immich mirror as one photo. On the reference library All
Media showed about the two sets added together, and each mirror walk logged `paired=0`. Why,
and what design delivers the decision without downloading originals, now that a cloud-only
file's digest waits for its bytes to be local (ADR 0009 §12)?

## The reference catalog (read-only, schema v78, 2026-11-17)

Read from the installed app's catalog, opened `mode=ro` while no Otos ran; the checksum each
library file's path would have was computed outside the catalog with the code's own rule
(`SHA-1("path:" + prefix + relative path)`). No path or name is recorded here.

| Fact | Count |
| --- | --- |
| Account rows (all external-library assets, `source_path_sha1` set) | 147,310 |
| Account rows with a digest | 14 |
| Mirrored library's files | 16,932 |
| … with a digest | 13,713 |
| `immich_mirror` rows | 1 (that library and the account) |
| Library files whose path, under the stored prefix, names an account asset | 982 |
| … listed with the file's size | 981 (one asset's size not yet reported) |
| … listed with the file's whole-second modification time | 982 |
| … where the file has a current digest | 14 |
| … recorded as one photo (the asset holding the file's digest) | 14 |
| Library files whose path names no asset under the stored prefix | 15,950 |
| … that do have an asset of the same name and size | 15,945 |

- The 982 files are exactly the files of two of the library's eleven second-level folders;
  none of the other nine folders' files is named under the prefix. Changing the case or
  Unicode form of a path component, or dropping or adding a component on either side of the
  prefix, names none of them.
- The only 14 account rows with a digest are the 14 pairs above: the digest v61's pairing
  wrote from the file.

## Why `paired=0` every pass

The log (`script/logs.sh show`, `op=immich.mirror`) shows each owed walk:
`phase=notMirrored candidates=3 known=true` for the mirrored library, then
`phase=paired files=12373…13710 paired=0`.

1. **Pairing needed the file's digest.** An asset was a file's copy only by taking the file's
   digest (`MirrorGateway.pair`), so the walk read only files with a current digest
   (`digestedFiles`). Of the 982 files the prefix names, 968 have none (3,219 of the library's
   files had none that day). The other 14 were paired already, so each pass
   paired 0. `files=` in the log is the digested files the walk read (12,373 rising to 13,710
   as digests arrived), almost none of which the prefix names.
2. **The probe asks three paths that never confirm.** The candidate read takes the first three
   library files, in path order, that have an asset of the same name, size and time. They are
   in a folder the prefix does not name. The "kept" test asks only whether one of those three
   confirms the stored prefix, so it never passes, and every owed walk asks the server for the
   same three paths. None of them taught a new prefix, so the stored one stayed.
3. **Most of the library is not under the prefix.** 15,950 files have a same-name, same-size
   asset whose path checksum is not the checksum of the prefix plus their relative path. What
   the server's path for them is cannot be told from the catalog: the checksum is one-way and
   the log never recorded a server's `originalPath` or why a candidate failed. Unknown until
   one such asset's path is read; the probe now logs the reason a candidate teaches nothing
   (`phase=candidateRefused reason=noPath|tailMismatch|checksumMismatch`, with the trailing
   components a mismatched path shares).

## What All Media shows (the order read's own rule, computed read-only)

Present rows of the two libraries and the account, less Live Photo movies and rows whose shown
copy's root is in the scope:

| | Items |
| --- | --- |
| Today | 164,934 |
| With every path-matched pair one photo (967 more rows left out: 982 pairs, 981 agreeing, 14 already one photo) | 163,967 |

Stacks fold some of these items further in the window; the difference is the pairs'. The
15,950 files the prefix does not name still show beside their assets.

## Design

- The pair is a fact of its own (`immich_mirror_pair`): a file and the asset its server path
  names, recorded from the listing alone. It needs no digest, so a file pairs before its bytes are ever read.
- The copies of a photo share one key (`media_asset.copy_key`): a row's own current digest,
  or, for a pair whose versions agree, the digest either holds, else the asset's path
  checksum. Every rule that groups copies groups by it, so the scope clause, the choice
  trigger, faces, Info and the window's held choice need no second relation.
- A stored prefix that pairs any file is kept with no request; the probe asks only for a
  library none of whose files is paired.

## Migration v79's cost on a generated reference-shaped catalog

Measured with `OTOS_SCALE_TEST=1 script/check.sh --only CatalogMigrationCostTests` on
`ReferenceShapedCatalog` at scale 1 (147,267 account rows, 16,683 generated pairs whose rows'
copy keys the triggers set), the catalog put back to v78 with each pair's asset holding its
file's digest where the file has one, as v61's pairing wrote it:

| Measure | Value |
| --- | --- |
| Migration time (the Store's own migration pass) | 1,406 ms and 4,263 ms in two runs, the second under other sessions' parallel checks |
| Write-ahead log it leaves | 74.0–74.2 MB |
| File size before / after | 2.32 GB, unchanged (no compaction owed) |
| `idx_media_asset_copy_key` | 68 leaf pages, 4,648 rows (every row with a current digest) |
| A Like, a format change, an insert and a delete: log bytes before / after | unchanged (61,832 / 57,712 / 111,272 / 111,272) |

The migration writes the copy key on every row with a digest, clears the external assets'
digests and regroups their files, renames `person_photo`'s column and refreshes its rows, then
builds the one partial index and the triggers. No order index is rebuilt, and the order reads
it measures read what they read before (`defaultOrder` 7,250 → 7,272 pages, `nameOrder` 6,974 →
6,975, `likedFilter` 96 → 97, `filterOptions` 7,843 → 7,844). Pairs are not written by the
migration; the account's first walk writes them.

## The order reads with every generated pair one photo

`OTOS_SCALE_TEST=1 script/check.sh --only OrderReadSurveyTests`, on the generated catalog with its
16,683 pairs (`ReferenceShapedCatalog.writeMirrorPairs`), newest first, no filter:

| Read | Rows | Pages | Rows visited per row returned |
| --- | --- | --- | --- |
| All Media | 148,083 (164,766 less the 16,683 pairs' assets) | 7,350 | 1.13, the date index alone |
| All Media, library 6 away | 147,295 | 7,350 | 1.13; the copy key's index is asked of no row |
| Places | 90,846 | 9,383 | 2.84 |
| People | 65,873 | 11,680 | 3.83 |
| The most photographed person | 17,003 | 4,773 | 1.85 |

The one-copy test reads `shown_copy_root_id` from the order index, as before v79; no read joins
the pair table.

## A second prefix (later on 2026-11-17, relied on by migration v80)

One read-only server answer, authorized by the user, gave the `originalPath` of one of the
15,955 unpaired files: the same library, under a second server prefix (written here as
`/srv/b/…`; the stored one as `/srv/a/…`). Checked offline against each unpaired file's
asset's `source_path_sha1`:

| Of the 15,955 files no stored prefix pairs | Count |
| --- | --- |
| Match `SHA-1("path:" + second prefix + relative path)` exactly | 15,942 |
| Match once the path is in the other Unicode normal form (a folder name with `ä`; local and server forms differ) | 3 |
| Have no asset on the server yet (new files) | 10 |

So one library has two prefixes on one server, and the probe never asked again because a stored
prefix that paired any file was kept. Immich hashes the path its crawl read from its own disk,
byte for byte, with no normalisation, so the form of an accented name is the server disk's.

Migration v80: a set of prefixes per library (`immich_mirror` keyed by the prefix), remembered
candidates (`immich_mirror_asked`), every path compared in either normal form
(`ImmichPathChecksum.everyForm`), and a pair's fallback copy key its own (`pair:<account>:<asset
path>`) in place of the asset's path checksum, which two servers can share.

### v80's cost on a generated reference-shaped catalog

Measured with `OTOS_SCALE_TEST=1 script/check.sh --only CatalogMigrationCostTests` on
`ReferenceShapedCatalog` at scale 1, which now generates its 16,683 pairs under two prefixes (982
under the first), each asset's path checksum that of its prefix and file, the catalog put back
to v79 (v79's triggers, one prefix per library, each pair keyed by its asset's path checksum):

| Measure | Value |
| --- | --- |
| Migration time (the Store's own migration pass) | 2,447 ms, under other sessions' parallel checks |
| Write-ahead log it leaves | 55.5 MB |
| File size before / after | 2.328 GB / 2.331 GB (no compaction owed) |
| A Like, a format change, an insert and a delete: log bytes before / after | unchanged (61,832 / 57,712 / 111,272 / 111,272) |
| Order reads' pages before / after | `defaultOrder` 7,372 → 7,374, `nameOrder` 6,974 → 6,976, `likedFilter` 96 → 98, `filterOptions` 7,843 → 7,845 |

Almost all of it is the rekey of every pair whose rows have no common digest (each regroups
its key). The generated catalog has 16,683 pairs; the reference catalog has 982, so its migration rekeys
about a seventeenth as many rows. No order index is rebuilt.
