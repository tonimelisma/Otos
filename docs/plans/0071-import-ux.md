# Plan 0071 — Import UX: one screen, four states

Follows `docs/research/2026-08-09-import-ux-benchmark.md`. That doc established what
seven comparable apps present and where Otos diverges. This plan records the owner's
decisions and turns them into a target design.

## 1. Owner decisions captured (restate before relying on these)

1. **Four user-facing states**: *Not ready → Ready to import → Importing → Done*, because
   enumeration-to-plan genuinely takes time.
2. **"New media" is the vocabulary.** The `copy · preexisting · companion · blocked ·
   skipped packages` totals string goes away.
3. **The leaked invariant goes.** "Cleanup/eject withheld while blocked…" is never prose.
4. **Per-card decisions inline; Settings keeps them as defaults.** Editing a control for
   one card must **not** rewrite the default, and must **not** affect another attached
   card's session.
5. **The grid is the plan view.** The read-only `Details…` modal sheet goes away.
6. **No per-item selection.** Import stays all-or-nothing over the new media.
7. **Eager planning on attach stays** — *and eager planning must cause no UI change.*
   Each removable source plans independently so its plan is ready the moment the user
   selects it. Attaching a card must not move the user.
8. **Determinate progress with Cancel.**
9. **Exactly one import runs at a time**, and a running import must not churn the plans of
   other attached-and-waiting sources.
10. **Destination is remembered per removable source**, listed in Settings alongside the
    other remembered-media facts, ordered by last use.
11. **There is no "choose a destination library" state.** A destination is always
    defaulted.
12. **Delete-after-import is a checkbox on the pre-import bar**, exactly like eject — not
    a completion-time alert.

## 2. What "blocked" means

`MediaOperationDisposition.blocked` has exactly three producers. All three mean one thing:
**Otos refuses to author a destination path it cannot prove is safe.** A refusal to guess,
not an error.

### 2.1 `.noUsableDate` — `MediaTransferPlanner.swift:181`

No date to name a folder or file from:
`hasUsableDate == captureWallCompact != nil || contentModifiedAt != nil`
(`MediaOperationModels.swift:69`). Both must be absent. Evaluated per **naming bundle**, so
one undatable member blocks its RAW+JPEG siblings. Rare in practice — mtime is nearly
always present.

**Finding (real over-block).** The bundle is blocked *before* the policy is consulted.
Under `destinationFolderPolicy == .none` and `destinationNamePolicy == .original`,
`folderPath` returns `""` (`:450`) and `baseFileName` returns the source stem (`:465`) —
the timestamp is never used, yet the bundle is still blocked. Correct rule: block only
when the selected policy requires a date. Stage 1.

### 2.2 `.filesystemObservationUnavailable("namespaceUnreadable")` — `:365`, `:278`

The destination folder could not be read, so the candidate path's freeness is unproven.
Rather than risk overwriting a file it cannot see, the planner blocks. Fires for the
primary candidate and, separately, for a sidecar destination. This is the one users will
actually meet, and on a cloud-synced destination it is **transient**.

### 2.3 `.filesystemObservationUnavailable("suffixExhausted")` — `:331`

All 10,000 suffix retries collided. Effectively unreachable; exists so the loop has no
silent fallthrough.

### 2.4 Consequence today

Per ARC-047 any blocked entry withholds source deletion and auto-eject for the whole
import. The rule is right; standing prose in an always-visible footer is not.

### 2.5 "Skipped packages" is the same shape

`skippedPackageCount` counts filesystem bundles (`isPackage == true`) the scanner declined
to descend (`CatalogScanner.swift:355`). On a camera card, essentially always zero.

**Design conclusion:** blocked and skipped-package are **rare exceptions**. Rare
exceptions get zero permanent real estate and surface only when nonzero.

## 3. Verified current behavior these decisions change

| # | Fact in the code today | Decision it collides with |
|---|---|---|
| a | `SidebarSelectionPolicy.selectionOnAttach` returns the attached source, so any card attach **switches the user's view** | 7 |
| b | `executing` is a `Set<LibraryRootPath>` — imports are single-owner **per source**, so two cards can import at once (`MediaOperationCoordinator.swift:44`) | 9 |
| c | On any occupancy change to a destination root, **every** source mapped to it is dirtied and rebuilt; the `!executing.contains` guard covers only the executing source (`:451-456`) | 9 |
| d | Destination mappings persist in `UserDefaults` keyed by **source path** (`:809-826`), so a card remounting at a different path loses its destination | 10 |
| e | Auto-map happens **only** when exactly one fixed library exists (`soleDestination`, `:467/:477`); otherwise `.waitingForDestination` (`:546`) | 11 |
| f | `importEnabled` requires `copyCount > 0 \|\| companionCopyCount > 0` (`ImportPlanFooter.swift:99`), so with zero new media the button is disabled | §5.6 |
| g | Delete-after-import **already deletes `.skipPreexisting` source files too** (`MediaImportExecutor.swift:308-319`, `:1125-1183`), and the UI never says so | §5.6 |

