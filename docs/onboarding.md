# Otos Onboarding — A Walkthrough Of The Code

This is a guided tour of the Otos codebase in the order that makes it easiest to
understand. It explains not just *what* each piece does but *why* it is shaped the
way it is — why there are actors, why we capture `weak self`, why work is split
across types, and why the data flows in one direction. Read it top to bottom once;
after that it is a map you can jump around in.

It describes the code as it exists now. If you change architecture or behavior,
update this document in the same change (see the living-documentation rule in
`AGENTS.md`). Treat it as the current reader's map, not optional intro text.

---

## 1. The one big idea

**The user's filesystem is the source of truth. Otos is an overlay on top of it.**

The user's photos and videos live wherever they put them — usually a cloud-synced
folder like OneDrive. Otos never moves them, never imports them into a hidden
library, and never writes into those folders. Everything Otos stores (the catalog
and thumbnail/metadata overlay, and later any edits) lives in its own Application
Support directory and is a *subordinate, rebuildable projection* of what is on
disk. When the catalog and the filesystem disagree, the filesystem wins.

Everything else in the architecture follows from this. The full set of rules is in
`AGENTS.md` under "Non-Negotiable Principles"; the deeper reasoning is in
`docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`.

## 2. The shape of the app in 30 seconds

Otos has exactly **one window** (a sidebar of libraries on the left, a media grid on
the right) and a separate **Settings** window for adding/removing libraries.

Data flows in **one direction**, and that one-directional flow is the most important
thing to internalize:

```
  filesystem (the truth)
        │  read-only scan
        ▼
  CatalogStore        ← the only owner of SQLite catalog truth and query APIs (an actor)
        │  cheap "something changed" signal + ordered-ID/detail queries
        ├──────────────▶ EnrichmentCoordinator  ← asks Store for enrichment candidates,
        │   writes back     produces thumbnails + metadata, writes them to the Store
        ▼
  CatalogProjection   ← turns raw truth into a UI-ready view (a second actor, off the main thread)
        │  CatalogWindowState, immediate for user query intents and roughly 1s for background changes
        ▼
  CatalogWindowViewModel  ← the bridge to SwiftUI (lives on the main thread)
        │  assigns @Observable state
        ▼
  SwiftUI views  →  AppKit NSCollectionView (the high-volume grid)
```

Nobody reads "upward." A view never calls the database; the database never knows a
view exists. Each layer only hands a value to the next. This is what keeps the app
understandable: to answer "where does X happen?" you find the one layer that owns X.
The **`EnrichmentCoordinator`** is the one write-side branch: it is the mirror of the
Projection — where the Projection reads Store truth *into UI state*, the coordinator
queries the same truth *into derived-product work* (thumbnails, metadata) and writes
results back through the Store, which then flows out to the views like any other
change.

## 3. Why there are three actors (the concurrency model)

An **actor** in Swift is a type that protects its own mutable state by letting only
one task touch its insides at a time. You already know what they are; here is *why
Otos uses them*:

- **`CatalogStore` is an actor** because SQLite, root runtime state, scan ownership,
  and background scans that stream in thousands of files all meet there. Making the
  Store an actor means every mutation of root state and every catalog write/query
  boundary is serialized for free — we never reach for a lock.
- **`CatalogProjection` is a separate actor** because turning catalog truth into
  window state must **not** happen on the main thread (that is what makes a UI
  hang). Store owns the indexed asset-order query; Projection owns the coalesced
  publication loop and asks pure policy helpers for the library ordering,
  availability hiding, sidebar scope, title, and empty-state rules around that
  query.
- **`EnrichmentCoordinator` is a third actor** because producing thumbnails and
  metadata means reading bytes (and downloading cloud files), scheduling two worker
  pools, and tracking what is in flight — shared mutable state that must not race and
  must not run on the main thread. It is an actor for the same reason the Store is:
  to serialize that state for free. The heavy work itself (decoding, parsing,
  downloading) runs *inside its worker tasks*, off the actor; only the fast
  scheduling and result hand-off run on it.
- **`CatalogWindowViewModel` is `@MainActor`** because it touches SwiftUI state, and
  all UI must run on the main thread. It does *only* the bridging: it never sorts,
  queries the database, or scans. If you ever find heavy work creeping into it, that
  is a bug — push it down into the Store, Projection, or coordinator.

