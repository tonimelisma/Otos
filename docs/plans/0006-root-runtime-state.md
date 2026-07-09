# Plan 0006 — Collapse the Six Parallel Root Dictionaries into `RootRuntimeState`

> Non-authoritative plan. Delete when done.
> Execution order: **sixth** — small, mechanical, high-leverage, and the
> foundation `RootRegistry` in plan 0007 builds on. Do it before the store
> decomposition, not after.

## 1. Problem (verified)

`CatalogStore` stores one root's runtime facts across **six** dictionaries all
keyed the same way, with these in-file usage counts:

```
rootsByPath           [LibraryRootPath: LibraryRoot]           31 refs
rootRowIDsByPath      [LibraryRootPath: Int64]                 34 refs
rootPathsByRowID      [Int64: LibraryRootPath]                 12 refs
availabilityByRootPath[LibraryRootPath: LibraryAvailability]   19 refs
activityByRootPath    [LibraryRootPath: CatalogLibraryActivity]11 refs
isEjectableByRootPath [LibraryRootPath: Bool]                   8 refs
```

Every root transition must keep up to six maps consistent by hand. This is
denormalized state, and "which map is stale" is exactly the failure class the
eject bug came from (availability flipped in one place; other views of the
root unchanged). `setAvailability`
([CatalogStore.swift:2450](../../Otos/Stores/CatalogStore.swift)) already has
to gate on `rootsByPath[path] != nil` before touching `availabilityByRootPath`
— the maps are logically one record.

## 2. Target

```swift
/// One record per known root. The single in-memory truth for a root's runtime
/// facts; the durable identity is still `LibraryRoot` (filesystem path).
nonisolated struct RootRuntimeState {
    var root: LibraryRoot
    var rowID: Int64
    var availability: LibraryAvailability
    var activity: CatalogLibraryActivity
    var isEjectable: Bool
}
```

Store keeps exactly two maps:

```swift
private var rootStatesByPath: [LibraryRootPath: RootRuntimeState] = [:]
private var pathsByRowID:     [Int64: LibraryRootPath]           = [:]   // the one real secondary index
```

`pathsByRowID` stays because reverse lookup by rowid is used by scan-lease and
enrichment-claim code that only has a rowid; it is maintained in lockstep by
two helpers so it can never drift alone:

```swift
private mutating func upsert(_ state: RootRuntimeState)   // sets both maps
private mutating func removeRoot(path:)                    // clears both maps
```

`CatalogLibraryState` construction (the projected row) is derived from
`RootRuntimeState` in one place (`libraryRoot(from:)`/`activity(for:)` collapse
into one `catalogLibraryState(_ state:)`).

## 3. Blast radius (this file only; nothing outside `Stores/` changes)

- All 115 dictionary references become field access on `RootRuntimeState`
  through `rootStatesByPath[path]` (or the `upsert`/`removeRoot` mutators).
  No public method signature changes; no caller outside the Store is touched
  (verified: the six dicts are `private`).
- `setAvailability(_:for:)`, the `activity(for:)` reader, `libraryRoot(from:)`,
  `attachRemovableRoot`/`updateExistingRemovableRoot`/`insertRemovableRoot`/
  `moveRootRuntimeState`/`removeRootRuntimeState`/`applyLoadedCatalog` — each
  becomes a single-record read or `upsert`/`removeRoot`.
- `currentLibraries()` maps `rootStatesByPath.values` through
  `catalogLibraryState(_:)`.
- `rootIDsForQuery`, `availableLibraryRootIDs`,
  `availableRootIDsByRemovablePriority`, `rootForDeviceIdentity` iterate
  `rootStatesByPath` instead of joining across maps.

## 4. Step-by-step

1. Add `RootRuntimeState` + the two maps + `upsert`/`removeRoot` +
   `catalogLibraryState(_:)`. Do **not** remove the old dicts yet.
2. Make `upsert`/`removeRoot` the only writers; route the existing write sites
   through them while old dicts still exist, keeping both in sync. Run tests
   green (pure refactor, both representations agree).
3. Convert readers to `rootStatesByPath` one method group at a time
   (availability, activity, rowid lookups, currentLibraries, query id helpers).
4. Delete the six dictionaries; delete the now-dead `activity(for:)`/
   `libraryRoot(from:)` split.
5. File-guide update in `CatalogStore.swift` (the "state it owns" section).

## 5. Tests

`CatalogStore` already has broad coverage (`CatalogStoreTests`,
`…RemovableSourceTests`, `…LifecycleRaceTests`, `…RootNormalizationTests`).
This is behavior-preserving, so those must stay green untouched. Add a focused
`RootRuntimeStateTests` only if `upsert`/`removeRoot` grow non-trivial logic
(they should not). The value is that a whole class of "forgot to update map N"
bug becomes impossible — assert it structurally by having a single mutator.

## 6. Acceptance criteria

- `rg "availabilityByRootPath|activityByRootPath|isEjectableByRootPath|rootRowIDsByPath|rootsByPath" Otos/` → empty.
- Exactly two root maps remain, mutated only through `upsert`/`removeRoot`.
- All existing store tests pass unchanged; `verify.sh` green.
- No public Store API changed (diff is confined to `CatalogStore.swift`).

## 7. Risks

Very low — internal, private, behavior-preserving, well-covered by existing
tests. The one subtlety is keeping `pathsByRowID` correct; the `upsert`/
`removeRoot` mutators are the single enforcement point, and step 2 keeps both
representations live until readers are migrated, so any divergence shows up as
a test failure before the old dicts are deleted.
