# 2026-08-09 — Import UX benchmark: what other apps present, and what Otos should learn

Online research pass benchmarking the card-to-library flow in Image Capture, Photos,
Photo Mechanic, Lightroom Classic, Capture One, Hedge OffShoot, and Mylio Photos,
against Apple HIG guidance and Otos's current import surface. Sources are listed at
the end; every product claim below traces to one of them. No claim here about a
competitor's internals is inferred from Otos.

## 1. Otos today (the thing being benchmarked)

Read from source at `7f5d319`:

| Step | What happens | Where |
|---|---|---|
| Card attaches | `RemovableVolumeMonitor` / `CameraSourceMonitor` register it; sidebar gains a "Removable" row; **the sidebar selection auto-switches to the card**, unconditionally, no preference | `Otos/Services/SidebarSelectionPolicy.swift:33` |
| Immediately | Coordinator **greedily plans every attached source** and enrichment begins hashing card bytes | `docs/requirements.md` ARC-047; field evidence in `docs/research/2026-08-01-…` |
| Card view | Normal media grid of the card's contents. No per-item selection semantics for import; no per-item disposition affordance | `Otos/ContentView.swift:35` |
| Footer | Destination `Picker` · readiness text · `Details…` · `Import` button; then a totals line; then a policy line | `Otos/Views/ImportPlanFooter.swift` |
| Readiness text | One of **11** raw state strings, e.g. `Waiting for metadata (12/139)`, `Import queued — finishing metadata…`, `Source changed — replanning…`, `Import queued (execution lands in a later update)` | `ImportPlanFooter.swift:121-146` |
| Totals text | `"12 copy · 4 preexisting · 3 companion · 1 blocked · 521 MB · 2 skipped packages"` | `ImportPlanFooter.swift:148` |
| Policy text | `"Sidecars on · Delete source after import · Auto-eject off · Cleanup/eject withheld while blocked or skipped-package attention remains"` | `ImportPlanFooter.swift:163` |
| Details… | **Modal sheet**, read-only, one row per file: `IMG_0042.CR3` → `Copy → 2026/08/IMG_0042.CR3` / `Blocked (no usable date)` | `Otos/Views/ImportPlanOverlay.swift` |
| Progress | Text only: `Importing 12/139`. No bar, no bytes, no ETA, no Cancel | `ImportPlanFooter.swift:135` |
| Policy settings | Sidecars / delete-source / auto-eject toggles + folder policy + filename policy live in **Settings → Import** | `Otos/Views/SettingsView.swift:47` |
| After import | `Imports` sidebar section with batch rows | `Otos/Views/SidebarView.swift:34` |

## 2. Per-app teardown

### 2.1 Image Capture (macOS, Apple) — the minimum viable importer

Flow: attach card → app lists devices in a left sidebar → thumbnails in the main area
(list or icon view) → **`Import To` pop-up** picks any Finder folder or an app to hand
off to → `Import` (selected) or `Import All` → files land in the chosen folder.

Notable:
- The **entire configuration surface is one pop-up menu**. Destination is the only
  first-class decision.
- `Delete after import` is a checkbox reachable from the toolbar action (ellipsis)
  menu — adjacent to the act, not in a Settings window.
- Attach behavior is a per-device preference: a disclosure triangle at the bottom-left
  reveals **`Connecting this camera opens:`** with an app pop-up (including
  `AutoImporter` for fully hands-off transfer, and `No application`).

Lesson: destination + go is a complete product for a large fraction of users. Every
other control in every other app is an *addition* to this baseline, and each one has
to earn its place.

### 2.2 Photos (macOS, Apple) — selection and a completion-time destructive prompt

Flow: attach card → device appears under **Devices** in the sidebar (opening Photos on
connect is a per-device checkbox, `Open Photos for this device`) → import screen shows a
grid, with **already-imported items distinguished from new items** → top-right offers
**`Import All New Items`** and **`Import Selected`** → progress → **after** import, an
alert asks `Delete Items` / `Keep Items` for the card → imported media lands in
`Imports` and the main library.

