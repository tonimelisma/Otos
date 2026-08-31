# Import Screen — Spec

The import experience: a removable source selected in the sidebar, its media in the
ordinary grid, and one status surface at the bottom of the content pane. Cites
`docs/design/design-system.md` by ID; rules are not restated.

Owner: `Otos/Views/ImportPlanFooter.swift`. Presentation source:
`MediaOperationSourcePresentation` (`Otos/Models/MediaOperationModels.swift`).
Grid is unchanged — a card renders exactly like a library (DES-065). Per-item
import selection is out of scope: import imports all new media.

Visual reference: `docs/design/mockups/Otos Import.dc.html`.

## Terminology

Platform names, used throughout so the spec and the code agree:

| Term | Means | Not |
| --- | --- | --- |
| **Pop-up button** | The destination control: a button showing the current value that opens a menu of mutually exclusive options. `Picker` with `.menu` style in SwiftUI, `NSPopUpButton` in AppKit. | "dropdown", "combo box", "select" |
| **Introductory label** | The static text beside a pop-up button naming what is being chosen. | a placeholder inside the control |
| **Checkbox** | A two-state per-run option. Per HIG, preferred over a button configured as a toggle. | "switch" — that is an iOS control |
| **Push button** | The action at the right of the bar. One is prominent (DES-052). | — |
| **Status surface** | The bar itself. | "footer", "toolbar" — a toolbar holds commands, not status (DES-040) |

## Destination control — recommendation

**Use a pop-up button with the introductory label `Copy into`.**

HIG's push-button guidance says to avoid introductory labels, because a push
button's title already describes its effect. That guidance does not transfer to
pop-up buttons, where HIG asks the opposite: give people a way to predict the
options without opening the menu, using an introductory label or a button label
describing the effect. A bare "Summer Photos" satisfies neither — it names the
current value but never tells you the menu holds *libraries*.

Against the alternatives, and against how the category words it:

| Label | Case for | Case against |
| --- | --- | --- |
| **`Copy into`** ✅ | Names the operation and the direction. Matches the app's actual guarantee — originals are read-only, this is a copy, nothing moves. Predicts the menu: things you can copy into are libraries. | Slightly longer than a noun. |
| `Destination` | Photo Mechanic and Capture One both use a destination noun (`Primary Destination`, `Import To`). | It is the planner's word, and it predicts a *path*, not a library (DES-035). Image Capture's `Import To` genuinely does pick any Finder folder; Otos's does not. |
| `Import into` | Echoes the button. | Duplicates the verb already on the primary button two zones away. |
| `Add to` | Photos-like. | Otos does not "add" — it copies bytes into a library folder on disk. |
| No label | Least chrome. | Fails the pop-up button guidance above. |

Menu contents: available libraries, and nothing else — no `Choose…` placeholder, no
separator, no folder picker. Today's `Choose…` item is removed with the placeholder
it represents.

**The destination is remembered per removable source, defaulting to the first
available library on first sight of that source.** "First" is the first row under
**Libraries** in the sidebar, in the user's own order (below). A source seen
before — reattached, or re-inserted after ejection — resumes wherever it last
landed, whether that was an explicit pop-up pick or a default still tracking the
first library. Only a source Otos has never seen, or whose remembered library is no
longer available, falls back to first-available and starts tracking it.

Changing the pop-up applies to the attached session — the choice must survive from
the moment it is made until that run finishes, same as before — and now also
survives detachment: re-inserting the same card resumes at that destination rather
than resetting to the first library. A destination that is still a tracked default
(never explicitly picked) keeps following reorders and reattachments alike; making
an explicit pick is what makes the memory sticky against those.

No device-identity heuristic and no last-used-anywhere heuristic: the remembered
value is keyed on the removable source's own path (`destinationBySource` in
`MediaOperationCoordinator.swift`), read back on every new attachment instead of
being unconditionally overwritten with `fixedAvailable.first`.

When no library is available to choose, see state **B**.

### Library order is user-owned

Making the first library decisive is only honest if the user controls which library
is first, so order stops being derived and becomes a stored property of the root:

- **Persisted** as a `sort_index` column on `library_root`, backfilled on migration
  in the current display order so nothing moves on upgrade; a newly added library
  appends last. The catalog owns root identity, so the order lives on the root row —
  never in a parallel list in preferences, which would drift on removal.
- **Ordered by the user** in Settings → Libraries: drag to reorder, plus `Move Up` /
  `Move Down` in the row's context menu and `⌘↑` / `⌘↓`, because drag alone is not
  completable from the keyboard (DES-080). All three call one `moveLibrary(from:to:)`
  intent.
