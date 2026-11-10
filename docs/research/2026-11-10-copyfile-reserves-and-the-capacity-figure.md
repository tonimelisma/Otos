# Copyfile reserves a file's size up front, and the capacity figure shows it at once

Date: 2026-11-10. Question: when the import's floor check reads
`volumeAvailableCapacityForImportantUsage` while copies are in flight, how much of
those copies does the figure already show? The answer decides whether subtracting the
in-flight bytes from the figure counts them twice (ADR 0027).

## Method

A probe, a standalone Swift program, ran on the internal APFS data volume. It called
`copyfile(3)` with `COPYFILE_ALL` on a 1 GiB file, as `CopyfileTransfer` does. From
copyfile's `COPYFILE_PROGRESS` callback, every 64 MiB, it read `COPYFILE_STATE_COPIED`,
the figure's drop since the copy started (read through a fresh `URL` each time, so no
resource-value cache), and `statfs` `f_bavail` for comparison. It also read both after
the copy returned. The copy stayed on one volume and was not a clone (`COPYFILE_CLONE`
was not passed, and the raw free blocks fell by the full size).

## Findings

| copied | figure's drop | `statfs` drop |
|---:|---:|---:|
| 1 MiB | 1.093 GB | 1.093 GB |
| 512 MiB | 1.109 GB | 1.109 GB |
| 961 MiB | 1.310 GB | 1.313 GB |
| done | 1.329 GB | 1.331 GB |

1. **copyfile reserves the destination's whole size when the data copy starts.** At
   1 MiB copied, free space had already fallen by the full 1 GiB (plus noise from
   other writers on the machine; the drop kept growing after the copy, to 1.68 GB at
   +10 s, from parallel builds).
2. **The figure tracked the raw free blocks at every sample.** In this run, CacheDelete's
   figure showed Otos's own reservation as soon as it was made. That does not make the
   figure authoritative: research 2026-09-09 (finding 4) documents it lagging and
   counting purgeable space.
3. Consequence: a figure read while copies are in flight already holds every started
   copy at its full size. A check that also subtracts those copies' planned bytes
   counts them twice: in an eight-worker run, up to eight files early. Copies not yet
   started are not in the figure.

## Conclusion

An owner with several writes in flight checks the floor against the lesser of the
figure now and its first reading less everything it has committed (`FreeSpaceLedger`,
ADR 0027). That is exact when the figure is fresh, as measured here, and it stays safe
when the figure lags, as research 2026-09-09 documents.

## Limits

- One volume (internal APFS SSD), one file size, on a busy machine. A card import reads
  from another volume, but the reservation happens on the destination, as measured.
- Camera staging downloads go through ImageCaptureCore, not copyfile. Whether that path
  reserves up front was not measured. The ledger is correct either way: a write the
  figure has not shown is covered by the projection.