The rule of thumb: **the main thread only assigns final UI state and starts work;
everything expensive happens on an actor off the main thread.**

## 4. The files, in reading order

### `Otos/Models/CatalogModels.swift` — the nouns

Start here. These are the plain value types (`struct`s and `enum`s) that flow between
the layers. Two design choices to notice:

- **Typed paths, not strings.** A library's identity is `LibraryRootPath`, a file's
  is `MediaRelativePath`, and the two together make a `MediaAssetID`. Under the hood
  they are just text, but giving them distinct types means the compiler stops you
  from ever passing a file path where a library path is expected — a whole class of
  bug becomes impossible.
- **Identity vs detail.** `CatalogMediaGridState` carries the sidebar scope,
  ordered `MediaAssetID`s, and a scalar `detailRefreshGeneration`. Visible tile
  details are fetched separately by ID through the Store-backed AppKit grid reader.
  The generation lets one thumbnail arrival invalidate visible detail reads without
  copying 25k asset values through a 25k-item publication.

### `Otos/OtosApp.swift` and `Otos/ContentView.swift` — the skeleton

`OtosApp` declares the single `Window` (deliberately not a `WindowGroup`, because one
main window is a permanent product rule) and owns the one `CatalogWindowViewModel`.
`ContentView` is intentionally *passive*: it reads `viewModel.state` and renders it.
It does not subscribe to anything, sort anything, or call the database. If you want
to know why a view is "dumb," that is the design — views render, the model decides.

### `Otos/Stores/CatalogStore.swift` — the single source of runtime truth

This is the heart. Read its file guide at the top first. Key whys:

- SQLite is the per-asset working set. The Store keeps root identity, availability,
  scan lifecycle, and notification state resident, but asset facts and enrichment
  overlay are read through Store-owned queries.
- It exposes a **cheap "something changed" notification** plus query APIs, rather
  than pushing big values to subscribers. Why: the Projection decides *when* to do
  background work (on its own one-second clock, with immediate wakeups for user
  query intents), so the Store only needs to say "I changed," then answer the
  current descriptor query when Projection asks.
- **The scan ownership lease (`ActiveScan`).** Because the Store is an actor, it can
  process a "remove this library" message *in the middle* of a scan (every `await`
  is a yield point). So each scan carries the root path plus the private database row
  id it owns, and the Store re-checks "do I still own this scan?" after every
  `await`. This is why a removed-then-re-added library can never have a stale scan
  write into its replacement.
- **The enrichment write lease.** Enrichment is allowed to lag behind scans: a tile
  may keep showing the best-known old thumbnail or date while newer bytes are being
  processed. What must not happen is a stale completion stamping the newer source
  as current. So `applyEnrichmentBatch` uses a SQLite `WHERE` clause that checks
  both existence and the source `(size, mtime)` signature before writing. Thumbnail
  files generated by the enricher are staged first; Store promotes a staged file to
  the final deterministic name only after that SQLite validation passes. If the
  file changed, the completion is ignored, its staged thumbnail is discarded, the
  previous final thumbnail remains, and the asset stays eligible for fresh enrichment.
- **Removing a library purges its overlay.** A library removal deletes the catalog
  rows for that root and then deletes the thumbnail files those rows referenced.
  That is the same overlay lifecycle as proven deletion: when Otos no longer holds
  a row, it does not keep the row's private thumbnail file.
- **Clean pre-user schema reset purges app-owned thumbnails.** When an incompatible
  local catalog schema is reset, Store recreates the current SQLite schema and then
  clears the app-owned thumbnail directory because the rows that referenced those
  derived files were discarded. Originals live in user media folders and are never
  touched by that reset.
- **Notify only on real change.** When a re-scan re-observes identical files, the
  Store does *not* fire its change notification. Why: otherwise every routine re-scan
  would wake the whole sort/filter/render pipeline for nothing. (Measured: this
  removed most of the work during a launch re-scan.)

### `Otos/Stores/CatalogStorePersistence.swift` — the SQLite edge

