# Plan 0091 — Liked, Not Rated, And Disliked Curation

## Goal

Implement one durable, mutually exclusive per-item curation choice throughout
Otos:

- **Liked** — positive choice, shown with a heart.
- **Not Rated** — no positive or negative choice, shown with a minus control.
- **Disliked** — negative choice, shown with an X control.

Every user action enters one owner intent. `P`, `U`, and `X`, menu commands, and
hover controls choose Liked, Not Rated, and Disliked. Grid, Loupe, Compare, and
both shared filmstrips render and mutate the same catalog value. The filter gains
one Curation group. A durable **Advance after choosing Liked, Not Rated, or
Disliked** setting controls post-choice navigation and defaults off. **Photo >
Move to Trash** uses Command-Backspace for explicit, recoverable deletion from
disk.

This plan is implementation-authoritative only after the user approves work on
it. Until it lands, `docs/requirements.md` remains the authority for current
behavior and must continue to say that curation is unimplemented.

Research and HIG review:
[`docs/research/2026-08-12-liked-curation-interaction-and-copy.md`](../research/2026-08-12-liked-curation-interaction-and-copy.md).

## Product Contract

### State and lifecycle

1. Add one `MediaChoice: String, Codable, CaseIterable, Sendable` with exactly
   `.liked`, `.notRated`, and `.disliked`. Do not model three booleans, optional
   flags, or two independent liked/disliked columns.
2. New assets start `.notRated`.
3. The choice is authored catalog overlay. It never changes the original, writes
   XMP, creates a sidecar, or becomes filesystem truth.
4. It follows the existing overlay lifecycle: retain it while the item exists;
   purge it only with the item after proven deletion or explicit root removal.
5. Library reorganization preserves it through the existing identity remap.
6. Import copies it from a cataloged source item to the published destination in
   the same atomic overlay-reuse/settlement path. A source that is not cataloged
   contributes no choice and the destination starts Not Rated.
7. Choice is independent from ephemeral Grid selection, Compare position,
   sidebar scope, media kind, import status, and future editing intent.

### Copy and symbols

| Context | Liked | Not Rated | Disliked |
| --- | --- | --- | --- |
| persisted/user state | `Liked` | `Not Rated` | `Disliked` |
| action/menu/tooltip | `Like` | `Mark as Not Rated` | `Dislike` |
| shortcut | `P` | `U` | `X` |
| hovered symbol | `heart.fill` / `heart` action | `minus` | `xmark` |

Do not introduce Picked, Unmarked, Rejected, Favorite, thumbs, stars, green, or
red as alternate user-facing vocabulary. Internal diagnostic values use the
enum raw values and never filenames.

### Resting and hover presentation

Follow the Photos app's low-chrome approach: all three choices render identically
at rest.
The hover group is the only direct control drawn over media. It is not the only
way to perform or perceive the operation: menus, `P/U/X`, filter values,
accessibility values, and VoiceOver custom actions remain available. Record this
intentional Photos-style content-chrome rule in the design system when implemented;
it follows a platform precedent and is not a `[deviation]`.

1. **Grid tile:** reserve the upper-left hover anchor for curation. At rest show no
   heart, X, dimming, or empty placeholder. On hover reveal heart, minus, and X in
   one compact material-backed control. Keep the lower-right RAW/video badge and
   accent selection ring unchanged.
2. **Filmstrip tile:** use the same owner and grammar at a smaller supported size.
   If the configured 48 pt minimum cannot fit three 28 pt hit targets, let the
   control overflow into a single material capsule above the tile rather than
   reducing hit targets or hiding actions. Prove it at 48, 72, and 192 pt.
3. **Loupe:** anchor the hover control to the preview pane's top-left. It does not
   move with the aspect-fit image rect and does not cover the centered video play
   affordance or top-right download progress. At rest it is absent.
4. **Compare:** each peer pane independently reveals its own hover controls and
   otherwise has no curation chrome. Hover does not select a pane. Clicking a pane
   background or its curation control makes that positional pane active. A
   standard focus indication makes the `P/U/X` target perceivable without adding Select,
   Candidate, promote, or role labels.
