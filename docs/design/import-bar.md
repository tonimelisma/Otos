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
│ L3  139 already in Summer Photos  │ Afterwards  ☑ Eject  ☐ Erase    │  │    Import    │  │
└──────────────────────────────────┴─────────────────────────────────┴────────────────────┘
      what                              choices                            the act
```

The divider between *what* and *choices* is the hairline; the divider before *the
act* is drawn only here, to mark the zone.

- **What** — L1 over L3, left-aligned.
- **Choices** — behind a `.5 pt` hairline, `padding-left: 12`. Two rows, `.callout`
  introductory labels in a fixed 66 pt column (DES-016), controls at 22 pt.
  Row 1: destination pop-up button. Row 2: `Eject the card`, `Erase the card`.
  Above row 1, a 12 pt slot for state A's small linear track; every other state
  holds it blank, so the rows never move when the plan lands (DES-053).
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
| 7 | `importRequested` — Import was pressed and the coordinator is holding the click until the plan is ready | Whatever state the bar is on, with `Import` disabled. The click's acknowledgement is the disabled button; every string, count and zone stays as it was (DES-035: no `Import queued`) | folds into the state it is on |
| 8 | `executing` | **E · Working** | ✅ |
| 9 | cancel requested, still winding down | E, cancelling variant | folds into E |
| 10 | `completed`, clean | **F · Done** | ✅ |
| 11 | `completed` with failures or skips | F, incomplete variant — stays on the batch row for its `Show them` reveal | folds into F |
| 12 | `failed` — a run the user started ended in failure | **G · Failed** | ✅ actionable |
| 12a | `planningFailed` — no plan could be made, nothing was attempted | G, planning variant: `Couldn't prepare the import` | folds into G |
| 13 | `executionUnavailable` | treated as C or D by its totals; the build condition is never shown (DES-039) | no |
| 14 | No libraries configured at all | B, with `Add a Library…` opening Settings instead of a pop-up | folds into B |
| 15 | Card removed or destination lost mid-import | G, with the cause named | folds into G |
| 16 | Camera still enumerating | Grid-level device banner, not the bar | separate, grid spec |
| 17 | The last run **stopped before attempting every planned entry** — the user's Cancel, or the disk floor (ADR 0027) | F, Stopped variant — never auto-dismisses | folds into F |

So: **seven bar states to draw** — A, B, C (+2 variants), D, E (+1), F (+2), G.

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
(DES-030, DES-032). The track sits above the choices in the same zone (mockup 2b):
the destination pop-up and both checkboxes are the controls Ready draws, usable
from the first frame, because choosing while we check costs nothing — the plan is
simply built against the choice — and a control that only appeared at Ready would
move between states (DES-053). Action: `Import` — the same push button Ready
enables, disabled and dimmed in place, never static text: a verb title says the
control is interactive, and a disabled control stays a control to VoiceOver and the
tab order (DES-053, HIG push buttons).

### B · No destination

Not a normal state: the first available library is auto-selected, so a user with a
library never sees this. It survives only for the case where **no libraries exist
at all** — L1 `Otos needs a library to copy into` · L3 `181 items on CAMERA`, middle
zone holds a single `Add a Library…` push button opening Settings → Libraries, and
the primary action stays `Import`, disabled.

### C · Ready

L1 `42 new items · 68 MB` · L3 `139 already in Summer Photos`, omitted at zero.
Action: `Import` — no count: the number is L1's primary fact, and Otos imports
everything new, so the title has no scope to name (DES-036). Photos does the same,
reserving a count for a user-chosen subset (`Import 3 Selected`) that Otos does not
offer.

**When not everything will fit**, L3 is that instead of anything else:
`Not everything will fit yet · 37.7 GB available`. Drawn only when the plan's bytes
plus the 5 GB floor exceed what the destination volume reported available when this
Ready was published — two measured values and Otos's own stopping rule (ADR 0027),
not an estimate, so it is not DES-032's one permitted estimate. It gates nothing: the
act stays `Import`, the run copies what fits, stops at the floor, and state F's
Stopped variant states what happened. "Yet" is the resumable design in one word — free
space, import the rest. It outranks the already-in-library clause because it changes
what the click will do (DES-034: one clause). "Available" is the metric's name across
macOS (Get Info, Storage, Software Update); Finder's "free space" belongs to a blocking
error, which this is not.

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

