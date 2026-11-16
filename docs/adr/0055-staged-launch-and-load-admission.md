# ADR 0055: Background owners start after the first grid, and heavy loads take turns

- Status: Accepted
- Date: 2026-11-16

## Context

Every background owner started the moment the catalog's load returned, beside the window's
first read, and its tasks inherited `.userInitiated` from a task the window model started on
the main actor. Tours on the owner's library (installed f192041a, plan 0116 §2.1b) measured:

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
   opening a current file reads no table and is not admitted), and an account's mirror
   pairing (`BackgroundLoad`). An owner wraps such a load in `run(_:_:)`, which waits for its turn and
   releases it when the body returns or throws. None runs before the window opens the
   admission at its first grid. Loads asked for before then run in `BackgroundLoad.launchRank`
   order (People, duplicates, search index, mirror pairing); after it, in the order asked, so a
   load that asks again goes behind those already waiting and never starves them. Readying
   the first search query (`searchPrepare`, ADR 0048) runs last (`runsLast`): behind every other
   waiting load, whenever it asked.
3. **The view's load goes first.** Every query the window applies says which load its view
   cannot answer without (`BackgroundLoad.needed(by:)`: a search needs the index, People and
   a person need People, Duplicates and a group need the duplicates build), and that load runs
   next. It does not stop the load running: published or unpublished, a heavy load is never
   cancelled for another (ADR 0032 rule 3).
4. **Teardown starts nothing.** The window shuts the admission in its deinit: every waiting
   load hears `CancellationError` and never starts, and no later request is admitted. A
   waiting task that is cancelled withdraws its request at once.
5. **Owners run below the window.** Every owner's tasks run at `TaskPriority.backgroundOwner`
   (`.medium`), inherited from the task that starts them; the window's state consumption stays
   `.userInitiated` (ADR 0032 rule 6).
6. **The admission is a pure machine behind a lock.** `LoadAdmissionMachine.handle(_:)` is the
   only writer of its state (ADR 0032's second shape, like `ImportSessionMachine`), held in a
   `Mutex` with the waiters' continuations; a continuation is resumed after the lock is
   released. Opening, wanting and shutting down are synchronous, so the main actor calls them
   in the step that applies the intent, and teardown from a deinit that cannot await.

The walks of enrichment, render signatures, preview faces, place names, descriptions and the
search index's embedding drain are not admitted. Each holds one bounded page at a time and
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
  reads the tours measured are the bounded loads'.
- **`.utility` or lower for the owners.** The walks that make visible thumbnails would run
  late whenever the window is busy; `.medium` is below the window and keeps them prompt.

## Consequences

- Launch to first grid moves toward the 2,200 ms measured with no owner running, and the
  footprint's peak toward the largest single load's, since no two overlap (plan 0116 bet 6).
- A People pass or duplicates build asked for while another load runs waits for it; with
  People or Duplicates shown, theirs runs next. A user's People act therefore waits at most
  one running load longer than before.
- `op=load.admission phase=granted` (with `waitMs`) and `phase=released` (with `ms`) log every
  turn, so a tour reads how long each load waited and ran.
- A test that makes an owner alone gets an open admission of its own; the window's owners
  share the window's.