5. Controls remain visible while the pointer traverses the group. A control click
   is consumed and must not also run Grid selection, strip replacement, preview
   double-click, or video playback.
6. Hover appearance/disappearance uses the design-system 0.15 s state animation;
   Reduce Motion uses the same allowed cross-fade and no translation or scale.
7. Invisible hover buttons never become keyboard focus stops. The Compare active-
   pane indication remains visible because it communicates the target of keyboard
   commands, not curation state.

### Commands and target resolution

All paths call `CatalogWindowViewModel.chooseMedia(_:target:origin:)`. Views never
write Store and the AppKit bridge never owns domain state.

1. Add a **Photo** menu with `Like`, `Mark as Not Rated`, and `Dislike` commands.
   Use title case and no ellipses because each command completes without a dialog.
2. Scope bare `P/U/X` to the main media browser responder. They must not fire
   while a text field/editor, Settings, sheet, alert, or other nonbrowser scene is
   key. Do not install a process-global event monitor or steal typing.
3. Grid keyboard/menu targets the current selection atomically. Disable the menu
   commands when Grid has no selection.
4. A Grid or filmstrip inline control targets exactly the item carrying it,
   without first changing unrelated multi-selection.
5. Loupe keyboard/menu targets the focused item. Its inline control targets that
   same item.
6. Compare keyboard/menu targets `activeComparePane`; inline controls target
   their own pane and set that pane active before submitting. Entering Compare
   defaults active pane to right. Strip replacement makes the replaced pane
   active. Sliding makes the arriving pane active. Swapping keeps the active
   **position**, not the asset, because Otos panes are positional peers.
7. Add **Swap Compared Photos** to View, enabled only for a two-item Compare pair,
   with Down Arrow as its view-scoped shortcut. It swaps left/right positions and
   does not change either choice. Up Arrow remains unassigned. `P/U/X` never mean
   swap or promotion.
8. Add **Move to Trash** to Photo with Command-Backspace
   (`.keyboardShortcut(.delete, modifiers: .command)`). It uses the same current
   target model as choice commands: Grid selection, Loupe focus, or active Compare
   pane. It is disabled without a target, during a conflicting filesystem
   operation, and for camera/MTP items that have no user-filesystem original.

### Advance preference and navigation

1. Add a General Settings pane with one checkbox:
   **Advance after choosing Liked, Not Rated, or Disliked**.
2. Persist it in the injected `PreferencesDomain` under one typed constant. The
   default is `false`. Tests use only suite domains; no new default parameter may
   reach `UserDefaults.standard`.
3. Every accepted choice invokes the same completion policy regardless of
   keyboard, menu, or hover origin. "Accepted" includes choosing the already
   stored state, so `U` advances through untouched Not Rated items when enabled.
4. A failed Store mutation never advances. Emit a bounded diagnostic and retain
   the current view/selection.
5. Snapshot the target IDs, pre-choice ordered IDs, relevant focus/pane position,
   query generation, and successor before awaiting Store. On completion,
   revalidate current mode, typed target identity, descriptor generation, and
   pane ownership before applying navigation. A stale completion may persist the
   user's choice but must not move a newer UI context.
6. Grid batch: after the atomic choice, select the first item following the last
   affected item in pre-choice display order. Inline choice advances after that
   exact item. Loupe focuses the next item. Do not wrap.
7. Compare replaces only the active positional pane with the next item after its
   prior member that is not already in the other pane. The other pane remains and
   the replaced position remains active. Do not wrap.
8. If choice filtering removes the target, use the precomputed successor only if
   it survives the new descriptor. Projection reconciliation must not perform a
   second advance. If nothing survives, show the existing No Matches state.

### Filtering

1. Extend `MediaFilter` with `choices: Set<MediaChoice>`.
2. Add a Curation group above media kinds in the existing filter popover:
   `Liked`, `Not Rated`, `Disliked`, each with heart, minus, or X.
3. Selected choices are OR within Curation. Curation is AND with the existing
   kind/format group. Thus Liked + Not Rated means hide Disliked; Liked alone
   means only Liked.
