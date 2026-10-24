# ADR 0019: Import Plan Namespace Resolution And Build Ownership

## Status

Accepted. Implemented in `ImportPlanBuilder` and `MediaTransferPlanner`.

## Context

Import planning must decide, for every file on an attached source, whether to copy
it to a destination path, skip it as already present, or block it. That decision
needs live destination facts: the catalog alone cannot see symlinks, directories,
packages, or files written by other applications, so freeness must be observed on
the filesystem (ARC-046).

The original implementation expressed that need as a request/resolve fixed point.
`planImport` walked the source bundles and, on reaching a candidate whose occupancy
it did not know, returned a request for that one path — discarding everything it had
planned so far. `buildImportPlan` resolved the request with a single `lstat` and
called `planImport` again from the first bundle, up to 10,000 times.

Because the only no-probe short circuit covered paths reserved by the plan itself,
essentially every candidate cost one full restart. Each restart re-sorted the entire
source list, computing `MediaSortKey.naturalKey` inside the sort comparator without
caching, and rebuilt a set of every destination occupant. Planning was therefore
O(n²·log n) in string construction.

Measured on a 1,578-file card against a 26,229-asset destination: **187,846 ms** to
produce a 204-copy plan, ~119 ms per restart across ~1,600 restarts. The filesystem
was not the cost — `lstat` against that destination measures 0.090 ms for an existing
path and 0.004 ms for an absent one, so all the probing together accounted for well
under a second.

The build also ran synchronously on `MediaOperationCoordinator`, inside the task that
consumes the planning-change stream. While a plan built, the coordinator could not
process any planning change. In the same session an SD card mounted at 22:30:05 and
was not noticed until 22:33:26 — the coordinator was inside a change it had received
at 22:26:24, and the four planning changes announcing the card were still queued
behind it. Attach-to-ready was ~6 m 29 s, of which the instrumented metric reported
only the last 3 m 08 s.

## Decision

**Destination occupancy is resolved by enumerating folders, not by probing paths.**

The set of destination folders a plan can touch is computable from source facts plus
policy alone, because a suffix retry changes the file name and never the folder.
`MediaTransferPlanner.destinationFolders(for:)` returns that set with no I/O.
`FilesystemNamespaceSemantics.enumerateNamespace(root:folders:)` reads exactly those
folders once into an immutable `DestinationNamespace`.
`MediaTransferPlanner.planImport(snapshot:namespace:)` is then a single pure pass:
every candidate, including each suffix retry, is answered from memory. The fixed
point, its 10,000-iteration cap, and its `preconditionFailure` are gone — the
pathology is unrepresentable rather than merely faster.

Absence is a claim about a folder that was actually read. `DestinationNamespace`
carries its enumerated folder set and answers `nil` for a path outside it; the
planner blocks those candidates with `.filesystemObservationUnavailable`. A folder
that does not exist is fully enumerated and contributes no occupants, which correctly
makes every candidate in it free.

A folder that exists but cannot be listed is recorded in the namespace's
`unreadableFolders` with the error it gave, and **a build carrying one is never
presented as a plan**: the planner's block is the safety net that keeps an unread
folder from planning an overwrite, not a state the user should see. The coordinator
defers such a build — the phase returns to `.inventory`, the last proven plan keeps
presenting, and a bounded backoff (1 s, 4 s, 16 s, 60 s) re-plans; past the last
delay the condition is a planning failure (`destinationUnavailable`, state G) that
`Try Again` or any planning wake clears by rebuilding. A cloud provider mid-sync
answers `contentsOfDirectory` with an error for a moment; on 2026-09-13 that moment
was promoted to a plan that read `0 new items · Import 0 Items` over 368 items
already in the library. Suffix exhaustion is a separate, per-item reason
(`.noFreeDestinationName`).

