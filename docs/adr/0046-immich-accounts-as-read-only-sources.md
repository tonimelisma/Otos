# ADR 0046: Immich accounts are read-only sources

## Status

Proposed

## Context

The owner wants Immich photos in Otos (2026-11-07): the user logs in to an Immich server
from Otos; the account appears in the sidebar like a local library; its photos appear in
the grid, loupe and compare like any other photo; every Otos feature that does not change
the media works on them. When the server cannot be reached, Otos still shows them. The
first version is **read-only**: nothing Otos does writes to Immich.

Verified facts (`docs/research/2026-11-07-immich-api.md`, measured against Immich 3.3.6):

- The sync stream (`POST /api/sync/stream`) is a server-side cursor per login session. It
  reports new, changed, trashed and permanently deleted assets, and asks for a full
  resync when its history is gone. It refuses API keys (403), so an account is added by
  logging in.
- `GET /api/assets/{id}/original` serves original bytes and honours byte ranges.
- Immich makes a 250 px (short edge) WebP thumbnail and a 1440 px (short edge) JPEG
  preview of every asset, orientation baked in, colour kept in sRGB or Display P3. Its
  RAW development is libvips, never RAW9. Every size and format is server admin
  configuration a client cannot choose
  (`docs/research/2026-11-07-immich-derived-assets.md`).
- Downloading every original to render it would move about 350 GB for the owner's
  14,000 stills; Immich's thumbnails and previews are about 6 GB.
- When the server is offline, Immich can serve nothing.

The closest existing precedent is the MTP/PTP camera (ADR 0013, decision 5). A camera is a
catalog root whose path is an Otos staging folder. Its rows come from the device's own
listing, its thumbnails are provisional, and its bytes are downloaded into the staging
folder on demand by the `MaterializationCoordinator` executor, which dispatches on root
kind. An Immich account takes the same shape, with three differences:

- it is a fixed library, not a removable source;
- its rows stay browsable while it is unreachable;
- its listing is a durable cursor, not a fresh enumeration on each attach.

The code has many bare `kind == .library` and `kind != .library` comparisons. Each one
answers a different question: All Media membership, import source or destination,
Trash, retention, scan and watch, the sidebar section. A fourth kind added to those
comparisons would be wrong in most of them. For example, `kind != .library` makes a root
an import source (`ImportSessionMachine`). Those comparisons are replaced, not extended.

## MECE Decision Scope

This ADR owns:

- the `immichAccount` root kind, its identity, its staging root and its relative paths;
- root-kind capabilities, which replace bare kind comparisons;
- the one owner of original locality (`local` / `fetchable` / `unreachable`) that every
  byte reader asks before it reads;
- how an account's rows arrive (the sync stream) and leave (permanent deletion only);
- what an account shows while unreachable;
- which images an account's grid and loupe show before, and after, its original is
  downloaded;
- what happens to downloaded originals;
- how the session token is stored;
- which Otos features are refused for an account, and why.

This ADR references but does not own:

- the overlay lifecycle (ADR 0008), restated here only for a server listing;
- enrichment products and staleness (ADR 0009), and the product states, including the
  source-provisional one this ADR's §7 relies on (ADR 0035);
- render-signature comparison (ADR 0042);
- materialization scheduling and the free-space floor (ADR 0016, ADR 0027);
- sidebar selection (ADR 0014, ADR 0031);
- the camera source (ADR 0013).

Adjacent decisions that need their own ADR:

- writing to Immich (Trash, upload as an import destination, album edits);
- partner and shared-album assets;
- OIDC login;
- one sidebar row per Immich external library.

## Decision

### 1. The source of truth is the source's own listing

A folder or card's truth is its filesystem. A camera's is its ImageCapture listing. An
Immich account's is its server's sync stream. The catalog is a subordinate projection of
each, and reconciles to it. The overlay lifecycle carries over unchanged: overlay is
purged only when the source proves an item gone. For an account, that proof is an
`AssetDeleteV1` event or a completed resync that no longer lists the asset. Being
unreachable is never a deletion.

### 2. Identity is the source's own name for an item

- **Root:** `LibraryRootKind.immichAccount`. Its `device_identity` is
  `immich:<normalized server URL>#<user id>`, and its path is an Otos staging folder
  `RemoteStaging/<sanitized identity>/` under the app's Caches folder, beside
  `DeviceStaging` but a separate container, so the camera sweep never touches it. Staged
  originals are working copies, not overlay, so they do not belong in the backed-up
  Application Support.
- **Asset:** the relative path is `<asset id>/<original file name>`. Otos invents no ID:
  the folder is Immich's asset ID, and the file name keeps export, hand-off and drag
  naming correct.
