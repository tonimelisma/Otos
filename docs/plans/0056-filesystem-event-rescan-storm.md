# Plan 0056 — Filesystem reconciliation and resource-aware cloud enrichment

Status: active implementation plan. Diagnosed 2026-07-11 from live-log evidence on
a running build while investigating the import-planning hang fixed in PR #111
(`fix: settle import planning against enriching cloud destinations`, commit
`b662d4f`). Delete this file when the work has landed on `main`.

This is a broad architecture correction, not a timing patch for one observed storm.
It replaces root-only invalidation with the smallest safely known reconciliation
scope, explicitly settles filesystem effects caused by known cloud materialization,
adds a long-running-session integrity sweep, and makes enrichment admission account
for media size. All implementation references are approximate against `main` at
`b662d4f`; locate sites by owner/function before editing.

---

## 1. Verified direction and requirements

The user confirmed the following direction on 2026-07-11:

1. Fix the filesystem-event architecture broadly now rather than preserve known
   coarse seams for later.
2. A filesystem change should reconcile the smallest scope that is safely known:
   one file, one subtree, or the selected root.
3. Events received while a scan owns a root must retain their useful path/scope
   information instead of automatically scheduling another full-root scan.
4. Cloud hydration is performed by the provider process (for the observed root,
   OneDrive), so FSEvents `IgnoreSelf` cannot identify those events as Otos-owned.
5. Otos may suppress the narrow, expected event shapes for the handful of paths it
   has explicitly asked the provider to materialize. It must settle each successful
   materialization with one targeted filesystem-fact reconcile.
6. Otos needs a periodic integrity scan for roots in long-running app sessions;
   launch scans remain the normal repair after the app was closed.
7. Default materialization request concurrency becomes 16 and enrichment worker
   concurrency becomes 8.
8. Count-only concurrency is insufficient. Admission must account for known logical
   size and prevent several multi-gigabyte videos from inundating either pool.
9. Viewport/user-visible work remains favored and must not be starved by eager
   background work.

The exact integrity interval and initial byte/large-video limits are policy values
to choose from measurement in this increment, then record in requirements/ADR. Do
not scatter thresholds across the coordinator.

## 2. Observed defect

A OneDrive-backed library (`~/Library/CloudStorage/OneDrive-Personal/Pictures/
Camera Roll`, observed 23,036 files) being background-materialized by enrichment
entered an endless loop of full-tree rescans. Live logs repeated every roughly
2–4 seconds for minutes:

```text
op=catalog.scan phase=finish rootPath=…/Camera Roll observed=23036 deleted=0
op=catalog.filesystemEvent phase=schedule mode=deferred rootPath=… eventCount=1..6
op=catalog.enrichment.batch phase=finish …
```

Each scan found no catalog change. Events that reached the debounce path during an
active scan were classified as `.deferUntilScanCompletes` before their flags or
paths were considered. Store discarded the batch, set `rescanAfterCurrentScan`,
and ran another O(root-size) scan. Provider materialization continued producing
events during every scan, sustaining the loop.

Impact:

- repeated enumeration and SQLite comparisons for no namespace change;
- database/WAL contention with enrichment writes;
- CPU, filesystem, battery, thermal, and diagnostic noise;
- a root-only reconciliation architecture that wastes precise FSEvent paths;
- count-only cloud scheduling that treats a tiny image and multi-gigabyte video as
  equivalent work.

The import-plan livelock formerly amplified by `planRevision` churn was separately
fixed in PR #111. This increment must remove the underlying rescan churn rather
than rely on that consumer-side tolerance.

## 3. Facts independently verified

### 3.1 Current code

- `CatalogFilesystemWatcher` requests file-level events and currently passes both
  `kFSEventStreamCreateFlagIgnoreSelf` and `MarkSelf`.
- `IgnoreSelf` covers the process that changed the hierarchy. It cannot suppress
  filesystem changes performed by the external cloud provider process.
- `FilesystemReconciler.decide` checks `hasActiveScanForRoot` before classifying
  event flags, so all events whose debounce fires during a scan lose their
  available granularity.
- The targeted file path already uses the shared `CatalogScannedFileReader` and
  Store persistence edge.