The actual SQL. The one thing to know: SQLite row ids stay *private to this file*.
The rest of the app identifies things by filesystem path, never by database id, so
the database is an implementation detail you could swap out. The current browser
query is one `CatalogQueryDescriptor` over generated best-value columns:
`best_capture_unix`, `best_kind`, and `best_format`. Scan and enrichment persist
facts; SQLite owns the current best-value ranking used by tile dates, sort order,
and filter membership.

### `Otos/Services/CatalogScanner.swift` — read-only filesystem observation

Walks a library folder and reports the image and video files it finds. Whys:

- It reads only **filesystem facts** (name, size, dates, type) and never file
  *bytes*. This matters because most media is in the cloud as "dataless" placeholders;
  reading bytes would force gigabytes of downloads. Filesystem facts are free; media
  *metadata* (EXIF and the like) is not, which is why it is the enrichment
  coordinator's job, not the scanner's. (Throughout Otos, "metadata" means media
  metadata, never filesystem facts — FND-059.)
- It **skips packages and symlinks** so it never descends into something like a
  `.photoslibrary` bundle or follows a link out of the library.
- It **skips non-media regular files** whose `contentTypeKey` is nil or does not
  conform to image or movie (`MediaEligibility`). Scan membership is decided here,
  not in Projection or the grid.
- It is a pure, idempotent *observation* — it makes no decisions about deletion or
  UI. The Store decides what to do with what the scanner saw.

### `CatalogProjection`, `CatalogWindowPolicy`, and `CatalogProjectionDiagnostics` — truth → view

Read `CatalogWindowPolicy` first if you want the pure rules: library sorting,
selection fallback, descriptor resolution, title lookup, scope membership, and
empty-state choice. Read `CatalogProjectionDiagnostics` next for equal-state
comparison and bounded JSONL field construction. Then read `CatalogProjection`,
the actor that owns the long-running tasks, dirty flags, in-flight publication
state, Store subscription, and stream continuation.

Together these files take current library rows plus Store-ordered asset IDs and
produce a `CatalogWindowState`. Whys:

- **Two-tier cadence.** During a scan or enrichment sweep the Store might change
  many times. Projection coalesces Store-originated background changes into a
  roughly one-second stream, while direct sidebar/sort/filter intents wake
  publication immediately. The Projection registers its Store change subscription
  before relying on the loop, so a detail-only thumbnail/date update immediately
  after startup still advances the grid detail-refresh generation.
- **Asset order and filter membership are Store queries.** The descriptor carries
  sidebar scope, media filter, and sort order. SQLite orders by indexed generated
  best values or persisted sort facts and Projection receives only IDs. The schema
  has root-local indexes for selected-library reads and global indexes for All
  Media reads, so SQLite can stream the ordered identities without temporary sort
  work for the covered paths. Projection asks Store for ordered IDs on every
  publication because enrichment can change best date, kind, or format. If the
  visible scope is empty, Projection asks Store for separate counts so it can tell
  "no media exists," "media exists but every root is unavailable," and "the active
  filter matches nothing" apart. There is no full asset map in window state.
- **Equal-state suppression.** If a rebuild produces a state identical to the last
  one, it is not published — the UI is never disturbed by a no-op.

### `Otos/ViewModels/CatalogWindowViewModel.swift` — the bridge

The `@MainActor` adapter between SwiftUI and the actors. This is where **`weak self`**
earns its keep, and it is worth understanding precisely:

The ViewModel starts a long-lived task that loops forever over the Projection's
stream of states (`for await nextState in states { ... }`). A `Task` keeps a strong
reference to anything it captures. If that task captured `self` strongly, then **the
task would keep the ViewModel alive forever** — even after the window is gone — and
the ViewModel's `deinit` (which cancels the task) could never run. That is a
retain cycle: the task keeps the ViewModel, the ViewModel keeps the task.

So the task captures `[weak self]` and re-acquires a strong reference *only* for the
brief moment it applies one state, then lets go again before the next wait. Now when
the window closes and nothing else holds the ViewModel, it deinitializes, which
cancels the task. Weak self here is not a style choice — it is what makes the
ViewModel able to die.

