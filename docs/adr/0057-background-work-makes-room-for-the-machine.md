# ADR 0057: Heavy background work starts only when the machine has room for it

- Status: Accepted
- Date: 2026-11-17

## Context

The owner's standing complaint is that leaving Otos open makes the machine un-quiet ("fills
the disk"). On his 16 GB Mac, a read-only ten-minute tour of the installed app (f398d5dc,
machine quiet at the start) was sampled every 30 s from outside: the kernel's pressure level
went from 1 (normal, 61 % available) at launch to 2 (warning, 29 %) within 30 s and stayed at
2 for the ten minutes, load 13–45. The app's own footprint peaked at 367 MB. The pressure is
what Otos's background work drives in other processes and in the file cache
(`docs/research/2026-11-17-background-load-attribution.md`):

| Owner | What it runs | Concurrency | Memory it causes elsewhere | CPU | What bounded it |
| --- | --- | --- | --- | --- | --- |
| Enrichment's downloads (hashing cloud originals) | the provider's download, then a whole read | up to 4 per root, 2 GB in flight, 2 large videos, a file over 1 GB alone | the file cache: 13.0 GB downloaded and read in 609 s (470 files), served by the provider's process | SHA-1 in Otos, the provider's process | per-root cap, byte budget, free-space floor |
| Descriptions | one request to the system language model's service | one at a time, continuous (143 in 609 s) | that service: about 411 MB at rest, 857–925 MB while describing | model service 10–59 % | none beyond one at a time |
| Text reading | one helper process (`Otos --read-text`) | one at a time, kept alive between pages | the helper: 35–132 MB, each cold start compiling the text model (3–116 s) | the helper | one helper |
| Renders, faces, embeddings | in Otos | the decode budget, enrichment's caps | in Otos's own footprint | 1.3 cores median in a new 2,000-photo library | decode budget, LoadAdmission |
| People, duplicates, search index builds | in Otos | one at a time | in Otos's footprint | in Otos | LoadAdmission |

No background owner asked whether the machine had room: only the window's targets were
judged, and they passed.

## MECE Decision Scope

This ADR owns whether heavy background work may start now, from which facts, and how owners
wait for it. It defers how many units of each kind run at once to each owner (ADR 0009
enrichment and materialization, ADR 0027 the free-space floor, ADR 0048 text reading, ADR 0053
descriptions, ADR 0055 heavy loads), owner state across suspensions to ADR 0032, and the
instruments to ADR 0015.

## Decision

