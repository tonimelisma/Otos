# Counting an import batch's photos: what it costs, and which batches need it

Date: 2026-11-15. Context: #767 made the Imports sidebar and All Imports count the photos each
batch's grid shows (ADR 0052: a stack counts once), reading every batch's rows and stacking
their folders on each pass where a membership, grouping or stack fact moved. This pass
measures that read on a backup of the reference catalog and in the installed app's log.

## The reference catalog

`sqlite3 .backup` of the installed app's catalog, read by the real
`CatalogQueryGateway.fetchImportBatches` in a test process (Debug, as the installed app
is), while other sessions' checks ran.

- 45 batches, 11,401 imported rows, in 10 folders. Their folders hold 14,121 stack candidates
  (the batch rows are most of them), which make 4,953 stacks.
- Every batch counted (#767): 843–1,513 ms in the first measurement, 350–416 ms warm in the
  second. By phase, warm: the rows 25–34 ms, the candidates 93–111 ms, the pairing rule
  (`PhotoStackRule`, in Swift) 169–239 ms, each batch's collapse about 50 ms. The batches'
  own rows are most of the candidates, so narrowing the candidate read cannot cut it.
- The newest batch counts 111 photos from 210 files, as its grid shows.
- The five newest batches hold 630 rows in one folder, whose candidates are 882.

## How often the read runs

From `script/logs.sh show --last 4h` of the installed app: `op=catalog.projection.window
phase=finish` ran up to 33 times a minute (09:43, 09:45) and 11–20 a minute for
10:06–10:11. A membership fact moves with every import write and scan change, and the stack
fact with every enrichment write to a still that shares a folder with a RAW, which is every
folder holding the reference library's camera imports. At 350 ms to 1.5 s a read, counting every batch
on such a pass would add seconds of work per minute to the projection while importing or
enriching.

## Conclusion

Only the batches the window shows are counted (`ImportBatchListing`): the Imports section's
newest five, an older batch while it is selected (the sidebar lists it after the five), and
every batch while All Imports lists them. A batch not shown has no count (nil), never a made
up one. The nonempty batches themselves are listed in `idx_media_asset_import_batch`'s order.
The projection holds the answer for the same count scope while no input moved
(`CatalogProjectionReads.importBatches`).

Measured on the final code:

| Count scope | Batches counted | Cold | Warm |
| --- | --- | --- | --- |
| The sidebar (All Media selected) | the newest 5 | 101 ms | 22–31 ms |
| The oldest batch selected | the newest 5 and it | 121 ms | 48–51 ms |
| All Imports | all 45 | 624 ms | 340–359 ms |

The counts are the same in every scope: the newest batch 111, all 45 batches 6,463 photos.
All Imports pays the whole read only while it is open.