4. Zero selected choices means no curation restriction. Selecting all three
   canonicalizes to the same no-filter representation. `Clear Filters` clears
   choice and media-type restrictions together.
5. Keep sort and choice orthogonal. Do not add choice sort order, sidebar smart
   collections, counts, saved filters, or persisted query state.
6. A choice change is structural when the active descriptor filters choices and
   detail-only otherwise. Start with one correct Store notification and query
   path; add notification specialization only if measurement proves the simple
   path insufficient.

### Move to Trash

1. **Move to Trash** is an explicit filesystem mutation, separate from Disliked.
   Disliking never deletes or hides an item, and moving an item to Trash never
   first changes its choice.
2. Move the proven physical members of each targeted catalog item: its primary
   original and cataloged useful `.xmp`/`.srt` companions. Do not discover
   companions by a same-basename heuristic. Future bundled-media concepts such as
   Live Photos extend this typed membership first; deletion does not anticipate
   them with filename guessing.
3. Use `FileManager.trashItem` off MainActor. Never call `removeItem`, unlink, or
   provide a permanent-delete fallback. Never read media bytes or deliberately
   materialize a dataless cloud placeholder. Stop and research the platform path
   if runtime evidence shows system Trash forces materialization.
4. A dedicated `MediaTrashCoordinator` owns a lossless serial command lifecycle.
   Generalize Store's typed reorganization lease into a per-root namespace-
   mutation lease used by reorganization and Trash; import publication must not
   begin against a leased destination. Store supplies typed root identity and the
   physical-member snapshot; every owner revalidates its lease after each await.
5. For each item, trash cataloged companions first and its primary last. Record
   per-path success. A partial failure is not rolled back and is never reported as
   total success; reconcile exactly the paths the filesystem proves moved while
   retaining unmoved members/items.
6. After a complete success, Grid selects the next survivor, Loupe focuses the
   nearest survivor, and Compare prunes or replaces the removed active pane. This
   navigation is independent of the advance-after-choice preference. A stale UI
   completion may reconcile catalog truth but cannot move a newer view context.
7. Routine successful moves have no confirmation or success alert because system
   Trash is recoverable. A single-item failure shows **This Item Couldn't Be Moved
   to Trash**; multi-item partial or complete failure shows **Some Items Couldn't
   Be Moved to Trash**. The message gives bounded item counts without raw paths and
   offers **Show in Finder** and **Dismiss**. Failed items remain selected. Show in
   Finder selects the first still-existing failed primary or opens its containing
   folder.
8. A crash does not trigger rollback or a speculative journal. The next reachable,
   complete scan reconciles filesystem truth. Add durable recovery state only if a
   fault-injection experiment proves that this simple path cannot recover.

### Accessibility

1. Extend tile labels in the existing required order: filename, media kind,
   preview/format state, then `liked`, `not rated`, or `disliked`, then transient
   selection where AppKit supplies it.
2. Grid and filmstrip do not add three Tab stops for every item. Expose `Like
   item`, `Mark item as not rated`, and `Dislike item` as VoiceOver custom actions
   on the item, and retain collection keyboard navigation plus `P/U/X`.
3. Hover-only buttons do not enter Tab order or appear on keyboard focus. Loupe
   and Compare expose the item/pane as the focusable command target; `P/U/X`, the
   Photo menu, and VoiceOver custom actions operate on that target. Focus rings
   are never suppressed.
4. Each control has a verb-first accessibility label and selected state/value.
   Announce the resulting state once after an accepted action; do not announce
   hover, database invalidation, or every projection tick.
5. Symbol shape communicates state without color. Validate VoiceOver,
   Full Keyboard Access, grayscale, Increase Contrast, Reduce Motion, and Reduce
   Transparency.

## Architecture

