# Research: destination free space and import failure recovery (2026-09-09)

The owner clicked `Import 38 Items` on an attached SD card and nothing appeared to
happen. A second click made the import bar disappear. This pass establishes what
actually happened, then answers the design question the incident raised: **free space
on the destination volume changes continuously and cannot be observed — so when, and
on what authority, may the import bar say an import will not fit?**

The short answer is that the question is unanswerable as posed, and does not need to
be answered. Free space is not knowable in advance on this OS, is not reliable when
read, and the reason nobody builds a machine to track it is that a **resumable**
import makes being wrong cheap. The conclusions are listed at the end.

## Method

1. **The live session's unified log**, captured from the running instance while it was
   still alive: `script/logs.sh show --last 25m --pid 73196` (ADR 0015). Timings below
   are from that capture, not from the console paste, which interleaves emitters and
   cannot order same-millisecond events.
2. **Source reading** of `MediaImportExecutor`, `MediaOperationCoordinator`,
   `ImportBarPresentation` and `CatalogWindowViewModelMediaOperations`.
3. **Apple documentation** via `script/apple-docs.sh`, plus prior-art and OS-behavior
   sources listed at the end.

## Finding 1 — the failure was real, correct, and destroyed in 24 ms

The destination is a folder on the boot volume. At the time of the incident the APFS
container had **18,183,512,064 bytes free** (`diskutil info /`; `df -k /` agreed at
~17.8 GB). The plan's `copyBytes` was **26,558,298,038**. `MediaImportExecutor`
requires `copyBytes + 64 MB` before writing anything
(`Otos/Services/MediaImportExecutor.swift`, `freeSpaceRequired` /
`hasEnoughFreeSpace`), so the run was refused before a single byte moved —
`publishedCount: 0`, `completedBytes=0`. The verdict was correct.

What the log shows next is the defect:

```
22:23:59.377  publish executing
22:23:59.427  publish failed(outOfSpace)              batchID=…439390
22:23:59.427  publish ready  (replan, run 6F0C6E13)   ← same millisecond
22:23:59.434  apply  drawnKind=failed  "The disk is full"
22:23:59.458  apply  drawnKind=ready   "Import 38 items"
```

The Failed bar was on screen for **24 ms**, roughly 1.5 frames. On the second click it
was never drawn at all: `failed` and `ready` published in the same millisecond and the
newest-value coalescing between the coordinator and the MainActor dropped `failed`
entirely — `apply` went `preparing` → `working` → `ready`.

This directly violates `docs/design/import-bar.md` state G, which says the Failed bar
**never auto-dismisses**.

## Finding 2 — completion survives a rebuild; failure does not

The mechanism is an asymmetry in `MediaOperationCoordinator`, not a race.

After **every** terminal outcome the coordinator unconditionally marks the session
dirty and schedules a fresh plan build:

```swift
// After terminal settlement, claims die with phase. Dirty to rebuild (new occupancy etc.)
current.isDirty = true
scheduleBuildIfNeeded(source)
```

That build ends at `updated.phase = .ready(readyCtx)` with no check of the phase it is
replacing. A completed run survives this because completion is **carried as session
state** — `session.lastCompletion`, documented in the type as "cleared by nothing" and
re-attached to each rebuilt presentation. A failed run has no equivalent carry: the
failure exists only as `session.phase`, which is exactly what the rebuild overwrites.

So the rule is accidental rather than designed: *a terminal state survives a rebuild
if and only if someone remembered to store it beside the phase.*

The replan cadence makes this fire every time. In this session the plan rebuilt
through generations 8, 9 and 10 within eight seconds, and `namingRevision` on the
destination root reached 24 within three minutes — because background enrichment of
the destination library bumps naming revisions continuously. There is always a fresh
`ready` immediately behind any terminal state.

## Finding 3 — macOS offers no free-space notification at an app-defined threshold

This is the finding that decides the design.

There is no API to observe "free space crossed the number I care about":

- `com.apple.diskspaced` fires at **system** thresholds — its documented defaults are
  `minFreeSpace` 20 GB and `minPurgeableSpace` 20 GB, with a user-visible warning near
  ~1 GB. It knows nothing about a pending 26.6 GB copy.
- `NSBundleResourceRequestLowDiskSpace` is On-Demand-Resources-specific.
- FSEvents reports directory mutations and carries no volume capacity.
- Apple's own [Checking Volume Storage Capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity)
  tells you to query before storing a large amount of data, and offers **no**
  staleness guidance and **no** observation mechanism at all.

Sampling is therefore the only mechanism that exists. Any design that *needs* to know
when free space changed is unbuildable on this platform, which rules out every variant
of "show a blocker, then clear it when space appears."

## Finding 4 — the capacity figure is not authoritative even at the instant it is read

