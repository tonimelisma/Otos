# ADR 0055: Background owners start after the first grid, and heavy loads take turns

- Status: Accepted
- Date: 2026-11-16

## Context

Every background owner started the moment the catalog's load returned, beside the window's
first read, and its tasks inherited `.userInitiated` from a task the window model started on
the main actor. Tours on the owner's library (installed f192041a,
`docs/research/2026-11-16-performance-baseline.md`) measured:

| Owners running | Launch to first grid | Peak footprint |
| --- | --- | --- |
| none | 2,200 ms | 336 MB |
| the search index alone | 3,608 ms | 973 MB |
| People alone | 1,875 ms | 2,263 MB |
| all of them | 2,760 ms | 3,804 MB |

The heavy loads overlapped: the footprint was 2,191 MB when the search index finished its
load at 17 s while People's pass ran, and People applied at 39.7 s. On a 16 GB Mac with about
100 MB free before Otos starts, two such loads at once push the catalog's pages out of
memory, and every later read is paid from disk.

## MECE Decision Scope

This ADR owns when the window starts its background owners, which of their loads are
admitted one at a time, in what order, and the priority their tasks run at. It defers each
owner's own work and its request counters to its ADR (0009 enrichment, 0042 duplicates, 0046
Immich, 0047 People, 0048 search), owner state across suspensions to ADR 0032, and
publication to ADR 0005.

## Decision

1. **Owners start after the first grid.** `CatalogWindowViewModel` starts its background owners
   when it applies the first state the catalog's load answers — the moment it logs
   `op=launch.firstGrid` — never on a timer (ADR 0033). They start in one explicit order:
   enrichment and materialization (the visible tiles' thumbnails), the Immich accounts' sync,
   render signatures, preview faces, place names, the search index, descriptions, and the
   metadata re-read.
2. **Heavy loads take turns.** One owner, `LoadAdmission`, admits the bounded loads that hold
   hundreds of megabytes or read much of the catalog, one at a time: a People pass, a
   duplicates build, a build of the search index's vector file from the catalog (ADR 0048;
   opening a current file reads no table and is not admitted), an account's mirror
   pairing, and each request for a photo's description (ADR 0053), whose memory is the
   system language model's (`BackgroundLoad`). An owner wraps such a load in `run(_:_:)`, which waits for its turn and
   releases it when the body returns or throws. None runs before the window opens the
   admission at its first grid. Loads asked for before then run in `BackgroundLoad.launchRank`
   order (People, duplicates, search index, mirror pairing, the derived folder, the first
   description); after it, in the order asked, so a
   load that asks again goes behind those already waiting and never starves them. Readying
   the first search query (`searchPrepare`, ADR 0048) runs last (`runsLast`): behind every other
   waiting load, whenever it asked.
   - **A load the user waits on does not take a turn.** A query's or the intent to search's
     encoder load (`run(_:for: .user)`, `LoadWaiter.user`) is granted at once, before the first
     grid and beside the load running, and no waiting load is granted while it runs. On the
     owner's library the first search, typed about 6 s after launch, waited 1,306 ms for an
     encoder load that had itself waited 2.7 s behind six background loads
     (`docs/research/2026-11-16-first-search-after-launch.md`). Rejected: letting the user's
     load take the next turn, which still waits for the load running (a People pass ran 8.9 s
     in that session); and stopping the running load, which ADR 0032 rule 3 forbids.
3. **The view's load goes first.** Every query the window applies says which load its view
   cannot answer without (`BackgroundLoad.needed(by:)`: a search needs the index, People and
   a person need People, Duplicates and a group need the duplicates build), and that load runs
   next. It does not stop the load running: published or unpublished, a heavy load is never
   cancelled for another (ADR 0032 rule 3).
4. **Teardown starts nothing.** The window shuts the admission in its deinit: every waiting
   load hears `CancellationError` and never starts, and no later request is admitted. A
   waiting task that is cancelled withdraws its request at once.
