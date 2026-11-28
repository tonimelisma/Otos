# Immich assets the server has not read yet — 2026-11-28

## Question

The user's Activity popover counted 934 Immich items as "sent only when you open them", and
the grid showed them as gray placeholders. The question was whether Otos can tell such items
apart from the server's own records, whether they should be shown at all, and why Otos's
one-copy rule (ADR 0054) did not hide the ones that are copies of library files.

## Method

All of it read-only:
- Otos's catalog on the test Mac, opened with `sqlite3 -readonly … ?mode=ro`.
- The test Immich server's database (Immich v3.4.2), inside `BEGIN READ ONLY … ROLLBACK`.
- Immich's server source at the `v3.4.2` tag (`server/src`).

## What the server holds

Of 149,438 assets on the server (not deleted, timeline or archive):

| State | Count | Metadata row (`asset_exif`) | `asset_job_status.metadataExtractedAt` | Thumbhash, thumbnail file |
| --- | --- | --- | --- | --- |
| Read, with images | 147,734 | yes | set | yes |
| Read, no images yet | 901 | yes | set | no |
| **Not read at all** | **942** | **none** | **none** | **no** |

- **Where the 942 came from.** They are all external-library assets: `libraryId` is set, 931 under one external library's folder, 11 under another's. All 1,647 assets added in the four days before were too; none was an upload.
- **Why they have no size.** A normal upload writes `fileSizeInByte` into `asset_exif` when the asset is created (`asset-media.service.ts`). A library scan creates the asset row and queues `AssetExtractMetadata`, and the server's queues then held 247,640 metadata jobs and 19,231 thumbnail jobs. So until the metadata job runs, an external-library asset has no metadata row at all, and no size.
- **Checksums are of paths, not bytes.** Every external-library asset's checksum is `sha1-path`, a hash of its path, so it says nothing about content (ADR 0054 already treats it so).

## What the sync stream tells a client

`SyncAssetV2` (`dtos/sync.dto.ts`) carries `thumbhash`, null until the thumbnail job runs. `SyncAssetExifV1` is sent only once an `asset_exif` row exists. So a client can tell three states apart from the stream alone:
- listed, but no metadata line: **not read**;
- metadata line, no thumbhash: **read, no images yet**;
- both: **ready**.

The stream cannot tell a job that is queued from one that failed. `asset_job_status` is not synced, and a failed thumbnail job records nothing per asset; failures show only as queue totals (93 failed thumbnail jobs, 11 failed metadata jobs that day).

## What Immich's own timeline shows

`AssetRepository.getTimeBucket` and the search queries join `asset_exif` with an inner join (`asset.repository.ts`, `search.repository.ts`). So **Immich's own timeline and search do not show an asset it has not read**. A metadata search for `20261125_134515.heif`, one of the 942, returned nothing; `20261122_162732_001.heif`, which had been read, was found.

## Why one-copy did not hide them

932 of the 943 such rows in Otos's catalog had a same-named file in the Camera Roll library.
- **930 were already paired with their file** through the server's path checksum (`immich_mirror_pair`, ADR 0054). Every one of them agreed on the whole-second modification time.
- **The version rule still failed for all 930.** It needs equal sizes when neither row has a digest, and an unread asset has no size. So each pair showed as two photos: the library's, with its thumbnail, and the account's, as a placeholder.

## The 2,119 pairs whose versions differ

Separately, 2,119 pairs with known sizes disagree: 1,984 on size and time, 135 on time alone. In each case the Mac's file is newer than what Immich lists, by hours up to six months. For three samples, the server's disk held exactly the Mac's size and time, while Immich's database still held an older size and time (its `updatedAt` from Nov 8 to 22). The HEIFs were 1,506 bytes smaller than Immich's record, which suggests a metadata rewrite of the files on Nov 20–25; what rewrote them was not found. Otos never writes originals.

So Immich has not re-read files that changed on disk, and Otos's rule correctly treats each pair as two versions until it does. Nothing in Otos changes for these.

## Conclusions (built, ADR 0046, ADR 0054)

- **A pair whose asset the server has not read agrees on its modification time alone** (v83). The path makes the file exact, and the time the scan read names its version; once the size arrives, the full check holds again.
- **An asset the server has not read is hidden by its source** (v84), as Immich's own timeline hides it:
  - `hidden_by_source` is "in the server's trash" (`source_deleted`) or "an account's row with no size";
  - only an unread asset has no size;
  - the account's Activity row says how many there are.