**Plan building is an owned per-source child task, and its result is an event.**
Session state lives in `ImportSessionMachine`, which changes only in the synchronous
`handle(_:)`. Taking a build up is a transition: it sets `planCovered = planRequested`
and returns a `startBuild` effect that the coordinator shell runs as a task held in
`buildTasks`. A request (a revision, destination or preference change, a scan batch) is
`planRequested &+= 1` and nothing ever decrements it, so one made while a build runs is
still owed when that build finishes. The planning-change consumer never awaits a build,
so the coordinator keeps servicing attach, detach, and Import intents while one is in
flight. The build task reads the Store and runs the planner, touching no session state;
it reports back `buildFinished(BuildID, outcome)`. Because that is a suspension point,
the machine judges the outcome against the session as it is *now* — the typed
`BuildID` (source, attachment, build generation), the destination, and the source and
destination occupancy revisions — and a build that lost the race requests another plan
instead of applying. A detached source cancels its build, and a stale result is dropped
by identity. The enumeration and planning pass run off the coordinator actor because
`LiveImportPlanBuilder.build` is `@concurrent`: this target compiles with
`NonisolatedNonsendingByDefault`, under which a plain `nonisolated async` call stays on its
caller's actor and measured 285–324 ms of the coordinator being unreachable per build
(`docs/research/2026-10-23-actor-hold-during-blocking-work.md`).

**Planning is instrumented at the boundary that owns it.** `op=import.plan` emits
`phase=start`, `phase=finish` (folder count, namespace entry count, `enumerateMs`,
`planMs`, and plan totals), and `phase=stale`, under an `ImportPlanBuild` signpost
interval. `enumerateMs` and `planMs` are reported separately so I/O cost and CPU cost
are attributable without a side experiment.

`knownForeignOccupants` is removed from the import path. `CatalogStore` declared a
`knownForeignOccupantsByRoot` dictionary that nothing ever wrote: `recordForeignOccupant`
marks the path dirty and bumps `namespaceRevision`, which replans. Enumeration then
observes the foreign occupant directly, so the field carried no fact the live read
does not already provide.

## Rejected Alternatives

### Batch the probes but keep the fixed point

Letting a pass run to completion and collecting every request would cut the restarts
from ~1,600 to roughly the maximum suffix depth. It preserves a request/resolve
protocol, a convergence cap, and a crash-on-non-convergence for a problem that does
not need iteration at all: the folder set is knowable before the first observation.
Enumerating removes the protocol instead of tuning it.

### Adaptive probing — enumerate large folders, stat individual paths for small imports

Importing three files into a 5,247-entry folder costs 184 ms to enumerate versus
0.3 ms to stat three paths. The rule would need a threshold, two code paths, and a
reason to trust the threshold. Reading the entire 16,167-file destination root takes
461 ms, so the worst case of the simple rule is already imperceptible for a
user-initiated import. One path, no threshold.

### Answer occupancy from the catalog and skip the live read

The scanner already enumerates roots, so the catalog could serve destination
occupancy with no planning-time I/O. This reintroduces exactly the catalog trust
ARC-046 forbids: the scan may be stale, and it discards non-media occupants, which
are precisely the foreign files that must force a suffix.

### Make the planning-change stream newest-wins per root

Stale replay looked like a cause of the observed backlog. It was a symptom: the
consumer was blocked, not oversubscribed. The stream is documented as a lossless
revision log, the coordinator already suppresses unchanged occupancy revisions, and
the revision counters and the one-build-at-a-time rule already coalesce redundant builds. With the consumer no longer
blocking, the backlog drains immediately. Changing the buffering policy would reverse
a deliberate decision to fix a problem that no longer exists.

## Consequences

- Planning cost is one enumeration of the touched folders plus one linear pass,
  instead of a restart per candidate.
- Convergence is structural. There is no iteration cap to exhaust and no
  `preconditionFailure` reachable from planning.
- An unreadable destination folder degrades to blocked entries, never to a planned
  overwrite. This is a new, tested safety property; the previous per-path probe
  treated an `lstat` failure as `.absent`.
- The coordinator stays responsive during a build, so attach-to-ready measures the
  work rather than the queue ahead of it.
- Enumeration reads whole folders, so a plan observes occupants no candidate asked
  about. That is what lets one read answer every suffix retry, and it is why foreign
  occupants need no separate bookkeeping.
- Reorganize plans the same way. It applies the import naming policy (`ImportNaming`),
  so its destinations cluster into the same small set of policy folders, and one
  enumeration answers every candidate. Its earlier per-candidate probe loop was
  dropped with the claim that its destinations were scattered; they never were.
- A folder a file makes impossible — the file holds the folder's own name or an
  ancestor's — is recorded as an occupied folder, not as an unreadable one. It is a
  fact about the library that waiting does not change, so its candidates are blocked
  (`destinationFolderOccupied`) instead of the build being retried forever.
