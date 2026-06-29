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
  CatalogStore        ← the only owner of "what media exists" at runtime (an actor)
        │  cheap "something changed" signal  +  on-demand immutable snapshot
        ├──────────────▶ EnrichmentCoordinator  ← reads the same snapshots, produces a
        │   writes back     thumbnail + metadata for each asset, writes them to the Store
        ▼
  CatalogProjection   ← turns raw truth into a UI-ready view (a second actor, off the main thread)
        │  CatalogWindowState, published at most 10×/second
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
reads the same truth *into derived products* (thumbnails, metadata) and writes them
back through the Store, which then flows out to the views like any other change.

## 3. Why there are three actors (the concurrency model)

An **actor** in Swift is a type that protects its own mutable state by letting only
one task touch its insides at a time. You already know what they are; here is *why
Otos uses them*:

- **`CatalogStore` is an actor** because three things race for the same data: the
  SQLite database, the in-memory catalog, and background scans that stream in
  thousands of files. If two of those touched the catalog at once, it would corrupt.
  Making the Store an actor means every read and write of catalog truth is
  serialized for free — we never reach for a lock.
- **`CatalogProjection` is a separate actor** because sorting and filtering tens of
  thousands of assets is real CPU work, and it must **not** happen on the main
  thread (that is what makes a UI hang). Putting it on its own actor moves that work
  off the main thread automatically. It is separate from the Store so that
  "what media exists" (Store) and "how this window shows it" (Projection) stay
  independent — you can change sorting without touching persistence.
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
- **`CatalogSnapshot` vs `CatalogWindowState`.** A *snapshot* is raw Store truth at
  one instant (assets keyed by id, unordered). A *window state* is the UI-ready
  result the Projection builds from it (sorted, filtered, with a title and an
  empty-state reason). Keeping them as separate types makes it obvious which layer
  produced a given value.

### `Otos/OtosApp.swift` and `Otos/ContentView.swift` — the skeleton

`OtosApp` declares the single `Window` (deliberately not a `WindowGroup`, because one
main window is a permanent product rule) and owns the one `CatalogWindowViewModel`.
`ContentView` is intentionally *passive*: it reads `viewModel.state` and renders it.
It does not subscribe to anything, sort anything, or call the database. If you want
to know why a view is "dumb," that is the design — views render, the model decides.

### `Otos/Stores/CatalogStore.swift` — the single source of runtime truth

This is the heart. Read its file guide at the top first. Key whys:

- It holds the catalog **both** in SQLite (durable) and in nested dictionaries in
  memory (the live working set), and keeps them in sync. Memory is the fast read
  path; SQLite is what survives a relaunch.
- It exposes a **cheap "something changed" notification** plus an on-demand
  `currentSnapshot()`, rather than pushing big values to subscribers. Why: the
  Projection decides *when* to do expensive work (on its own 10 Hz clock), so the
  Store only needs to say "I changed," not "here is everything."
- **The scan ownership lease (`ActiveScan`).** Because the Store is an actor, it can
  process a "remove this library" message *in the middle* of a scan (every `await`
  is a yield point). So each scan carries the root path plus the private database row
  id it owns, and the Store re-checks "do I still own this scan?" after every
  `await`. This is why a removed-then-re-added library can never have a stale scan
  write into its replacement.
- **The enrichment write lease.** Enrichment is allowed to lag behind scans: a tile
  may keep showing the best-known old thumbnail or date while newer bytes are being
  processed. What must not happen is a stale completion stamping the newer source
  as current. So `applyEnrichmentBatch` re-checks both existence and the source
  `(size, mtime)` signature before writing memory or SQLite. If the file changed,
  the completion is ignored and the asset stays eligible for a fresh enrichment.
- **Removing a library purges its overlay.** A library removal deletes the catalog
  rows for that root and then deletes the thumbnail files those rows referenced.
  That is the same overlay lifecycle as proven deletion: when Otos no longer holds
  a row, it does not keep the row's private thumbnail file.
- **Notify only on real change.** When a re-scan re-observes identical files, the
  Store does *not* fire its change notification. Why: otherwise every routine re-scan
  would wake the whole sort/filter/render pipeline for nothing. (Measured: this
  removed most of the work during a launch re-scan.)

### `Otos/Stores/CatalogStorePersistence.swift` — the SQLite edge

The actual SQL. The one thing to know: SQLite row ids stay *private to this file*.
The rest of the app identifies things by filesystem path, never by database id, so
the database is an implementation detail you could swap out.

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

### `Otos/Services/CatalogProjection.swift` — truth → view

Takes a `CatalogSnapshot` and produces a `CatalogWindowState`. Whys:

- **One 10 Hz loop.** During a scan the Store might change hundreds of times a
  second. The Projection coalesces all of that into at most one update every 100 ms,
  so the UI is fed a steady, bounded stream instead of a flood.
- **Sorts every publication by a precomputed key.** Each asset carries a cheap
  `sortKey`; sorting compares those instead of doing locale-aware text comparison
  per pair. This made re-sorting cheap enough that there is no order cache to keep
  valid — a real simplification (see `docs/adr/0007-catalog-order-reuse.md`).
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
behavior: sidebar clicks keep only the newest (you do not care about stale clicks),
add/remove commands are lossless and serial (you must not drop a command), and
state delivery is consumed losslessly. They are separate because mixing those
delivery rules would be wrong for at least one of them.

### `Otos/Views/*` — passive rendering

`SidebarView`, `MediaGridView`, and `SettingsView` are small SwiftUI views that
render the state they are handed and call back with intents (`selectSidebar`,
`addLibrary`). They hold no catalog logic.

