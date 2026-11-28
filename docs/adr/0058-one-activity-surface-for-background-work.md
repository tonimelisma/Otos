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
2. **Status, not history: needs you, working, paused, waiting or up to date.** A kind works
   while an owner serving it moves its work: not quiescent, with items left that are not
   parked (`WorkProgress.counted`'s `parked`, the items that wait out a failure or are being
   tried again). Busy alone is not enough: an owner retrying parked items is busy, and a retry
   that fails moves nothing — read as work, a library with a thousand paced rows flipped its
   row between working and waiting at every retry (owner, 2026-11-27: "why does its progress
   bar disappear and reappear all the time"). A kind is paused while every owner moving it
   waits on a hold. A kind that cannot move waits while something stops it or items it has
   left are parked, and keeps waiting, with what stopped it still said, through its owners'
   retries until it has finished an item more than when it began to wait — a fact its count
   reports, never a time (ADR 0033) — or nothing of it works or waits. An owner that is only
   a kind's detail (the downloads behind the photos to show, `Watched.Role.detail`) never makes
   it work. An owner that groups a kind's finished items (`Watched.Role.grouping`: People's
   assignment, the duplicate groups) has no count; while only it moves the kind, the row says
   that it groups (`Grouping faces into people`, `Grouping duplicates`), draws a spinner in
   place of a bar, and keeps its count only while items are left (owner, 2026-11-28). The board keeps when a kind's stretch of work began, which only orders the line;
   no time is shown. The owner rejected a list of finish times (2026-11-21: "it's a status
   window. not when something was done"). An Immich account reads syncing or connecting
   (working), offline (waiting), signed out (needs you), or online (up to date).
3. **A problem is said only when the user would notice it** (owner, 2026-11-27: "why are we
   showing these to the user? what does the user care about?";
   `docs/research/2026-11-27-activity-and-the-hig.md`). Every round asks each watched owner
   what stops its work (`QuiescentOwner.troubles()`, `OwnerTrouble`), and the cause carries
   its standing (`OwnerTrouble.Standing`):
   - **needs you**: something the user can fix and nothing moves until they do — a full disk,
     Apple Intelligence turned off, a signed-out account (with `Open Settings…`). Said first,
     on the line too, whatever else works.
   - **unavailable**: a source or service the work needs — a cloud provider named as the
     sidebar names its library (`OwnerTrouble.sources`), the face model, Apple Intelligence
     not ready, not responding or busy, place names or search failing. Said on the row it
     stops.
   - **retried**: one item failed — a download, a ranged read a server did not answer, a RAW's
     camera support, faces, a description — and is tried again on its own. Never said: the
     user notices nothing, and people need to hear only when something does not succeed
     (HIG Feedback). The item stays in its kind's count, parked, and a row whose items all
     wait says only `Otos will try these again later.` A server that stops answering for a
     whole account is said on the account's row.
   - **user work only**: an item whose source sends its original only for the user's work
     (ADR 0046 §4). No background work can do it, so it is no work left at all: neither said
     nor counted. It read `The server sends 934 items only when you open them. Otos will try
     again.` — a cause that blamed the server for Otos's own rule, and a promise no retry
     could keep.

   Every owner that arms a backoff wake reports the failure it waits out; a wake alone is
   never read as a trouble, because a wake says when, not why. Enrichment's pacing ledger
   records the cause of each row it paces (`RetryLedgerEntry.cause`) and the outcome it was
   claimed for, and keeps the row until its read lands, so its entries are the rows
   held back now. Every cause is logged at a session's end (`op=owners.trouble`) and on each
   board change, said or not.
4. **Outcomes the user would notice missing, named for what Otos does.** `ActivityKind` names
   outcomes (DES-035), each said as a verb and the thing Otos makes, so the user knows what it
   does and where to find what it gives them (HIG Writing: "Choose words that are easily
   understood and convey the right thing"; Progress indicators: "Avoid vague terms"):
   - `Making thumbnails`: thumbnails and previews made or remade, with the background
     downloads it waits on as its line. Never an Immich account's thumbnails: the account's
     sync brings them, and says so on its own row.
   - `Reading photo info`: the details the Info pane shows — dates, camera, lens, place — read
     from each file or an account's server, and read again by a metadata refresh.
   - `Scanning for faces`: faces detected in stills' previews and videos' frames, then grouped
     into people. Most of the work is detection, which "finding people" overclaimed; Apple's
     Photos counts the same work as photos "scanned".
   - `Looking up place names`, counted in the map's areas (`locations`), never in photos.
   - `Indexing for search`: what search compares a query with, made for each item — no label
     is identified, which "detecting" would claim.
   - `Writing descriptions`.
   - `Finding duplicates`: the groups, the render signatures they compare and the digests that
     tell exact copies apart.

   Enrichment is one walk serving four of these; each owed row is filed under exactly one
   (`EnrichmentPurpose`: a thumbnail, a video's faces, the photo info, the digest, the first
   that applies), alike in Swift at the claim and in SQL in the count
   (`EnrichmentClaimGateway.purposeSQL`). The owner rejected names that hid the work —
   `Showing photos`, `Finding people`, `Reading details` for three unrelated jobs (2026-11-27:
   "Reading details is also incredibly obscure") — and `Making thumbnails` while it counted an
   account's details as thumbnails still to make ("it doesn't make any sense"). Downloads are a
   means, not an outcome, so they are no row. `BackgroundOwnerSet.activityOwners()` is the one
   map from owner to kind; one owner can serve several kinds, each counted and stopped apart
   (`QuiescentOwner.progress(for:)`, `troubles(for:)`), and several owners can count one kind
   (a still's faces and a video's), which the board sums. The projection's publications, the
   People gallery's tally and the derived folder's launch tidy are machinery and are not
   watched. Work that has its own surface — an import, Move to Trash, export, reorganization, a
   pane's download — is not listed (one fact, one owner).
5. **Every row says how much is left, exactly** (owner, 2026-11-26: "each should give the
   actual progress", "shouldn't each of these have a progress bar?"). Each kind has one owner
   that counts its work, or several whose counts it sums (`QuiescentOwner.progress(for:)`,
   `WorkProgress.counted`): the items each has finished, counted at each write the catalog
   accepted (`OwnerActivity.finished`; enrichment counts the rows of a fully applied batch by
   the outcome each was claimed for), what is left, an exact COUNT over the very predicate its
   walk reads, through the same partial index — enrichment's claims per root, by outcome; the
   stills not yet checked for faces; unnamed place cells; owed search embeddings; owed
   descriptions; owed render signatures — and how many of those are parked. The board asks again only when that owner's work has moved (`OwnerWork`),
   so a round woken by anything else reads no count. A stretch of work keeps its start: `done`
   is what the owner finished since then and `total` is that plus what is left, which the bar
   draws; the row says what is left (`39,902 photos and videos left`), the number a user reads
   at a glance, where `19,659 of 20,715` named a total from when the stretch began that matched
   nothing they knew. A fall of the count is not work done: an item stops being owed when its
   facts change again or its row goes, and a writer whose every attempt failed had read as
   thousands done (owner, 2026-11-26: "Whatever the problem the status needs to be right!"). A
   row draws its determinate bar only while it works; a paused or waiting row keeps its count
   and draws none ("It cant give a progress bar if theres none"). A row draws one indicator:
   its bar while it works, a spinner only while it works with nothing counted, a warning while
   it needs the user, none while it waits (HIG Progress indicators: never switch between a
   spinner and a bar). A failed count publishes nothing new (ADR 0032 rule 4). No row shows a
   percentage, a remaining time or a rate: every number is a count Otos holds.
6. **Only what runs or waits is listed.** The popover lists the kinds and accounts that work,
   are paused, wait or need the user, and says `Everything else is up to date` for the rest
   (owner, 2026-11-21: "Only running or stuck"). Apple's Feedback guidance is that people expect
   a task to succeed and need to hear only when it does not; nine `Up to date` rows hid the two
   that mattered.
7. **One place to look, plus the scope's own line.** The sidebar's foot carries the Activity
   line and its popover, which is read-only but for a row's one act (DES-124; DES-040 names it). A scope whose result is still
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
- **Every cause said, each item's failure with its count.** Shipped first and rejected by the
  owner (2026-11-27): `The server didn’t answer for 114 items` and `The server sends 934 items
  only when you open them` named neither a source nor anything the user could do, about items
  they could not see missing, and the second blamed the server for Otos's own rule.
- **A kind works while any owner of it is busy.** Shipped first; a retry of a parked item
  made the row flip between a bar with a spinner and a pause at every retry (decision 2).
- **Holding a waiting row on screen for a while after a retry.** Time standing in for a fact
  (ADR 0033); the row waits until its count says an item finished.
- **A row per source.** The popover answers "what is Otos doing"; one row per kind of work,
  with a problem naming its source, says it without repeating every kind under every
  library and account.
- **Only the counts Otos already held** (People's tally, the items a trouble stops). Shipped
  first and rejected by the owner: a spinner beside `Reading photos` said neither what the
  work was nor how far it had come. Each count is one COUNT over a partial index that already
  exists, read only when its owner's work moved.
- **A total of the whole library per kind.** Its eligible set is a second predicate per kind
  that would have to agree with the walk's exactly; the stretch's own tally needs only the
  walk's count, and says what the user asks: how much of what is under way is done.
- **Rows written as `done`.** Units differ across owners (a pass writes several rows for one
  item), so a written count is not an item count.
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
  date while it waits, and count the items it holds back as parked, or its row reads working
  while it retries; `OwnerTrouble.Cause` is the vocabulary, a new cause needs its standing,
  and one the user is told needs its sentence in `ActivityPresentation.troubleText`.
- A failure that is never said is still in the logs: `op=owners.trouble`, the board's
  `op=activity phase=changed`, and a diagnostics export.
- The board's loop reads up to a dozen owners per round, each owner's troubles included. Rings coalesce to one round at a
  time, and a round that changes nothing publishes nothing.
- A new background owner is shown only when `BackgroundOwnerSet.activityOwners()` names its
  kind.