`volumeAvailableCapacityForImportantUsage` does not come from APFS. It is CacheDelete's
latest calculation, maintained by the `deleted` daemon and recalculated periodically.
Eclectic Light documents a volume reporting **100 GB available for important usage
while a copy was refused for lack of space**.

Worse for a precheck: when space is tight, `deleted` runs up to three purging rounds of
increasing urgency and **blocks writes with `ENOSPC` while it does so**. A copy can
therefore fail with out-of-space and succeed on immediate retry. And purgeable space is
counted in the figure while being, in that article's words, only a potential — it is not
free until `deleted` actually realises it.

The figure can therefore be wrong in **both** directions. It is usable as a cheap way to
skip an obviously doomed run; it is not usable as truth, and must never gate a control.

## Finding 5 — prior art: nobody predicts, everybody recovers

Lightroom Classic is the closest analogue — same job, same problem — and uses three
points with no polling anywhere:

1. An advisory `Not enough Space` note against the destination in the import panel,
   computed when the panel is drawn and tolerated as stale.
2. An explicit **"Checking free space on disk"** phase when the import starts — visible
   enough in its pipeline that users file bugs about it hanging.
3. **"Import stopped due to low disk space"** as a *partial* mid-run outcome.

Point 3 is the load-bearing one. The reason a forecast can be this casual is that
failing is cheap: the work already done is kept, and the operation is repeated against
what remains.

## Finding 6 — Otos has no vocabulary for the disk filling mid-copy

The precheck is the only place Otos names out-of-space. The per-entry failure
vocabulary is:

```swift
private enum EntryFailure: Equatable, Sendable {
    case sourceNotReady
    case sourceChanged(ChangedFact)
    case sourceAbsent
    case other
}
```

`ENOSPC` from a transfer lands in `.other`, which that type's own comment describes as
"inherently per-file" and which never promotes to a run-level classification. So a
26.6 GB copy that exhausts the volume at item 20 of 38 reports a vague per-file failure
inside an otherwise clean-shaped `.completed`, not "the disk filled up".

This is the case no precheck can ever cover, because it is precisely the case where the
free space changed after the check. It is also the likely case in practice here: the
`EnrichmentCoordinator` was concurrently materializing OneDrive placeholders onto the
same volume throughout the incident — 232 MB, 223 MB and a 514 MB `.MOV` among them
(ADR 0008 accepts that cost deliberately, and nothing arbitrates it against a
concurrent import competing for the same finite space).

The presentation layer is already ready for the fix: `MediaOperationSourcePresentation`
carries `failed(reason:publishedCount:)`, and `ImportBarPresentation` already renders
`"\(publishedCount) items were copied before it stopped"` when the count is nonzero.
Only the executor cannot produce it.

## Conclusions

1. **Free space is not plan state.** The plan answers "what would we copy, and under
   what names" — a property of one destination folder, revised on namespace and naming
   changes. Free space is a property of the whole volume, changed by processes Otos does
   not control. They have unrelated change rates and no common observer; a free-space
   sample riding the plan-rebuild cadence is freshest when it does not matter and
   stalest when it does.

2. **Free space must never gate a control.** Findings 3 and 4 make a blocker
   unclearable and untrustworthy. `Import` stays enabled; if it will not fit, the
   attempt says so.

3. **The only authority is the write.** The precheck stays as a courtesy that avoids
   opening a journal for a doomed run, but `ENOSPC` at the transfer is the truth, and
   `Try Again` is the correct action because a purge-blocked write may simply succeed
   next time.

4. **Partial completion is what makes the absence of a forecast acceptable.** Imports
   are per-item, journaled and staged, and the plan is recomputed from the filesystem on
   every build — it already produces `skipCount` for items present at the destination.
   Stopping at item 20 of 38 and reporting it honestly means the next click copies the
   remaining 19. The cost of having no forecast is bounded and recoverable, which is why
   no forecast is needed.

5. **Terminal states must outrank speculative rebuilds** on the presentation channel,
   by design rather than by whether someone stored a companion fact next to the phase.

## Open observations at closure (2026-09-13)

Plan 0102 shipped its five increments and was deleted. These were found while
diagnosing and deliberately left outside it; none is a requirement.

1. **GRDB and MediaMetadata were linked twice — observed and fixed.** The app
   target still carried both package products from before ADR 0023 moved every
   source into `OtosKit`, so each static product was linked into
   `OtosKit.framework` and again into `Otos.debug.dylib`, and dyld warned of
   "spurious casting failures and mysterious crashes" at every launch. The app
   target now links nothing but OtosKit, which is what `docs/architecture.md`
   already said; ADR 0023 records the trap.
2. **`op=mainThreadStall stallMs=126`** attributed to
   `MediaGridViewController.reconfigureVisibleItems` while reporting
   `lastLongOperationMs=0` — the blamed op did nothing.