Causes currently drawn here: items with no usable date, items for which no free
destination name exists, and items whose bytes could not be read — the last of which
cannot be copied either, so blocking and showing it is the only honest outcome;
retrying it forever would hide a failing card behind a bar that never settles. A
destination folder Otos could not *list* is not drawn here at all: that is a missing
observation, not a plan, and the coordinator retries the build while the last proven
plan keeps showing (ADR 0019).

L1 `39 new items · 61 MB` · L3 ⚠ `3 items have no date · Show them`. The orange
badge carries a glyph, never colour alone (DES-029). `Show them` selects and scrolls
the affected tiles in the grid — the grid is the plan view; there is no modal list
(DES-041). Action: `Import` — omitted when nothing is importable, because a button
over nothing is a control whose subject does not exist (DES-053; drawn once, as
`Import 0 Items`, on 2026-09-13 over 368 blocked items). `Erase the card` is disabled while attention
remains, with the tooltip `Some items still need attention.` (DES-038).

**The clause must name the real cause.** `blocked` is not one condition, and none of
its causes is "can't be read" — an earlier draft said so, and it was a fabricated
diagnosis (`MediaOperationBlockReason`, `MediaOperationModels.swift:109`):

| Cause | Clause | Why |
| --- | --- | --- |
| `noUsableDate` | `3 items have no date` | The file reads fine. It carries no capture date and no modification date, so Otos cannot choose a dated folder for it. |
| `noFreeDestinationName` | `Otos couldn't find a free name for 3 items in Summer Photos` | Every suffix the naming policy allows is taken in the destination folder. |
| `filesystemObservationUnavailable` | `Otos couldn't check 3 names in Summer Photos` | The planner's safety net for a folder it could not read. Never presented: the coordinator defers such a build and retries it (ADR 0019); the clause exists so the mapper stays total. |
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
removable row and the import batch row are views onto the same operation, so wherever
the bar is drawn it says the same thing. Keying the wording to the selected row would
make one finished import say two different things depending on which row was clicked,
which is the duplication DES-040 exists to prevent. What differs by row is only
*whether* it is drawn: the batch row shows the bar while there is something the grid
cannot say (the run in flight, or a settle that was not fully clean); the card's own
row shows it for as long as the card is attached (below, "Dismissal").

**F · card still attached.** L1 ✓ `Everything on this card is imported` · L3
`42 copied just now · 181 items in Summer Photos`. Choices present. Primary
**`Eject Card`** — the one remaining useful act — and nothing beside it. Drawn on
`.library(card)`, and re-derived from the plan every time the user comes back to it:
click away and back, and it offers `Eject Card` again. Never dismisses while the card
is attached: the card is still there and still has actions attached to it. Not drawn
on `.importBatch(new)` after a fully clean run — the grid there already shows the
items, and the card's acts belong on the card's row.

**F · card gone** (eject ran, or the card was pulled). There is no card to talk about,
so the sentence is about the result instead: L1 ✓ `42 items copied and verified` · L3
`In Summer Photos · card ejected — safe to remove`, and **both** the choices zone and
the act are omitted — their subject no longer exists (DES-053 exception). Reachable only
from `.importBatch(new)`, since the removable row is gone, and drawn there only while
an unresolved outcome exists: a non-clean completion, a stopped run, or a source-removal
failure. A fully clean detached completion has no status left to report and is discarded.

Two properties keep the attached case honest rather than a stale banner: it is produced
by the re-plan, so a card that gains a file returns to **C** with `1 new item`; and the
`copied just now` clause is scoped to this attachment and to the library it copied into,
so re-inserting the card later gives C's ordinary nothing-new wording, no import having
happened in that session — and changing the destination after a run withholds the whole
outcome rather than pairing its count with another library's name; the plan then speaks
for itself (`Nothing new on this card` or `181 new items`), and picking the original
library again brings the outcome back.

**F · Stopped.** The run ended before it attempted everything it planned — the user
pressed Cancel, or the destination volume reached the disk floor (ADR 0027). It is
still F: a partial batch is a real batch, the card is unchanged, and nothing already
copied is lost. What differs is that the bar must *say* the run stopped, from the
run's own facts, and offer what is left. L1 `Stopped — 12 of 42 items copied` · L3
one clause for the cause: `They're in Summer Photos` after a Cancel (omitted when
nothing was copied), `Not enough room on the disk · 5.4 GB left` at the floor — the
capacity read when the run stopped, in the bar's byte units. Choices present while the card
is attached. The act is **`Import`** for what is left — and this is the one F
variant with a prominent act, because its subject exists: items are still on an
attached card, so DES-053's exception does not apply. What it imports is the
re-plan's remainder, not the run's arithmetic: the coordinator drops the plan the run
executed from (its landed entries are skips now), so the act is disabled for the
moment the re-plan takes and enabled once the honest plan lands (DES-030). When nothing is left, the act
is the card's, as in F-attached. Identical on `.library(card)` and
`.importBatch(new)`. Never auto-dismisses, and never fully clean, so the card is
neither ejected nor erased on the stop's account.

