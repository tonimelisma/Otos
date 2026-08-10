# Plan 0071 — Import UX: one screen, four states

Follows `docs/research/2026-08-09-import-ux-benchmark.md`. That doc established what
seven comparable apps present and where Otos diverges. This plan records the owner's
decisions on that research and turns them into a target design.

## 1. Owner decisions captured (restate before relying on these)

1. **Four user-facing states**, not three: *Not ready → Ready to import → Importing →
   Done*. Rationale: enumeration-to-plan genuinely takes time, so "not ready" is a real
   condition the user must be able to see, not a transient to be hidden.
2. **"New media" is the vocabulary.** The `copy · preexisting · companion · blocked ·
   skipped packages` totals string goes away.
3. **The leaked invariant goes.** "Cleanup/eject withheld while blocked or
   skipped-package attention remains" is never shown as prose.
4. **Per-card decisions move next to the Import button — and Settings keeps them as
   defaults.** Changing a control for one card must **not** rewrite the default.
5. **The grid is the plan view.** The read-only `Details…` modal sheet goes away.
6. **No per-item selection** for now. Import stays all-or-nothing over the new media.
7. **Eager planning on attach stays**, deliberately, because MTP and slow cards make
   enumeration-plus-planning long enough that deferring it would be felt.
8. **Determinate progress with Cancel.**

## 2. What "blocked" means

`MediaOperationDisposition.blocked` has exactly three producers. All three mean the same
thing at the product level: **Otos refuses to author a destination path it cannot prove
is safe.** It is a refusal to guess, not an error.

### 2.1 `.noUsableDate` — `MediaTransferPlanner.swift:181`

The naming bundle has no date to name a folder or file from:
`hasUsableDate == captureWallCompact != nil || contentModifiedAt != nil`
(`MediaOperationModels.swift:69`). Both must be absent. Because blocking is evaluated per
**bundle** (RAW+JPEG plus companions grouped by stem), one undatable member blocks its
whole bundle.

In practice this is **rare** — filesystem mtime is almost always present, so this fires
mainly for files whose mtime is genuinely unreadable.

**Finding for the owner (real over-block).** The bundle is blocked *before* the policy is
consulted. Under `destinationFolderPolicy == .none` and `destinationNamePolicy ==
.original`, `folderPath` returns `""` (`:450`) and `baseFileName` returns the source stem
(`:465`) — the timestamp is never used. So a file that needs no date is still blocked for
not having one. The correct rule is: block only when the *selected policy* requires a
date. Fixing this is a small planner change with its own test, and it should land before
the UI work, because it changes what the user can be told.

### 2.2 `.filesystemObservationUnavailable(detail: "namespaceUnreadable")` — `:365-372`, `:278-293`

The destination folder could not be read, so the candidate path's freeness is unproven.
Rather than risk overwriting a file it cannot see, the planner blocks. This is the
Otos-specific one and it is correct behavior: on a cloud-synced destination, an
unreadable directory is a normal transient. It fires for the primary candidate and,
separately, for a sidecar/companion destination.

This is the blocked reason a user is most likely to actually meet, and it is
**transient** — the right response is almost always "try again in a moment."

### 2.3 `.filesystemObservationUnavailable(detail: "suffixExhausted")` — `:331-342`

All 10,000 suffix retries (`_001`…`_9999`) collided at the destination. Effectively
unreachable; it exists so the loop has no silent fallthrough.

### 2.4 Consequence today

Per ARC-047, any blocked entry withholds source deletion and auto-eject for the whole
import. That rule is right. What is wrong is that it is currently communicated as a
sentence of prose in a footer that is always visible, whether or not anything is blocked.

### 2.5 The same is true of "skipped packages"

`skippedPackageCount` counts filesystem **bundles** (`isPackage == true`) that the
scanner declined to descend into (`CatalogScanner.swift:355`). On a camera card this is
essentially always zero. It occupies permanent footer space for a condition that
approximately never occurs.

**Design conclusion for both:** blocked and skipped-package are **rare exceptions**, not
steady-state facts. Rare exceptions must not hold permanent real estate. They appear only
when their count is nonzero, in plain language, attached to the thing they affect.

