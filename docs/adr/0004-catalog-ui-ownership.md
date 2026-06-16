# ADR 0004: Catalog UI Ownership

- Status: Accepted
- Date: 2026-06-15
- Spec: `docs/specs/0007-catalog-window-model.md`

## Context

Otos has one catalog browser surface and exactly one main window. The earlier
catalog UI split used `CatalogSession` for shared catalog state and
`CatalogBrowserState` for window-local sidebar selection and projection state.
That split implied a multi-window architecture that Otos does not have and must
not grow.

The app still needs strict ownership:

- SQLite, migrations, in-memory catalog truth, and scans must stay out of
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
- The scene choice for the main window: singleton SwiftUI `Window`, not
  `WindowGroup`.

## Related Decisions This ADR Does Not Own

This ADR references but does not own:

- SQLite schema, GRDB connection type, in-memory catalog retention, scanner
  filesystem facts, and scan persistence cadence. Those belong to ADR 0002.
- Library-root identity, unsandboxed root access, and the decision not to use
  bookmarks or App Sandbox. Those belong to ADR 0003.
- Store change notifications, projection-owned publication cadence, ViewModel
  state stream consumption, and transient library availability. Those belong to
  ADR 0005.
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
  migrations, in-memory catalog state, scan lifecycle, and raw point-in-time
  snapshot construction.
- `CatalogProjection` remains a non-MainActor actor. It owns catalog library
  sorting, asset sorting, selected-scope filtering, title lookup, availability
  hiding, empty-state selection, selected-library validation, and the UI-state
  publication loop described by ADR 0005.
- `CatalogWindowViewModel` is the single main window's `@MainActor @Observable`
  adapter. It owns final SwiftUI-visible state assignment, sidebar selection,
  user intents, and task lifetimes. It does not own SQLite, filesystem traversal,
  scanning, sorting, filtering, availability policy, or projection cadence.
- `ContentView`, `SidebarView`, `MediaTableView`, and `SettingsView` are passive
  SwiftUI surfaces. They render inputs, hold local control state when
  appropriate, bind controls, and call model intents.
- Settings receives `[CatalogLibraryState]` plus add/remove closures; it renders
  library name/path/availability and does not receive catalog snapshots, scan
  activity UI, media rows, sidebar state, or the full window ViewModel.

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

### Alternative C: Keep `CatalogSession` And `CatalogBrowserState`

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

## Consequences

Positive:

- The architecture now says what the app actually is: one main catalog window.
- `ContentView` becomes passive composition.
- MainActor work remains limited to UI state assignment and user intents.
- Settings receives only the state it needs.
- Retired state owners are removed instead of patched around.

Negative:

- `CatalogWindowViewModel` is a central UI adapter and must remain disciplined.
- Tests need explicit hygiene checks for retired names and `WindowGroup`.

## Performance And Simplicity

This decision prioritizes simple ownership over speculative flexibility. It does
not add caches, database pools, query observations, worker queues, or a
multi-window state graph. Projection remains off the MainActor because that is a
current responsiveness requirement, not speculative scale work.

## Verification

- Source hygiene rejects `CatalogSession`, `CatalogBrowserState`,
  `CatalogBrowserProjection`, `CatalogWindowModel`, and main-window
  `WindowGroup`.
- Source hygiene proves `ContentView` does not coordinate catalog notifications,
  snapshot construction, or projection work.
- Projection tests prove `CatalogProjection` owns sorting, filtering, title
  lookup, availability hiding, empty-state selection, and missing-library
  fallback.
- ViewModel tests prove `CatalogWindowViewModel` owns start idempotence, state
  stream consumption, sidebar selection routing, resolved selection application,
  and add/remove routing.
- Local verification runs through `script/verify.sh`.