The ViewModel also uses **three separate async lanes** with deliberately different
behavior: query intents keep only the newest descriptor request, catalog mutation
commands are lossless and serial (you must not drop a command), and state delivery
is consumed losslessly. They are separate because mixing those delivery rules would
be wrong for at least one of them. Query requests carry a monotonic generation.
When a projected state arrives, the ViewModel updates its local query controls
only if the state generation exactly matches the newest local sidebar/sort/filter
intent; this keeps rapid A -> B -> A user edits from being rebuilt from stale
control state. Projection's removed-library fallback is still accepted because it
preserves the generation of the request it resolved.

### `Otos/Views/*` — passive rendering

`SidebarView`, `MediaGridView`, and `SettingsView` are small SwiftUI views that
render the state they are handed and call back with intents (`selectSidebar`,
`addLibrary`). They hold no catalog logic. The sidebar uses projected library
rows for identity and selection, but renders only folder icons and library names;
transient availability and scan activity stay out of sidebar row text.

`MediaAssetCollectionView` is the exception and the one place we drop to **AppKit**.
Why: a media library can have tens of thousands of tiles, and `NSCollectionView`
reuses cells (it only creates views for what is on screen), which SwiftUI's grids do
not do as well at that scale. Read `MediaAssetCollectionView.swift` with its focused
selection and structural-apply extensions (`MediaAssetCollectionSelection.swift` and
`MediaAssetCollectionStructuralApply.swift`) as one AppKit boundary. The small
`MediaAssetCollectionApplyGate` exists so that only one structural update runs at a
time and only the newest pending update survives — backpressure for a high-volume
surface. Identity/order changes go through diffable data-source applies so
surviving visible items keep identity and their rendered thumbnails instead of
being torn down by `reloadData`. Small and user-visible insert/remove changes may
animate; large same-membership background reorders apply nonanimated because a
real-library smoke run proved multi-second animated full-grid reorders can jank the
browser without adding useful user feedback.
Detail-only changes for the same ordered IDs advance `detailRefreshGeneration`,
re-read only visible details, and reconfigure the existing visible AppKit items in
place, so a thumbnail does not blink just because metadata for an item changed.
Structural applies do not prune the visible-detail cache first: the post-apply
visible-detail request replaces that map for the current viewport.
Structural-apply diagnostics record aggregate insert/remove counts, reorder-only
status, animation status, apply time, and the visible-detail request count caused
by the apply. They do not try to count scroll-driven visible loads that merely
happen while a long apply is running. The bridge also reports the visible
identities upward (the **viewport**) so enrichment can prioritize what you are
looking at. `MediaAssetTileView` is one reusable tile. The collection cell stays
transparent; the visible face is the loaded thumbnail's aspect-fit rect, or a
full-square neutral placeholder before any image has loaded. Filename and relative
capture date sit on a small top-left scrim inside that face. Videos, and only
videos, add a bottom-right scrim with duration text when Store has parsed it or a
film symbol while duration is still unknown. The tile formats those scalar labels
synchronously during configuration, while loading and decoding the thumbnail *off
the main thread* and only assigning the finished image on Main, with a generation
token so a load that finishes after the tile has been reused for another asset is
discarded. The image reload key includes the thumbnail path plus source size and
modification stamp, but not the date or duration, so overlay-only enrichment
updates do not clear or reload the image.

Selection and copy also live at this AppKit boundary. `NSCollectionView`'s native
selection gives click, ⌘-click, ⇧-click, and ⌘A for free, and its
`selectionIndexPaths` is the single live selection truth — there is no mirror in
the ViewModel. The tile draws selection on the visible thumbnail/placeholder face,
not the whole square cell. Because enrichment and scans re-apply the grid
structure often, each structural apply snapshots the selected `MediaAssetID`s
first and restores the survivors by identity afterward, so a background update
never loses your selection;
`MediaGridSelection` holds that pure, tested membership logic. ⌘C / Edit ▸ Copy
reaches the controller through the responder chain and `MediaGridClipboard` writes
the selected assets' original file URLs to the pasteboard (one per asset, in display
order). It writes references only — no image or video bytes are read — so copy is
instant and never materializes a dataless cloud original; the URL is built by
`MediaAssetID.fileURL`, the one asset→URL construction shared with enrichment. See
ADR 0012 for why file URLs and not image pixels.

### `Otos/Services/EnrichmentCoordinator.swift` — the thumbnail + metadata scheduler