**F · Stopped, card gone.** L1 the same · L3 `In Summer Photos · card ejected — safe
to remove`; choices and act omitted, as in F card-gone.

The stop is a fact about the *last run*, so it is stated until the next run starts —
a card that gains a file meanwhile still reads `Stopped — 12 of 42 items copied`,
still offering `Import`, which takes whatever is new — the extra file included —
because both halves stay true. A new run's Working (or
its own Failed) outranks it. It is not a failure: nothing went wrong that
`Try Again` could fix, and state G's cause vocabulary does not include it.

### There is no `Show These Items` button

The act zone is empty here, and in F-incomplete, because the only thing that was
ever offered there was a jump to the batch row — and the user is already standing
on it. The selection follows the work to the batch when execution starts, and
follows it there again if the card's own row disappears while they are on it
(*Where the user is standing*, below). So the button's entire effect was to
re-select the row that was already selected: a prominent, Return-firing control
that does nothing, on the one screen whose job is to report honestly what
happened. It is removed from the bar in every state — as a primary action and as
the secondary text button F-attached used to carry.

What survives is the **`Show them` reveal on L3**, which is a different act: it
selects and scrolls *specific* items — the ones that couldn't be copied — inside
the grid the user is already looking at. That is a real change of what is on
screen, and it is the only "show" the bar offers.

An empty act zone is DES-053's stated exception ("a control whose subject no
longer exists may be omitted"), reached from both directions here: after eject
the card the act would address is gone, and in F-incomplete the destination the
act would navigate to is already underfoot. The surface's height and the zone's
width do not change (DES-018), so nothing shifts when the act disappears; and
DES-052 is an upper bound, not a quota — zero prominent buttons is a legitimate
answer for a state that is pure report.

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

**Dismissal:** on the batch row the bar leaves the moment a run settles fully clean —
no failures, no skips, no attention items — with no timer and nothing remembered: the
user is already looking at what was imported, and the batch stays selected. A run that
was not fully clean keeps its bar on the batch row, because that is the only place the
exception is reported. The card's own row never dismisses while the card is attached:

### G · Failed

L1 `Couldn't finish the import` · L3 one clause naming the cause and what to do:
`The card was removed` / `Summer Photos isn't available`. Action: `Try Again`. Never
auto-dismisses. Nothing already copied is lost, and the count copied so far is stated
when nonzero. Running out of room is **not** a failure: nothing went wrong that
`Try Again` could fix, so it is the Stopped variant of F with the floor's clause
(ADR 0027).

**Planning variant.** When no plan could be made — the destination folder stayed
unreadable past its retry budget, a root vanished between the wake and the
snapshot, the builder threw — nothing was started, so "finish" would be a lie
about what happened. L1 `Couldn't prepare the import`, the same L3 cause clause,
the same choices and `Try Again`. The headline names the stage; the clause names
the cause; the act is the same because the remedy is the same. The model keeps
this a separate case (`planningFailed`) rather than a flag on `failed`: a run
failure carries a count landed and a batch, a planning failure has neither.

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
source removed and destination unavailable — with one case reserved for the
unexpected, whose clause names no cause and whose detail goes to the log rather than
the bar. Both clauses have typed producers: a run whose source disappears is retained
as `failed(.sourceRemoved, publishedCount:)` under its batch, and a destination failure
uses the existing typed destination-unavailable reason. The source-removal result is
settled by the owned execution task after detach, so a later result cannot recreate a
live card presentation for a replacement attachment at the same path.

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
| F, G | Whether the run was **fully clean** (the batch-row dismissal gate) | Partly — `completed` carries `skippedForeignCount` and `failedCount`; blocked and attention items must join them. |
| G | Typed **failure reason** | No — `failed(problem: String)`. See state G. |
| F, Stopped | Typed **stop reason** | No — a cancelled run reaches the completion as `isFullyClean: false` and nothing more, indistinguishable from a run that attempted everything and lost some. |
| F, Stopped | The run's own **planned count**, for "12 of 42" | No — the re-plan's `copyCount` is the remainder, not the run's total, and moves if the card gains files. |