(c) is the churn predicted in decision 9, confirmed: Card A importing into Library L bumps
L's occupancy revision repeatedly, and Cards B and C mapped to L are dirtied and replanned
throughout A's import.

## 4. Research basis for the open questions

| Question | What the field does |
|---|---|
| Auto-navigate on attach? | Every app makes it a **preference**, none steals focus inside an already-open app: Photos `Open Photos for this device`; Image Capture `Connecting this camera opens:`; Photo Mechanic `On Mount of Camera Disk`. |
| Progress while preparing? | Photos, Lightroom and Capture One let the **thumbnail grid filling in** be the progress. HIG: prefer determinate, never fake a ratio, avoid vague labels, keep it moving. |
| Navigate to the result after import? | A three-position preference in both tools that have it. Photo Mechanic: open contact sheet as soon as some files land (default) / never / **open in background without stealing the active tab**. Capture One: open Recent Imports / notify only / stay put — and it keeps the **last ten** import collections. |
| One import at a time? | Photos reports "Another import session is in progress… try again when the current task is complete." |
| Showing already-imported items | Photos **groups the import screen into "Already Imported Photos" and "New Photos"**, rather than badging within one list. |
| Erase-card confirmation | Image Capture, Photo Mechanic and Capture One all use a **checkbox with no confirmation**; only Photos uses a completion alert. Decision 12 is the majority pattern. |

## 5. The vision

### 5.1 One principle for the Settings split

> **Inline = what happens to this card. Settings = how my library is shaped.**

- **Inline (per-source session override, seeded from defaults, never written back):**
  destination, *Delete files from the card after importing*, *Eject the card after
  importing*.
- **Settings → Import (defaults only):** the same two toggles as defaults, plus sidecar
  import, folder policy, filename policy.

Mechanically: the coordinator gains `sessionOptions: [LibraryRootPath: ImportSessionOptions]`,
seeded from `ImportPreferences` when a source first appears and discarded on detach.
Isolation between simultaneously attached cards is then structural, and
`ImportPreferences` is written only from Settings.

**Recommendation with rationale:** the override does **not** survive detach/reattach. The
destination is the sticky per-card fact; the destructive toggles are not. A card you erased
once should not silently re-arm erase the next time it is inserted.

### 5.2 Attach changes nothing on screen

`selectionOnAttach` stops returning a selection for removable sources. Attaching plans in
the background and the user stays exactly where they are. The affordance moves to the
sidebar row that already appears:

- indeterminate ring while preparing,
- `1,204 new` count when ready.

That is the payoff of decision 7 made visible without a jump.

**Open decision:** `defaultSelection` also prefers a connected card *at launch*. Launch
interrupts nothing, so keeping it is defensible; it is listed as a decision, not assumed.

### 5.3 Destination is always defaulted

`.waitingForDestination` is removed as a user-facing state. Resolution order:

1. this source's remembered destination,
2. else the most recently used destination across any source,
3. else the first fixed library.

Persistence moves from path-keyed to **device-identity-keyed** (`deviceIdentity` already
exists on `CatalogLibraryState`; see `CatalogWindowViewModel.swift:671`) with a path
fallback, so a card that remounts at `/Volumes/CAMERA 1` keeps its destination.

Settings → Removable Media already renders Name / Kind / Last Seen with
`RelativeDateText` (`SettingsView.swift:96-140`). It gains a **Destination** column and
sorts by Last Seen, newest first.

### 5.4 The four states

The 11 internal `MediaOperationSourceState` cases stay — they are correct and the
coordinator needs them. They stop being published as prose.