- **Shown in that order in the sidebar**, so "the first library" is a fact the user
  can see without opening Settings. `CatalogWindowPolicy.sortLibraries` stops sorting
  library roots and preserves stored order; removable sources keep their own rule.
- **Consequence, deliberate:** reordering changes the default destination, so a card
  attached at the time re-plans against the new first library and its counts change.
  This is the same re-plan the pop-up already triggers (J5 step 3), reached from
  Settings instead of from the bar.

Settings has no screen spec yet; only this ordering behavior is specified here,
because the import destination depends on it.

## Preparing state — recommendation

**L1 `Checking the card…` · L3 `112 of 181 items`.**

HIG's progress guidance is the constraint: prefer determinate; keep the indicator
moving; show a description only when it adds context; be accurate and succinct;
avoid vague terms like *loading* because they seldom add value. Accessibility adds
one more: this string is announced by VoiceOver on entry (DES-083), so it should be
short and should not repeat what the next line says.

| Candidate | Assessment |
| --- | --- |
| **`Checking the card…`** ✅ | Accurate — the app is checking what is on the card and what is already in the library. Succinct, three words, announces cleanly. Names the object, so it reads correctly when the same pattern is reused for a folder or a camera. |
| `Looking through the card…` | Friendlier, but a word longer, and "looking through" implies browsing rather than comparing. |
| `Reading the card…` | Accurate but ambiguous with copying — a user watching a card light blink cannot tell "reading" from "importing". |
| `Preparing…` | The vague-term failure HIG names. Says nothing the spinner doesn't. |
| Today's `Inventory…` / `Planning…` / `Waiting for metadata` | Planner vocabulary (DES-035); `Source changed — replanning…` reports our internal churn as if it were the user's problem. |

L3 carries the honest denominator when one exists — `112 of 181 items`, not
`Checked 112 of 181 items`, because L1 already supplied the verb. Where no honest
denominator exists yet, L3 is omitted entirely rather than showing a moving total
(DES-030, "honest numbers, or none").

## Number formatting

| Range | Shown as | Example |
| --- | --- | --- |
| < 1 MB | whole KB | `840 KB` |
| 1–99 MB | whole MB, no decimal | `68 MB` |
| ≥ 100 MB | GB with one decimal | `0.5 GB`, `4.2 GB` |
| ≥ 100 GB | whole GB | `128 GB` |

A decimal place on a megabyte figure is precision the user cannot act on, and it
makes the number wider than the fact deserves. Item counts are always exact and
never abbreviated. Both figures are tabular (DES-005).

## Layout

One surface, fixed height across every state (DES-018, DES-053), `padding: 12 16`,
column gap 28:

```
┌──────────────────────────────────┬─────────────────────────────────┬────────────────────┐
│ L1  42 new items · 68 MB         │ Copy into   [Summer Photos ⌄]    │  ┌──────────────┐  │
│ L3  139 already in Summer Photos  │ Afterwards  ☑ Eject  ☐ Erase    │  │  Import 42…  │  │
└──────────────────────────────────┴─────────────────────────────────┴────────────────────┘
      what                              choices                            the act
```

The divider between *what* and *choices* is the hairline; the divider before *the
act* is drawn only here, to mark the zone.

- **What** — L1 over L3, left-aligned.
- **Choices** — behind a `.5 pt` hairline, `padding-left: 12`. Two rows, `.callout`
  introductory labels in a fixed 66 pt column (DES-016), controls at 22 pt.
  Row 1: destination pop-up button. Row 2: `Eject the card`, `Erase the card`.
- **The act** — one prominent 30 pt push button, Return default (DES-052).

Both checkboxes take their initial value from the Settings → Import preferences
each time the surface appears for a source; changing one applies to this run only
and does not rewrite the preference (DES-027A).

## State inventory

`MediaOperationSourceState` has ten cases, plus the conditions that cross them. The
right column is the answer to "which need UI specs" — seven do; the rest fold into
one of those seven.