```text
pointer control / P-U-X / Photo menu / VoiceOver action
                         │
                         ▼
CatalogWindowViewModel.chooseMedia(choice, target, origin)
  ├─ resolves exact IDs and pre-await navigation snapshot
  └─ lossless serial MediaChoiceCommand stream
                         │
                         ▼
CatalogStore.setMediaChoice(choice, ids) ── one SQLite transaction
  ├─ preserves filesystem facts and every other overlay column
  └─ emits catalog invalidation after commit
                         │
             ┌───────────┴───────────┐
             ▼                       ▼
CatalogProjection             command completion
  ├─ SQL choice filter          ├─ typed stale checks
  └─ detail refresh             └─ optional one-step advance
             │
             ▼
Grid / filmstrip / Loupe / Compare render one catalog value
```

Use a dedicated lossless serial `MediaChoiceCommand` consumer rather than adding
closures to `CatalogMutationIntent`, making detached tasks per keystroke, or
optimistically duplicating catalog truth on MainActor. The command contains only
typed IDs, choice, target/origin, and the minimum navigation snapshot. Store owns
the transaction; ViewModel owns post-commit UI navigation.

Move to Trash follows a separate constructive/destructive command path:

```text
Command-Backspace / Photo > Move to Trash
                    │
                    ▼
CatalogWindowViewModel.moveTargetedMediaToTrash()
  └─ lossless serial command + typed UI snapshot
                    │
                    ▼
MediaTrashCoordinator
  ├─ acquires generalized root namespace-mutation lease
  ├─ revalidates source/session and cataloged physical members
  └─ FileManager.trashItem off MainActor, companions before primary
                    │
          ┌─────────┴─────────┐
          ▼                   ▼
exact-path Store         truthful completion
reconciliation           navigation or failure alert
```

## Exact Change Map

### Domain and persistence

- `Otos/Models/CatalogModels.swift`
  - Add `MediaChoice`.
  - Add choice to `MediaTileDetail` and stored asset/detail mappings.
- `Otos/Stores/CatalogStorePersistence.swift`
  - Add migration `v14_media_choice` with non-null text `media_choice`, default
    `notRated`, and a CHECK constraint for the three raw values.
  - Update schema fixtures and compatibility tests without destructive reset.
  - Preserve/copy choice in import settlement and every row-copy/remap statement.
- `Otos/Stores/CatalogStore.swift`
  - Add atomic `setMediaChoice(_:for:)` returning which requested IDs existed and
    whether values changed; an all-current request is successful, not failure.
  - Extend tile-detail reads and catalog invalidation.
- `Otos/Stores/CatalogQueryGateway.swift`
  - Add parameterized choice predicates; never interpolate raw values into SQL.
  - Preserve current index-backed order plan. Use `EXPLAIN QUERY PLAN` proof.

### Query, projection, and filter UI

- `Otos/Models/CatalogQueryModels.swift`
  - Add `MediaFilter.choices`, group-aware `isActive`, canonicalization, diagnostic
    description, and pure inclusion helpers.
- `Otos/Services/CatalogProjection.swift` and build/diagnostic helpers
  - Publish choice-filtered identity order and detail generations without moving
    choice derivation onto MainActor.
- `Otos/Views/CatalogToolbarControls.swift`
  - Add the labelled Curation filter group and accessibility state.
- `Otos/ViewModels/CatalogWindowViewModel.swift`
  - Add pure choice-filter intents that continue using the query-generation gate.

### Mutation and navigation ownership

- Add `Otos/ViewModels/CatalogWindowViewModelChoice.swift` with the file guide,
  `MediaChoiceTarget`, `MediaChoiceOrigin`, `MediaChoiceCommand`, stream ownership,
  target resolution, serial forwarding, typed post-await validation, and advance
  policy.
- `Otos/ViewModels/CatalogWindowViewModelViewMode.swift`
  - Add `activeComparePane`, pane activation, swap intent, and focused Compare
    advance without Select/Candidate roles.
- `Otos/Models/ComparePairPolicy.swift`
  - Add pure `swapped` and `replacingActiveWithNext` policies.
- `Otos/ViewModels/CatalogWindowViewModelMutation.swift`
  - Do not absorb media choice into root/source mutation execution. It remains a
    separate high-frequency command lifecycle with UI completion semantics.