The write-side satellite from §2. Read its file guide first. It runs two worker
pools — one that enriches already-local files, one that downloads (materializes)
dataless cloud files — and decides what to work on next by asking Store for a
bounded set of current enrichment candidates, prioritizing the viewport and freshly
materialized IDs. Store selects eligible candidate keys in useful order, claims
still-free rows with `enrichment_claimed_until`, and fetches the claimed rows back
in that order; visible priority fills past contended rows, and fallback work uses
the same newest-best-date default as the browser before stable path tie-breakers.
The coordinator's sets and small queue of already claimed work are process-local
scheduling state, not a SQL exclusion list or durable backlog. The queue lets the
coordinator claim a modest batch and feed future worker slots without one SQLite
write transaction per slot. Because those leases are process-local ownership, Store
clears abandoned claims during startup and coordinator shutdown releases queued,
undispatched, in-flight, and pending claims before dropping runtime state. Its
products are written back through `CatalogStore.applyEnrichmentBatch` in batches.
See
`docs/adr/0009-enrichment-storage-and-staleness.md`,
`docs/adr/0010-store-owned-query-catalog-and-identity-grid.md`, and
`docs/specs/0022-metadata-and-thumbnail-enrichment.md`.

### `Otos/Services/MediaEnricher.swift` and `Otos/Services/ThumbnailStore.swift`

`MediaEnricher` does the work for one asset: it parses the file's metadata (the
`MediaMetadata` library), promotes tile-visible video duration into the hot asset
row, and renders a 256 px thumbnail (QuickLook). It is an injectable value (like
`CatalogScanner`), so tests substitute a fake. `ThumbnailStore`
owns the thumbnail files on disk — the directory, deterministic `.jpg` names, the
opaque 8-bit sRGB JPEG encode, staged files, atomic promotion to the final name so
a tile never reads a half-written image during a re-enrichment, loading via Image
I/O into an already-decoded `CGImage`, and deletion when the owning catalog row
is purged by proven deletion, library removal, or clean pre-user schema reset. At
app-owned thumbnail-store startup, orphan hidden staged `.*.tmp` files under that
thumbnail directory are cleaned up; originals and user media folders are never
touched.
Thumbnails are files referenced by path; the catalog never stores the bytes.

### `Otos/Services/FileMaterialization.swift` — the cloud guard

A small helper that reports whether a file is a dataless cloud placeholder *without*
reading its bytes, and that can trigger a non-blocking download. The enricher checks
it immediately before any read so it never triggers a *surprise* download, and the
coordinator uses it to deliberately materialize the library in the background. See
`docs/specs/0016-cloud-materialization-detection.md` and
`docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`.

### `Otos/Support/*` — observability

`Instrumentation.swift` (logging + signposts), `RunContext.swift` (process
session naming), `Diagnostics.swift` (session-scoped debug JSONL), and
`UIJankDiagnostics.swift` (a monitor that catches real main-thread stalls). You do
not need these to read the app, but they are how we *measure* it instead of
guessing. Store diagnostics split database wait from SQLite execution, scan and
enrichment batch diagnostics include write pressure and WAL byte-size samples,
filesystem-event diagnostics are one decoded batch summary per debounce window
rather than one durable row per event, and stall records include the active UI
operation or the most recent long completed operation so a 100 ms+ main-thread
stall has nearby owner context. Default diagnostics retention is an explicit
lifecycle step, so disabled JSONL writing still prunes the default diagnostics
directory without creating a new file.

## 5. A day in the life — two narratives

**Launching the app and seeing your media:**

1. The window appears; `ContentView`'s `.task` calls `viewModel.start()`.
2. Agent smoke launches may pass `OTOS_SMOKE_LIBRARY_ROOT`; `SmokeLibrarySeed`
   then submits that path through `viewModel.ensureLibrary(url:)`, which uses the
   same Store-owned mutation lane as manual library adds. This is process tooling,
   not product onboarding.
3. The ViewModel starts its tasks and tells the Store to load.
4. `CatalogStore` opens SQLite, reads the saved library roots, repairs reachable
   symlink-spelled roots to their resolved provider paths, migrates any thumbnail
   files whose deterministic names changed with the root spelling, and fires
   "I changed."