1. **One owner, `BackgroundRoom`, holds the machine's conditions** (`MachineConditions`):
   the kernel's memory-pressure level, `ProcessInfo.thermalState`, Low Power Mode, and
   whether Otos is the active app (`NSApplication` becoming and resigning active: the
   person is in the app). `MachineConditionsMonitor`, owned by the app delegate, is the one
   listener to the platform's reports; each changes its one field in the step it arrives.
   **Memory pressure is read at the moment of each decision, not heard** (below, "The two
   memory-pressure sources"): every `hold(for:)` and `untilOpen(for:)` reads
   `kern.memorystatus_vm_pressure_level` first (`MemoryPressureReader`), so a unit never
   starts on a level older than its own question; `LoadAdmission` asks at each request and
   release. The memory-pressure source (`DispatchSource.makeMemoryPressureSource`) is only a
   doorbell: on a report the room reads the kernel, and the kernel's level wins; when the
   kernel cannot be read, the report is the level. While the level the room holds is above
   normal, and only then, it reads the level again every 5 s (`time: poll`), since nothing
   reports a return to normal to a process the kernel did not tell of the warning; the
   interval is the kernel's own smoothing of a falling level (5 s), so a closer look finds no
   newer fact. No timer stands in for any other fact (ADR 0033).
2. **The room decides, per kind of work, whether a new unit may start**
   (`MachineConditions.hold(for:)`). Four kinds (`BackgroundWork`): a background download of a
   cloud original, a page of text reading, a description request, and a background heavy
   load. Memory at `warning` or `critical`, a `serious` or `critical` thermal state, and Low
   Power Mode hold every kind. A description is also held while the person is in the app.
3. **Every owner asks before a unit.** The description writer waits in `untilOpen(for:)`
   before each request; the search index waits there before each page of text; the text
   reader asks before each reading. The materializer reads `hold(for: .download)` in its
   admission pass for background requests only and is rung by `observe(_:)`; `LoadAdmission`
   performs `room(held:)` on every change and, while held, grants only the load the current
   view needs. A waiter starts in the step that delivers the conditions that open its kind,
   exactly once (ADR 0032 rule 8). An owner waiting names the hold in its status (`heldBy`
   in `op=owners.status` / `op=owners.pending`), and every change logs
   `op=background.room phase=changed` with each kind's hold.
4. **What the person waits on is never held**: an interactive, command or device download,
   a load for the current view, a load the person waits on (`LoadWaiter.user`), a render
   the person waits on, and every window read.
5. **What runs is stopped only where it stops safely.** A text-reading helper is let go at
   once when the room holds text reading and no reading runs in it, and mid-reading at
   `critical`; its reading stays owed. A download in flight is not stopped: the provider's
   download goes on whatever Otos holds (`MaterializationCoordinator.cancelWaiter`). A
   description request in flight (about 4 s) and a heavy load in flight finish.
6. **Concurrency per kind, from the measurements.**
   - Text reading: one helper, never more. Only one ever ran (the survey's "three readers"
     counted readers seen so far, not alive); each holds its own copy of the text model,
     and its cold start alone costs 3–116 s of compile.
   - Descriptions: one request at a time, as before; the model service answers one at a time.
   - Downloads: unchanged — four per root (the owner's choice, 2026-10-31), 2 GB in flight,
     two large videos, and a file larger than half the budget alone, so never two multi-GB
     transfers at once. The room adds the hold, not a smaller cap: no measurement shows a
     cap below four costs less per byte hashed.
   - Heavy loads: one at a time (ADR 0055).

### The two memory-pressure sources

Measured on the owner's machine (installed f398d5dc, pid 10258, ten minutes): the kernel's
level, read from outside every 30 s, was 2 (warning) from 30 s after launch to the end,
while the app's dispatch source reported warning at 119 s, normal at 271 s and warning at
534 s. In a sandbox tour the kernel read 2 for about 34 s and the source reported nothing
(`docs/research/2026-11-17-background-load-attribution.md`). The two are different facts:

- **`kern.memorystatus_vm_pressure_level` is the kernel's current level.** XNU
  (`bsd/kern/kern_memorystatus_notify.c`) defines it read-only (`CTLFLAG_RD`) and returns the
  internal level converted to the memory-pressure notes: normal →
  `NOTE_MEMORYSTATUS_PRESSURE_NORMAL` (1), warning and urgent → `_WARN` (2), critical →
  `_CRITICAL` (4) (`bsd/sys/event_private.h`), the same bits the SDK's
  `DISPATCH_MEMORYPRESSURE_NORMAL`/`_WARN`/`_CRITICAL` define. The handler's privilege check
  (`PRIV_VM_PRESSURE`) is compiled only for targets other than macOS; on macOS 27 an
  unsandboxed user process reads it with no entitlement (read here: `1`, beside
  `kern.memorystatus_level` 76). It is one `sysctlbyname` call.
- **The dispatch source is a notification the kernel sends to processes it chooses.** The
  SDK documents it as monitoring "changes in memory pressure condition"
  (`dispatch/source.h`). In XNU, `memorystatus_update_vm_pressure()` notifies one candidate
  at a time (`vm_pressure_select_optimal_candidate_to_notify`): a process already notified
  at that level is skipped, one under 10 MB is skipped, the foreground and background passes
  are separate, the least important and then the largest goes first, with 0.25 s between
  notifications and resting periods of 25 s; and a return to normal goes only to a process
  that was notified of warning or critical. So a process may hear a warning late or never,
  and a process never told of the warning never hears the return to normal.
- **No other supported call gives the current level.** `os_proc_available_memory` is
  unavailable on macOS (`os/proc.h`), `ProcessInfo` has no level, `host_statistics64` gives
  page counts, not the level, and `memorystatus_get_level` is not in the SDK.

So the level is read where it is needed, and the source rings the room to read it. Whether
the source ever delivers a normal after a warning it never sent was not measured live
(producing pressure on the owner's machine is not safe); the kernel's code says it does not,
which is why the held level is read again on a poll rather than left to the next event.

### Decision for the owner to confirm

**Descriptions run only while Otos is not the active app.** While the person uses the
window, the system language model's service (about 450 MB more than at rest) is not asked;
when they switch to another app, the backlog continues, and stops again when they come back.
It is the option that keeps the machine quiet while the window is in use. Its cost: on a
library whose window is always in front, no description is written. The framework may
rate-limit a request from an app in the background; a busy answer paces the writer for a
minute (ADR 0053), as before. Recorded in ADR 0009 and ADR 0053 too.

## Rejected alternatives

- **The dispatch source as the level.** It reports late or never (above); the room believed
  `normal` while the kernel said warning for minutes.
- **Leaving a silent return to normal to the next event.** The kernel sends no normal to a
  process it never warned, so held work would wait for an unrelated change (a thermal or
  active-app report) that may not come in the session.
- **Polling the level all the time.** A rise is caught by the next decision's read, so a
  poll while the level is normal finds nothing a decision would not.

- **A throttle by time** (a pause between units, a nightly window): time stands in for facts
  the platform reports (ADR 0033), and it slows the backlog on an idle machine too.
- **Moving every cap into the room.** Per-root fairness, the decode budget's bytes and the
  one-at-a-time load turn are each their owner's single answer; a second copy in the room
  would be two owners of one question. The room answers only "may any start now".
- **Cancelling in-flight downloads at `critical`.** Otos holds no handle on the provider's
  download; cancelling only stops Otos waiting for it.
- **More than one text-reading helper.** Each is a process with its own model; one never
  waited on another.
- **Holding renders and the in-process walks** (faces, embeddings). They are in Otos's own
  footprint, bounded by the decode budget (peak 486–609 MB measured on new libraries), and
  the visible tiles depend on them; the sandbox tour of a new 2,000-photo library kept the
  machine at normal with them running.

## Consequences

- Under `warning`, no new description, text page, background download or background heavy
  load starts; the window's own work does. The hold begins at the first decision after the
  kernel reaches warning, whatever the source says. When the level returns to `normal`, each
  held owner resumes in the step that reads it: a source report or the next look, at most
  5 s after the kernel lowered it.
- `op=system.pressure` is the kernel's level over the session: `phase=launch` is the
  room's first read, each read whose level differs from the last logged is `phase=changed`
  (`cause` = `decision`, `sourceReport` or `recheck`, with the source's last report), and each
  source report is `phase=sourceReport` beside the kernel's level. The scorecard's MACHINE
  section reads the launch and changed lines, so a level the source never announced is in it.
- The backlog drains only while the machine has room: on a machine that sits at `warning`,
  it waits. Rows hashed and described per minute are lower on a loaded machine.
- A test scripts the conditions (`BackgroundRoom(conditions:)`, `deliver(_:)`), and the
  kernel and its looks (`BackgroundRoom(memory:)` with a scripted `MemoryPressureReader`);
  owners made alone get a roomy room with no reader, so every existing owner test runs as
  before. Only the app's room reads the live kernel.