| # | Internal state / condition | User-facing state | Own UI spec? |
| --- | --- | --- | --- |
| 1 | `inventory`, `planning`, `waitingForMetadata` — **only before this attachment has ever produced a plan** | **A · Preparing** | ✅ |
| 2 | `session.destination == nil` — reachable only when no library is available to choose | **B · No destination** | ✅ actionable, so distinct |
| 3 | `ready` with new items | **C · Ready** | ✅ |
| 4 | `ready`, `copyCount == 0`, `skipCount > 0` | C, nothing-new variant | folds into C |
| 5 | `ready`, source empty | C, empty-card variant | folds into C |
| 6 | `ready` or `executionUnavailable` with attention items | **D · Ready, needs attention** | ✅ badge + reveal |
| 7 | `queuedForReadiness` | A, with the button in its queued disabled form | folds into A |
| 8 | `executing` | **E · Working** | ✅ |
| 9 | cancel requested, still winding down | E, cancelling variant | folds into E |
| 10 | `completed`, clean | **F · Done** | ✅ |
| 11 | `completed` with failures or skips | F, incomplete variant — no auto-dismiss | folds into F |
| 12 | `failed` | **G · Failed** | ✅ actionable |
| 13 | `executionUnavailable` | treated as C or D by its totals; the build condition is never shown (DES-039) | no |
| 14 | No libraries configured at all | B, with `Add a Library…` opening Settings instead of a pop-up | folds into B |
| 15 | Card removed or destination lost mid-import | G, with the cause named | folds into G |
| 16 | Camera still enumerating | Grid-level device banner, not the bar | separate, grid spec |

So: **seven bar states to draw** — A, B, C (+2 variants), D, E (+1), F (+1), G.

### A · Preparing

**A means Otos cannot yet describe what is on this card.** That is true before any
plan has been proved, and again whenever naming facts are pending — enrichment has
not read some file, so its count is not knowable. It is *not* true of a re-plan: a
rebuild over an already-proven set keeps showing the plan it is replacing (state C)
until the newer one lands, because the old answer stays true until the new one
arrives. Drawing A on every rebuild reported internal churn
as though it were the user's problem — the exact failure DES-035 names — and on an
enriching cloud destination it did so about once a second, each cycle ending in the
identical count.

**A is a state the user watches, not a flash.** This was written as though it were
momentary, and on a card it nearly is. On a camera it is not: reading a capture date from
every item took **263 seconds** for a 991-item card when measured, because each read is a
round trip and ImageCaptureCore serialises them. (An earlier estimate of ~90 s was
extrapolated from per-file timings and was optimistic by about 2.8x.) That is 29× better than the 45 minutes it
cost when the card had to be transferred first, and still long enough that everything below
about the count is load-bearing rather than cosmetic — the count must not blank, the track
must not fall back to indeterminate, and the numbers must describe the work actually
happening. A user who watches a bar for ninety seconds notices every one of those.

The figure is arithmetic over per-file measurements, not a timed run; a run with a camera
attached is what would confirm it.

L1 `Checking the card…` · L3 `112 of 181 items`. Middle: a **determinate** bar
driven by that same count — HIG prefers determinate wherever a real total exists,
and once enumeration has finished the total is real. It is indeterminate only
during enumeration itself, before any honest total exists, and L3 is then omitted
(DES-030, DES-032). The destination and checkboxes stay visible and usable; choosing
while we check costs nothing. Action: `Import` — visible, disabled (DES-053).

### B · No destination

Not a normal state: the first available library is auto-selected, so a user with a
library never sees this. It survives only for the case where **no libraries exist
at all** — L1 `Otos needs a library to copy into` · L3 `181 items on CAMERA`, middle
zone holds a single `Add a Library…` push button opening Settings → Libraries, and
the primary action stays `Import`, disabled.

### C · Ready

L1 `42 new items · 68 MB` · L3 `139 already in Summer Photos`, omitted at zero.
Action: `Import 42 Items` — count and scope in the title (DES-036).

- **Nothing new:** L1 `Nothing new on this card` · L3 `All 181 items are already in
  Summer Photos` · action `Eject Card`. The choices zone stays fully present: the
  destination pop-up is *what that sentence is measured against*, and changing it
  re-plans against a different library, which can make the same card full of new
  items again. Checking `Erase the card` here turns the primary button into
  `Erase 181 Items` — an erase-only run, which the coordinator already supports
  (`beginExecutionIfPossible` stays Ready on a zero-copy plan unless delete is
  requested).
- **Empty card:** L1 `This card is empty` · L3 omitted · action `Eject Card`. This is
  the one state where the choices zone is omitted: there is nothing to copy and
  nothing to compare, so its subject does not exist (DES-053 exception).
- **Erase checked:** no change to the copy. The checkbox says `Erase the card` and
  the user has just read it; restating it as a consequence line is the kind of prose
  DES-038 exists to prevent. The confirmation happens where it matters — at the point
  of an erase-only run, below.

### D · Ready, needs attention

Causes currently drawn here: items with no usable date, destination names Otos could
not check, and items whose bytes could not be read — the last of which cannot be
copied either, so blocking and showing it is the only honest outcome; retrying it
forever would hide a failing card behind a bar that never settles.

