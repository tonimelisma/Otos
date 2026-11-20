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
   - **A People pass that covers the user's own People act is a load they wait on.** A name
     given or removed, a merge, an undo: the act's path asks `PeopleAssignment.requestForUser()`,
     which records the request it made as a revision (`userAwaited`, ADR 0032 rule 2); the
     pass that starts while it is uncovered runs `for: .user`, and a background People pass
     already waiting is promoted to the user's (`LoadAdmission.promote`, machine event
     `.promote`), granted at once. On the owner's library a face named Kim left its twin HEIC
     Unidentified for 133 s, the People pass waiting in the room's memory hold (2026-11-19). A
     pass owed only to background facts (faces read, catalog changes) waits its turn as before.
     Rejected: marking the pass from the catalog change the act wrote, which the projection
     forwards with every other change and so cannot tell whose it was; and a boolean a
     finishing pass clears, which an act during the pass would lose.
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
   walk between requests holds no turn. **The view's load does not wait for a request:** while
   a description holds the turn, the load the current view needs (decision 3) is granted beside
   it in the step it is wanted or asked (`LoadAdmissionMachine.beside`), so a click on People,
   Duplicates or a search never waits up to 11 s behind the model. Its memory is the model
   service's, not Otos's footprint, so this is not the two-loads-at-once overlap rejected below;
   nothing else is granted until both end.
8. **A heavy load that raised the pressure is admitted against the room it was seen to take;
   a description never waits for headroom.** The owner's direction (2026-11-18): "Descriptions
   should run when the app is foreground ed. OS will swap running apps." His machine sat at
   45–53 % available, so the cost floor this decision used to set for descriptions (67 %
   available) held all of them: 0 written, 755 owed on the tour of 6dc46aa3
   (`docs/research/2026-11-16-performance-baseline.md`). The memory a request takes is in the
   system language model's service, which macOS compresses and swaps like any other app's;
   free memory is not a precondition for it.
   - **A description is held only by the room** (ADR 0057: critical memory pressure, a serious
     or critical thermal state, Low Power Mode). It has no requirement, never ratchets, and its
     grant clears the record of the last grant, so pressure that rises while it runs is charged
     to no load. A grant beside it (decision 7) is not measured either: two run at once.
   - **A heavy load's grant that raised the pressure ratchets its requirement.** Loads run one
     at a time, so the background heavy load granted last when the room's memory hold begins
     (ADR 0057) is the one the machine was carrying as the level rose (`op=load.admission
     phase=pressureRaised`). Its requirement (`LoadAdmissionMachine.RoomNeed`) is a share of
     `kern.memorystatus_level`, read by the room: the line at which the owner's Mac goes to
     warning, 32 % (`BackgroundLoad.warningLinePercent`: across the tours of
     `docs/research/2026-11-17-launch-pressure-dips.md` the kernel read warning at as much as
     31 %, never above, and returned to normal only at 33 % or more), plus its measured cost —
     the share at its grant less the lowest share read from the grant to the hold, the
     warning's read included. It becomes the largest of what it was, the line plus that cost,
     and one point above the share it was granted at, so the same grant is never repeated
     into the same room; it never falls in the session. No load has a requirement until a
     grant of it raised the pressure.
   - A load that raised the pressure also waits behind every other waiting load (before only
     readying a search) for the session; the room reopens on one load, the next at its
     release, so each is seen alone. A hold for any other reason measures nothing, and an
     unread share admits a load: an error is not a fact. Nothing reports a rise in available
     memory, so while a load waits for its requirement the room reads the kernel on its 5 s
     look (ADR 0057); every admission step tells the room the requirement a waiting load needs
     (`Admission`'s `afterStep`).
   - Each beginning and end of the room's memory hold logs the loads running up to it
     (`op=load.admission phase=memoryHold held= running=`), so the scorecard attributes the
     pressure a description raised to descriptions (ADR 0015).

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
- **Re-admitting a load that raised the pressure once the share exceeds the one it was
  granted at** (#941). On installed b1429daa, from 45 % available at launch, a description was
  granted at 30–54 % thirteen times and twelve warnings followed one within about 5 s, 128.4 s
  at warning in 617 s: each re-admission a few points higher fell back below the line, since
  the bar did not cover what a request costs.
- **A cost floor for descriptions (67 % available) with a per-session ratchet** (#941, #943).
  It stopped the dips, and with them every description on the owner's machine, which never
  reached 67 %; the owner's direction of 2026-11-18 replaces it (decision 8).
- **Holding descriptions at memory-pressure warning.** Before #943 a request held at warning
  loaded the model, raised the level, was held, and was let start again at the return to
  normal: 13 dips in 128 s. A description is held only at critical (ADR 0057).
- **Taking descriptions out of the turn.** A background People pass would run beside a cold
  request again, the overlap of decision 7, and the pressure the request raised would be
  charged to the People pass (decision 8), holding it for the session.
- **A size for each load read from the model.** The model's resident size and whether it is
  loaded are not readable by a process; the line and the costs are what the kernel reported.
- **Lowering the requirement after a clean run.** A warm request costs a few points, but the
  next one may be cold; a requirement that falls re-admits the request into the room it ran
  out of.
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
  works. A description starts whatever memory is available, while Otos is frontmost, and at
  warning. While descriptions keep the machine at warning, background heavy loads (a People
  pass after new faces, a duplicates build) wait in the room until it reads normal; the load
  a view needs starts at once, beside a request if one runs. A heavy load that raised the
  pressure starts in the background only with the room it took, for the session.
- A test that makes an owner alone gets an open admission of its own; the window's owners
  share the window's.