### Rendering and input

- Add `Otos/Views/MediaChoicePresentation.swift` for pure state/action copy,
  symbols, hover overlay geometry, selected-control treatment, and accessibility
  values. It returns no resting curation presentation.
- `Otos/Views/MediaAssetTileView.swift`, `MediaGridItem.swift`, and bridge input
  files
  - Add tracking-area hover controls, consumed button events,
    VoiceOver actions, and scoped `P/U/X` routing.
  - Preserve no-blank thumbnail ownership and the current selection-ring path.
- Add `Otos/Views/MediaChoiceControl.swift` for the shared SwiftUI Loupe/Compare
  control; AppKit tiles use equivalent presentation policy without embedding a
  SwiftUI host per cell.
- `Otos/Views/LoupeView.swift` and `Otos/Views/CompareView.swift`
  - Render hover controls, Compare active-pane focus, and exact
    item intents while keeping the views passive.
- `Otos/ContentView.swift`
  - Pass scalar choice values and closures; do not pass Store or add subscriptions.
- `Otos/OtosApp.swift`
  - Add Photo commands, Photo > Move to Trash with Command-Backspace, and View >
    Swap Compared Photos with correct enablement.

### Recoverable filesystem deletion

- Add `Otos/Services/MediaTrashCoordinator.swift` with a boundary file guide,
  lossless serial ownership, typed post-await validation, per-file results, and
  `FileManager.trashItem` execution outside MainActor.
- `Otos/Stores/CatalogStore.swift`, `Otos/Services/LibraryReorganizationRunner.swift`,
  and `Otos/Services/MediaOperationCoordinator.swift`
  - Generalize the current reorganization lease into one typed root namespace-
    mutation lease, make reorganization and Trash mutually exclusive, prevent
    import publication into a leased destination, supply typed physical-member
    snapshots, and reconcile only proven moved paths. Keep filesystem truth primary.
- `Otos/ViewModels/CatalogWindowViewModelMutation.swift`
  - Resolve Grid/Loupe/active-Compare targets, submit one trash command, reject
    stale navigation, retain failed selection, and surface bounded failure state.
- `Otos/ContentView.swift` and `Otos/ViewModels/CatalogWindowViewModel.swift`
  - Add the bounded actionable failure alert at the existing window-level alert
    owner; do not invent a success toast or confirmation sheet.
- Add `docs/adr/0022-recoverable-media-deletion.md` (or the next free number at
  implementation time) owning the system-Trash-only boundary, generalized lease,
  physical-member ordering, partial-failure truth, and crash reconciliation.

### Settings and documentation

- Add `Otos/Models/BrowsingPreferences.swift` only if more than the one Boolean is
  needed during implementation; otherwise keep one typed defaults key and scalar
  ViewModel property rather than inventing a preferences framework.
- `Otos/Views/SettingsView.swift`
  - Add General as the first pane and the one checkbox. Preserve existing pane
    ownership: it receives a Boolean binding/closure, not the ViewModel.
- `docs/design/design-system.md`
  - Add current-state DES rules for hover-only curation chrome, geometry, semantic
    colors, hit targets, accessibility, and its Photos precedent after the UI
    lands.
- `docs/requirements.md`
  - Replace APP-001's unimplemented-curation exclusion and add rows covering
    choice lifecycle, commands/advance, filter semantics, all-surface UI, and
    recoverable deletion.
  - Amend ARC-032 and MED-001 so their read-only default names this explicit,
    implemented system-Trash exception, and amend APP-008 for the actionable Trash
    failure alert. Do not weaken the default no-write invariant.
- `docs/architecture.md`
  - Add Store/Projection/ViewModel choice ownership and where-to-change guidance.
- `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`
  - Name choice as authored overlay with the existing retain/purge lifecycle.
- `docs/adr/0016-view-modes-and-preview-decode.md`
  - Record active Compare position solely as keyboard action targeting, not a
    Select/Candidate role.
- Delete this plan only after every stage and closeout below is complete.

## Stages And Required Proofs

### Stage 1 — Failing domain, migration, and Store tests