L1 `39 new items · 61 MB` · L3 ⚠ `3 items have no date · Show them`. The orange
badge carries a glyph, never colour alone (DES-029). `Show them` selects and scrolls
the affected tiles in the grid — the grid is the plan view; there is no modal list
(DES-041). Action: `Import 39 Items`. `Erase the card` is disabled while attention
remains, with the tooltip `Some items still need attention.` (DES-038).

**The clause must name the real cause.** `blocked` is not one condition, and none of
its causes is "can't be read" — an earlier draft said so, and it was a fabricated
diagnosis (`MediaOperationBlockReason`, `MediaOperationModels.swift:109`):

| Cause | Clause | Why |
| --- | --- | --- |
| `noUsableDate` | `3 items have no date` | The file reads fine. It carries no capture date and no modification date, so Otos cannot choose a dated folder for it. |
| `filesystemObservationUnavailable` | `Otos couldn't check 3 names in Summer Photos` | A destination problem, not a source one: Otos could not determine whether the destination name was free. |
| More than one cause present | `3 items need attention` | DES-034 allows one clause; a mixed set names no single cause honestly. |

`Show them` therefore needs the affected items' identities, not a count.
`MediaOperationPlanTotals` carries counts only, so the presentation gains the
blocked entries' `MediaAssetID`s and the ViewModel selects and scrolls them through
the existing grid selection intent.

### E · Working

L1 `Importing 12 of 42` · L3 `19 MB of 68 MB · about 40 seconds left`. Middle:
determinate bar exposing real value and total, with `Into Summer Photos · the card
ejects when it's done` beneath at L3. Action: `Cancel`, no confirmation (DES-032).

- **Cancelling:** L1 `Stopping…` · L3 `Finishing the current item`; the bar stays
  determinate and moving; action disabled. Resolves to F with the honest count.

### F · Done

Done is **not terminal**, and it is **not two states**. `MediaOperationCoordinator`
marks the session dirty after settlement and rebuilds the plan, so a card left in the
reader returns to a zero-copy plan. The bar reflects that plan.

There is one post-import state, and the thing that varies is **whether the card still
exists** — a fact about the world, not about where the user is standing. Both the
removable row and the import batch row are views onto the same operation, so both show
the same bar. Keying the wording to the selected row would make one finished import say
two different things depending on which row was clicked, which is the duplication
DES-040 exists to prevent.

**F · card still attached.** L1 ✓ `Everything on this card is imported` · L3
`42 copied just now · 181 items in Summer Photos`. Choices present. Primary
**`Eject Card`** — the one remaining useful act — with `Show These Items` as a
secondary text button to its left. Identical on `.library(card)` and on
`.importBatch(new)`. Never auto-dismisses: the card is still there and still has
actions attached to it.

**F · card gone** (eject ran, or the card was pulled). There is no card to talk about,
so the sentence is about the result instead: L1 ✓ `42 items copied and verified` · L3
`In Summer Photos · card ejected — safe to remove`, primary `Show These Items`, and the
choices zone is omitted — its subject no longer exists (DES-053 exception). Auto-dismisses
after 6 s on a fully clean run. The bar can only be seen from `.importBatch(new)`, since
the removable row is gone.

Two properties keep the attached case honest rather than a stale banner: it is produced
by the re-plan, so a card that gains a file returns to **C** with `1 new item`; and the
`copied just now` clause is scoped to this attachment, so re-inserting the card later
gives C's ordinary nothing-new wording, no import having happened in that session.

**Erase-only run.** Reached by checking `Erase the card` in attached-F, or from a card
that was already fully imported. Deletion with no copies is the one uncommon,
un-undoable destructive action on this screen, and HIG asks for an alert. The primary
button becomes `Erase 181 Items`, and pressing it presents:

> **Erase CAMERA?**
> 181 items will be deleted from the card. All of them are already in Summer Photos.
> [ Cancel ]  [ **Erase** ]

The second sentence is a claim about every item on the card, so it is stated only
when the plan proves it — every item a skip, nothing blocked, nothing skipped as
foreign. Otherwise it is omitted and the alert carries the count alone; Otos does
not tell the user their files are safe elsewhere unless it knows.

Verbs, not OK (DES-036); `Erase` is destructive-styled because the count is the new
information — the user is confirming a number they have not previously seen. On success:
L1 ✓ `Card erased · 181 items deleted` · primary `Eject Card`.

**Dismissal:** auto-dismiss after 6 s only when the card is gone *and* the run completed
fully with no failures, no skips and no attention items. Otherwise the bar persists,
because it is the only place the exception is reported:

### G · Failed