| User-facing | Internal cases | Footer |
|---|---|---|
| **Not ready** | `inventory`, `waitingForMetadata`, `planning`, `needsReplan`, `queuedForReadiness` | Determinate bar **only** where a true ratio exists (`waitingForMetadata(done, total)`) → `Preparing 412 of 1,204 items`. Otherwise a spinner and `Reading card…` — never a faked denominator. |
| **Ready to import** | `ready` | Count line (§5.6) + primary button. |
| **Importing** | `executing(progress)` | Bar lives with the batch (§5.7). |
| **Done** | `completed` | `Imported 1,204 items · 3.2 GB` + `Show in Library`. |
| **Failed** | `failed`, `executionUnavailable` | Actionable sentence + `Try Again`. |

`executionUnavailable` stops saying "execution lands in a later update". It is reachable
only for `.deviceMTP` with no camera-import capability
(`MediaOperationCoordinator.swift:255-264`) — a real capability gate deserving capability
copy.

**Answer to "should there be a progress indicator for not ready?"** Yes, in two places and
two forms: an indeterminate ring on the **sidebar row** (the only surface visible for a
card the user has not selected), and in the footer a determinate bar **only** when
`waitingForMetadata` supplies a real ratio. Because the grid is the plan view (decision 5),
tiles filling in already carry most of the signal, exactly as in Photos and Capture One.

### 5.5 The grid is the plan view

Badges only — no selection semantics, no new engine, no change to tile paint:

- **already in library** — subdued check. This is what makes "New" honest.
- **needs attention** — badge on blocked tiles.
- everything else — new and importable.

Companions are not grid items and follow their primary silently; the word leaves the UI.
`Details…` and `ImportPlanOverlay` are deleted.

### 5.6 Deletion made visible, and the zero-new case

Today the executor deletes `.skipPreexisting` source files as well as copied ones
(`MediaImportExecutor.swift:308-319`), so "import 12, clear all 212 off the card" is
already the behavior — and the UI says nothing about it. Worse, with zero new media the
button is disabled (`ImportPlanFooter.swift:99`), so the delete-only pass is unreachable.

**Options considered**

| | Approach | Cost | Verdict |
|---|---|---|---|
| A | Two verbs in the button: `Import 12 New · Delete 212 from Card` | none | Rejected — two verbs on one button |
| B | Count line states it; button keeps one verb | none | **Recommended** |
| C | Photos-style grouped sections, "New" above "Already imported" | high — grid ordering is `CatalogProjection`'s, and this fights the sort model | Rejected for now |

**Recommended (B).** The button title is a function of *(new count, delete enabled)*:

| new | delete | Button | Line beneath |
|---|---|---|---|
| >0 | off | `Import New Media` | `12 new · 3.2 GB` |
| >0 | on | `Import New Media` | `12 new · 3.2 GB · 212 already imported will be deleted from the card` |
| 0 | on | **`Delete 212 Files from Card`**, destructive style | `Nothing new to import` |
| 0 | off | disabled | `Nothing new to import` |

The zero-new case gets its own verb, which is both the owner's instinct and HIG's rule:
"A specific button title like 'Erase,' 'Convert,' 'Clear,' or 'Delete' helps people
understand the action they're taking." It is still **one intent** — `queueImport` on a plan
whose copy count is zero — so there is no second implementation path.

This is also the mitigation that replaces the completion alert rejected in decision 12:
confirmation by labeling. The deletion is named before the press, not after.

### 5.7 Where the import bar lives

Pressing Import is user-initiated, so following it is not focus theft — the thing decision
7 forbids is a **system**-initiated jump on attach. The two apps with a preference here
(Photo Mechanic, Capture One) both default to showing the result immediately, and both
offer a background/stay-put position.

**Recommended:** pressing Import switches the sidebar selection to that import's batch row
— the `Imports` section already exists (`SidebarView.swift:34`) — and the determinate
progress bar plus Cancel live in **that batch's** footer.

Consequences, which answer "how long and where does the bar stay":

- The bar belongs to the **batch**, not to the card, so it persists exactly as long as the
  batch row does. The card's footer is only ever the *pre-import* bar.
- Because exactly one import runs (decision 9), there is never more than one active bar.
- Selecting the card during its own import shows `Importing… — see [batch]`, not a second
  bar. One bar, one owner.
- Batch rows already persist after completion. Capture One's "last ten" is the precedent if
  a retention limit is wanted; **open decision**, since Otos keeps overlay for the life of
  the item and may simply keep every batch.

### 5.8 One import at a time, and no cross-plan churn

`executing` becomes a single optional source, not a set. A second Import press while one
runs is **queued, not dropped** — CLAUDE.md forbids a dropping buffer for constructive
commands without a rejection surface — and that source's footer reads
`Waiting for the current import to finish`.