Write tests first:

1. New and migrated rows read Not Rated.
2. Future/unrecognized schema refusal remains nondestructive.
3. One transaction changes all requested existing IDs and no unrelated columns.
4. Repeating the current choice succeeds with zero changed rows.
5. Concurrent scan/enrichment writes cannot erase choice.
6. Proven deletion/root removal purges it with the row; temporary unavailability
   retains it.
7. Reorganization and import overlay reuse preserve it.

Do not change production behavior until these fail for the intended absence.

### Stage 2 — Choice filtering below MainActor

Add pure filter tests and Store query tests:

1. One, two, zero, and all-three choice selections have the specified truth table.
2. Kind/format OR semantics remain unchanged and are ANDed with choice.
3. Canonical all-choice selection equals no choice filter.
4. Query arguments are bound and order remains deterministic.
5. `EXPLAIN QUERY PLAN` retains an appropriate ordered index path for each sort.
6. Query-generation tests prove stale projected state cannot roll back a newer
   choice filter intent.

### Stage 3 — Lossless commands and advance policy

Test the owner without UI rendering:

1. Rapid `P/U/X` commands execute in submission order with none dropped.
2. Grid batch and inline targets resolve exactly as contracted.
3. Same-value `U` advances when enabled and stays put when disabled.
4. Failed Store write never advances.
5. Mode, descriptor, target, or active-pane change during await makes completion
   inert for navigation while retaining the persisted user command.
6. End-of-scope does not wrap.
7. Compare replaces only the active pane and never duplicates the other member.
8. Swap keeps active position and choices attached to their assets.

### Stage 4 — Grid and filmstrip rendering/input

Add pure presentation tests plus AppKit behavior tests:

1. Resting Liked/Not Rated/Disliked output is visually identical: no curation
   badge, dimming, reserved placeholder, or always-visible choice toolbar.
2. Hover reveals exactly three actions at 48, 72, 192, and representative Grid
   sizes with at least 28×28 hit regions.
3. Clicking an action invokes once and triggers no selection, double-click, strip
   replacement, or video action.
4. Item reuse clears hover and cannot show another asset's choice.
5. A detail refresh changes the selected state shown on the next hover without
   blanking a painted thumbnail or revealing resting chrome.
6. `P/U/X` works in Grid/strip and is ignored by text entry or nonbrowser scenes.
7. VoiceOver label/action order and names match the copy table.

### Stage 5 — Loupe and Compare

1. Loupe and each Compare pane are curation-neutral at rest and show the right
   selected choice only in their hover group.
2. Pane control hit testing does not play video or exit Loupe.
3. Compare defaults active right, click activates without changing pair, strip
   replacement activates its target, and the focus indication is perceivable.
4. Keyboard `P/U/X` changes only the active pane item.
5. Down Arrow swaps the pair exactly once; left/right retain slide behavior.
6. Full Keyboard Access reaches the Loupe/Compare target and uses the menu or
   `P/U/X`; invisible hover buttons never create ghost focus stops.
7. Choice/detail changes never paint another asset's state or image.

### Stage 6 — Settings, menus, and HIG/accessibility audit

1. General pane is first and persists the checkbox in an isolated suite.
2. Default is off; relaunch reads the saved value.
3. Menus use exact verb-first title-case copy and accurate enablement.
4. Accessibility Inspector finds labelled actions, values, and visible focus.
5. Grayscale, light/dark, Increase Contrast, Reduce Motion, and Reduce
   Transparency retain every distinction.
6. Keyboard-only walkthrough completes Grid, Loupe, Compare, filtering, swapping,
   and setting adjustment without pointer input.

### Stage 7 — Recoverable Move to Trash

Write coordinator, Store-boundary, and ViewModel tests before wiring the command:

1. Command-Backspace and Photo > Move to Trash submit the same one owner intent;
   text entry, sheets, Settings, and camera/MTP items cannot trigger it.
2. Grid selection, Loupe focus, and active Compare pane resolve the exact targets.
3. The coordinator trashes only cataloged physical members, companions before
   primary, off MainActor, without media-byte reads or materialization requests.
