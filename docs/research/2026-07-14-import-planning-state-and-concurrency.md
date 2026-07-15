# Import planning state, idempotence, and copy concurrency

Date: 2026-07-14. Context: a live import (121 files, SD card → OneDrive-synced
library) exposed three defects and two design gaps. This doc records the field
evidence, the survey of how comparable tools solve the same problems, the design
alternatives considered, and the conclusions the next increment relies on.

## Field evidence (live session, 2026-07-14)

- One Import click started **two concurrent `MediaImportExecutor.execute()` runs**
  (batch IDs `1784083438029` and `1784083439983`, interleaved settles). Root
  cause: `MediaOperationCoordinator.buildPlan` re-triggers
  `beginExecutionIfPossible` while `queuedStart[source]` is still set, and
  `queuedStart` is only cleared after `execute()` returns. No guard rejects
  execution for a source already `.executing`. Effects: every file's bytes read
  and written twice, 111 `mediaOperation.publish phase=foreignOccupant` races,
  progress UI flickering between the two executors' counts, journal recovery
  replaying live operations mid-import (`renamex_np errno=2`).
- Post-import replanning classified the import as **70 preexisting + 51 blocked**.
  The blocked entries were `comparisonRequiresMaterialization`: OneDrive had
  already evicted (`compressed,dataless` in `ls -lO`) many just-imported `.arw`/
  `.hif` files, and `ContentEqualityChecker` correctly refuses to materialize
  during background planning. 56 `op=import.compare phase=requiresMaterialization`
  events logged.
- Every settle bumps destination occupancy → `handlePlanningChange` → full plan
  rebuild with filesystem occupancy probes and byte-equality probes, continuously,
  **during** the import. Scanner-level reconciliation of self-caused writes is
  already a no-op (`changed=false` in 1–2 ms); the waste is planner-level.
- The copy pipeline is strictly serial: one file at a time, with ~4 serialized
  CatalogStore round trips (journal begin/progress/publish/settle) between byte
  transfers, so the source medium idles during every metadata phase. No per-file
  copy span or throughput instrumentation exists.

## Survey: how comparable tools handle "already imported"