- **Live Photos:** the motion part of a Live Photo is placed under the still's asset
  folder, `<still id>/<motion original file name>`, so the existing pairing rule (same
  folder, same `content_identifier`, ADR 0041) pairs them unchanged.
- **Server and credentials:** `library_root.remote_base_url` holds the server URL that Settings
  shows. The session token lives in the Keychain, never in SQLite.

### 3. Root-kind capabilities replace bare kind comparisons

`LibraryRootKind` answers each question with one named property:

| Capability | library | removableVolume | deviceMTP | immichAccount |
|---|---|---|---|---|
| `isMemberOfAllMedia` (All Media, Places, Duplicates) | yes | — | — | yes |
| `acceptsFileOperations` (import destination, reorganization, Move to Trash) | yes | — | — | — |
| `isRemovable` (attach/detach, Removable section, 90-day retention, `awaiting_presence`, import source, Erase) | — | yes | yes | — |
| `hasFilesystemNamespace` (scan, FSEvents watch, integrity, path normalization) | yes | yes | — | — |
| `showsRowsWhileUnreachable` | — | — | — | yes |
| `bytesArrive` | in place | in place | staged | staged |

No call site compares a kind directly. A new kind is a new column in this table.

### 4. One owner of original locality

`MaterializationCoordinator` answers `locality(of:)` with `.local`, `.fetchable`, or
`.unreachable`:

- for in-place roots, from `SF_DATALESS`;
- for staged roots, from whether the staged file exists and whether the source can
  currently serve it.

It also owns `ensureLocal(_:priority:)`, which replaces `makeLocal`.
`PreviewImageLoader`, `VideoPreviewLoader`, enrichment readiness, `MetadataRefresher`,
export, hand-off, and the edit lanes all ask it. Each keeps its synchronous re-check
immediately before the read. The executor gains an `immichAccount` branch:

1. an HTTP download into a temporary file;
2. an atomic move into the staging folder;
3. the existing priorities, free-space floor, and per-root breaker throughout.

### 5. Rows arrive from the sync stream

`ImmichCatalogSync` is one owner per account, the counterpart of `CameraCatalogSync`. It
reads `AssetsV2` and `AssetExifsV1`, keeping:

- `type` `IMAGE` and `VIDEO` (no audio: product rule);
- `visibility` `timeline` and `archive`;
- `hidden` only as a Live Photo's motion part;
- never `locked`.

Each row's provisional facts come from the sync stream, as a camera's come from its
listing:

- name;
- `fileSizeInByte` as size;
- `fileModifiedAt` as content-modified time, so ADR 0009 staleness works unchanged;
- `localDateTime` as capture date.

Its thumbnail and preview are Immich's (§7).

