# ADR 0058: Background work is shown in one Activity surface, read from the owners' own status

- Status: Accepted
- Date: 2026-11-21

## Context

Most of Otos's work runs unasked: enrichment reads every photo (thumbnails, previews,
details, digests), the materializer downloads cloud originals, faces are found and put
together into people, places named, search prepared, photos described, duplicates
grouped, details re-read after a parser fix, and each Immich account synced. On the owner's
cloud library some of it lasts hours. Before this ADR none of it was visible except People's
unchecked tally (DES-109), search's still-reading count inside an empty result (DES-108) and
an account's status in Settings. The owner asked where a user could see what is going on,
and when, unintrusively, and chose a sidebar line plus scope lines from six options
(2026-11-21: a footer at the grid's end, a Window ▸ Activity panel, a toolbar indicator, and a
per-photo Info section were the others).

Every background owner already keeps its bookkeeping in one `OwnerActivity` and reports an
`OwnerStatus` (ADR 0032 rule 8): requests owed, passes running, work held, a backlog walk,
and the machine hold its next unit waits on (ADR 0057). Nothing published it; the logs and a
tour's session end read it.

## MECE Decision Scope

This ADR owns how the window learns what background work runs, which work is named and how,
and where it is shown. It defers each owner's work and its holds to its own ADR (0009, 0027,
0046, 0047, 0048, 0051, 0053, 0057), quiescence to ADR 0032, and the surface's look to
`docs/design/activity.md` (DES-124, DES-125).

## Decision

1. **One owner answers "what is Otos doing": `ActivityBoard`**, an actor per window. It holds
   no copy of any owner's state. Each watched owner's `OwnerActivity` rings the board's
   doorbell (`ring`) in the steps that can change whether it works or is held — a request, a
   pass beginning or ending, a settle, a hold set or cleared — and the background room's
   observation rings it on every change of conditions, from which a description's hold is
   read (`heldNow`). One loop, woken by the doorbell (`.bufferingNewest(1)`), reads every
   watched owner's `OwnerStatus` as a value and applies the round in one synchronous step
   (ADR 0032 rules 1, 3). A round that changes what the board shows publishes one
   `ActivitySnapshot`, newest wins, and logs `op=activity phase=changed`.
2. **Status, not history: working, paused, stuck or up to date.** A kind works while any
   owner serving it is not quiescent (`OwnerStatus.isQuiescent`), and is paused while every
   one of those waits on a hold. A kind none of whose owners works is stuck while something
   stops work it owes, and up to date otherwise. The board keeps when a kind's stretch of
   work began, which only orders the line (the work that has run longest); no time is shown.
   The owner rejected a list of finish times (2026-11-21: "it's a status window. not when
   something was done"). An Immich account reads syncing or connecting (working), offline or
   signed out (waiting), or online (up to date).
3. **What stops work is named by its owner, with its cause.** Every round asks each watched
   owner what stops its work (`QuiescentOwner.troubles()`, `OwnerTrouble`): a cause in the
   user's terms — downloads that failed, a full disk, a server that did not answer, a source
   that sends originals only when opened, faces that could not be read, Apple Intelligence
   off, unsupported, not ready, not responding or busy, a cloud provider not answering,
   place names or search that failed — and, where the owner holds one, the exact number of
   items it stops. Every owner that arms a backoff wake reports the failure it waits out;
   a wake alone is never read as a trouble, because a wake says when, not why. Enrichment's
   pacing ledger records the cause of each row it paces (`RetryLedgerEntry.cause`), so the
   rows it holds are counted by what stopped them. A working kind's troubles are shown with
   its work: some items can wait out a failure while the rest are read. The causes are
   logged at a session's end (`op=owners.trouble`) and on each board change.
4. **The user's words, not the owners'.** `ActivityKind` names outcomes (DES-035), each said
   as what it does: `Reading photos` (enrichment, and the metadata re-read after Otos learned
   to read more), `Downloading photos` (materialization), `Finding people` (faces found and
   put together into people), `Naming places`, `Preparing search`, `Describing photos`, and
   `Looking for duplicates` (the groups and the render signatures they compare). A user
   cannot tell reading a photo from re-reading its details, or finding a face from
   recognizing its person, so each pair is one kind. `BackgroundOwnerSet.activityOwners()`
   is the one map from owner to kind. The projection's publications, the People gallery's
   tally and the derived folder's launch tidy are machinery and are not watched. Work that
   has its own surface — an import, Move to Trash, export, reorganization, a pane's download
   — is not listed (one fact, one owner).
5. **Honest numbers, or none.** A count is shown only where Otos already holds an exact one:
   People's unchecked tally under `Finding people`, and the items a trouble stops. No owner gains a count query for this
   surface: the owed predicates are paged walks whose totals move as other owners write, and
   a moving denominator is what DES-031 forbids.
6. **Only what runs or waits is listed.** The popover lists the kinds and accounts that work,
   are paused or are stuck, and says `Everything else is up to date` for the rest (owner,
   2026-11-21: "Only running or stuck"). Apple's Feedback guidance is that people expect a
   task to succeed and need to hear only when it does not; nine `Up to date` rows hid the two
   that mattered.
7. **One place to look, plus the scope's own line.** The sidebar's foot carries the Activity
   line and its read-only popover (DES-124; DES-040 names it). A scope whose result is still
   being built says so in its own bar (DES-125): People and search already did, and the
   duplicates bar says `Still looking for duplicates` while the groups are built and nothing
   would move.

## Rejected Alternatives

- **Owners push a state to the board.** A pushed partial state goes stale whenever a step
  changes the owner's state without a push: the materializer begins and ends a pass in one
  synchronous step, and enrichment's held work is known only to it. Reading the status on
  every ring is as current as the last ring.
- **The view model polls `ownerStatuses()`.** A poll stands in for facts the owners can
  report (ADR 0033).
- **A bare `Waiting to try again`.** Shipped first and rejected by the owner ("I don't know
  any of these statuses"): it names neither the problem nor what happens next, which the
  HIG asks of a stalled process (Progress indicators), and it was inferred from a backoff
  wake that cannot say why it was armed.
- **Every kind listed, `Up to date` included.** Shipped first; replaced by decision 6.
- **A count for every kind.** Each would be a new query over a 2.5 GB catalog, and its total
  moves while other owners write. Counting rows written instead mixes units across owners.
- **A toolbar indicator.** DES-040 keeps operation status out of the toolbar, and something
  is enriching nearly always, so it would be a permanently busy control in the chrome.
- **Start and finish times per kind.** Shipped first and rejected by the owner: a list of
  when things finished does not say whether anything is still owed, and the user asks
  "is it done, working, or stuck", not "when".
- **Holding a short job on screen for a minimum time.** Time standing in for a fact (ADR 0033);
  the line names the work that has run longest instead, so a short job beside a long one
  changes only the count.

## Consequences

- A short pass with nothing else running shows on the line for as long as it runs. That is
  the fact, and the line's spinner and words change with it.
- An owner that adds a backoff must add its cause to `troubles()`, or its row reads up to
  date while it waits; `OwnerTrouble.Cause` is the vocabulary, and a new cause needs its
  sentence in `ActivityPresentation.troubleText`.
- The board's loop reads up to a dozen owners per round, each owner's troubles included. Rings coalesce to one round at a
  time, and a round that changes nothing publishes nothing.
- A new background owner is shown only when `BackgroundOwnerSet.activityOwners()` names its
  kind.