- **Lightroom Classic** — "Don't Import Suspected Duplicates" matches on
  *original filename + capture date/time + file size*. No checksums. Known
  failure modes: renamed originals and timezone shifts defeat it.
  ([Ask Tim Grey](https://asktimgrey.com/2022/11/23/limits-of-duplicate-detection-in-lightroom-classic/),
  [Lightroom Queen](https://www.lightroomqueen.com/community/threads/finding-the-suspected-duplicate.41919/))
- **Photo Mechanic** — "Copy new photos only" keeps a per-computer ledger of every
  photo previously ingested, independent of whether the option was on during the
  earlier ingest. Reformatting the card resets the ledger's usefulness — accepted
  limitation. This is provenance-keyed-by-source, exactly the model that makes
  re-inserting a card instant.
  ([Camera Bits docs](https://camerabits.freshdesk.com/support/solutions/articles/48000207409-ingesting-photos),
  [Camera Bits forums](https://forums.camerabits.com/index.php?topic=4548.0))
- **digiKam** — persists a `uniqueHash` per image (MD5 over EXIF + first 8 KB +
  file length) plus Haar-signature similarity fingerprints in its DB.
  ([digikam-devel](https://mail.kde.org/pipermail/digikam-devel/2010-April/042209.html))
  This is the content-fingerprint model ADR-0008 explicitly rejects for Otos.
- **rsync / rclone** — default "quick check" is *size + mtime*; full checksum is
  opt-in because it costs a full read of both sides. Industry acceptance that
  size+mtime is the right default equality proxy for sync tools.

## Survey: self-caused filesystem events

- FSEvents offers `kFSEventStreamCreateFlagIgnoreSelf` (macOS 10.6+), which drops
  events *caused by the calling process* at the stream level.
  ([Apple docs](https://developer.apple.com/documentation/coreservices/1455376-fseventstreamcreateflags/kfseventstreamcreateflagignoreself))
  Rejected for Otos: the OneDrive File Provider daemon generates its own events
  for the same paths (upload, eviction), so self-filtering removes little; and the
  scanner's reconciliation of self-caused writes is already a cheap no-op because
  settle wrote matching catalog rows first. The churn to eliminate is planner
  re-triggering, which has a narrower owner (the coordinator), not event
  filtering.

## Survey: copy concurrency on flash media

- Flash has no seek head; the classic interleaved-I/O penalty is a spinning-disk
  concern. SD 6.0 (2017) added Command Queueing (queue depth 2–32) for A2-class
  cards; hosts that queue see real gains
  ([SD Association](http://www.sdcard.org/press/thoughtleadership/applications-in-action-introducing-the-newest-application-performance-class/),
  [Pi 5 CQ testing](https://forums.raspberrypi.com/viewtopic.php?t=367459&start=25)).
  UAS USB readers queue at the SCSI layer regardless.
- Parallel transfer's dominant win is amortizing per-file latency and overlapping
  read/write/metadata phases across files, not multiplying bus bandwidth: rclone's
  parallelism measured ~4× over single-stream rsync on the same hardware
  ([Jeff Geerling](https://www.jeffgeerling.com/blog/2025/4x-faster-network-file-sync-rclone-vs-rsync/));
  small-file transfer literature attributes this to latency amortization
  ([arXiv 2312.17524](https://arxiv.org/pdf/2312.17524)).
- Counter-evidence exists (parallel copy slower in some local cases,
  [Rust forum](https://users.rust-lang.org/t/why-copying-files-in-parallel-is-slower-than-sequential/55633);
  HDD fragmentation from parallel writes,
  [rclone forum](https://forum.rclone.org/t/default-for-copy-move-to-local-hdds-causes-extreme-fragementation-and-slow-reads-after-transfer-is-complete/41630)),
  concentrated on spinning disks and unbounded queues. A single large sequential
  stream already saturates the card bus; extra workers help the long tail of
  small files and the metadata bubbles.
- Conclusion: a bounded worker pool is justified, sized by measurement (1/2/4/8)
  with per-file and per-batch throughput spans, not assumed. Expect most gain by
  2–4 workers on UHS-I sources.

## Design alternatives for instant, idempotent replanning

Invariant adopted: **planning is idempotent and convergent** — a fully applied
plan replans to all-preexisting/no-op using catalog facts only (no byte I/O, no
materialization exposure), and identical inputs always produce identical plans.

- **(A) Settle-time provenance — chosen.** At settle, record the source identity
  and source facts (source root path, source relative path, byte size, mtime)
  alongside the destination row, in the same transaction that already writes the
  media row and `import_batch_unix_ms`. The planner short-circuits: a member
  whose current facts match a provenance row is `skipPreexisting` with zero I/O.
  Survives relaunch and OneDrive eviction. These are filesystem facts, not
  content fingerprints, but the ADR-0008 boundary gets an explicit paragraph.
  This is the Photo Mechanic ledger with Otos's path-is-identity discipline; its
  accepted limitation (source facts change → provenance no longer matches) simply
  falls back to the existing equality path.
- **(B) Ephemeral memo seeding (seed `ContentEqualityChecker` at settle)** —
  rejected as the primary fix: process-lifetime only, so the first replan after
  relaunch re-reads every file and re-blocks on evicted bytes. Fails the
  invariant durably.
- **(C) Metadata-heuristic equality (Lightroom model: name + capture time +
  size)** — rejected as primary: probabilistic, known false negatives (renames,
  timezones), and unnecessary when we possess exact provenance for files we
  copied ourselves. May be revisited someday for cross-tool duplicate detection,
  which is a different feature.
- **(D) Persisted content hashes (digiKam/rsync -c model)** — rejected:
  ADR-0008 forbids durable content fingerprints, and full-content hashing forces
  the materialization problem we are eliminating.
- **(E) Replan suppression while executing — chosen, complementary.** The
  coordinator does not rebuild a source's plan while that source is `.executing`;
  dirty bits accumulate and one rebuild runs at completion. With (A), that single
  rebuild resolves from SQLite alone. Occupancy-revision causality tagging was
  considered and rejected as extra machinery the gate makes unnecessary.

## Field evidence addendum (same evening): event latency, admission storm, eject

- A Finder move of media between two configured libraries surfaced in the app
  only minutes later, one file at a time. FSEvents delivery and classification
  were prompt (classify lines ~1 s after events), but reconcile execution
  crawled: `op=catalog.reconcile … totalMs=48240` for 3 files, 20.8 s for 175,
  12.2 s and 11.7 s for others. The store actor was saturated, so per-file
  upserts landed minutes after their events — matching the observed dribble.
- Dominant saturator: `EnrichmentCoordinatorWorkSelection.dequeueDownloadWork`
  logged **381,881 `downloadReject reason=rootEagerFairness` lines in 12.5
  minutes** (~500/s). The dequeue loop, on hitting a fairness/capacity
  rejection, moves to the next candidate and logs again — with thousands of
  eager dataless items pending, one dequeue call at capacity iterates (and logs)
  the entire pending queue, O(pending) per call, on every completion wakeup.
  Fix: break out on capacity-class rejections that apply to every remaining
  eager candidate, and log one summarized rejection per dequeue pass.
- Sidebar Eject produced zero log lines in any session while the volume was
  already unmounted at the OS level (the store had dropped its events with
  `reason=unavailable`, yet the source row and eject affordance remained). The
  eject intent path (`ejectRemovableSource` → serial mutation queue →
  quiesce/drain/unmount) has silent-return guards and no entry-point logging,
  so a dead click is unattributable. Fix: log every user intent at its owner
  entry point, make the eject guard failure visible, and reconcile sidebar
  presentation with OS mount state.

## Conclusions carried into the next increment

1. Single-execution guard per source in `MediaOperationCoordinator` (fixes the
   double-batch, flicker, foreign-occupant races).
2. Settle-time provenance + planner short-circuit (A), with the idempotence
   invariant added to `docs/requirements.md` and an adversarial test that a
   fully-imported source replans to all-preexisting with zero comparison probes.
3. Replan gating during execution (E).
4. Per-file and per-batch copy spans (bytes, ms, MB/s) in the executor.
5. Bounded worker pool for copy entries — owner directive: 8 workers — with the
   new spans still measuring 1/2/4/8 so the choice is documented by evidence;
   companion bundles stay within one worker.
6. Enrichment admission dequeue stops scanning on capacity-class rejections and
   logs one summarized reject per pass (kills the ~500 lines/s storm and the
   O(pending) rescan per completion).
7. User intents log at their owner entry point (starting with eject), the eject
   silent guard becomes a visible failure, and sidebar removable-source rows
   reconcile against actual OS mount state.
