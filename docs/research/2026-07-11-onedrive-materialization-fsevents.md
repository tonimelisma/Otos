# Research: OneDrive materialization FSEvents (2026-07-11)

Sources and bounded capture used to decide the known-materialization event
policy in plan 0056. Conclusions feed ADR 0009 and ARC materialization rows.

## Sources

- Apple FSEvents Programming Guide; `kFSEventStreamCreateFlagIgnoreSelf`
- `FileManager.startDownloadingUbiquitousItem(at:)`
- File Provider synchronization notes
- Live Terminal probe: `script/probe-onedrive-materialization-fsevents.swift`
- Prior single-file Terminal probe recorded in plan 0056 §3.3

## Library size distribution (facts only, no byte reads)

Root: `~/Library/CloudStorage/OneDrive/Pictures/Camera Roll` (sample of
2001 media files under `2026/03` walk):

| metric | value |
| --- | --- |
| images | 1464 |
| videos | 537 |
| p50 logical size | ~5.4 MiB |
| p90 | ~95 MiB |
| p95 | ~128 MiB |
| p99 | ~256 MiB |
| max | ~6.8 GiB |

Admission budgets chosen from this distribution: 2 GiB aggregate materialization
byte budget, 1 GiB enrichment budget, large-video threshold 256 MiB, caps of 2
concurrent large-video materializations and 2 video enrichments, maxima 16/8.

## Materialization / FSEvent capture

Probe watched the normalized CloudStorage root with `FileEvents` + `IgnoreSelf`
(no `MarkSelf`). Samples were dataless before `startDownloadingUbiquitousItem`.

### Prior sample (plan §3.3)

`20260315_094624.heif` (9,691,136 bytes): one event `0x1d400`
(`itemInodeMetaMod,itemModified,itemChangeOwner,itemXattrMod,itemIsFile`);
logical size and content-mtime unchanged.

### Additional samples (this increment)

| label | size | lag request→materialized | events | size/mtime changed |
| --- | --- | --- | --- | --- |
| small-heic | 1,499,258 | ~8.9 s | one `0x1d400` file event | no |
| medium-heic | 1,749,236 | ~2.3 s | none matched in window | no |
| small-mp4 | 67,257,470 | ~4.0 s | `0x1c400` then `0x1d400` | no |

Decoded allowlisted shapes observed: regular-file combinations of inode meta,
modified, change-owner, and xattr flags. No create/remove/rename/directory/
`MustScanSubDirs`/dropped/root-changed flags on these hydrations.

Delivery lag from request peaked near 9 s. Events arrived within ~0.2 s of the
`SF_DATALESS` clear when present. One sample materialized without a matching
path event in the probe window (provider under-delivery), which is why launch
and periodic integrity remain required.

## Decision

**Suppress without final settlement** for proven allowlisted regular-file
non-membership shapes on normalized `MediaAssetID`s Otos has explicitly asked
to materialize.

- Begin grace: 15 s from materialization begin (covers measured ~9 s lag + margin)
- End grace: 5 s after successful materialization (late duplicate events)
- Failure/cancel: clear immediately
- Never suppress create/remove/rename/directory/symlink/dropped/root/`MustScanSubDirs`
- No final targeted settlement: stored facts were unchanged across samples; settlement
  would be a guaranteed no-op for the observed provider behavior
- Periodic integrity interval: 24 h successful full-root age (process-local)

Part A typed dirty scopes remain the structural storm fix even if suppression is
later disabled.