L1 `Couldn't finish the import` · L3 one clause naming the cause and what to do:
`The card was removed` / `Summer Photos isn't available` / `The disk is full`.
Action: `Try Again`. Never auto-dismisses. Nothing already copied is lost, and the
count copied so far is stated when nonzero.

**This state cannot be built on today's failure value.** `failed(problem: String)`
carries raw internal tokens — `executionUnavailable`, `noDestinationLibrary`,
`snapshotUnavailable`, `insufficientSpace`, `namespaceLeaseUnavailable`,
`notAnImportPlan`, and `String(describing: error)` for anything else
(`MediaOperationCoordinator.swift:340,489,780,812,855`;
`MediaImportExecutor.swift:137,152,169`) — and the footer prints them verbatim as
`Failed: <problem>`, which is exactly the published-internal-vocabulary failure
DES-035 and DES-039 forbid. A `String` also cannot be mapped to a clause without
matching on its spelling, which is the stringly-typed smell.

`problem` becomes a typed reason whose cases are the causes the user can act on —
at minimum source removed, destination unavailable, and out of space — with one
case reserved for the unexpected, whose clause names no cause and whose detail goes
to the log rather than the bar. Two of the three clauses above have no producer
today: nothing fails with "card removed" (pulling a card removes the session and the
row instead) and nothing fails with "destination unavailable" mid-execution. Those
producers are part of the work, not an assumption.

## What the presentation must carry

The bar is passive: it renders what it is handed and calls intents (`AGENTS.md` →
Architecture Standards). Today's `ImportPlanFooter` breaks that — it derives every
string in the view, from `readinessText` down. The rewrite moves that derivation to
one pure, testable mapper from presentation to drawn state, which means the
presentation has to carry the facts the states need. It currently carries four:
`sourcePath`, `destinationPath`, `state`, `attachToReadyMs`
(`MediaOperationModels.swift:201`).

| State | Fact needed | Present today? |
| --- | --- | --- |
| C, D, F | Destination library **display name** | No — only `destinationPath`. The view has `fixedLibraries` and could map it, but then the sentence is assembled in two places. |
| D | Blocked entries' **asset IDs** and their **reason** | No — `MediaOperationPlanTotals` is five counts. |
| E | **Remaining time** | No — `MediaOperationProgress` has counts and bytes, no time base. Needs bytes-over-elapsed for this run (DES-032), omitted until meaningful. |
| E, F | **Batch ID** | No. See *Where the user is standing*. |
| F | Whether the **card still exists** | Derivable: the source's row is present in `removableSources`. State the owner explicitly rather than letting the view guess. |
| F | Count **copied just now**, scoped to this attachment | Partly — `completed` carries a summary, but "this attachment" needs the attachment generation the coordinator already tracks. |
| F, G | Whether the run was **fully clean** (auto-dismiss gate) | Partly — `completed` carries `skippedForeignCount` and `failedCount`; blocked and attention items must join them. |
| G | Typed **failure reason** | No — `failed(problem: String)`. See state G. |

Nothing here is a new subsystem: each is a fact the coordinator already knows and
does not publish. Add them to the presentation rather than letting the view re-derive
them, or the "one owner per fact" rule is lost at the last hop.

## Where the user is standing

Sidebar selection is `SidebarSelection` (`Otos/Models/CatalogModels.swift:578`):

| Case | Sidebar row | Note |
| --- | --- | --- |
| `.allMedia` | **All Media** | default on launch |
| `.library(LibraryRootPath)` | a **Libraries** row *or* a **Removable** row | the same case for both — a card is a root whose `RootKind` is `.removableVolume` (`CatalogModels.swift:229`) |
| `.importBatch(ImportBatchID)` | an **Imports** row | last five shown; the selected batch is kept visible even when older (`SidebarView.swift:144`) |
| `.allImports` | **All Imports…** | appears once there are more than five batches; shows a batch list, not a grid (`ContentView.swift:34`) |

Two consequences that shape the journeys:

- **A card and a library are the same kind of selection.** So the import bar is not a
  mode; it is what the content pane shows when the selected root happens to be
  removable. Nothing about the grid changes (DES-065).
- **The batch row cannot pre-exist the import.** The real `ImportBatchID()` is minted
  inside `MediaImportExecutor` when execution starts
  (`MediaImportExecutor.swift:141`), and the row appears in the sidebar only once
  assets are journaled against it. So "select the new batch" is possible at execution
  start, but the row is empty for the first moment and fills as items land.
- **Do not read the batch ID off the plan.** `MediaTransferPlanner.swift:77` mints a
  second, throwaway `ImportBatchID()` into `plan.mode` on *every* plan build. It is
  not the batch the assets land in, it changes on every re-plan, and using it would
  select a row that never exists.