3. **Enrichment and import compete for the same finite disk** with no arbitration
   (ADR 0008 accepts the materialization cost but does not consider a concurrent
   import). The floor bounds the damage from Otos's own side only.
4. **Startup publishes `planningFailed(unexpected("noDestinationLibrary"))`** for
   an ordinary not-yet-resolved condition. Never drawn — the bar reads
   `destinationPath == nil` as state B before it looks at the state — and kept
   because the honest alternative, `inventory`, would put a "preparing" spinner
   on the sidebar row for a card that has nothing to prepare against. Planning
   failures that *are* drawn now say `Couldn't prepare the import` (state G,
   planning variant) instead of borrowing the run failure's `Couldn't finish`.
5. **Rebuild storm**: plan generations 27→34 in 50 s on 2026-09-13 because OneDrive
   was syncing new files into the destination (`destinationOccupants` 8270→8277),
   200–470 ms of planning each. Harmless to terminal states now; still O(n) per
   arriving file.
6. **`op=ui.sidebarSelectionToPaint` leaves its span open** when a selection is
   abandoned, so an abandoned navigation is indistinguishable from a hung one.
7. **Stale Ready between two Done frames — observed live and fixed.** On
   2026-09-13 at 17:57:37 a completed 368-item run drew `Ready · Import 368 Items`
   for 360 ms between two Done frames, from the held pre-run plan. A completed run
   now drops that plan like a stop does, and the settlement presents until the
   re-plan lands (`docs/research/2026-09-13-unreadable-destination-folder-frozen-into-a-plan.md`).
8. **Camera (MTP) writes that refuse for space** arrive as a string from the camera
   layer and classify as per-file `.other`, not `.outOfSpace`; the per-entry floor
   admission covers that path, so only a lying capacity figure reaches this gap.
9. **Superseded batch rows.** With a real partial batch selected, starting a second
   run mints a new batch and the first batch's row has no live presentation, so its
   bar disappears until the selection resolves elsewhere. `import-bar.md` describes
   two rows onto *the same* operation and does not say whether a superseded batch
   row keeps its own finished operation's bar — an owner decision.
10. **Auto-eject after a completed import failed with `fBsyErr: File is busy`**
    (2026-09-13, 17:57:37) — fixed: the auto path had skipped the reader drain and
    dropped the outcome. It now fires the same intent as the sidebar's eject
    control, retries a busy volume on a bounded schedule, and shows the alert if
    it still cannot.
11. **Advisory line in Ready — decided and built** (owner, 2026-09-13): `Not
    everything will fit yet · 37.7 GB available`, sampled on each Ready publish,
    gating nothing (ADR 0027).

## Sources

- Apple, [Checking Volume Storage Capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity)
- Apple, [volumeAvailableCapacityForImportantUsage](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage)
- Apple, [NSBundleResourceRequestLowDiskSpace](https://developer.apple.com/documentation/foundation/nsnotification/name/1614835-nsbundleresourcerequestlowdisksp)
- Howard Oakley, [Where does macOS get its volume free space figures from?](https://eclecticlight.co/2023/04/27/where-does-macos-get-its-volume-free-space-figures-from/)
- Howard Oakley, [What happens when a Mac's boot volumes run out of space?](https://eclecticlight.co/2026/09/07/what-happens-when-a-macs-boot-volumes-run-out-of-space/)
- Howard Oakley, [Why can purging snapshots fail?](https://eclecticlight.co/2026/08/27/why-can-purging-snapshots-fail/)
- Lightroom Queen forums, [Import stopped due to low disk space](https://www.lightroomqueen.com/community/threads/import-stopped-due-to-low-disk-space.26391/)
- Lightroom Queen forums, [Disk space is low warning](https://www.lightroomqueen.com/community/threads/disk-space-is-low-warning.47819/post-1316962)
- Adobe community, [Import stuck on "Checking free space on disk"](https://community.adobe.com/bug-reports-679/p-import-stuck-on-checking-free-space-on-disk-662568/index2.html)

## Appendix — capturing this evidence again

The app must still be running; macOS unified-log retention is finite (ADR 0015).

```
pgrep -x Otos
script/logs.sh show --last 25m --pid <pid> > /tmp/otos.ndjson
jq -r 'select(.eventMessage != null)
       | select(.eventMessage|test("import\\.|sidebarSelectionToPaint"))
       | "\(.timestamp[11:23]) [\(.category)] \(.eventMessage)"' /tmp/otos.ndjson
```

The `phase=publish` / `phase=apply` pairing on `op=import.presentation` is what makes
the 24 ms window visible: `publish` is the coordinator's decision, `apply` is what the
MainActor actually drew, and a published state with no matching `apply` was coalesced
away before anyone could see it.
