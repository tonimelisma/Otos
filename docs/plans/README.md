# Active Plans

Completed plans are removed after their implementation, documentation,
verification, and merge closure.

- [Plan 0115: Stacks — RAW+JPEG pairs and bursts as one photo](0115-stacks.md), opened
  2026-11-13 (ADR 0052).

Plan 0114 (On This Day and its story player) is complete in one increment and was removed
at closure. It opened 2026-11-09 from the survey
`docs/research/2026-11-07-memories-and-highlights.md`. Its decisions live in ADR 0049,
`docs/design/on-this-day.md`, DES-112 and APP-069 to APP-071; the layout research is
`docs/research/2026-11-09-on-this-day-layouts.md`. **Owner decisions.** On This Day is a
sidebar row under Places (chosen from a row, a strip above the grid, a menu command only,
and a row plus a strip); its pane is a grid of landscape photo cards, one per earlier year
(chosen from cards, story balls, a by-year feed, and a hero with smaller cards); a single
click on a card plays that year's story, an Immich-style player with segments, photos held
5 s and videos played to their end.

Plan 0111 (every duplicate group has a default) is complete in two increments and was
removed at closure. It opened 2026-11-01, when the owner compared Duplicates with Photos,
Lightroom Classic 15.4, Lightroom on the web, PhotoSweeper, Gemini 2 and Mylio and asked
for a default in every group. Its decisions live in ADR 0042 ("Every group has a default,
and no default loses work"), DES-107, APP-060 and APP-061. **Owner decisions.** Every group
has a default; a moved copy's curation and edit are carried onto the kept copy and undo
takes them back; only work that cannot be combined waits; same-photo groups keep the
camera original with the most pixels; across libraries each library keeps its own copy and
`Keep Only <Library>` names the one to keep; Keep Only This Copy; same-photo versions show
large thumbnails and `Compare` opens two side by side — in rows, not side by side in the
list, because the list's rows are the selection.

Plan 0110 (one freshness stamp per product) is
complete in one increment and was removed at closure. It opened 2026-10-31, when a card's
readiness was shown to wait on thumbnails and previews the import planner never reads,
and an imported RAW's card thumbnail was discarded at import. Its decisions live in ADR
0009 (metadata, rendering and digest each stamped by the bytes they were made from; a
claim makes every stale product from one read; an import settles products separately and
never waits for one), ADR 0018
(a card's metadata pass, then its rendering-and-digest pass), ADR 0035 (renderings, card
provisional thumbnails, import renders), ENR-007, ENR-013, ENR-016, ENR-017, ARC-053 and
ARC-057. Its measurements are `docs/research/2026-10-31-card-readiness-products.md`.
**Owner decisions.** Readiness waits on metadata only; thumbnails made before an import are
kept on the copy; an import never waits for a thumbnail — a card renders while it waits for
Import, and a copy still owing one is rendered first after it lands, while it is local; a
read made for one product makes every product the row owes, and a card, being local, may be
read in passes.

Plan 0109 (duplicates, card checksums, and Trash that can be put back) is complete across
six increments and was removed at closure. It opened 2026-10-31 from the design study
`docs/research/2026-10-31-duplicate-detection.md` and its two adversarial reviews.

**Decisions and where they live.**
- **Trash.** Kept rows while a file is in the Trash, Put Back after a relaunch, and the
  trash bar's Cancel: ADR 0022, ARC-058, DES-089.
- **Card digests.** Idle cards are checksummed behind their thumbnails, and the import
  verifies each staged copy against the card's digest: ADR 0018, ENR-013, ENR-017.
- **Import skips.** The import skips items a library holds by content, and Erase
  re-confirms each match: ADR 0018/0026, APP-032, `import-bar.md`.
- **Duplicates.** Identical copies with a safe-only keeper rule and per-pair Keep All
  memory: ADR 0042, APP-060, DES-107, the DES-052 deviation, `docs/design/duplicates.md`.
- **Same photo.** Versions of one photo, by stored-thumbnail render signatures and three
  burst gates: ADR 0042, APP-061, ENR-021.
- **MediaMetadata 0.9.0.** EXIF sub-seconds and Apple's burst identifier.

**Calibration.** The Vision feature print was rejected for a difference hash plus a 32 × 32
pixel difference: `docs/research/2026-10-31-duplicate-calibration.md`.

**Owner decisions.** Bursts are never duplicates, and Duplicates has no single-letter
shortcuts.

**Deliberately left out.**
- The bar's "N not checked yet" and "N to download" lines. APP-045 asks about a download
  at act time.
- Exclusion of `isUtility` screenshots. Same-photo groups are never preselected, so a
  wrong group costs a click, not a photo.

**Still open.** The staged-copy hash's cost against copy time is unmeasured, because no
card import ran during the plan. It stays inline until a measurement shows it limits
throughput.

Plan 0108 (editing, previews, hand-off and export) is complete across fourteen
increments and was removed at closure. It opened 2026-10-24 when the owner chose to edit
photos inside Otos: one current edit per photo in the catalog, no sidecars, originals
never modified, controls only from what macOS provides. Its decisions live in ADR 0008
and ENR-008 (macOS evicts uploaded, idle downloads; background downloads keep the 5 GB
floor), ADR 0013 and ARC-033 (removable sources forgotten after 90 days unseen), ADR 0034
(the move witness that re-attaches overlay after a rename or move outside Otos), ADR 0035
(RAW9 renders and stored HEIC previews), ADR 0036 and APP-046–APP-050 (edit recipes, the
edit panel's Crop, Light, Color, Effects, Detail and Optics, and video trim; DES-092,
DES-093, `docs/design/edit-panel.md`), ADR 0037 and APP-051 (hand-off as one full-size file
per photo, the owner's mixed-selection paste into a browser), and ADR 0038 and APP-052
(export; DES-094, DES-095). Its research is listed in those ADRs; experiment R2 (OneDrive
remote renames and moves) is in `docs/research/2026-10-25-cloud-drives.md`.

Plan 0106 (time is never a stand-in for a fact that can be known) is complete across
seven increments and was removed at closure. It opened 2026-10-05, after test waits with
wall-clock deadlines were shown to fail on load and to hide tests that asserted nothing.
Its rule and the six cases where time may appear live in ADR 0033 and AGENTS.md, and
`script/time-guard.sh` checks every wait in `Otos/`, `OtosTests/` and `script/` in the
fast gates and CI. Test waits wait on owner-reported facts with no deadline; the eject
drain waits on the work it drains; Otos's own Eject resumes a card on its reported
failure, and a refused unmount started elsewhere — which the system reports to no one
else — resumes after a documented limit; smoke selection follows published state; the
filesystem-event debounce and the enrichment apply timer became owner coalescing;
enrichment claims stopped expiring; File Provider arrival is the vnode's attribute
change, not a 250 ms poll. The cadences that remain stand on measurements in
`docs/research/2026-10-23-cadence-audit.md`, and the OS reports behind the rest are in
`docs/research/2026-10-23-removable-and-camera-state-reports.md` and
`docs/research/2026-10-23-materialization-arrival.md`. Camera catalog completeness has
no OS report, so its settle check stays time-based and gates only deletion proof.

Plan 0107 (owner state changes synchronously, and requests are never lost) is complete
across seven increments and was removed at closure. It opened 2026-10-05, when the hangs
plan 0106's deadline removals exposed traced to owners holding state across an `await`
rather than to slow machines. Its decisions live in ADR 0032 (seven rules: synchronous
state changes, a request is a revision counter, one doorbell loop per owner, an error is
not a fact, ordered intents, blocking work leaves the actor by a named mechanism,
deterministic interleaving tests), ARC-019 and ADR 0005 (`CatalogProjection` as one
revision-counted loop whose failed read publishes nothing), ARC-047 and ADRs 0017, 0019,
0021 and 0024 (`ImportSessionMachine`, with the coordinator as its shell; ordered import and
trash intents; per-run progress stream), ARC-058 and APP-040 (the audit's trash-queue and
preview-loader findings), and `docs/research/2026-10-23-actor-hold-during-blocking-work.md`
(the coordinator held 284–324 ms per plan build and the store up to 995 ms per subtree
rescan, before `@concurrent` and a detached walk). The same increment 2 changed behavior:
the window now follows a run into its batch once the batch's first item lands
(`import-bar.md`, APP-002). One lint rule landed
(`projection_catch_substitutes_value`); the matching rule for `@concurrent` on `Live*`
async functions was left out because a regex cannot tell an actor method from a
`nonisolated` one, and review carries it (AGENTS.md, Code Review lens A).

Plan 0104 (recoverable Move to Trash for cloud-only media, with undo) is complete
across four increments and was removed at closure. It opened 2026-10-04 when Move
to Trash failed for every cloud-only OneDrive item (`trashItem` refuses a dataless
placeholder, Cocoa 3328). Its decisions live in ENR-008 (the bounded `command`
materialization priority), ARC-058 (pending trash as a durable fact on the asset
row), APP-027 (the queue, the delete-immediately questions at a definitive download
failure or the 5 GB floor), APP-039 (trash on the undo stack), APP-045 and DES-090
(the over-100 MB download question and its setting), DES-089 and
`docs/design/trash-status-bar.md` (the trash status bar), DES-076, MED-001 and ADR
0022. Its research is `docs/research/trash-dataless-placeholders.md`.

Plan 0103 (Share, Open With, context menus, drag-out, curation undo, loupe zoom and
info, trash confirmation) is complete across eight increments A–H and was removed at
closure. It opened 2026-09-13 from an ideation pass on the macOS Share button and
"open in the default app". Its decisions live in APP-035 (Open / Open With, ⌘E, URLs
only), APP-036 (Share from toolbar, File menu and context menus, no shortcut), APP-037
(one context menu model, one AppKit renderer on grid, filmstrip, loupe and compare),
APP-038 and ADR 0028 (drag-out as file URLs; plain click on a selected tile commits on
mouse-up), APP-039 (curation undo from Store-reported priors; Trash stays on Finder's
Put Back, ADR 0022), APP-040 (loupe zoom as `NSScrollView` magnification with a
native-pixel document and a second full-resolution decode), APP-041 and DES-088 (the
read-only info overlay), and APP-027 (Move to Trash asks first; plain Delete unbound).
ADR 0012 was extended to Open and Share. Quick Look and Get Info were removed rather
than fixed; Show in Library, an F full-screen preview, a Move Disliked batch command
and export stay deferred. Native full screen needed no work: on 2026-09-14 the running
app's View menu, read through System Events, listed `Enter Full Screen` after Zoom Out,
supplied by AppKit for the resizable `Window` scene, and the Window menu carried `Full
Screen Tile`; no requirement row claims it because Otos implements none of it.

Plan 0102 (import to the disk floor, stopped outcomes, and terminal-state durability)
is complete across five increments and was removed at closure. It opened from a live
session where `Import 38 Items` drew its correct `The disk is full` verdict for 24 ms
before a speculative replan erased it, and a second click unmounted the bar for
8.3 s; on 2026-09-13 the owner decided that an import that cannot fit whole copies
up to a 5 GB floor and stops as a designed, resumable outcome. Its decisions live in
ADR 0027 (free space is measured only at the attempt: no precheck, no polling, a
per-entry floor with in-flight accounting, `ENOSPC` as backstop, a floor stop as a
Cancel-shaped outcome), APP-029 (batch identity and navigation are two facts; state
F's Stopped variant; the floor's rendering; a recorded failure outranks the re-plan),
ARC-047 (a run's outcome is a fact, not a phase; the executor never refuses for
space) and `docs/design/import-bar.md` (F · Stopped, J8, J9, G). Its research pass is
`docs/research/2026-09-09-destination-free-space-and-import-failure-recovery.md`.

Plan 0100 (camera import: prove naming from ranges, stage only what is imported) is complete
and was removed at closure. It opened from a live MTP session where a 991-item card staged in
full — 36.5 GB, ~45 minutes — before the Import button could appear, and ~73 GB was written
for one import. Its decisions live in ENR-011 (a device that answers ranged reads is not
staged at all; capability is measured per attach; a failed read is transient), APP-018
(staging cleared at three points, per-instance trees, proven containment before any delete),
ARC-047 (the session holds its last proven naming count across a rebuild), APP-029 and
DES-031 (the bar's track reports the progress of the stage it is in), and ADR 0018 (content
hashing follows byte locality, so `.deviceMTP` is hashed after import).

Plan 0101 shipped as `MediaMetadata` 0.4.1: a transport-independent byte source, a
three-outcome read contract, public read cost, `identify(source:)`, `CachingByteSource`, and
embedded preview descriptors. Its boundary rule — every change must be justifiable to a
second consumer who has never heard of Otos — lives in that package's `ARCHITECTURE.md`.

## Closed

Plan 0099 (honest import naming and plan stability) is complete across six
increments and was removed at closure. It opened from a card whose import bar
oscillated between "730 new items" and "Checking the card…", and found a
duplicate-creating defect already proven in the catalog: 23 hash-identical video
pairs, both copies written by Otos, in two import batches five minutes apart, each
pair named apart by exactly that video's duration. Its decisions live in ARC-046
(planning revisions split by role — namespace for both roles, naming for the source
only), ARC-057 and ADR 0026 (a naming fact is offered only once enrichment has
*looked*; a durable mtime is a proven fallback, never an assumed one), ARC-047 (a
refresh is not a first check — a published plan survives the rebuild replacing it),
ENR-011 (every offered device seed is staged, none discarded), and ENR-012 (a video
with no embedded date derives its wall from mtime less duration, which names the
file but never stamps it).

Its supervision findings live in `AGENTS.md` ("Supervising long checks") and in
`script/check.sh` plus `script/hooks/guard-long-checks.sh`, added after a verify run
deadlocked and ran 9 h 40 m unnoticed — the cause being long-lived tasks that held
their owner weakly but never exited when that upgrade failed.

Plan 0098 (verification integrity, naming facts, and typing the namespace lease)
is complete across seven increments and was removed at closure. It opened against
a `main` that had been red since at least `40261bf` with five failing tests, and
green was restored in increment 4. Its decisions live in ADR 0015 (constant log
subsystem, no gate hides another), ADR 0025 (normalization is not a per-volume
capability), and ADR 0026 (naming facts answer the naming question; one source
delete owner; the erase lease is scoped to the erase sweep).

Plan 0097 was implemented, verified, merged in PR 291, and removed after
documentation closure.

Plans 0085–0096 are complete and were removed when the implementation, structural
guards, behavioral proofs, and verification closure landed. 0092 (import screen
redesign and design-system adoption) and its spun-off 0093 (grid day headers,
DES-069/APP-030) are both fully landed. 0094 (the OtosKit framework, the unhosted
test bundle, and the in-memory `PreferenceStore`) is fully landed — see ADR 0023
and `docs/research/2026-08-16-unhosted-test-bundle-capability.md` for the decision
and its evidence. 0095 (honest import — MTP correctness, one writer per published
fact, app-wide design system) is fully landed across twelve increments; ADR 0024
(readiness gate and single presentation writer) carries its architectural
decisions forward. 0096 (path equality, settled naming, honest progress) landed
its implementation in `40261bf` and its decisions in ADR 0025 and ADR 0026; plan
0097 closed the remaining integration debt in PR 291.