## 3. The vision

### 3.1 One principle for the Settings split

> **Inline = what happens to this card. Settings = how my library is shaped.**

- **Inline (per-card, seeded from defaults, never written back):** destination library,
  *Delete files from the card after importing*, *Eject the card after importing*.
- **Settings → Import (defaults only):** the same two toggles as defaults, plus sidecar
  import, destination folder policy, and filename policy — because those describe the
  shape of the library, are answered once, and would be noise on every card.

This satisfies decision 4 exactly: the footer edits a per-source override struct seeded
from `ImportPreferences` at attach; `ImportPreferences` is written only from Settings.

### 3.2 The four states

The 11 internal `MediaOperationSourceState` cases stay — they are correct and the
coordinator needs them. They stop being published as prose. The mapping:

| User-facing | Internal cases | Footer shows |
|---|---|---|
| **Not ready** | `inventory`, `waitingForMetadata`, `planning`, `needsReplan`, `queuedForReadiness` | Determinate bar when a real ratio exists (`waitingForMetadata(done, total)`), else a spinner. One line: `Preparing 412 of 1,204 items`. Primary button disabled, titled `Import New Media`. |
| **Not ready — needs you** | `waitingForDestination` | No bar. The destination picker is the answer, so the line reads `Choose a destination library` and the picker is the only enabled control. |
| **Ready to import** | `ready` | `1,204 new items · 3.2 GB`. Primary button enabled: **`Import New Media`**. |
| **Importing** | `executing(progress)` | Determinate bar, `412 of 1,204 · 1.1 GB of 3.2 GB`. Primary button becomes **`Cancel`**. |
| **Done** | `completed` | `Imported 1,204 items · 3.2 GB`, plus `Show in Library` linking to the batch that already exists in the sidebar. |
| **Failed** | `failed`, `executionUnavailable` | Actionable sentence + `Try Again`. |

Six rows, four states: the two extra rows are a sub-state of *not ready* that is
actionable, and failure, which HIG requires be reportable.

`executionUnavailable` is not a fifth product state and must stop saying "execution lands
in a later update". It is reachable only for `.deviceMTP` when no camera-import capability
is present (`MediaOperationCoordinator.swift:255-264`) — a genuine capability gate. Its
copy becomes a capability sentence, not a build-status note.

### 3.3 The grid is the plan view

The card's media already renders in the grid. It becomes the plan view by adding badges
only — no selection semantics, no new engine, and no change to tile paint:

- **already in library** — a subdued check on the tile. This is the visual form of
  `skipPreexisting`, and it is why the button can say "New".
- **needs attention** — a badge on blocked tiles. Only these get a badge that draws.
- everything else — unbadged, i.e. new and importable.

Companions/sidecars are not grid items; they follow their primary silently. The word
"companion" leaves the UI entirely.

The `Details…` button and `ImportPlanOverlay` are deleted. HIG's objection was that a
macOS sheet is always modal and blocks the parent for what is a read-only inspection; the
stronger objection is that the sheet listed files the user was already looking at.

### 3.4 Exceptions surface only when they exist

When blocked count > 0, and only then, the footer's status line gains a trailing element:

> `3 items need attention`

as a button that scrolls the grid to the first badged tile. Choosing it reveals a plain
sentence per cause — `Otos couldn't read the destination folder for 3 items. This is
usually temporary.` / `3 items have no date, and the current folder naming needs one.`
No `file:line`, no `namespaceUnreadable`, no raw disposition kinds.

Same rule for skipped packages: shown only if nonzero, phrased as
`2 folders were skipped because macOS treats them as bundles.`

### 3.5 The destructive decision

`Delete files from the card after importing` is an inline checkbox defaulting from
Settings. Because deleting a card is un-undoable, HIG's rule about uncommon irreversible
actions applies even when deliberately chosen. The pattern, following Photos:

- The checkbox is the intent.
- At the end of a successful import, one alert: title
  `Delete 1,204 files from "CAMERA"?`, buttons **`Keep Files`** / **`Delete Files`**.
  Verbs, never `OK`. `Keep Files` is the safe default.