For churn, the fix follows from single-flight. Today `:451-456` rebuilds every source
mapped to a destination whenever that destination's occupancy changes, guarding only the
executing source. Once exactly one import can run, every destination-occupancy change
*during* an import is import-caused, so the correct rule is the existing per-source rule
generalized: **while an import is executing, suppress destination-driven rebuilds for all
sources and coalesce them into one rebuild per affected source after settlement.** This is
ARC-046A's "self-caused occupancy changes defer to one post-execution rebuild" widened from
self to global, not new machinery.

Separately, N attached cards currently build plans concurrently, each reading the same
destination namespace. **Recommended:** serialize plan builds through one queue, with the
user's currently selected source jumped to the front. This is simpler than concurrent
builds, not an optimization of them.

### 5.9 Eager planning does not mean eager hashing

Planning needs no content hashes — ARC-046A matches size and mtime and "ignores provenance
and hashes". The card collapse measured in
`docs/research/2026-08-01-removable-import-and-grid-field-diagnosis.md` (0.005 MB/s on a
440 KB file, 101 s) was *enrichment* content hashing competing for the card. Keep eager
planning; hold removable-source content hashing until that source's plan is ready. Eager
planning then gets the card to itself, which is the point of doing it eagerly.

**Explicit non-claim:** Otos does not verify destination bytes. The XXH3-128 digest at
settlement is the *source* content hash reused as overlay
(`CatalogStoreImportJournal.swift:139-153`), so the UI must never say "verified".
Post-copy verification is a separate idea, out of scope.

## 6. What this deletes

`ImportPlanOverlay.swift` and the `Details…` button · `ImportPlanFooter.totalsText` ·
`ImportPlanFooter.policyText` · the 11 prose cases of `readinessText` · the
`.waitingForDestination` user-facing state · `ImportPlanDetailReader` if nothing else
consumes it (confirm at implementation time, do not assume).

Every deletion removes *display*, not capability — the Lightroom 6.2 lesson.

## 7. Stages

- **Stage 1 — planner correctness.** Block on `.noUsableDate` only when the selected policy
  needs a date (§2.1). Test: undatable file + `.none`/`.original` plans a copy; same file +
  `.yearMonth` or `.captureDateTime` still blocks.
- **Stage 2 — ownership.** Global single-flight import with a queued second press;
  suppress-and-coalesce destination-driven rebuilds during execution; serialize plan builds
  (§5.8).
- **Stage 3 — destination identity.** Device-identity-keyed persistence, the three-step
  default (§5.3), removal of `.waitingForDestination`, Destination column + Last Seen sort
  in Settings.
- **Stage 4 — four-state presentation.** Collapse the 11 cases behind a coordinator-owned
  presentation type; sidebar ring; determinate bar only where a ratio exists; Cancel.
- **Stage 5 — per-card session overrides.** `sessionOptions` seeded from `ImportPreferences`;
  the two toggles inline; test that inline edits never write the defaults and never affect
  a second attached card.
- **Stage 6 — grid badges, delete the sheet.** Already-in-library and needs-attention
  badges; delete `ImportPlanOverlay` and the totals/policy lines. Must not regress the
  no-blank-grid invariant — badges compose over tile content, never replace it.
- **Stage 7 — deletion visibility and the zero-new case.** The §5.6 button/line matrix.
- **Stage 8 — batch-owned progress.** Switch to the batch on Import; move the bar there
  (§5.7).
- **Stage 9 — enrichment/planning separation** (§5.9).

## 8. Non-goals

Tokens/variables in naming, secondary destinations, metadata templates, import presets,
per-item selection, post-copy byte verification, Photos-style grouped import sections, and
any change to the compare-pair meaning of grid selection (APP-021).

## 9. Open decisions for the owner

1. **Launch-time selection.** Keep `defaultSelection`'s preference for a connected card at
   launch (interrupts nothing), or drop it for consistency with §5.2?
2. **Batch retention.** Keep every import batch row forever, or cap it (Capture One keeps
   ten)?
3. **Session-override lifetime.** Recommended: discarded on detach, so erase never
   re-arms silently. Confirm.
4. **Grid badge composition.** §5.5 assumes badges compose onto tiles without touching the
   thumbnail paint path. If the AppKit tile cannot do that, the badge layer needs its own
   design before Stage 6 — the no-blank-grid invariant outranks this entire plan.