5. **Owners run below the window, and no lower.** Every owner's tasks run at
   `TaskPriority.backgroundOwner` (`.medium`), inherited from the task that starts them; the
   window's state consumption stays `.userInitiated` (ADR 0032 rule 6). No load runs lower: a
   granted load holds the one turn, and macOS throttles `.background` work hardest, its CPU and
   its I/O, page-ins included, while other work runs. A derived-folder look started at
   `.background` was granted the turn in a full check under parallel load and made no progress
   for minutes, holding People, the duplicates build and the search index behind it (the idle
   guard's hang of 2026-11-16). Each grant logs its priority (`op=load.admission phase=granted
   priority=`).
6. **The admission is a pure machine behind a lock.** `LoadAdmissionMachine.handle(_:)` is the
   only writer of its state (ADR 0032's second shape, like `ImportSessionMachine`), held in a
   `Mutex` with the waiters' continuations; a continuation is resumed after the lock is
   released. Opening, wanting and shutting down are synchronous, so the main actor calls them
   in the step that applies the intent, and teardown from a deinit that cannot await.

7. **A description request takes a turn.** On the owner's library a cold request made the
   system load its 3B model and image encoder into the model's service while a People pass
   ran; the machine-wide compressor grew 1.5 GB in 3.6 s and the kernel went to
   memory-pressure warning, and each time the background room reopened the two started
   together again and the machine dipped again, four times in a minute
   (`docs/research/2026-11-17-launch-pressure-dips.md`). The writer runs each request inside
   `run(.description)`; a request is bounded (3–11 s), so its turn starves nothing, and the
   walk between requests holds no turn.
8. **A load that raised the pressure is admitted against the room it took.** Loads run one at
   a time, so the background load granted last when the room's memory hold begins (ADR 0057)
   is the one the machine was carrying as the level rose (`op=load.admission
   phase=pressureRaised`, with the kernel's available share at its grant). It starts again
   only when the kernel reports more available memory than that share (`kern.memorystatus_level`,
   read by the room; its status `heldBy=memoryHeadroom` meanwhile), and behind every other
   waiting load (before only readying a search). Nothing reports a rise in available memory,
   so while such a load waits the room reads the kernel on its 5 s look (ADR 0057). Once it
   runs to its release with no hold beginning, it is no longer marked; the room reopens on
   one load, the next at its release, so each is seen alone. A hold for any other reason
   marks nothing, and an unread share admits it, behind the others.

The walks of enrichment, render signatures, preview faces, place names, and the search
index's embedding drain are not admitted; descriptions' walk is not, its requests are. Each holds one bounded page at a time and
runs for as long as its backlog lasts, up to hours: an exclusive turn held for that long would
starve every bounded load behind it.

## Rejected alternatives

- **A delay after launch before the owners start.** Time standing in for a fact the window
  reports (ADR 0033).
- **A doorbell loop for the admission.** Every caller would hop to it (the window model by a
  task per query or an extra stream, the deinit not at all), and a release and the next grant
  would be two steps with a suspension between them. The machine decides in the step that
  delivers each event.
- **A cap of more than one heavy load.** Two loads at once is the overlap measured above.
- **Preempting the running load for the view's.** It throws away work already paid for, and
  a cancelled pass publishes nothing; the longest bounded load waited out is one pass.
- **Admitting the walks page by page.** Each page is bounded already; the memory and the cold
  reads the tours measured are the bounded loads', and a description request's, which is
  admitted on its own (decision 7).
- **A size for each load, fixed in advance.** Admitting a load only when the share exceeds a
  stated cost needs the kernel's warning line and the model's resident size, neither of which
  a process can read. The share a load started from when it raised the pressure is a fact the
  kernel reported; the rule needs nothing else.
- **Only ordering a load that raised the pressure behind the others.** In a sandbox tour of a
  library with no faces, People passes took milliseconds and the description request was the
  only heavy load; every reopen re-granted it at once and the machine went back to warning
  within 3–4 s, three times in 40 s (`docs/research/2026-11-17-launch-pressure-dips.md`).
- **Re-granting the held loads in their old order at a reopen.** The load that was running
  when the level rose starts again first and raises it again: four dips in one minute on
  a934ef17.
- **`.utility` or lower for the owners.** The walks that make visible thumbnails would run
  late whenever the window is busy; `.medium` is below the window and keeps them prompt.

## Consequences

- Launch to first grid moves toward the 2,200 ms measured with no owner running, and the
  footprint's peak toward the largest single load's, since no two overlap. On the final
  tours of the performance program the first grid painted in 1,052–1,271 ms and the peak was
  327–390 MB (`docs/research/2026-11-16-performance-baseline.md`).
- A People pass or duplicates build asked for while another load runs waits for it; with
  People or Duplicates shown, theirs runs next. A user's People act therefore waits at most
  one running load longer than before.
- `op=load.admission phase=granted` (with `waitMs`) and `phase=released` (with `ms`) log every
  turn, so a tour reads how long each load waited and ran; `phase=pressureRaised` names the
  load that ran into a memory hold.
- A description waits for one running load, at most a People pass; with People passes asked
  continuously, requests alternate with them, so descriptions per minute fall while People
  works. A description that took the machine to warning waits until the machine has more
  room than it started with; on a machine that stays fuller, no description is written in
  that session.
- A test that makes an owner alone gets an open admission of its own; the window's owners
  share the window's.