5. `CatalogProjection`, already subscribed to Store invalidations, asks Store for
   current library rows and descriptor-ordered asset IDs on its background tick,
   then publishes a `CatalogWindowState`.
6. The ViewModel assigns that to its `@Observable` `state`; SwiftUI notices and
   re-renders; the grid fills.
7. Meanwhile the Store re-scans the libraries in the background to reconcile with
   the current filesystem. If nothing changed, it stays silent (no needless work).
8. After load, `CatalogFilesystemWatcher` subscribes to macOS FSEvents for each
   saved root. Changes under a root debounce (one-second quiet period). Safe single
   regular-file events reconcile one path; ambiguous events schedule a full-root
   rescan for **that root only** through the same scan pipeline.

**Filesystem changes while the app is running:**

1. macOS delivers file-level FSEvents under a saved library root.
2. `CatalogFilesystemWatcher` forwards the event to `CatalogStore` (never SQLite).
3. The Store ignores events until that root's first scan has completed, then
   resets a per-root debounce timer on each burst.
4. When the quiet period elapses, Store classifies the event batch. Single regular-
   file creates/modifies read filesystem facts through `CatalogScannedFileReader`
   and upsert one row when it is still catalog-eligible; if that path now exists
   only as a non-catalog-eligible item, Store deletes the old row and thumbnail
   overlay. Single regular-file removes delete one row only after Store checks that
   exact path is absent.
5. Directory, symlink, dropped, unknown, subtree, and active-scan cases fall back to
   `enqueueScans([root])` — or defer until the current scan for that root finishes
   (`rescanAfterCurrentScan`).
6. Either path notifies Store consumers only if catalog-visible facts changed; for
   successful scan-batch writes the notification happens before awaited diagnostics
   work, then Projection updates the grid on its next coalesced tick. Durable
   diagnostics record one bounded batch summary with decoded FSEvent flag/action
   counts and representative examples rather than per-event rows.

**Adding a library:**

1. In Settings you pick a folder; `SettingsView` calls `viewModel.addLibrary(url:)`.
2. The ViewModel puts that on its lossless mutation lane; the Store inserts the
   library row, then starts a scan.
3. The scan streams files in batches; the Store writes each batch to SQLite and
   fires "I changed" only when SQLite reports inserted or changed rows.
4. Projection → ViewModel → grid, exactly as above, so you watch the grid populate.

**Seeded smoke launch:**

1. `script/smoke-run.sh` defaults to `$HOME/Desktop/OneDrive/Pictures`, validates
   that it is a directory, resolves symlink components to the real provider path,
   and launches the Debug app with `OTOS_SMOKE_LIBRARY_ROOT`.
2. `SmokeLibrarySeed` reads that environment value and calls
   `viewModel.ensureLibrary(url:)`.
3. `CatalogStore.ensureLibrary(url:)` loads the catalog if needed, no-ops if the
   resolved root is already saved, or inserts the root and starts the normal scan
   if it is missing.
4. In quick `--verify` mode, the smoke script locates that app run's diagnostics
   by PID and fails unless a successful ensure event exists for the seeded root.
5. The default smoke script lets startup run for about 10 seconds, then drives down/up
   scrolling, captures compact unified logs under `logs/`, and summarizes the
   newest session-scoped catalog diagnostics. It is the default agent runtime
   smoke path because an empty catalog launch is not useful browser evidence.

## 6. Where to make a change without breaking things

- **Changing what the UI shows** → the Projection (derivation) or the ViewModel
  (final assignment), never a view.
- **Changing what is stored** → `CatalogStore` + a SQLite migration in
  `CatalogStorePersistence.swift`, and an ADR (see `AGENTS.md`).
- **Adding heavy work** (more enrichment, future decode/export) → a new actor or
  service off the main thread that consults `FileMaterialization` before reading
  bytes, following `EnrichmentCoordinator`'s pattern (query bounded work from Store,
  do the heavy work in worker tasks, write results back through the Store in batches).
- **Never** violate the non-negotiables: the filesystem is the truth, originals are
  read-only, nothing is written into the user's folders, and the main thread stays
  free of database/scan/sort/decode work.

If a change makes you touch two layers to answer one question, stop — that usually
means the boundary is in the wrong place, and the fix is to move the responsibility,
not to wire the layers together.