- Unsafe/directory/unknown events currently fall back to `enqueueScans([root])`.
- There is one automatic scan for each database-restored root at launch and scans
  caused by add/event flows. There is no periodic integrity scan.
- `EnrichmentCoordinator` defaults to four materialization and four enrichment
  workers. `sourceSize` and media kind already exist on scheduling work.
- Materialization state is transient and is not a stored catalog fact. The catalog
  stores logical filesystem facts that are available while a File Provider item is
  dataless: path/name, content type, logical size, creation date, and content mtime.

### 3.2 Apple platform contract

Primary sources:

- [File System Events Programming Guide — Using the FSEvents Framework](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
- [`kFSEventStreamCreateFlagIgnoreSelf`](https://developer.apple.com/documentation/coreservices/file_system_events/1455376-fseventstreamcreateflags/kfseventstreamcreateflagignoreself?language=objc)
- [`FileManager.startDownloadingUbiquitousItem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem%28at%3A%29)
- [Synchronizing the File Provider Extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension)
- [`URLResourceKey`](https://developer.apple.com/documentation/foundation/urlresourcekey)

The relevant platform conclusions are:

- FSEvents are invalidation hints, not a durable item-change journal.
- File-level mode can provide individual paths, but events may be coalesced.
- `MustScanSubDirs` requires recursively reconciling from the reported path.
- dropped events mean coverage is unknown and require conservative reconciliation
  of the monitored directories.
- observation should begin before snapshot enumeration; scopes dirtied while the
  snapshot is built must be reread afterward.
- File Provider represents dataless items with metadata already present and adds
  content when materialized. Hydration is not itself a logical file edit.
- calling `startDownloadingUbiquitousItem` requests download/synchronization; the
  provider may perform resulting filesystem work in another process.

### 3.3 Provider-specific evidence captured and still required

Apple documentation cannot prove what the installed OneDrive provider on the
current macOS build emits. One successful Terminal Swift probe on 2026-07-11
materialized a 9,691,136-byte HEIF from the Desktop alias into its resolved
OneDrive File Provider location:

```text
request path=~/Desktop/OneDrive/Pictures/Camera Roll/2026/03/20260315_094624.heif
before flags=0x40000060 dataless=true size=9691136 mtime=1773593184.0
event t=5.429 flags=0x1d400
      itemInodeMetaMod,itemModified,itemChangeOwner,itemXattrMod,itemIsFile
event path=~/Library/CloudStorage/OneDrive-Personal/Pictures/Camera Roll/2026/03/20260315_094624.heif
after t=10.425 flags=0x40 dataless=false size=9691136 mtime=1773593184.0
```

For this sample, hydration preserved the logical size and content-modification
time that Otos stores. It changed dataless/provider inode state and emitted one
regular-file metadata/content-shaped event, with no create, remove, rename,
directory, dropped, or `MustScanSubDirs` flag. The event used the normalized
CloudStorage path rather than the user-selected Desktop alias. Suppression identity
must therefore use the same normalized path spelling as catalog/root identity;
raw request-path equality is incorrect.

This validates known-materialization suppression plus final targeted settlement
for the observed shape, but one file is not enough to freeze the provider allowlist
or delivery grace. Before production logic is finalized, capture additional
representative materializations, including:

- small and large images;
- small and large videos;
- decoded FSEvent flags, event path, event time, and materialization generation;
- request/start/materialized times;
- pre/post catalog facts (logical size, creation second, content-mtime second,
  content type, regular-file eligibility);
- whether events name the file, a parent directory, or both;
- delivery lag after the `SF_DATALESS` transition;
- occurrence of `MustScanSubDirs`, dropped, rename, remove, or unknown shapes.

An earlier Codex-hosted attempt was rejected by macOS privacy/TCC with
`NSCocoaErrorDomain Code=257`; running the same probe from the user's authorized
Terminal succeeded. Further sampling may use that probe or bounded temporary
in-app instrumentation. Remove temporary high-volume instrumentation afterward and
preserve the complete evidence and conclusion in
`docs/research/2026-07-11-onedrive-materialization-fsevents.md`.

The capture is a design gate for the suppression allowlist and grace interval. It
is not a gate for implementing typed reconciliation scopes.

## 4. Target architecture

### 4.1 One typed dirty-scope accumulator per root

Represent pending reconciliation as the narrowest safely known scope:

```swift
nonisolated enum FilesystemDirtyScope: Equatable {
    case file(MediaRelativePath)
    case subtree(MediaRelativePath) // directory relative to selected root
    case root
}
```

Store owns one process-local accumulator per `LibraryRootPath`. The concrete data
structure may use file/subtree sets plus a root-dirty bit; do not build a general
job framework.

Coalescing rules:

- duplicate file paths collapse;
- repeated flags for a path merge conservatively;
- a subtree removes/subsumes descendant file and subtree entries;
- an existing ancestor subtree absorbs a new descendant scope;
- `.root` clears/subsumes every narrower scope;
- dropped, unknown-coverage, root-change, or unmappable events escalate to `.root`;
- a reported descendant directory/`MustScanSubDirs` becomes `.subtree(path)` when
  its boundary is trustworthy;
- a supported regular-file event becomes `.file(path)`.

There is no fixed `512`-path or similar threshold. Such a number is not justified
by root size or measured cost and can recreate the full-scan storm. Instrument
scope counts and durations first. Add a cost crossover only if measurement proves
one, owned by one policy type and based on actual root/work facts.

### 4.2 One reconciliation state machine

The Store remains the single owner. For each root:

1. Live events debounce and classify into typed dirty scopes.
2. If no reconciliation lease owns the root, Store takes the accumulator and runs
   the minimal required reconciliation.
3. If a full-root scan or subtree reconciliation is active, new events accumulate
   in the next dirty generation; no useful event information is discarded.
4. On success, cancellation, or failure, release the lease and atomically take the
   next dirty generation.
5. Reconcile again only when dirt exists.

Do not maintain both a raw `deferredFilesystemEvents` array and
`rescanAfterCurrentScan` for the common event path. The typed accumulator is the
deferred state. `rescanAfterCurrentScan` may remain only for another independently
verified owner such as reorganization until that flow is migrated deliberately.

Root removal, path remap, shutdown, and unsupported future schema handling must
cancel tasks and clear accumulator/suppression state for the old root. Stale
completion must revalidate the typed root row/lease generation after every await.

### 4.3 File reconciliation

Reuse the existing targeted path:

- supported upsert-shaped event: reread the one path through
  `CatalogScannedFileReader`; upsert if eligible, otherwise remove an existing row;
- remove-shaped event: delete only if the exact path is absent;
- rename remains independent remove/add facts; do not invent inode identity;
- purge overlay only on the same proof of deletion used today.

Coalesce repeated events so one path is settled once per dirty generation. The
settlement reads current filesystem state; it does not replay historical actions.

### 4.4 Subtree reconciliation

Add a scanner entry point that enumerates one descendant directory without reading
media bytes. It uses the same resource keys, eligibility policy, companion policy,
package handling, instrumentation, persistence edge, cadence, cancellation, and
ownership validation as a root scan.

On a successfully completed reachable subtree scan:

- upsert observed eligible media and companions under that boundary;
- fetch only catalog rows whose relative paths lie inside the subtree boundary;
- delete only rows inside that boundary that were not observed;
- purge overlay for those proven deletions;
- never affect siblings or ancestors outside the subtree;
- bump occupancy only for a real namespace/fact change.

On cancellation, failure, disappearance of the root, or incomplete enumeration,
preserve existing rows. Path-prefix SQL and Swift checks must respect component
boundaries (`a/b` must not match `a/b2`). Root itself is represented by `.root`,
not an empty/stringly subtree.

Multiple disjoint subtrees may be reconciled serially under one Store-owned lease.
Start simple; do not add parallel scanners until profiling proves enumeration is
the bottleneck and the ownership model remains clear.

### 4.5 Full-root reconciliation

Use the existing completed-snapshot proof for:

- kernel/user dropped or otherwise unknown event coverage;
- root-level `MustScanSubDirs`;
- root move/change or ambiguous mapping;
- unsupported/unknown event shapes whose safe boundary cannot be derived;
- periodic integrity sweeps.

Full scans remain idempotent reconciliation operations, not durable scan entities.

## 5. Known cloud-materialization settlement

### 5.1 Why suppression is valid here

Otos explicitly selects a dataless path and asks the external provider to add its
content locally. At any instant the candidate set is bounded by materialization
admission. The file's logical metadata already exists while dataless; ordinary
hydration changes residency/provider bookkeeping rather than catalog membership.

It is therefore valid to suppress proven hydration-shaped events for only those
known paths, provided Otos:

- never suppresses an unsafe membership/coverage shape;
- performs one final targeted fact reconcile;
- bounds and expires state correctly;
- makes the behavior observable;
- retains launch and periodic repair.

This accepts bounded eventual consistency if a logically independent modification
occurs in the narrow overlap after final settlement but before grace expiry. That
tradeoff is explicit and repaired by the next qualifying event, launch scan, or
periodic integrity scan.

### 5.2 Typed generation-safe state

Store owns active/recent materialization suppression keyed by normalized asset
identity, not arbitrary unnormalized strings. Each record carries:

- `MediaAssetID`/root-relative identity;
- operation generation or existing claim identity;
- start instant;
- phase (`active`, `settling`, `grace`);
- expiry instant;
- provider flag shapes proven suppressible by the diagnostic capture.

An older completion must not shorten/remove a newer operation's state. Begin/end
must be paired with `defer`-equivalent cleanup across success, timeout,
cancellation, and request failure.

Expiry must actually remove entries. Prune the whole small map on begin/end and on
incoming events, or own one scheduled nearest-expiry task. Do not claim a map is
bounded when expired unique paths remain until the same path emits another event.

### 5.3 Event policy

An event is suppressible only when all are true:

- its normalized identity matches an active/recent known materialization;
- its flags are in the provider-specific allowlist proven by the in-app capture;
- it is a regular-file non-membership change;
- it has no dropped/unknown/root/subtree coverage implication.

Never suppress create, remove, rename, directory, symlink, root-change,
`MustScanSubDirs`, kernel/user dropped, or unknown shapes. Those enter the normal
dirty-scope accumulator immediately.

Record bounded aggregate diagnostics by root/generation/decoded action, not one
durable JSON object per event.

### 5.4 Final settlement

After the provider reports successful materialization (`SF_DATALESS` cleared):

1. transition the operation to settling;
2. enqueue/perform one `.file(path)` reconcile through the shared targeted edge;
3. transition to a short grace interval covering already-queued provider events;
4. expire the suppression record.

If materialization fails, times out, is cancelled, or the path disappears, end the
active state without pretending success. Any already received unsafe event still
reconciles normally.

The grace duration comes from measured event-delivery lag plus a small explicit
margin; do not assume three seconds without the capture.

## 6. Periodic integrity reconciliation

Add a Store-owned long-running-session integrity scheduler. It is defense in depth
for advisory FSEvents/provider anomalies and bounds the accepted suppression
residual. It must not become another rescan storm.

Requirements:

- track each root's last successful completed full-root reconciliation;
- launch/add scans count as successful integrity scans;
- when the configured interval elapses, mark that root `.root` dirty once;
- do not enqueue duplicates when the root is active, pending, already dirty, under
  incompatible reorganization ownership, or unavailable;
- availability return should wake overdue work;
- use one owner task with cancellation on shutdown;
- persist only the smallest fact needed if the interval must survive relaunch;
  otherwise launch scanning already resets the clock;
- no scan-history table or durable scan entity;
- failures preserve catalog/overlay and retry on a bounded later opportunity, not
  an immediate loop.

Choose the initial interval during implementation. A 24-hour successful-scan age is
the starting candidate for measurement/review, not yet an authoritative constant.

## 7. Resource-aware materialization and enrichment

### 7.1 Defaults

- materialization request concurrency: **16**;
- enrichment worker concurrency: **8**.

These are maximum counts, not permission to admit sixteen huge videos or eight
simultaneous heavyweight video decodes.

### 7.2 One concrete scheduling policy owner

Add a small value/pure policy type used by `EnrichmentCoordinator`, for example
`EnrichmentAdmissionPolicy`. It receives current in-flight work and one candidate
and answers whether it may dispatch. Do not add a generalized scheduler, protocol,
or worker framework.

Policy facts already available or cheaply derivable:

- logical `sourceSize`;
- image versus video;
- viewport/fresh/eager/device-staging priority;
- current in-flight counts and estimated bytes;
- root identity;
- retry readiness.

Unknown size is conservative background work but must remain dispatchable; it must
not deadlock behind a byte budget it cannot satisfy.

### 7.3 Materialization admission

The policy must enforce all of:

- at most 16 outstanding materialization requests;
- reserve capacity for viewport/device work so eager background requests cannot
  occupy every slot;
- an aggregate estimated in-flight logical-byte budget;
- a separate cap for large/huge videos;
- an oversized item may run alone rather than become permanently inadmissible;
- bounded fairness across roots so one large root cannot monopolize all eager work;
- eager ordering continues to prefer images before videos, then current capture
  date/path policy unless measurement supports a simpler size-first refinement.

Use size classes only if they make policy clearer. Initial candidate classes for
measurement are small (<32 MiB), medium (32–256 MiB), large (256 MiB–1 GiB), and
huge (>1 GiB), but these are not authoritative until real library distribution and
traces are captured. Prefer one aggregate byte budget plus a large-video cap over a
forest of knobs.

### 7.4 Enrichment admission

The policy must enforce:

- at most 8 enrichment workers;
- a smaller simultaneous video-enrichment cap;
- size-aware admission for large/huge media to bound decoder/memory pressure;
- viewport work priority with at most one explicit budget overcommit for an item
  that otherwise could never run;
- no blocking byte read before the existing immediate `FileMaterialization` check;
- one existing buffered/serialized Store apply path.

Do not assume download and enrichment cost scale identically with logical size.
Measure them separately.

### 7.5 Measurements required

Before choosing final byte/large-video values, collect from the real library without
reading file bytes:

- image/video counts and logical-size percentiles (p50/p90/p95/p99/max);
- estimated aggregate bytes for 4, 8, and 16 size-ordered candidates;
- materialization latency and outcome by media kind/size class;
- enrichment wall time and peak-memory/pressure observations by kind/size class;
- provider retry/timeouts with 4 versus 16 request concurrency;
- viewport latency while eager work is saturated.

The scanner/catalog facts are sufficient for size distribution; this measurement
must not materialize files merely to count them.

## 8. Implementation sequence

Keep one plan/DoD but land in reviewable commits in this dependency order:

1. **Diagnostic evidence**
   - add bounded decoded event/materialization correlation;
   - run OneDrive capture inside Otos;
   - record research conclusion and remove temporary high-volume logging.
2. **Typed dirty scopes and file coalescing**
   - replace active-scan root escalation for safe file events;
   - add lifecycle cleanup and adversarial race tests.
3. **Subtree reconciliation**
   - scanner/store boundary, component-safe queries, deletion proof, tests.
4. **Full-root fallback and periodic integrity owner**
   - unknown/dropped/root coverage and long-session repair without duplicate work.
5. **Known-materialization settlement**
   - generation-safe suppression allowlist, final targeted reconcile, real expiry.
6. **Resource-aware scheduling**
   - library size measurement;
   - 16/8 maxima plus byte/video/root-fairness policy;
   - before/after latency/resource evidence.
7. **Current-truth documentation and full verification.**

If a commit temporarily changes behavior, keep it internally correct and tested;
do not land an intermediate state that drops received events.

## 9. Correctness arguments to prove in tests/review

### Event/scan races

- A file changed before its path is enumerated is represented by scan or redundant
  settlement.
- A file changed after enumeration is corrected by the next dirty generation.
- An event whose debounce fires after scan completion is processed normally once.
- Dirt arriving while subtree/root reconciliation awaits DB work is not lost.
- cancellation/failure preserves old rows and drains or conservatively retains the
  next dirty generation.
- stale completion after remove/remap/re-add cannot mutate the replacement root.

### Scope safety

- file scope cannot delete a different path;
- subtree scope cannot mutate a sibling prefix (`a/b` versus `a/b2`);
- incomplete subtree enumeration deletes nothing;
- dropped/unknown coverage reaches root reconciliation;
- ancestor scope coalescing never narrows required coverage.

### Materialization suppression

- only a proven allowlisted event for the exact generation/path is suppressed;
- remove/rename/create/coarse/unknown events bypass suppression;
- success performs exactly one final targeted settlement;
- failure/cancellation expires state and does not fabricate catalog facts;
- old completion cannot clear a newer operation;
- thousands of completed unique paths leave no expired map growth;
- launch/periodic scan repairs a deliberately simulated overlapping missed fact.

### Scheduling

- no more than 16 materializations and 8 enrichments dispatch;
- byte/video limits prevent a multi-large-video flood;
- one oversized item eventually runs;
- unknown-size work eventually runs;
- viewport/device work is not starved by eager work;
- roots receive bounded fair opportunity;
- cancellation releases all count/byte/class admission facts.

Tests assert observable owner behavior and typed pure-policy results. They must not
read Swift source text or sleep when an owned gate/recorder can prove ordering.

## 10. Instrumentation and acceptance evidence

Use the repo facade and machine-greppable bounded summaries:

- `op=catalog.filesystemEvent phase=classify` with decoded scope/action counts;
- `op=catalog.reconcile phase=finish mode=file|subtree|root`, scope path, observed,
  changed/deleted counts, wait/exec/total milliseconds;
- `op=catalog.materializationEvent phase=suppress|settle` with generation and
  aggregate flag/action counts;
- `op=catalog.integrityScan phase=schedule|finish|error` with successful-scan age;
- `op=catalog.enrichment.admission` aggregate in-flight count/estimated bytes,
  image/video/large counts, priority class, and rejection reason;
- materialization/enrichment latency summaries by size/media class.

Acceptance on the original 23k OneDrive root:

- enrichment no longer causes a repeating full-root scan every 2–4 seconds;
- safe events during a scan settle as file scopes;
- descendant coarse events settle as subtree scopes when their boundary is known;
- only unknown/root-wide coverage produces root scans;
- known provider hydration noise is suppressed and each successful materialization
  gets one final targeted settlement;
- no `planRevision`/occupancy churn occurs for identical fact settlement;
- 16/8 scheduling respects measured byte/video limits and keeps viewport work
  responsive;
- periodic integrity scheduling cannot duplicate or self-perpetuate scans.

Capture before/after logs and Instruments evidence appropriate to enumeration,
database, CPU, memory, and responsiveness. Report worst spans and relevant size
distribution, not only averages.

## 11. Documentation updates

This increment changes architecture and implemented behavior, so update current
truth in the same PR:

- `docs/requirements.md`
  - ARC-041: file/subtree/root reconciliation, dirty generations, periodic integrity;
  - ARC-046: events during active scans retain minimal scope without planning churn;
  - ARC-034/036 or a new MECE row: known-materialization suppression plus final
    targeted settlement;
  - enrichment requirement: 16/8 maxima and size/video-aware admission.
- `docs/adr/0002-catalog-persistence-and-filesystem-scan.md`
  - replace root-only event fallback/current active-scan behavior with typed scopes,
    subtree proof, and periodic integrity ownership.
- `docs/adr/0009-enrichment-storage-and-staleness.md`
  - materialization settlement and resource-aware admission policy.
- `docs/architecture.md`
  - current file/subtree/root dataflow, owner tasks, and scheduling policy.
- `docs/research/2026-07-11-onedrive-materialization-fsevents.md`
  - provider-specific capture, sources, measurements, and chosen thresholds.

Do not add a new ADR unless the existing ADR ownership boundaries truly cannot hold
these decisions; rewrite current truth rather than append increment history.

## 12. Definition of Done

Use the repository-standard final DoD only after merge and cleanup:

- dedicated worktree/branch and intentional reviewable commits;
- provider capture and size/resource research recorded;
- all agent-owned unit/integration/runtime adversarial checks run;
- `script/verify.sh` green under the configured Xcode 27 beta;
- before/after logs and profiling evidence attached with worst-span/resource summary;
- requirements, ADRs, architecture, and research updated as current truth;
- media-original review confirms only explicit test materialization occurred and no
  original contents were written;
- diagnostics reviewed for bounded payloads and no per-event durable spam;
- code smells reported, including owner duplication, arbitrary thresholds,
  MainActor gravity, unsafe concurrency escape, and diagnostic sprawl;
- last five PRs scanned and actionable unresolved comments claimed/addressed;
- remote CI green, or exact GitHub billing/quota waiver evidence pasted;
- PR reviewed and merged to `main`;
- branch/worktree/stashes belonging to the increment cleaned up;
- clean next-start branch checked out;
- this plan deleted;
- the same complete final DoD report posted on the PR and sent to the user.
