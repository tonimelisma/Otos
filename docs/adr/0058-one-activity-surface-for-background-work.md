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
2. **Status, not history: working, waiting or up to date.** A kind works while any owner
   serving it is not quiescent (`OwnerStatus.isQuiescent`), and is paused while every one of
   those waits on a hold. A kind none of whose owners works waits on what an owner at rest
   reports: an armed backoff (`OwnerWake.Kind.backoff`, `Waiting to try again`) or rows it
   holds for a fact outside it (`OwnerHeldRows`: claims paced after a failed read,
   `Waiting to try again`). Held rows are asked of
   an owner only at rest, so a working owner's rings cost no count. Otherwise the kind is up
   to date. Every watched kind is always listed. The board keeps when a kind's stretch of
   work began, which only orders the line (the work that has run longest); no time is shown.
   The owner rejected a list of finish times (2026-11-21: "it's a status window. not when
   something was done"). An Immich account reads syncing or connecting (working), offline or
   signed out (waiting), or online (up to date).
3. **The user's nouns, not the owners'.** `ActivityKind` names outcomes (DES-035): reading
   photos (enrichment), downloading originals (materialization), updating photo details
   (the metadata re-read), finding faces, recognizing people, naming places, preparing
   search, describing photos, and looking for duplicates (the groups and the render
   signatures they compare, two owners for one kind). `BackgroundOwnerSet.activityOwners()`
   is the one map from owner to kind. The projection's publications, the People gallery's
   tally and the derived folder's launch tidy are machinery and are not watched. Work that
   has its own surface — an import, Move to Trash, export, reorganization, a pane's download
   — is not listed (one fact, one owner).
4. **Honest numbers, or none.** A count is shown only where Otos already holds an exact one:
   People's unchecked tally under `Finding faces`. No owner gains a count query for this
   surface: the owed predicates are paged walks whose totals move as other owners write, and
   a moving denominator is what DES-031 forbids.
5. **One place to look, plus the scope's own line.** The sidebar's foot carries the Activity
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
- The board's loop reads up to a dozen owners per round. Rings coalesce to one round at a
  time, and a round that changes nothing publishes nothing.
- A new background owner is shown only when `BackgroundOwnerSet.activityOwners()` names its
  kind.