`MediaAssetCollectionView` is the exception and the one place we drop to **AppKit**.
Why: a media library can have tens of thousands of tiles, and `NSCollectionView`
reuses cells (it only creates views for what is on screen), which SwiftUI's grids do
not do as well at that scale. The small `MediaAssetCollectionApplyGate` exists so
that only one structural update runs at a time and only the newest pending update
survives — backpressure for a high-volume surface. It also reports the visible
identities upward (the **viewport**) so enrichment can prioritize what you are
looking at. `MediaAssetTileView` is one reusable tile: it shows the thumbnail and
capture date, loading and decoding the thumbnail *off the main thread* and only
assigning the finished image on Main, with a generation token so a load that
finishes after the tile has been reused for another asset is discarded.

### `Otos/Services/EnrichmentCoordinator.swift` — the thumbnail + metadata scheduler

The write-side satellite from §2. Read its file guide first. It runs two worker
pools — one that enriches already-local files, one that downloads (materializes)
dataless cloud files — and decides what to work on next by scanning the resident
catalog for anything `needsEnrichment`, prioritizing the viewport. It keeps almost
no state of its own: the work is *derived* from the Store snapshot, not maintained
in a backlog. Its products are written back through `CatalogStore.applyEnrichmentBatch`
in batches. See `docs/adr/0009-enrichment-storage-and-staleness.md` and
`docs/specs/0022-metadata-and-thumbnail-enrichment.md`.

### `Otos/Services/MediaEnricher.swift` and `Otos/Services/ThumbnailStore.swift`

`MediaEnricher` does the work for one asset: it parses the file's metadata (the
`MediaMetadata` library) and renders a 256 px thumbnail (QuickLook). It is an
injectable value (like `CatalogScanner`), so tests substitute a fake. `ThumbnailStore`
owns the thumbnail files on disk — the directory, the naming, an *atomic* write
(temp file then rename) so a tile never reads a half-written image during a
re-enrichment, loading via Image I/O into an already-decoded `CGImage`, and deletion
when the owning catalog row is purged by proven deletion or library removal.
Thumbnails are files referenced by path; the catalog never stores the bytes.

### `Otos/Services/FileMaterialization.swift` — the cloud guard

A small helper that reports whether a file is a dataless cloud placeholder *without*
reading its bytes, and that can trigger a non-blocking download. The enricher checks
it immediately before any read so it never triggers a *surprise* download, and the
coordinator uses it to deliberately materialize the library in the background. See
`docs/specs/0016-cloud-materialization-detection.md` and
`docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`.

### `Otos/Support/*` — observability

`Instrumentation.swift` (logging + signposts), `Diagnostics.swift` (a debug-only
JSONL record), and `UIJankDiagnostics.swift` (a monitor that catches real main-thread
stalls). You do not need these to read the app, but they are how we *measure* it
instead of guessing.

## 5. A day in the life — two narratives

**Launching the app and seeing your media:**

1. The window appears; `ContentView`'s `.task` calls `viewModel.start()`.
2. The ViewModel starts its tasks and tells the Store to load.
3. `CatalogStore` opens SQLite, reads the saved libraries and their files into
   memory, and fires "I changed."
4. `CatalogProjection`, on its 10 Hz tick, pulls a snapshot, sorts and filters it,
   and publishes a `CatalogWindowState`.
5. The ViewModel assigns that to its `@Observable` `state`; SwiftUI notices and
   re-renders; the grid fills.
6. Meanwhile the Store re-scans the libraries in the background to reconcile with
   the current filesystem. If nothing changed, it stays silent (no needless work).
7. After load, `CatalogFilesystemWatcher` subscribes to macOS FSEvents for each
   saved root. Changes under a root debounce (500 ms quiet period) and schedule a
   full-root rescan for **that root only** through the same scan pipeline.

**Filesystem changes while the app is running:**

1. macOS delivers file-level FSEvents under a saved library root.
2. `CatalogFilesystemWatcher` forwards the event to `CatalogStore` (never SQLite).
3. The Store ignores events until that root's first scan has completed, then
   resets a per-root debounce timer on each burst.
4. When the quiet period elapses, Store calls `enqueueScans([root])` — or defers
   until the current scan for that root finishes (`rescanAfterCurrentScan`).
5. The existing scan → batch → reconcile → notify → Projection path updates the grid.

**Adding a library:**

1. In Settings you pick a folder; `SettingsView` calls `viewModel.addLibrary(url:)`.
2. The ViewModel puts that on its lossless mutation lane; the Store inserts the
   library row, then starts a scan.
3. The scan streams files in batches; the Store writes each batch to SQLite, mirrors
   it into memory, and fires "I changed."
4. Projection → ViewModel → grid, exactly as above, so you watch the grid populate.

## 6. Where to make a change without breaking things

- **Changing what the UI shows** → the Projection (derivation) or the ViewModel
  (final assignment), never a view.
- **Changing what is stored** → `CatalogStore` + a SQLite migration in
  `CatalogStorePersistence.swift`, and an ADR (see `AGENTS.md`).
- **Adding heavy work** (more enrichment, future decode/export) → a new actor or
  service off the main thread that consults `FileMaterialization` before reading
  bytes, following `EnrichmentCoordinator`'s pattern (derive work from the snapshot,
  do the heavy work in worker tasks, write results back through the Store in batches).
- **Never** violate the non-negotiables: the filesystem is the truth, originals are
  read-only, nothing is written into the user's folders, and the main thread stays
  free of database/scan/sort/decode work.

If a change makes you touch two layers to answer one question, stop — that usually
means the boundary is in the wrong place, and the fix is to move the responsibility,
not to wire the layers together.