These are coordinator-owned lifecycle facts. The presentation carries them rather than
letting the view re-derive them, preserving the "one owner per fact" rule at the last
hop.

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
- **The batch row cannot pre-exist the import.** The coordinator mints the real
  `ImportBatchID()` when execution starts and carries it through the executor
  (`MediaOperationCoordinator.swift`); the row appears in the sidebar only once
  assets are journaled against it. So "select the new batch" is possible at execution
  start, but the row is empty for the first moment and fills as items land.
- **Do not read the batch ID off the plan.** `MediaTransferPlanner.swift:77` mints a
  second, throwaway `ImportBatchID()` into `plan.mode` on *every* plan build. It is
  not the batch the assets land in, it changes on every re-plan, and using it would
  select a row that never exists.

**Selection behavior.** The view follows a batch once when a live presentation proves
that it has published assets. An unresolved detached outcome may follow only when no
replacement live card presentation exists for that path. A zero-published failure,
including a source-removal failure, never navigates to an empty batch row.

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
2. **Never move them twice.** No selection change at completion or at re-plan. The
   exception is forced, not chosen: when the *selected row itself stops existing*, the
   policy must resolve the selection somewhere (`CatalogWindowPolicy.swift:64`,
   `CatalogWindowViewModel.swift:734`).

**Where a forced re-resolution lands.** If the row that vanished is a removable source
the user just imported from — they ejected it, or pulled it, while standing on its
row — the selection resolves to **that source's import batch**, not to
`SidebarSelectionPolicy.defaultSelection`. The default would answer with another
connected card, an unrelated library, or All Media: three things the user was not
looking at and did not ask for. The batch is the continuation of what they *were*
looking at, and it is what makes F's card-gone bar honest with no act on it — the items
it is reporting are on screen.

The ViewModel remembers the last batch and attachment generation for each live
removable source rather than reading it from a detached presentation at removal time:
the coordinator's presentation stream and the catalog publish that drops the row are
independent, so which arrives first must not decide where the user lands. Reattaching
the same path invalidates the previous record, and the move fires only when that batch
is actually in the sidebar, so a card that imported nothing falls back exactly as
before.

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
| 4 | `.library(card)` | **C** `42 new items · 68 MB` / `139 already in Summer Photos` | `Copy into: Summer Photos`, eject checked from preference. Primary `Import` |
| 5 | → `.importBatch(new)` | **E**, travels with the operation | Import pressed; `ImportBatchID()` minted, batch row appears and the view follows it |
| 6 | `.importBatch(new)` | **E** `Importing 12 of 42` / `19 MB of 68 MB · about 40 seconds left` | Grid fills in as items land. The card's own row shows nothing — the bar owns status |
| 7 | `.importBatch(new)` | bar leaves as the run settles | Verified, then ejected. Batch stays selected; the user is looking at exactly what they just imported, and the card is gone, so there is nothing left to say or do |

### J2 · The same import, eject unchecked

Steps 1–6 as J1, then:

| # | Where | Bar | What happens |
| --- | --- | --- | --- |
| 7 | `.importBatch(new)` | — | Copy settles and verifies. No eject, so the card is still attached and still in the sidebar |
| 8 | `.importBatch(new)` | bar leaves as the run settles | The batch stays selected; the card's acts live on the card's row |
| 9 | → `.library(card)` when the user clicks the card | **F, card attached** ✓ `Everything on this card is imported` / `42 copied just now · 181 items in Summer Photos` | Re-derived from the plan: every item is now a skip. Choices present. Primary **`Eject Card`** and nothing else. Never dismisses while the card is attached, however many times the user clicks away and back |
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
2. **C** — `1 new item · 4 MB` / `181 already in Summer Photos`, primary `Import`.
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

1. `.library(card)` — **D** `39 new items · 61 MB` / ⚠ `3 items can't be read · Show them`, primary `Import`. `Erase the card` disabled, tooltip `Some items still need attention.` — the invariant lives on the control it blocks, not in a status line.
2. `Show them` selects and scrolls those tiles **in place**, on `.library(card)`. The grid is the plan view; there is no modal list, and the selection does not move.
3. Import proceeds on the 39; selection moves to the new batch as in J1.
4. Eject was withheld while attention remains, so the card survives: the bar settles into **F, card attached** reporting `39 copied just now` — on either row.

### J8 · Cancelling

Where: `.importBatch(new)` — the user is on the batch when they cancel.

