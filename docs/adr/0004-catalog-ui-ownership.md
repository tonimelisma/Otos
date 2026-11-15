# ADR 0004: Catalog UI Ownership

- Status: Accepted
- Date: 2026-06-15
- Last updated: 2026-06-22

## Context

Otos has one catalog browser surface and exactly one main window. The earlier
catalog UI architecture is therefore intentionally centered on one window model,
not a session/window graph for multiple browsers.

The app still needs strict ownership:

- SQLite, migrations, Store-owned catalog truth, and scans must stay out of
  SwiftUI views.
- Sorting, filtering, title lookup, availability hiding, empty-state selection,
  and selected-library validation must stay off the MainActor.
- Views must not coordinate catalog notifications, snapshot construction, or
  projection invalidation.
- Settings must receive only the projected library rows and add/remove intents it
  needs.

## Decision Area This ADR Owns

This ADR owns:

- The permanent single-main-window catalog UI architecture.
- The boundary between `CatalogStore`, `CatalogProjection`, and
  `CatalogWindowViewModel` at the UI ownership level.
- The rule that SwiftUI views are passive composition surfaces for catalog UI.
- The rule that Settings receives narrow library-management inputs.
- ViewModel task lifetime and delivery semantics for projected state and catalog
  mutations.
- The scene choice for the main window: singleton SwiftUI `Window`, not
  `WindowGroup`.

## Related Decisions This ADR Does Not Own

This ADR references but does not own:

- SQLite schema, GRDB connection type, Store-owned query/read model, scanner
  filesystem facts, and scan persistence cadence. Those belong to ADR 0002.
- Library-root identity, unsandboxed root access, and the decision not to use
  bookmarks or App Sandbox. Those belong to ADR 0003.
- Store change notifications, projection-owned publication cadence, ViewModel
  state publication, sidebar-selection delivery, and transient library
  availability. Those belong to ADR 0005. This ADR owns the ViewModel consumer's
  lifetime but not Projection's publication mechanics.
- Future metadata, thumbnails, preview, import, export, rendering, and editing
  pipelines. Those require their own specs or ADRs if they are ever implemented.

This ADR intentionally does not leave a future multi-main-window decision open.
Otos has exactly one main window as a permanent product and architecture
invariant.

## Decision

Use a single-window catalog UI ownership model:

- `OtosApp` owns one `CatalogWindowViewModel` and declares one main
  `Window("Otos", id: "main")`.
- The app removes the standard New Window command for the main window.
- `CatalogStore` remains the only runtime catalog truth owner. It owns GRDB,
  migrations, root runtime state, scan lifecycle, Store-owned asset queries, and
  cheap change notifications.
- `CatalogProjection` remains a non-MainActor actor. It owns catalog library
  sorting, asset sorting, selected-scope filtering, title lookup, availability
  hiding, empty-state selection, selected-library validation, and the UI-state
  publication loop described by ADR 0005.
- `CatalogWindowViewModel` is the single main window's `@MainActor @Observable`
  adapter. It owns final SwiftUI-visible state assignment, sidebar selection,
  explicit selection delivery, catalog mutation delivery, user intents, and
  task lifetimes. Projected state is consumed by a ViewModel-owned task that
  holds the ViewModel only while applying one completed state. Sidebar selection
  uses a newest-value stream, while add/remove commands use a separate lossless
  serial stream. It does not own SQLite, filesystem traversal, scanning, sorting,
  filtering, availability policy, or projection cadence.
- `ContentView`, `SidebarView`, `MediaGridView`, and `SettingsView` are passive
  SwiftUI surfaces. They render inputs, hold local control state when
  appropriate, bind controls, and call model intents.
- Settings receives `[CatalogLibraryState]` plus add/remove closures; it renders
  library name/path/availability and does not receive catalog snapshots, scan
  activity UI, media rows, sidebar state, or the full window ViewModel.

### Applying A Publication

The ViewModel's apply of a projected state costs in what changed, never in the
library's size. What changed is a fact Projection already holds when it publishes
(ADR 0005), so it is handed over as identity rather than re-derived on the main actor:

- The grid's order, day buckets and stacks are one immutable `CatalogGridContent`
  held by reference. An unchanged content arrives as the last publication's own
  object, so `sharesContent(with:)` — one pointer comparison — answers whether the
  order, its days or its stacks moved. A content whose order and days are the last
  one's but whose stacks are not keeps the last one's order (`sharesOrder(with:)`), so
  the grid's mutation gate and Story tell "same order" by identity too.