**Required change.** Today nothing moves the selection on import: the user presses
Import and stays on `.library(card)`. The intended behaviour — the view follows the
work to the new batch — needs `selectSidebar(.importBatch(batchID))` called once,
at execution start.

**Carry the batch ID as state, not as an event.** The obvious implementation — watch
the presentation stream for the moment a source turns `executing` and move the
selection then — is wrong here. `presentationsStream()` uses
`.bufferingNewest(1)` (`MediaOperationCoordinator.swift:138`), so intermediate frames
are dropped by design: a fast import can deliver `ready` and then `completed` with
the `executing` frame never observed, and the selection would silently never move.
Instead `MediaOperationSourcePresentation` gains the batch ID, present on every frame
from execution start onward. The ViewModel then acts on the *value* it sees rather
than on a transition it must not miss, and keeps the set of batch IDs it has already
auto-selected so that repeated frames are idempotent. Two rules go with it:

1. **Only if the user has not moved.** If they navigated away between pressing Import
   and the batch existing, leave them where they are (DES-040 gives them the sidebar
   indicator instead).
2. **Never move them twice.** No selection change at completion, at re-plan, or on
   eject. The one exception is forced, not chosen: when a selected batch disappears the
   policy already invalidates the selection and falls back (`CatalogWindowPolicy.swift:64`,
   `CatalogWindowViewModel.swift:734`).

## Journeys

Step by step. **Where** is the sidebar selection at that step; **bar** is the status
surface at the bottom of the content pane. Every state transition is driven by the
coordinator's plan, never by a remembered UI flag.

### J1 · The ordinary import, eject on (the default path)

| # | Where | Bar | What happens |
| --- | --- | --- | --- |
| 1 | `.library(card)` — auto-selected on attach | slides up, 24 pt + fade | Card appears under **Removable** |
| 2 | `.library(card)` | **A** `Checking the card…`, indeterminate, L3 empty | Enumerating; no honest total yet |
| 3 | `.library(card)` | **A** + `112 of 181 items`, determinate | Total is now real |
| 4 | `.library(card)` | **C** `42 new items · 68 MB` / `139 already in Summer Photos` | `Copy into: Summer Photos`, eject checked from preference. Primary `Import 42 Items` |
| 5 | → `.importBatch(new)` | **E**, travels with the operation | Import pressed; `ImportBatchID()` minted, batch row appears and the view follows it |
| 6 | `.importBatch(new)` | **E** `Importing 12 of 42` / `19 MB of 68 MB · about 40 seconds left` | Grid fills in as items land. The card's own row shows nothing — the bar owns status |
| 7 | `.importBatch(new)` | **F, card gone** ✓ `42 items copied and verified` / `In Summer Photos · card ejected — safe to remove` | Verified, then ejected. No card to talk about, so the sentence is about the result; choices omitted |
| 8 | `.importBatch(new)` | bar slides away after 6 s | Batch stays selected; the user is looking at exactly what they just imported |

### J2 · The same import, eject unchecked

Steps 1–6 as J1, then:

| # | Where | Bar | What happens |
| --- | --- | --- | --- |
| 7 | `.importBatch(new)` | — | Copy settles and verifies. No eject, so the card is still attached and still in the sidebar |
| 8 | `.importBatch(new)` | **F, card attached** ✓ `Everything on this card is imported` / `42 copied just now · 181 items in Summer Photos` | Re-plan lands; every item is now a skip. Choices present. Primary **`Eject Card`**, `Show These Items` secondary. No auto-dismiss |
| 9 | → `.library(card)` if the user clicks the card | **the same bar, unchanged** | Both rows are views onto the same operation, so neither the wording nor the buttons change |
| 10 | either row | bar leaves with the card | `Eject Card` pressed |

**F is a property of the plan, not of the vantage point.** The bar shows the attached
wording whenever the selected root — or the batch's source — has a zero-copy plan and
this session imported from it. Clicking between the card row and the batch row changes
nothing. Unplug and re-insert and you get C's ordinary nothing-new wording, because no
import happened in that session.

### J3 · Erasing after the import (idempotence)

Where: either row — the bar is the same on both. The steps below read as `.library(card)`
for concreteness only.