4. Injected filesystem tests prove the production executor uses `trashItem`, never
   permanent deletion, and reports per-path success/failure truthfully.
5. A partial failure reconciles only moved paths, retains failed items/selection,
   logs bounded counts without paths, and presents the exact actionable alert.
6. Success advances to the specified survivor independently of the choice-advance
   preference; stale mode/session/target completions do not navigate.
7. Concurrent import publication, reorganization, Trash, and root mutation are
   excluded by the generalized root namespace lease. Adversarial detach/reattach
   and root-removal tests prove typed ownership is revalidated after every await.
8. Fault injection between every member move proves the next complete reachable
   scan reconciles truth without a journal or rollback.
9. A dataless cloud fixture and filesystem tracing prove Move to Trash does not
   read bytes or request materialization. If system behavior contradicts this,
   stop the stage and revise the researched platform contract before shipping.

### Stage 8 — Current-truth docs and independent closeout

Update requirements, design rules, architecture, and ADRs only to behavior that
has landed. Run a cold review with both required lenses. Invert every claim:

- Can two states coexist in persistence?
- Can a scan, import, reorganization, or enrichment erase choice?
- Can a recycled tile show the prior asset's selected hover control?
- Can a state leak through resting badge, dimming, or invisible focus controls?
- Can a keyboard-only or VoiceOver user perform and perceive every choice even
  though direct content controls are hover-only?
- Can bare keys fire while typing?
- Can a stale completion move a newer view?
- Can active filtering advance twice or leave a wrong pane?
- Can Disliked be mistaken for deletion or unavailable media?
- Can Move to Trash permanently delete, target a camera staging file, materialize
  cloud media, or claim success after moving only part of an item?
- Can a color-blind or VoiceOver user distinguish all states?

Fix every confirmed issue before merge and delete this plan when complete.

## Verification And Evidence

- Run focused tests after each stage.
- Run `script/verify.sh` with the repository's full Xcode 27 beta toolchain.
- Run `script/smoke-run.sh --jank` over a fixture containing all three states in
  Grid, Loupe, Compare, and 48 pt filmstrip.
- Capture screenshots proving identical Liked/Not Rated/Disliked rest states plus
  light/dark hover, smallest/largest tile, Loupe, both active Compare positions,
  Curation filter, and General Settings.
- Read `script/logs.sh` output; prove one catalog write and at most one navigation
  completion per action, with no raw filename logging.
- Profile the hover/reuse/detail-refresh and Move-to-Trash submission paths.
  Record the worst main-actor span and require it below 100 ms; scrolling and
  hover must remain well below that bound.
- Verify production catalog and preferences remain untouched by tests.
- Run `script/dod-report.sh`; post the one final DoD report only after merge and
  cleanup, as required by AGENTS.md.

## Non-goals And Guards

- No star ratings, color labels, favorites collection, smart albums, saved
  filters, search, AI culling, or automatic choice.
- No delete-disliked command, auto-delete, hiding by default, permanent deletion,
  camera-source deletion, or hover trash button. The only filesystem write added
  here is explicit user-initiated Move to Trash.
- No XMP/sidecars or durable identity beyond filesystem path.
- No color-only meaning and no red/green curation state.
- No Select/Candidate Compare roles, pane role labels, promote command, or choice
  tied to pane position.
- No optimistic second truth in ViewModel, tile store, or SwiftUI local state.
- No resting curation badge/dimming, keyboard-focus reveal, invisible Tab stop,
  global key monitor, or undersized filmstrip hit target. Hover is the only direct
  content control; menu, shortcut, and accessibility paths remain equivalent.
- No cache, generalized rating framework, protocol, or background pipeline without
  a present requirement and evidence.

## Definition Of Done

Done means all stages are implemented and falsified; required source, tests,
requirements, design rules, architecture, and ADRs agree; local verification and
runtime/accessibility evidence are green; the implementation PR is merged to
`main`; this plan is deleted; and its branch/worktree/stashes are cleaned with a
clean synchronized next-start `main`.