- `state` is observed by hand (`access` / `withMutation`) instead of through the
  macro's tracked storage, whose setter compares an `Equatable` old value with the new
  one; for a window state that comparison walked every identity, day and stack on every
  enrichment batch. A published state is a change by construction, so a set notifies.
- Selection pruning, loupe, compare and story focus reconciliation, the ordered
  selection behind every target, and item-target membership ask the content's position
  index (`MediaDisplayOrder`), so they cost in the selection and the focus. The policies
  take any `MediaDisplayOrder`; a plain `[MediaAssetID]` answers the same questions by
  walking itself, for callers whose order is small.
- Stacks carry the selection, and duplicate picks are forgotten, only when the content
  or the groups changed.

Measured on 158,000 tiles with a tenth of them collapsed pairs, in the Debug build the
owner runs: a republication that moved nothing visible took 405 ms on the main actor and
an order change under a loupe 289 ms; both now cost a fraction of a millisecond plus the
work the change itself owns (`window.apply.*` in `OtosTests/BenchmarkTests.swift`).

Rejected: comparing the order on the main actor with a faster algorithm (still library-
sized, and SwiftUI's observation compared it again); revision numbers stamped on the
state (two independently built states could share a number, and every test-built state
would need one — an object's identity cannot collide); a lazily built index without a
build at publication (the first main-actor lookup after a change would build it).

While the sidebar has selected a scope that Projection has not published yet, the pane
shows the selected scope waiting (DES-118, APP-084): `CatalogWindowViewModel.detailPane`
is the one answer to which pane shows — the selected scope's surface, and whether its
state has been applied — so the title, the surface and its bar follow the click in the
step that applies it, and nothing of the scope left is drawn. The waiting pane's one
indicator appears when the pane reports a presented frame without the state, a platform
report rather than a timer (ADR 0033). The acts still check `showsSelectedScope` as a
defence for anything that keeps the left scope's state: the targets are empty and the
duplicates list's, the People gallery's, the map's and On This Day's acts do nothing.

Move to Trash is shown before the Store records it (DES-119, APP-085). Projection, the
owner of what is shown, takes the items off the window it last built on a `hide` intent
(`CatalogProjectionIntent`, one lossless stream with the queries) and keeps them off every
later publication until a pass that read the catalog after the Store's mark covers it;
the trash queue's consumer relays the mark's landing (`hideLanded`) or its failure or
undo (`hideWithdrawn`). Rejected: removing the items in the view model's copy of the state
(a second owner of what is shown, and an order-sized filter and index build on the main
actor); waiting for the mark (a write that queues behind background writers, seconds
under load); re-reading the catalog for the hide (the read is the cost being avoided).

Every other act is shown first too (DES-120). What decides the owner is what the act
changes. A choice changes a tile's detail, which no publication carries: the grid, the panes,
the toolbar control and the Info pane each read it through the one tile-detail read
(`MediaTileDetailReader`). So the choices submitted and not read back are held beside that
read, in `MediaChoiceOverlay`, which the view model submits to, lands and withdraws in the
steps that handle the intent and the Store's answer, and which answers every read: a read
numbers its start, a landing records the number reached, and a choice retires when a read
that started after its landing answers for its item (ADR 0032 rule 2), so a read from before
the write can never take it back. The tiles on screen take the choice from the tile store in
the same step and the grid reconfigures the visible ones in place
(`TileChoiceChange`), never applying its structure. What a choice does to what is shown —
a photo leaving a choice filter it no longer matches — is Projection's, on the same lossless
intent stream as the hide (`CatalogProjectionIntent.choose`), kept as a hold beside the
hide's until a pass that read the landed write covers it; both are `WindowHold`s. A People act
changes People, which the projection publishes as built by `PeopleAssignment`: the one People
overlay (`PendingPeopleActs`) lays each act's known effect over the published state with the
builder's own gallery order (`CatalogPeopleState.overlaying`), and retires it when a state
whose build covers the request the write's answer named arrives (`CatalogPeopleState.covers`,
`CatalogProjection.requestPeopleBuild`). An expansion is the collapse of an order Projection
holds, so Projection shows it inside the intent that asks for it (`showExpansion`) instead of
waiting for the loop, and a pass in flight publishes with it. Rejected: a pending-choice map in
the view model's copy of the window state (a second owner of what is shown, and no answer for a
read already in flight); writing the choice into the tile store alone (a read from before the
write lands puts the old value back); a People overlay that retires at the Store's answer (the
gallery would revert until the next build).