1. From **F**, user checks `Erase the card`. Per-run only; the Settings preference is untouched.
2. Plan rebuilt: zero to copy, 181 to delete. `beginExecutionIfPossible` permits this — it stays Ready on a zero-copy plan *unless* delete is requested, which it now is.
3. **F, erase-armed** — same two lines, primary `Erase 181 Items`.
4. Pressed. Deletion with no copying is the one uncommon, un-undoable act here and the count is new information, so an alert confirms: **Erase CAMERA?** / `181 items will be deleted from the card. All of them are already in Summer Photos.` / [Cancel] [**Erase**].
5. Confirmed: ✓ `Card erased · 181 items deleted`, primary `Eject Card`. Selection does not move — the batch is untouched by this.
6. Unchecking before step 4 re-plans back to plain **F**.

### J4 · A card that gains files while attached

Where: `.library(card)`.

1. From **F**, the camera writes one more frame. The watcher fires; the session re-plans.
2. **C** — `1 new item · 4 MB` / `181 already in Summer Photos`, primary `Import 1 Item`.
3. Importing it mints a *second* batch and moves the selection there, exactly as J1 step 5.

This is why F is derived rather than remembered: nothing has to expire.

### J5 · A card with nothing new

Where: `.library(card)` throughout; no batch is created, so the selection never moves.

1. Steps 1–3 of J1.
2. **C, nothing-new** — `Nothing new on this card` / `All 181 items are already in Summer Photos`, primary `Eject Card`.
3. The choices zone stays fully present: the destination pop-up is *what that sentence is measured against*. Switching it to Camera Roll re-plans, and the same card can immediately read `181 new items` against a library that has never seen it.
4. Checking `Erase the card` goes to J3's erase-only run with no import having happened.

### J6 · An empty card

Where: `.library(card)`. **C, empty** — `This card is empty`, primary `Eject Card`.
The only state whose choices zone is omitted: nothing to copy, nothing to compare, so
the controls' subject does not exist (DES-053 exception).

### J7 · Items that need attention

1. `.library(card)` — **D** `39 new items · 61 MB` / ⚠ `3 items can't be read · Show them`, primary `Import 39 Items`. `Erase the card` disabled, tooltip `Some items still need attention.` — the invariant lives on the control it blocks, not in a status line.
2. `Show them` selects and scrolls those tiles **in place**, on `.library(card)`. The grid is the plan view; there is no modal list, and the selection does not move.
3. Import proceeds on the 39; selection moves to the new batch as in J1.
4. Eject was withheld while attention remains, so the card survives: the bar settles into **F, card attached** reporting `39 copied just now` — on either row.

### J8 · Cancelling

Where: `.importBatch(new)` — the user is on the batch when they cancel.

1. `Cancel` (or Escape). No confirmation: copies are additive, originals read-only.
2. **E, cancelling** — `Stopping…` / `Finishing the current item`. Indicator stays determinate and moving; button disabled.
3. **F, cancelled** — `Stopped — 12 items copied` / `They're in Summer Photos`, primary `Show These Items`. Never auto-dismisses. The partial batch remains a real batch in the sidebar.
4. Back on `.library(card)`, the re-plan shows **C** with the remaining 30. Pressing Import creates a *second* batch. Nothing is duplicated.

### J9 · A failure mid-import

1. From `.importBatch(new)` in **E**: card pulled, destination offline, or disk full.
2. **G** — `Couldn't finish the import` / `The card was removed · 12 items were copied before it stopped`. Primary `Try Again`. Never auto-dismisses.
3. If the card was pulled, its row is gone; the batch row remains, holding the 12 that landed. Nothing already copied is lost.
4. `Try Again` needs the card back. With it re-attached, the button returns the user to `.library(card)` and re-plans against what is now reachable.

### J10 · Looking away mid-import

1. From `.importBatch(new)` in **E**, the user clicks a library — `.library(other)`.
2. The bar leaves with the operation it belongs to. The **batch row** now shows a 32 pt determinate bar, and that is the *only* place status appears (DES-040).
3. Returning to `.importBatch(new)` — or to `.library(card)` — brings the full bar back at its current state. Both rows lead back to the same operation.
4. If they navigated away *before* the batch existed, the selection is never moved for them (rule 1 above).

### J11 · No libraries at all

Where: `.library(card)`.

1. Card inserted; no library configured. **B** — `Otos needs a library to copy into` / `181 items on CAMERA`. Middle zone holds a single `Add a Library…` push button opening Settings → Libraries. `Import` present, disabled.
2. Once a library exists the plan builds and the bar goes to **C**. A user who has ever configured a library never sees this state — the first library auto-selects.

### J12 · Many imports, and All Imports…

Only five batch rows are shown (`SidebarView.swift:144`). On the sixth import the
selection still moves to the new batch, which is by definition among the newest five,
so it is visible. An older selected batch is kept visible rather than hidden. If the
user is on `.allImports` when an import starts, they are moved to the new batch like
anyone else — that list is a navigation surface, not a place to watch work from.