- If any entry is blocked, **the alert simply does not appear**, and the Done line reads
  `Imported 1,201 items · 3 need attention · files kept on the card.` That is the
  invariant from §2.4 stated as a consequence at the moment it matters, instead of as
  standing prose.

### 3.6 Progress and Cancel

Determinate, in the footer, same location in every state (HIG: consistent location, keep
it moving, describe succinctly). Cancel is safe by construction: copies are additive,
originals are read-only, and the journal owns settlement — a cancelled import leaves
already-copied files in place and the source untouched, which is exactly what the Done
line should then say.

**Explicit non-claim:** Otos does not verify destination bytes after copying. The
XXH3-128 digest carried through settlement is the *source* content hash reused as
overlay (`CatalogStoreImportJournal.swift:139-153`). The UI must therefore never say
"verified". Post-copy verification à la OffShoot is a separate, worthwhile idea and is
out of scope here.

### 3.7 Eager planning stays; one refinement

Decision 7 stands: plan on attach. The "not ready" state exists precisely so that eager
work is legible rather than hidden.

The refinement is a separation the 2026-08-01 field evidence supports: **planning does
not need content hashing.** Per ARC-046A the planner matches on size and mtime and
"ignores provenance and hashes". The measured card collapse in
`docs/research/2026-08-01-removable-import-and-grid-field-diagnosis.md` (0.005 MB/s on a
440 KB file, 101 s) was *enrichment* content hashing competing for the card, not planning.
So: keep eager planning, and keep enrichment content-hashing off removable sources until
a plan is ready. This makes eager planning faster, which is the whole point of doing it
eagerly.

## 4. What this deletes

- `ImportPlanOverlay.swift` and the `Details…` button.
- `ImportPlanFooter.totalsText` (the five-count string).
- `ImportPlanFooter.policyText` (the four-clause policy string, including the leaked
  invariant).
- `ImportPlanFooter.readinessText`'s 11 prose cases, replaced by a four-state mapping.
- `ImportPlanDetailReader` if nothing else consumes it — to be confirmed at implementation
  time, not assumed.

Net: the import surface loses two of its three text lines and one modal, and gains a
progress bar, two checkboxes, and a conditional attention affordance.

## 5. Stages

Each stage is independently shippable and independently verifiable.

- **Stage 1 — planner correctness.** Block on `.noUsableDate` only when the selected
  policy requires a date (§2.1). Test: undatable file + `.none`/`.original` policy plans a
  copy; same file + `.yearMonth` or `.captureDateTime` still blocks.
- **Stage 2 — four-state presentation.** Collapse the 11 cases to the §3.2 mapping behind
  a presentation type owned by the coordinator; add the determinate bar and Cancel.
  Internal states unchanged.
- **Stage 3 — per-card overrides.** Add the per-source override seeded from
  `ImportPreferences`; move the two toggles inline; prove in test that editing inline never
  writes `ImportPreferences`.
- **Stage 4 — grid badges, delete the sheet.** Already-in-library and needs-attention
  badges; delete `ImportPlanOverlay` and the totals/policy lines. Must not regress the
  no-blank-grid invariant — badges compose over tile content, never replace it.
- **Stage 5 — destructive alert + attention surface.** Completion-time delete alert; the
  conditional `N items need attention` affordance and its plain-language causes.
- **Stage 6 — enrichment/planning separation.** Hold removable-source content hashing
  until the source's plan is ready.

## 6. Non-goals

Tokens/variables in naming, secondary destinations, metadata templates, import presets,
per-item selection, post-copy byte verification, and any change to the compare-pair
meaning of grid selection (APP-021). The Lightroom 6.2 lesson applies throughout:
relocating a control is safe, deleting a capability someone depends on is not — and every
deletion listed in §4 removes *display*, not capability.

## 7. Open question

§3.3 assumes badges can be composed onto grid tiles without touching the thumbnail paint
path. If that is not true of the current AppKit tile, the badge layer needs its own design
before Stage 4, because the no-blank-grid invariant outranks this entire plan.