## Alternatives Considered

### Alternative A: Single-Window Catalog ViewModel

Use `CatalogWindowViewModel` as the only MainActor adapter for the one main
window, while preserving `CatalogStore` and `CatalogProjection`.

Pros:

- Matches Otos's permanent one-main-window product rule.
- Removes a speculative layer without merging persistence and UI work.
- Keeps Views passive and keeps projection work off the MainActor.
- Keeps Settings narrow.

Cons:

- The ViewModel has a central role and needs tests/comments to prevent it
  becoming catalog truth.

Failure modes:

- Developers could add store or projection work to the MainActor ViewModel unless
  source hygiene and comments guard the boundary.

### Alternative B: Projection In `CatalogStore`

Let the store produce UI-ready window state.

Pros:

- Fewer moving parts.
- One catalog actor can see all in-memory data.

Cons:

- Mixes persistence/scanning with view-specific selection, titles, and sorting.
- Makes store tests depend on presentation behavior.

Failure modes:

- `CatalogStore` becomes an application model and accumulates UI concerns.

### Alternative C: Split Shared Session And Browser State

Keep the previous session/browser split and make views thinner.

Pros:

- Clearer separation for a true multi-window app.
- Lower rename churn.

Cons:

- Otos is not a multi-window app.
- Leaves a layer whose main justification is a future that is explicitly out of
  product scope.
- Keeps more task and state owners than needed.

Failure modes:

- Agents continue asking about or designing for multiple main windows.

### Alternative D: View-Orchestrated Projection

Let `ContentView` subscribe to catalog changes and call projection when catalog
state or sidebar selection changes.

Pros:

- Locally visible data flow in the view file.
- Fewer model methods.

Cons:

- Views become orchestration owners.
- SwiftUI `.task` and synchronous setup can inherit MainActor isolation.
- Cancellation and publication details leak into view code.

Failure modes:

- Sorting/filtering, notification subscription, or snapshot construction drifts
  into view updates.

### Alternative E: Independent Task Per Catalog Mutation

Create an unstructured task for every add/remove action.

Pros:

- Minimal forwarding code.

Cons:

- The ViewModel cannot cancel or order the tasks.
- Store actor reentrancy permits operations to overlap at suspension points.

Failure mode: completion order differs from user submission order.

### Alternative F: One Stream For Selection And Mutations

Send every user intent through one stream and forwarding task.

Pros:

- One producer/consumer pair.

Cons:

- Selection and mutations require incompatible buffering semantics.
- Database work can delay sidebar responsiveness.

Failure mode: either obsolete selections accumulate or accepted mutations drop.

## Consequences

Positive:

- The architecture now says what the app actually is: one main catalog window.
- `ContentView` becomes passive composition.
- MainActor work remains limited to UI state assignment and user intents.
- Settings receives only the state it needs.
- There is one explicit MainActor adapter instead of overlapping UI-state owners.
- State subscription cannot indefinitely retain that adapter, and ViewModel
  mutations reach Store serially in user order.

Negative:

- `CatalogWindowViewModel` is a central UI adapter and must remain disciplined.
- Tests need explicit hygiene checks for retired names and `WindowGroup`.

## Performance And Simplicity

This decision prioritizes simple ownership over speculative flexibility. It does
not add caches, database pools, query observations, worker queues, or a
multi-window state graph. Projection remains off the MainActor because that is a
current responsiveness requirement, not speculative scale work.

## Verification

- Source hygiene rejects multiple main-window construction and retired parallel
  UI-state owners.
- Source hygiene proves `ContentView` does not coordinate catalog notifications,
  snapshot construction, or projection work.
- Projection tests prove `CatalogProjection` owns sorting, filtering, title
  lookup, availability hiding, empty-state selection, and missing-library
  fallback retention with newer-intent precedence.
- ViewModel tests prove `CatalogWindowViewModel` owns start idempotence, state
  stream consumption, explicit sidebar intent delivery, resolved selection
  application without feedback, deallocation with an active subscription,
  lossless ordered add/remove delivery, failure continuation, and queued-command
  cancellation.
- Local verification runs through `script/verify.sh`.