Notable:
- Duplicate suppression is **not a checkbox** — it is the meaning of the primary button.
  The word "new" carries the whole concept; there is no user-visible skip count.
- The destructive card-erase decision is asked **once, at completion, per import**, as an
  alert with two explicit verbs — not as a persistent setting.
- There is no destination control at all: the library is the destination.

### 2.3 Photo Mechanic 6 (Camera Bits) — the professional ingest benchmark

Flow: `File → Ingest` (⌘G), or automatically on card mount if
`Preferences → General → On Mount of Camera Disk = Show ingest dialog`; `Auto Ingest`
goes further and starts the copy immediately with the last-used settings.

The Ingest dialog, in order:
- **Source**: `Disks` (mounted cards, with Rescan/Unmount, multi-select), `Folders`
  (saved recurring sources), or `From Selection` (current contact-sheet selection).
- **Primary Destination…** plus an optional **Secondary** destination (backup copy in
  the same pass).
- **Source directory structure**: ignore / preserve separating folders / preserve whole
  hierarchy. **Copy photos**: into destination / into dated folder / into named folder
  (variables + path separators) / named folder inside dated folder, with
  `Use Folder Sequence` → `{ingestsequence}`.
- **Rename ingested photos as**: text + variables + sequence.
- **Apply metadata template**: local (this ingest) or global.
- **Filters**: by file type, and by camera-side lock state.
- **Incremental Ingest**: copies only photos not previously ingested *on this machine*;
  Photo Mechanic remembers prior ingests silently.
- **Post-ingest**: unmount source, optionally erase (the docs themselves discourage it).
- Bottom bar: Snapshots (saved configurations), a variables reference, client variables,
  and `Close` (keep settings) / `Cancel` (discard) / `Ingest`.
- Ingest runs **as a background task** — the contact sheet opens on partially-copied
  files, so culling starts before the copy finishes.

Lesson: this is the most control-dense ingest UI in the category and it is still **one
dialog, one page, no state machine**. Complexity is absorbed by *saved configurations*
(Snapshots) and *auto-run with last settings*, not by asking more questions each time.
The pro user configures once per job type and then never looks at the dialog again.

### 2.4 Lightroom Classic (Adobe) — the cautionary tale

Layout: left = source tree (with `Include Subfolders`, `Eject after import`); center =
thumbnail grid where **every photo has a checkbox** (`Check All` / `Uncheck All`,
shift-click ranges); top = the mode row **`Copy as DNG` / `Copy` / `Move` / `Add`**;
right = stacked panels — `File Handling` (preview quality, Build Smart Previews,
**`Don't Import Suspected Duplicates`**, `Make a Second Copy To`, `Add to Collection`),
`File Renaming`, `Apply During Import` (develop preset, metadata preset, keywords),
`Destination` (`Into one folder` / `By date`, with a folder-structure preview). Import
presets sit at the bottom, and a disclosure arrow at lower-left toggles a **compact
"simplified" dialog** vs. the full one.