## Copy rewrites

| Current string | Replacement |
| --- | --- |
| `Inventory…`, `Planning…`, `Waiting for metadata (12/139)`, `Source changed — replanning…` | `Checking the card…` + L3 `12 of 139 items` |
| `Import queued — finishing metadata…` | `Checking the card…`, disabled `Import queued` button |
| `Importing 12/139` | `Importing 12 of 139` + L3 `19 MB of 68 MB · about 40 seconds left` |
| `12 copy · 4 preexisting · 3 companion · 1 blocked · 521 MB · 2 skipped packages` | `12 new items · 521 MB` + L3 `4 already in Summer Photos` (attention count moves to state D) |
| `Cleanup/eject withheld while blocked or skipped-package attention remains` | Nothing — the erase checkbox disables with a tooltip (DES-038) |
| `Sidecars on · Delete source after import · Auto-eject off` | Nothing — the inline checkboxes state their own condition |
| `Import queued (execution lands in a later update)` | The disabled `Import queued` button acknowledges the request (DES-039) |
| `Import complete — nothing new` | `Nothing new on this card` |
| `Nothing can be imported yet · 3 need attention` | State D wording above |
| `Destination` | `Copy into` |
| `Delete all 181 items from the card after importing` | `Erase the card`, with the consequence stated at L3 when checked |
| `Eject the card after importing` | `Eject the card` — the `Afterwards` label carries the timing |
| `Failed: <problem>` | `Couldn't finish the import` + a cause clause at L3 |

## Ownership of status

One fact, one owner (DES-040). An import is reachable from two sidebar rows — the
removable row and, once execution starts, the batch row — so "the sidebar" is not
an owner; one named row is.

1. **While the bar is on screen for this operation, the bar owns the status** and
   *neither* sidebar row shows an indicator. When import starts and the view moves
   to the new batch, the same bar travels with the operation, so this holds across
   the move.
2. **When the selection is elsewhere, exactly one row shows a 32 pt determinate
   bar**, and it is the row the operation currently lives on: the **batch row** once
   `ImportBatchID` exists, the **removable row** before that (states A–D, where
   there is no batch yet). The other row shows its ordinary accessory — for the
   removable row, its eject button.

This removes the current duplication, where an in-flight import is reported in the
footer and the sidebar at the same time
(`Otos/Views/SidebarView.swift:104`, `Otos/ContentView.swift:44`).

## Motion

Enter: slide up 24 pt with fade, 0.35 s spring (DES-071). Between states:
cross-fade the left block, swap the right button in place, fixed height. Done:
checkmark scales from 0.6 with overshoot (DES-073); on a clean run the bar holds
6 s and leaves. All of it becomes a 0.15 s cross-fade under Reduce Motion (DES-075).

## Accessibility

Tab order left to right: destination pop-up, eject, erase, primary button. Return
imports; Escape cancels during E. L1 is a live region announced on state change
only (DES-083). The determinate indicator exposes value and total, never a
synthesized percentage. Every measured contrast pair for this surface is recorded
in `hig-validation.md`.

## Decisions, 2026-08-13

| Question | Decision |
| --- | --- |
| Destination label | `Copy into`, as an introductory label on a pop-up button |
| Byte formatting | Whole MB under 100 MB, then GB with one decimal |
| Preparing indicator | Determinate once a real total exists; indeterminate only during enumeration |
| No-destination state | Vestigial — the first library auto-selects; kept only for the no-libraries-at-all case |
| Erase consequence line | Dropped; the checkbox says it, and an erase-only run confirms with a counted alert |
| Done | Not terminal, and not two states — one post-import state keyed on whether the card still exists, identical on the card row and the batch row. Attached: `Everything on this card is imported`, primary `Eject Card`. Gone: `42 items copied and verified`, auto-dismisses |
| Destination menu | Libraries only, first available on first sight of a source and remembered per source thereafter, no placeholder item |
| Preparing wording | `Checking the card…` + `112 of 181 items` |
| Card erase | Sticky Settings preference, which is the default value of the bar's pre-flight checkbox |
| Done bar | Auto-dismisses after ~6 s only on a fully clean run; otherwise persists |
| Tile shape | Aspect-shaped, uncropped, as today (DES-060A) |
| Day headers | Yes, pinned while scrolling (DES-069) |
| Chrome | Sidebar `#FAFAFB`, bar `#FBFBFC`, hairlines 8% (DES-022, DES-023) |
| L3 text colour | 60%, raised from the system value for contrast (`hig-validation.md` F-1) |
