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

1. **One owner, `BackgroundRoom`, holds the machine's conditions as the platform reports
   them** (`MachineConditions`): the memory-pressure source
   (`DispatchSource.makeMemoryPressureSource`, its level at launch read from
   `kern.memorystatus_vm_pressure_level`), `ProcessInfo.thermalState`, Low Power Mode, and
   whether Otos is the active app (`NSApplication` becoming and resigning active: the
   person is in the app). `MachineConditionsMonitor`, owned by the app delegate, is the one
   listener; each report changes its one field in the step it arrives. Nothing samples, and
   no timer stands in for any of these facts (ADR 0033).
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

### Decision for the owner to confirm

**Descriptions run only while Otos is not the active app.** While the person uses the
window, the system language model's service (about 450 MB more than at rest) is not asked;
when they switch to another app, the backlog continues, and stops again when they come back.
It is the option that keeps the machine quiet while the window is in use. Its cost: on a
library whose window is always in front, no description is written. The framework may
rate-limit a request from an app in the background; a busy answer paces the writer for a
minute (ADR 0053), as before. Recorded in ADR 0009 and ADR 0053 too.

## Rejected alternatives

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
  load starts; the window's own work does. When the level returns to `normal`, each held
  owner resumes in that step.
- The backlog drains only while the machine has room: on a machine that sits at `warning`,
  it waits. Rows hashed and described per minute are lower on a loaded machine.
- A test scripts the conditions (`BackgroundRoom(conditions:)`, `deliver(_:)`); owners made
  alone get a roomy room, so every existing owner test runs as before.