The cautionary part: in **Lightroom 6.2 / 2015.2 (Oct 2015) Adobe shipped a genuinely
simplified import dialog** — cleaner, fewer controls — and the backlash was severe
enough that Adobe publicly apologized ("these changes were not communicated properly or
openly before launch… I've failed the original core values of the product") and
**restored the classic import experience in 6.3** a month later. Two distinct causes are
reported in the coverage: (a) removed capabilities, `Eject card after import` named
explicitly, and (b) stability — crashes that forced restarting the import.

Lesson: simplification that **removes a capability a workflow depends on** gets rejected
even when the result is objectively cleaner. The safe move is to change *where and when*
a control is presented, not to delete it. And an importer that fails midway is
unforgivable in a way that an ugly importer is not.

### 2.5 Capture One — panelized, with the count on the button

Opens on card insert, toolbar button, drag-to-dock, or tethering. Left panels:
`Import From` (source + `Include Subfolders` + **`Exclude Duplicates`**), `Import To`
(Inside Catalog / Current Location / custom folder, plus a **`Sub Folder` field driven by
tokens** — capture date, ISO, orientation, free text, `/` creates hierarchy),
`Backup To` (checkbox + folder; notably **cannot use the sub-folder tokens**),
`Naming` (same token system, presets, RAW+JPEG paired counters), `Metadata`
(copyright/description), `Adjustments` (styles/presets at import), `File Info`. Center is
a thumbnail viewer with sizing, sorting, and search. Bottom: `Import Collection`
behavior (open Recent Imports / notify / stay put), eject and erase checkboxes, and the
primary button whose title is **`Import 6 Images` when six are selected, otherwise
`Import All`**.

Lesson: the **button title carries the count and the scope**. That single detail removes
an entire class of "what exactly am I about to do?" ambiguity, and it does so without a
totals line. Also: `Recent Imports` keeps the **last ten** import sessions as
collections, rather than a single "Last Import" that is destroyed by the next one — the
closest analogue to Otos's `Imports` sidebar batches.

### 2.6 Hedge OffShoot — the "no configuration" extreme

Flow: **drag the source into the left column, drag destinations into the right column,
press Start.** Multiple sources and multiple destinations in one run, checksum
verification on every transfer by default (hash before and after; mismatch = failed
transfer, surfaced as such). Since 25.1 it supports **cascading transfers** — copy to the
fastest drive first, then fan out to slower destinations in the background **so the card
can be ejected sooner**.

Lesson: for the offload half of the job, the correct number of settings is approximately
zero, and the correct primary feedback is **verification** ("these bytes are provably
there"), not "here is my plan". Cascading is a genuinely good idea for Otos's
cloud-synced destinations: the user's real goal at the card stage is *give me my card
back*, and everything else can finish afterwards.

### 2.7 Mylio Photos — closest philosophical sibling

Mylio's folder tree "directly reflects the structure of your actual file system", and
linked folders leave files where they are. Its import asks two things: **Source** device
and **Destination** location, plus a **Folder Organization** setting — keep the card's
structure "as is", or reorganize by capture date.

Lesson: an app with Otos's filesystem-is-truth stance ships an importer with essentially
**two questions and one policy toggle**. That is the ceiling Otos should be measured
against, not Photo Mechanic's.

## 3. Apple HIG findings that bear directly on this screen

**Progress indicators** (verbatim guidance, condensed):
- Prefer **determinate** — an indeterminate indicator "doesn't help people estimate how
  long a task will take", while a determinate one lets people "decide whether to do
  something else while waiting… or abandon the task."
- "Keep progress indicators moving so people know something is continuing to happen.
  People tend to associate a stationary indicator with a stalled process or a frozen app."
- "If it's helpful, display a description that provides additional context… Be accurate
  and succinct. **Avoid vague terms like loading or authenticating because they seldom
  add value.**"
- "When it's feasible, let people halt processing… include a Cancel button." If halting
  loses work, add **Pause** as well, and confirm the cancel.
- Display it in a **consistent location**.

**Alerts**:
- "Avoid displaying alerts for common, undoable actions… In comparison, **when people
  take an uncommon destructive action that they can't undo, it's important to display an
  alert** in case they initiated the action accidentally."
- Button titles must be verbs describing the result — "Erase," "Delete" — never "OK".
- Destructive styling is for a destructive action the person **didn't deliberately
  choose**; a deliberately-chosen destructive action (Empty Trash) doesn't get the red
  treatment.

**Sheets**:
- A sheet is for "a scoped task that's closely related to their current context" —
  requesting information, completing a small task and returning.
- On macOS a sheet is **always modal** and blocks the parent view.
- "Use a **nonmodal view** when you want to present supplementary items that affect the
  main task in the parent view… consider… a **panel in macOS**."
- Pair `Done` with `Cancel` or `Back`; a lone `Done` "implies that completing the task is
  the only way to exit the sheet."

## 4. Cross-app comparison

| Axis | Image Capture | Photos | Photo Mechanic | LrC | Capture One | OffShoot | Mylio | **Otos today** |
|---|---|---|---|---|---|---|---|---|
| On attach | per-device pref | per-device pref | pref: show dialog / auto-ingest | — | opens import dialog | — | — | **auto-switches view + starts planning & hashing, no pref** |
| Where you configure | one pop-up | nothing | one dialog | right panels | left panels | drag columns | two fields | **split: footer + Settings window** |
| Per-item selection | ✅ Import / Import All | ✅ Import Selected | ✅ from selection | ✅ checkboxes | ✅ + count in button | n/a | — | ❌ **all-or-nothing** |
| Duplicate handling | — | "new items" in button | silent Incremental Ingest | checkbox | `Exclude Duplicates` | n/a | — | **`4 preexisting` in a totals string** |
| Erase card | checkbox near action | alert at completion | dialog option, discouraged | — | checkbox, discouraged | — | — | **persistent Settings toggle, no per-run confirm** |
| Eject | — | — | dialog option | `Eject after import` | checkbox | cascade → eject early | — | Settings toggle |
| Progress | system | determinate + count | background, non-blocking | determinate | determinate | determinate + verify | determinate | **text `12/139`, no bar, no cancel** |
| Second destination | — | — | ✅ Secondary | `Make a Second Copy To` | `Backup To` | ✅ N destinations | — | — |
| Integrity proof | — | — | — | — | — | **checksum verify** | — | digest recorded (not surfaced) |
| After import | Finder folder | `Imports` album | contact sheet opens early | folder in tree | last 10 `Recent Imports` | report | folder | `Imports` sidebar batches |
| Reusable config | — | — | **Snapshots** | Import Presets | presets per panel | — | — | — |

## 5. Assessment of the current Otos import UI

The complexity is real, and it is a specific, diagnosable kind: **the planner's internal
state machine and vocabulary have been published straight to the user**. Nothing else in
the category does this.

1. **11 readiness strings.** `inventory`, `waitingForDestination`, `waitingForMetadata`,
   `planning`, `ready`, `queuedForReadiness`, `executing`, `needsReplan`, `completed`,
   `failed`, `executionUnavailable` all render as prose in the same label. HIG's "avoid
   vague terms like loading" is aimed at exactly the opposite failure, but the principle
   is the same: the text must be *actionable*. `Inventory…`, `Planning…`, and
   `Source changed — replanning…` tell the user nothing they can act on, and
   `Import queued (execution lands in a later update)` is a build-status message.
   Every benchmarked app has effectively **three** user-visible states: *not ready to
   go*, *going*, *done*.
2. **The totals line is domain jargon.** `copy · preexisting · companion · blocked ·
   skipped packages` are five internal disposition kinds. The comparable products
   surface **one** number, in the primary button: `Import All New Items`,
   `Import 6 Images`. Otos's five counts are all real facts, but four of them are
   answers to questions the user has not asked yet.
3. **The policy line leaks an invariant.** "Cleanup/eject withheld while blocked or
   skipped-package attention remains" is a correct and important rule and a sentence no
   user should ever read. It is also unactionable — there is no path from that sentence
   to resolving a blocked entry.
4. **Configuration is split across two surfaces.** Destination is inline (right), but
   `delete source after import`, `eject after import`, folder policy, and filename policy
   are in a Settings window. That is backwards relative to every benchmark: Image
   Capture, Photo Mechanic, LrC, and Capture One all put erase/eject **next to the
   import button**, because they are per-card decisions. `Delete source files after
   import` as a sticky global toggle with no per-run confirmation is the single riskiest
   element on this screen, measured against HIG's rule about uncommon, un-undoable
   destructive actions.
5. **The Details… sheet is the wrong shape twice over.** It is a macOS modal that blocks
   the parent, for a purely read-only inspection task (HIG: prefer a panel for
   supplementary information affecting the main task), and it presents a file-path table
   when the app already has a **thumbnail grid of exactly those files** on screen behind
   it. Every competitor's "plan view" *is* the thumbnail grid.
6. **No per-item selection.** This is the one outright capability gap versus all four
   photo apps. It is also why the blocked/skipped counts have to be explained in text:
   with selection, a blocked item is simply an item you can see, badged, and choose to
   exclude.
7. **Attach behavior is unconditional and expensive.** Auto-switching the sidebar
   selection to the card hijacks whatever the user was doing, with no equivalent of
   `Open Photos for this device` / `On Mount of Camera Disk`. Greedy planning plus
   enrichment hashing on card bytes is, per `docs/research/2026-08-01-…`, actively
   harmful on slow cards. No benchmarked app plans before the user opens the ingest
   surface.
8. **Progress is below the category floor.** `Importing 12/139` as a static label, no
   determinate bar, no byte/ETA context, no Cancel — against HIG's explicit "when it's
   feasible, let people halt processing" and "keep progress indicators moving."

## 6. Candidate direction (for discussion — not a plan)

Ordered by value-to-cost, and checked against Otos's invariants (filesystem is truth,
originals read-only, one intent per action, simplest correct model).

**A. Collapse the state machine into three user-facing states.** *Preparing* (any of
inventory/planning/waitingForMetadata/needsReplan → one spinner + one line),
*Importing* (determinate bar + Cancel), *Done* (summary + link to the batch). Keep all 11
internal states — they are correct — and stop publishing them. `failed` and
`waitingForDestination` are the only two that need distinct user-facing treatment,
because only those two are actionable.

**B. Put the count and the scope in the button.** `Import 137 New Items` /
`Import 6 Selected`, à la Capture One and Photos. Retire the totals string; move
`preexisting` into the word "new", and move `companion` into the sidecar preference's
own copy.

**C. Add per-item selection, and let the grid be the plan view.** Otos already renders
the card's contents in the media grid. Badge the exceptional items there — already
imported, blocked, companion-only — and let selection drive the button. That deletes the
`Details…` sheet, the totals line, and most of the explanatory prose in one move, and it
closes the only real capability gap. This is the largest change and the one with the
highest payoff; it is also the one that must not regress the no-blank-grid invariant.

**D. Move the per-card decisions next to the import button; leave true preferences in
Settings.** Destination (already there), plus `Eject after import` and `Delete source
after import` as inline checkboxes with the current preference as their default — the
Lightroom Classic and Capture One arrangement. Then treat the erase as HIG treats
uncommon destructive actions: either Photos' completion-time
`Delete Items` / `Keep Items` alert, or a per-run confirmation. Never both a sticky
global toggle *and* silent execution.

**E. Give attach a preference and stop planning before the user asks.** An
`On card insert:` control (`Do nothing` / `Show the card` / `Show the card and prepare`)
mirrors Image Capture and Photo Mechanic, respects the user's current context, and
directly retires the enrichment-storm risk documented on 2026-08-01. Planning on
selection rather than on attach is also the simpler model — one owner, one trigger.

**F. Determinate progress with Cancel, in a consistent location.** Bytes and items, a
real bar, a Cancel that is safe because copies are additive and originals are read-only.

**G. Consider surfacing verification, not the plan.** OffShoot's insight is that the
reassuring fact is "the bytes are provably at the destination". Otos already records a
primary digest at settlement (ARC-046A). Saying *`137 items copied and verified`* at the
end is worth more than any number of pre-flight disposition counts — and it is the
honest version of the same reassurance the totals line is currently reaching for.

**Explicitly not recommended:** Photo Mechanic's variable/token language, secondary
destinations, metadata templates, and import presets. They are the correct answer for a
wire-service workflow and the wrong answer for Otos's stated "smallest correct model"
principle. Note also the Lightroom 6.2 lesson before removing anything a workflow already
depends on: relocating a control is safe, deleting it is not.

**Open question for the owner:** is per-item import selection in scope as a product
concept, given that grid selection is already overloaded — APP-021 defines the compared
pair as "the selection capped at two". Item C assumes grid selection can additionally
mean "items to import" while a card is the selected source. If it cannot, the plan-view
problem needs a different answer (a per-tile import checkmark distinct from selection,
as Lightroom Classic does — its checkboxes are deliberately *not* the same thing as
selection).

## Sources

Retrieved 2026-08-09.

- [Ingesting Photos — Camera Bits (Photo Mechanic)](https://camerabits.freshdesk.com/support/solutions/articles/48000207409-ingesting-photos-with-photo-mechanic)
- [Automatically Open Ingest Window Upon Inserting a Card — Camera Bits](https://docs.camerabits.com/support/solutions/articles/48000341502-automatically-open-ingest-window-upon-inserting-a-card-into-your-reader)
- [Import photos to Lightroom Classic — The Lens Lounge](https://thelenslounge.com/how-to-import-photos-to-lightroom-classic/)
- [Adobe issues Lightroom 6.2 apology and update — DPReview](https://www.dpreview.com/articles/9338796360/adobe-issues-lightroom-6-2-apology-and-update)
- [Update on Lightroom 2015.2 / Lightroom 6.2 Release — Adobe Lightroom Journal](https://blogs.adobe.com/lightroomjournal/2015/10/update-on-lightroom-2015-2-lightroom-6-2-release.html)
- [Adobe Releases Lightroom 6.3 with Restored "Classic" Import Experience — Laura Shoe](https://laurashoe.com/2015/11/17/adobe-releases-lightroom-6-3-with-restored-classic-import-experience/)
- [Capture One In Depth: Importing — Thomas Fitzgerald Photography](https://blog.thomasfitzgeraldphotography.com/blog/2019/9/capture-one-in-depth-importing)
- [Importing images into a Catalog — Capture One Support](https://support.captureone.com/hc/en-us/articles/360002492617-Importing-images-into-a-Catalog)
- [Import photos and videos from a camera — Apple Photos User Guide](https://support.apple.com/guide/photos/phtae4e05c67/mac)
- [Image Capture User Guide for Mac — Apple Support](https://support.apple.com/guide/image-capture/image-capture-user-guide-imgcp1003/mac)
- [How to import photos using the Image Capture app on Mac — AppleInsider](https://appleinsider.com/inside/macos/tips/how-to-import-photos-using-the-image-capture-app-on-mac)
- [OffShoot — Hedge](https://hedge.co/products/offshoot) and [Verification — Hedge docs](https://docs.hedge.video/offshoot/features/verification)
- [OffShoot vs ShotPut Pro vs Silverstack — Tusk](https://tuskbackup.com/blog/hedge-vs-shotput-pro-vs-silverstack)
- [Add Media From a Camera, Memory Card, or Phone — Mylio Photos manual](https://manual.mylio.com/24.3/en/topic/add-media-camera-memory-card-phone)
- [Your File System and Mylio Photos — Mylio Photos manual](https://manual.mylio.com/24.3/en/topic/your-file-system-and-mylio-photos)
- [Progress indicators — Apple HIG](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- [Alerts — Apple HIG](https://developer.apple.com/design/human-interface-guidelines/alerts)
- [Sheets — Apple HIG](https://developer.apple.com/design/human-interface-guidelines/sheets)
- [File management — Apple HIG](https://developer.apple.com/design/human-interface-guidelines/file-management)