1. `Cancel` (or Escape). No confirmation: copies are additive, originals read-only.
2. **E, cancelling** — `Stopping…` / `Finishing the current item`. Indicator stays determinate and moving; button disabled.
3. **F, Stopped** — `Stopped — 12 of 42 items copied` / `They're in Summer Photos`, and the act zone is empty if the card went with the cancel; the user is already on the batch holding the 12. Never auto-dismisses. The partial batch remains a real batch in the sidebar.
4. With the card still attached, the same bar — on the batch row and on `.library(card)` alike — offers `Import` for what is left, once the re-plan has counted it. Pressing it creates a *second* batch. Nothing is duplicated.

### J9 · A failure mid-import

1. From `.importBatch(new)` in **E**: card pulled or destination offline. (Running out of room is J8's shape with the floor's clause, not this one — ADR 0027.)
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
| `Import queued — finishing metadata…` | `Checking the card…` + L3 `12 of 139 items`, `Import` disabled — the held click changes nothing else |
| `Importing 12/139` | `Importing 12 of 139` + L3 `19 MB of 68 MB · about 40 seconds left` |
| `12 copy · 4 preexisting · 3 companion · 1 blocked · 521 MB · 2 skipped packages` | `12 new items · 521 MB` + L3 `4 already in Summer Photos` (attention count moves to state D) |
| `Cleanup/eject withheld while blocked or skipped-package attention remains` | Nothing — the erase checkbox disables with a tooltip (DES-038) |
| `Sidecars on · Delete source after import · Auto-eject off` | Nothing — the inline checkboxes state their own condition |
| `Import queued (execution lands in a later update)` | The disabled `Import` button acknowledges the request (DES-039, DES-035) |
| `Import complete — nothing new` | `Nothing new on this card` |
| `Nothing can be imported yet · 3 need attention` | State D wording above |
| `Destination` | `Copy into` |
| `Delete all 181 items from the card after importing` | `Erase the card`, with the consequence stated at L3 when checked |
| `Eject the card after importing` | `Eject the card` — the `Afterwards` label carries the timing |
| `Failed: <problem>` | `Couldn't finish the import` + a cause clause at L3 |
| `Failed: <problem>` before any run | `Couldn't prepare the import` + the same cause clause |

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
checkmark scales from 0.6 with overshoot (DES-073) on the card's row; on the batch row
a clean run's bar leaves as it settles. All of it becomes a 0.15 s cross-fade under Reduce Motion (DES-075).

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
| Done | Not terminal, and not two states — one post-import state keyed on whether the card still exists, worded the same wherever it is drawn. Attached: `Everything on this card is imported`, primary `Eject Card`, on the card's row. Gone: `42 items copied and verified`, on the batch row only after a run that was not fully clean |
| Destination menu | Libraries only, first available on first sight of a source and remembered per source thereafter, no placeholder item |
| Preparing wording | `Checking the card…` + `112 of 181 items` |
| Card erase | Sticky Settings preference, which is the default value of the bar's pre-flight checkbox |
| Done bar | Leaves the batch row the moment a fully clean run settles, no timer; stays there after a run that was not fully clean; never leaves the card's row while the card is attached (2026-09-14, replacing the 6 s hold) |
| Tile shape | Aspect-shaped, uncropped, as today (DES-060A) |
| Day headers | Yes, pinned while scrolling (DES-069) |
| Chrome | Sidebar `#FAFAFB`, bar `#FBFBFC`, hairlines 8% (DES-022, DES-023) |
| L3 text colour | 60%, raised from the system value for contrast (`hig-validation.md` F-1) |

## Decisions, 2026-09-13

| Question | Decision |
| --- | --- |
| Count on the Import button | None — `Import`. The count is L1's primary fact and the click has no scope to choose (DES-036 rewritten). A count stays on `Erase N Items`, where it is the new information a destructive click commits to |
| Disabled Import | A real push button, disabled and dimmed in place — never static text (DES-053, HIG). One `PrimaryAction` case whether enabled or not |
| Choices while checking | Usable from the first frame, with the small linear track above them in the same zone (mockup 2b); the bar's fixed height grows to fit (61 pt content) |
| Destination changed after a run | The run's outcome (copied just now, fully clean, stop reason) is presented only while the destination is still the library it copied into; the batch identity stays |
| Destination changed on a Ready plan | The held plan and settled outcome are dropped and the bar returns to A until the plan for the new library lands — the old counts were measured against another library, so holding them (ARC-047) would put them under the wrong name and offer an Import the click would not honour |