Otos acknowledges each batch only after the Store has applied it, so a crash replays a
batch rather than losing one. An asset with a non-null `deletedAt` (in Immich's trash) is
hidden but keeps its overlay, the same rule as Otos's own Trash (ADR 0022). Restoring it
in Immich shows it again. `AssetDeleteV1` purges the row. `SyncResetV1` runs a full
resync: rows the resync does not list are purged only after it completes.

The sync runs when the account is added, at launch, and whenever the server becomes
reachable. While reachable, it runs again on a schedule (`time: poll`), because Immich
offers no change notification a native client can subscribe to. The schedule polls the
stream's cursor, never re-reads a full listing.

### 6. Unreachable is a state, not an absence

- An account's rows stay in the grid while it is unreachable.
- The sidebar row shows it as offline.
- Stored thumbnails and previews, Immich's or Otos's (§7), serve the grid, loupe,
  compare, curation, and every filter.
- Work that needs original bytes reports that the server is offline instead of waiting
  silently: full-resolution zoom, a new edit, export, hand-off, drag of the original,
  and a digest.
- Reachability is learned from requests (a request answers or fails with a transport
  error); it is never assumed from elapsed time.

### 7. Immich's images until the original is local

When the sync adds or changes an asset, Otos downloads Immich's `thumbnail` and `preview`
of it into the derived-image store (ADR 0035). They are **source-provisional products**:
the grid thumbnail and loupe preview, kept as overlay for the asset's life, but not an
Otos rendering. Otos reads each image's pixel size and colour profile from the file it
receives and never assumes Immich's defaults, because they are admin configuration.

Enrichment never downloads an account's original only to render it. Otos renders its own
products (ADR 0035) from an original that is local for another reason:

- full-resolution zoom;
- a new edit, whose rendering only Otos can make;
- export, hand-off, drag of the original;
- a digest (ADR 0018), which needs the original's bytes because Immich offers only SHA-1.

That one read writes every product the row is missing, as ADR 0009 requires: rendering,
metadata from the full file, digest. The Otos rendering then replaces Immich's for that
asset, under the no-blank rule (APP-015).

Consequences per product:

- A non-RAW still's loupe preview is Immich's 1920–2160 px long edge instead of 2560 until
  Otos renders it.
- A RAW shows libvips's development until RAW9 renders it. **When RAW9 renders an
  account's RAWs — on open or zoom, or as a background job while the server is reachable
  — is an open owner decision.**
- An edited still always shows Otos's rendering.
- Duplicates compares render signatures only within one pipeline (ADR 0042), so an
  Immich thumbnail and an Otos rendering of the same photo do not confirm a same-photo
  pair until measurement shows they stay under its threshold.

An original downloaded for any reason stays staged until quit and is swept at launch. It
is a working copy, not a library, so Otos never holds an opaque mirror of the user's
Immich library.

### 8. Refused features

Each refused feature is refused through the capability table, and its UI says why:

- import into an account;
- reorganization;
- Move to Trash;
- Duplicates' "move copies to Trash" resolution for an account's copy.

Duplicates still finds groups that include an account's photos.

## Alternatives Considered

### A read-only File Provider extension presenting Immich as a cloud folder

Pros:

- Every filesystem path, `SF_DATALESS` gate, and FSEvents watch would work unchanged.

Cons:

- It needs a separate sandboxed extension process and a domain visible in Finder.
- It is a second process with its own lifecycle.
- The library would appear as a folder the user never chose, against ADR 0003.

Failure modes:

- When the extension is unavailable, every file reads as an error rather than as
  "server offline".

### API keys instead of login

Pros:

- No password handling.
- The key can be scoped.

Cons:

- Sync refuses API keys (403, measured). It would leave only listing endpoints, with
  client-side diffing and inferred deletions.

### Mirror every original locally

Pros:

- Fully offline.

Cons:

- It is the opaque app-owned vault the product forbids.
- It doubles the user's storage.

### Download every original to render Otos's own products

Pros:

- Grid and loupe show RAW9 and a 2560 px preview from the first sync.

Cons:

- About 350 GB for the owner's 14,000 stills: 47 minutes at 1 Gbit/s, 39 hours at
  20 Mbit/s, plus about 4.3 hours of RAW9 rendering, against about 6 GB for Immich's
  images.
- Until it finishes, an account shows nothing the user can browse offline.

### Make Otos's own products match Immich's sizes and pipeline

Pros:

- One look for every photo, wherever it lives.

Cons:

- A client cannot choose Immich's sizes, and any admin can change them.
- It would lower every local library to 1440 px, quality 80 and libvips.

## Consequences

- An account behaves like a library in browsing, curation, editing, places,
  duplicates, and export. It does not behave like one in file operations.
- Offline, everything that needs no original bytes keeps working.
- A first sync of a large account downloads Immich's thumbnail and preview of each asset,
  about 6 GB for 14,000 stills, under the free-space floor. Originals are downloaded only
  for work that needs their bytes.
- Until Otos renders them, an account's RAWs show Immich's development and its stills a
  smaller loupe preview.
- Otos gains its first networking code (URLSession) and Keychain code (Security
  framework). Both are Apple frameworks, so no third-party dependency is needed.

## Retirement Proof

- Every bare `kind == .library` and `kind != .library` comparison in `Otos/` is replaced
  by a capability. Afterwards a search for `kind == .` and `kind != .` outside
  `LibraryRootKind` finds nothing.
- `MaterializationCoordinator.makeLocal` is replaced by `ensureLocal`.
- Byte readers no longer call `FileMaterialization.status` directly to decide whether to
  fetch; they ask `locality(of:)`.
- The camera-specific Store enumeration names become kind-neutral source-enumeration
  names.

## Living Documentation Impact

- `AGENTS.md` (also `CLAUDE.md`): the source-of-truth, identity, deletion-proof, and
  byte-read principles are restated for sources that are not folders, each in the
  increment that implements it (plan 0112).
- ADR 0005: unreachable roots that `showsRowsWhileUnreachable` stay browsable.
- ADR 0008: proof of deletion for a server listing.
- ADR 0013: capabilities replace kind checks; retention applies to `isRemovable` only.
- ADR 0016: `locality(of:)` and `ensureLocal`.
- ADR 0035: the source-provisional product state.
- ADR 0042: render signatures keyed by pipeline.
- `docs/requirements.md`: new rows land with each increment's behavior.
- `docs/architecture.md`: the Immich owners are added to the code map.

## Reversal Plan

- An account is one root. Removing the kind deletes its rows, overlay, staging folder,
  and Keychain item through the existing remove path.
- The capability table and the locality owner stand on their own. They remain correct
  for folders, cards, and cameras if Immich is removed.
