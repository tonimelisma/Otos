# ADR 0046: Immich accounts are read-only sources

## Status

Accepted

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

Before this decision the code had many bare `kind == .library` and `kind != .library`
comparisons. Each one answered a different question: All Media membership, import source
or destination, Trash, retention, scan and watch, the sidebar section. A fourth kind added to those
comparisons would have been wrong in most of them. For example, `kind != .library` made a
root an import source (`ImportSessionMachine`). Those comparisons are replaced, not extended.

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
  `RemoteStaging/<sanitized identity>/` under the app's Caches folder named by its bundle
  identifier, beside `DeviceStaging` but a separate container, so a dev build and the
  installed app (ADR 0030) never share it. One value answers where a source stages: the
  Store's `StagingContainers`, derived from its catalog location (the app's bundle
  identifier under Caches, a catalog file's folder, an in-memory catalog's own temporary
  folder), which the camera monitor, the sweeps, the quit check and an import's release of a
  staged file all read; nothing else builds a container path. The path is a function of those
  containers and the identity, not a fact of its own: the catalog stores it
  because asset identity is the path (ADR 0008), and the Store re-derives it at every load,
  a camera's root too. A root stored elsewhere — by another build, or under the one shared
  container before containers were named by bundle identifier — moves into this build's own:
  its row stays, so every overlay keyed by row and relative path moves with it, derived images
  take the new names, and an import or erase journaled against the old path follows; nothing
  on disk moves, the staged bytes being a cache fetched again on demand and the old folder
  its own build's to sweep. While Otos holds the account, signed in or not,
  it claims the tree with the same `flock` a camera's tree carries, so another instance's
  sweep never deletes the originals it staged; forgetting the account releases it. Staged
  originals are working copies, not overlay, so they do not belong in the backed-up
  Application Support.
- **Asset:** the relative path is `<asset id>/<original file name>`. Otos invents no ID:
  the folder is Immich's asset ID, and the file name keeps export, hand-off and drag
  naming correct.
- **Live Photos:** the motion part of a Live Photo is placed under the still's asset
  folder, `<still id>/<motion original file name>`, so the existing pairing rule (same
  folder, same `content_identifier`, ADR 0041) pairs them unchanged.
- **The row's own ID:** because a folder can hold a motion part, a folder names only its
  still. Every account row stores Immich's ID for its own file (`source_item_id`,
  migration v20). The original's download, its ranged reads, its preview, and every size
  and deletion the stream reports apart from an asset's line find the row by that ID,
  never by parsing its path.
- **Motion part facts:** the stream reports a motion part as its own `hidden` asset,
  linked from its still's `livePhotoVideoId`. A still's line lists its folder in full:
  the still, and the motion part it links. The motion part's facts come from its own line
  in the same pass, with its size when that is there too, or else from
  `GET /api/assets/{id}`; a motion part the server refuses to describe (400 or 404) leaves
  its still listed alone and its folder's rows as they are, so one asset never holds back
  every pass. A still that no longer links its motion part drops it. A motion part's own
  line without its still's refreshes the row it already has in its still's folder, found by
  its ID, and keeps the hidden state its still decided; its size arrives by its own ID. A
  motion part's own folder is never a row's: a video listed there before it became a
  motion part leaves it when its `hidden` line arrives.
- **Server and credentials:** `library_root.remote_base_url` holds the server URL that Settings
  shows. The session token lives in the Keychain, never in SQLite.

### 3. Root-kind capabilities replace bare kind comparisons

`LibraryRootKind` answers each question with one named property:

| Capability | library | removableVolume | deviceMTP | immichAccount |
|---|---|---|---|---|
| `isMemberOfAllMedia` (All Media, Places, Duplicates) | yes | — | — | yes |
| `isImportDestination` | yes | — | — | — |
| `supportsReorganization` | yes | — | — | — |
| `supportsMoveToTrash` | yes | yes | — | — |
| `isRemovable` (attach/detach, Removable section, 90-day retention, `awaiting_presence`, import source, Erase) | — | yes | yes | — |
| `hasFilesystemNamespace` (scan, FSEvents watch, integrity, path normalization) | yes | yes | — | — |
| `showsRowsWhileUnreachable` | — | — | — | yes |
| `stagesOriginals` (`stagingContainer`) | — | — | DeviceStaging | RemoteStaging |

The enum answers further questions the same way (`isUserChosenFolder`,
`isInLibrariesSection`, `rowsComeFromSourceListing`, `readsFaces`, `readsVideoFaces`,
`availabilityAtLaunch` and others in `Otos/Models/CatalogModels.swift`). No call site
compares a kind directly. A new kind is a new column in this table.

### 4. One owner of original locality

`MaterializationCoordinator` answers `locality(of:)` with `.local`, `.fetchable`,
`.fetchableForUserWork`, or `.unreachable`:

- for in-place roots, from `SF_DATALESS`;
- for staged roots, from whether the staged file exists (absent is `.fetchable`); whether
  the source can serve it now is the executor's answer (`deviceUnavailable`,
  `serverUnreachable`), not part of locality;
- for an account, whose source sends an original only for the user's work
  (`LibraryRootKind.sendsOriginalsOnlyForUserWork`), an absent staged file is
  `.fetchableForUserWork`. A requester asks `isFetchable(at:)` with its priority, so
  background and device work never ask the server for one: `ensureLocal` answers
  `.userWorkOnly` without a request, and enrichment releases the row to the pacing ledger
  instead of demanding a download. In the installed app, 36 background requests in 20
  minutes were dispatched, refused by the executor and logged as failures before the type
  said so (`docs/research/2026-11-14-scope-switch-and-background-laps.md`).

It also owns `ensureLocal(_:)` (on `MaterializationRequesting`; the request carries the
priority), which replaces `makeLocal`. `PreviewImageLoader`, `VideoPreviewLoader`,
enrichment readiness, `MetadataRefresher`, import recovery, export, hand-off, the edit
lanes and the Inspector all ask it; enrichment first routes a row whose source serves
ranged reads to them, since that needs no download. Each keeps its synchronous re-check
of the file's own status immediately before the read. The executor gains an `immichAccount` branch:

1. an HTTP download into a temporary file, through `ImmichAccounts`, which holds the
   account's session;
2. a move into the asset's folder under a hidden name, then a rename over the final
   name, so a reader never sees half a file;
3. the existing priorities and per-root breaker throughout. Only the user's work —
   interactive or command priority — downloads an original, because an account's
   originals are never downloaded to render the library (owner, 2026-11-09). Locality says
   so, so no background or device request reaches the executor; its refusal of one stays
   as the boundary's own guard.

An original that lands is offered to enrichment ahead of other work, for every product it
still owes (`CatalogStore.originalBecameLocal`, the list imported copies use): Otos's
rendering — RAW9 for a RAW — replaces Immich's images, and its digest is taken. Ranged
reads serve only claims that need no rendering or digest — metadata and a video's faces
(`EnrichmentScope.isReadableInRanges`).

### 5. Rows arrive from the sync stream

`ImmichCatalogSync` is one owner per account, the counterpart of `CameraCatalogSync`. It
reads `AssetsV2` and `AssetExifsV1`, keeping:

- `type` `IMAGE` and `VIDEO` (no audio: product rule);
- `visibility` `timeline` and `archive`;
- `hidden` only as a Live Photo's motion part;
- never `locked`: an asset moved into the locked folder has its row and overlay purged,
  because the locked folder is the user asking that it not be seen.

Each row's provisional facts come from the sync stream, as a camera's come from its
listing:

- name;
- `fileSizeInByte` as size, which `AssetExifV1` carries apart from the asset's own line; a
  line without it keeps the size the catalog holds;
- `fileModifiedAt` as content-modified time, so ADR 0009 staleness works unchanged;
- `fileCreatedAt` as created time.

Its metadata — capture date, location, camera — is read from the original itself by
MediaMetadata, which owns those facts (ADR 0039), in byte ranges of `/original` while the
server answers: a few 128 KB chunks per file, never a download. A ranged read's status is
judged when its headers arrive, and anything but a 206 cancels the transfer before its body
is received; a read its caller stops waiting for is cancelled too. Enrichment claims an
account's rows for metadata and a video's faces (read in the same ranges, ADR 0047) only,
and only while `ImmichAccounts` reports its server online (`CatalogStore.setSourceAnswering`); a read the server does not answer paces its
row (`EnrichmentOutcome.unanswered`) rather than claiming it again at once. Immich's own
EXIF is never used for these facts.

Its thumbnail and preview are Immich's (§7).

Each pass receives the stream whole into a temporary file at the network's pace and then
applies it from the file, so the transfer never waits on the Store: a stream read only as fast
as the Store applies it times out on the client while the server is still sending
(`docs/research/2026-11-13-immich-stream-slow-reader.md`). Otos acknowledges each batch only after the Store has applied it, so a crash replays a
batch rather than losing one. An asset with a non-null `deletedAt` (in Immich's trash) is
hidden but keeps its overlay, the same rule as Otos's own Trash (ADR 0022): its row is
marked `hidden_by_source` (migration v16), which the shared scope clause and Duplicates'
reads leave out. Restoring it in Immich shows it again. `AssetDeleteV1` purges the row. `SyncResetV1` runs a full
resync: rows the resync does not list are purged only after it completes. The resync is
recorded as owed in the catalog (`library_root.resync_owed`, migration v41) before the
reset is acknowledged. A new session owes one too, recorded before its token is saved: its
cursor is empty and the server sends it no reset, so its first stream lists from zero
without saying so, and deletions while the account was signed out would never be purged
(`docs/research/2026-11-13-immich-sync-reset.md`). While a resync is owed, every pass asks
the server to discard the cursor (`reset: true`) and reads the stream from zero. The server
resumes a plain stream after the last acknowledged batch, so a resync that dropped after
acknowledging some batches and was then resumed would list only the rest, and its
completion would purge every row the acknowledged batches carried; reading from zero each
time is what makes the completing pass a full listing. The pass that reaches the end purges
every row it did not list and settles the debt in one Store transaction
(`CatalogStore.completeSourceResync`), so neither a crash nor a failed write separates the
two. The debt is a revision counter (ADR 0032 rule 2): each request adds one, and a pass
settles only the revision it read when it started, so a request made while it ran stays
owed. A reset answered to a stream read from zero, or a second reset in one pass, ends the
pass as a reset loop. A pass is a sync only when its stream ends with `SyncCompleteV1`; one
cut short keeps what it applied but is not reported as a sync.

A line of a type Otos did not ask for, or an asset whose type or visibility this version
does not know, is logged, ignored and acknowledged: one line a newer server writes never
fails every pass.

The sync runs when the account is added and at launch. While its server answers, it
runs again on a schedule (`time: poll`, every five minutes), because Immich offers no
change notification a native client can subscribe to; while it does not, it tries
again on a growing backoff (15 s to 5 min), which is how Otos learns the server is
back. Each pass reads the stream from its cursor, never a full listing. A refused
session stops the passes until the user signs in again. `ImmichAccounts` owns every
account's session, loop and status.

A request for a sync is answered only by a pass that succeeded: its stream synced, its
mirror walk and its walk over the rows owed the server's images did not fail (a walk held at
the free-space floor answers it, since free space, not the server, ends that wait). A pass
that failed answers nothing (ADR 0032 rule 4), and neither does a fetch of the rows on screen
that failed; the next pass that succeeds, which the poll or the backoff rings, answers both.
So an account whose server does not answer is never quiescent or caught up
(`QuiescentOwner`): a launch's settlement stage `launchWork` waits for it, a settled tour
meets its deadline instead (`by=deadline`), and the session's end names it
(`op=owners.pending owner=immichSync holdsWork=true`). Reporting it caught up would claim a
sync that did not happen.

### 6. Unreachable is a state, not an absence

- An account's rows stay in the grid while it is unreachable.
- The sidebar row marks it with a glyph whose tooltip says the server can't be reached and
  when the account last synced; Settings says `Synced 3m ago` with the same glyph. An
  account's status says when it last synced, not whether it is connected: the last pass
  that applied the stream to its end is kept in the catalog (`library_root.last_synced_at`),
  so it is known at a launch whose server does not answer.
- Stored thumbnails and previews, Immich's or Otos's (§7), serve the grid, loupe,
  compare, curation, and every filter.
- Work that needs original bytes reports that the server is offline instead of waiting
  silently: full-resolution zoom, a new edit, export, hand-off, Reveal in Finder, drag
  of the original, and a digest. The executor reports a download the server did not answer as
  `serverUnreachable`, a state of the source like a disconnected camera's
  `deviceUnavailable`, never a file provider's failure. Hand-off and Reveal in Finder name
  the account in their alert (ADR 0037).
- Reachability is learned from requests (a request answers or fails with a transport
  error); it is never assumed from elapsed time. Only a request that reached no server
  makes an account offline. A server that answered with a failure (a 5xx, a line Otos
  cannot read, a reset loop), or a failure of Otos's own, leaves what it last answered
  standing, and the pass is retried on the backoff, as is a pass whose root could not get
  or keep its listing lease. A pass whose loop was stopped (signing in again replaces it,
  removing the account ends it) says nothing about the account and rings no further pass.
- A pass's server has answered once the first line of its stream is read, so the account is
  online from then on, not only when the pass ends: a first sync of a large library takes
  minutes. Whether Otos can apply what the server said is the pass's outcome, never the
  server's reach: a batch the catalog refuses leaves the account online.

### 7. Immich's images until the original is local

After each sync pass, Otos downloads Immich's `preview` of every asset still owed one and
writes Otos's own two products from it into the derived-image store (ADR 0035): the
preview at Immich's size, for a still, and the 256 px grid thumbnail drawn from it — one
request per asset, so Immich's separate thumbnail is never needed. They are
**source-provisional products**: kept as overlay for the asset's life, but not an Otos
rendering. They are stamped with the `(size, mtime)` they were made for
(`source_products_*`, migration v17), so an asset whose file changes is owed new ones,
which replace the shown images only when they arrive (APP-015). Otos reads each image's
pixel size and colour profile from the file it receives and never assumes Immich's
defaults, because they are admin configuration. The fetch keeps the free-space floor
(ADR 0027) and stops when the server stops answering; what it did not fetch stays owed.

The rows on screen do not wait for that walk. A pass reaches its images only after listing
everything and pairing mirrors, and then goes in path order, so a row listed while on screen
would stay blank until the next poll's pass reached it. The window hands each account the
rows on screen, and the account fetches their owed images at once, by key and in the
screen's order (`ImmichCatalogSync.runVisible`): when the rows on screen change, and after
each listing batch lands, which can make a row on screen owed. The fetch is the walk's own,
with the same floor, refusals and stop; a row both reach is fetched twice at most. Enrichment
gives an account row no thumbnail: it reads the original only in ranges, for metadata and a
video's faces, so the server's images are the only thing that paints a listed row. An asset
the server has made no previews of stays without images until a listing carries its
thumbhash.

Only the server knows whether it has an asset's previews, and it says so twice. Immich
writes an asset's `thumbhash` only after it has generated the previews, and that write
changes the asset, so the stream lists it again; it never generates them for a hidden asset
(a Live Photo's motion part). And a preview request it cannot serve is answered with a
404. Only a 404 is that answer: any other status (a 5xx, a 429) is the server failing now,
which ends the fetch with the row still owed, after the page's images already fetched are
written. Otos keeps the newer of the two answers (`source_products_absent`,
migration v39): an asset listed without a thumbhash, or answered with a 404, is not asked for its
images again until a later listing carries a thumbhash. Asking again every pass would
spend one request per such asset per pass for an answer the server has already given.

Enrichment never downloads an account's original only to render it. A video's faces are read
in byte ranges of its original, never a download (ADR 0047). Otos renders its own
products (ADR 0035) from an original that is local for another reason:

- full-resolution zoom;
- a new edit, whose rendering only Otos can make;
- export, hand-off, Reveal in Finder, drag of the original;
- a digest (ADR 0018), which needs the original's bytes because Immich offers only SHA-1.

That one read writes every product the row is missing, as ADR 0009 requires: rendering,
metadata from the full file, digest. The Otos rendering then replaces Immich's for that
asset, under the no-blank rule (APP-015).

Consequences per product:

- A non-RAW still's loupe preview is Immich's 1920–2160 px long edge instead of 2560 until
  Otos renders it.
- A RAW shows libvips's development until RAW9 renders it, which happens lazily: when its
  original is downloaded for full-resolution zoom, an edit, export or hand-off. No
  background job downloads RAWs to render them (owner decision, 2026-11-09).
- An edited still always shows Otos's rendering. It is never owed Immich's images, so none
  is fetched for it or written to it, even when its file changes.
- Duplicates compares render signatures only within one pipeline (ADR 0042), so an
  Immich thumbnail and an Otos rendering of the same photo do not confirm a same-photo
  pair until measurement shows they stay under its threshold.

An original downloaded for any reason stays staged until quit, which releases the account's
claim and sweeps it, as it does a camera's staged files; after a crash, the launch sweep collects any tree no
live instance claims. It is a working copy, not a library, so Otos never holds an opaque mirror of the user's
Immich library.

### 8. Refused features

Each refused feature is refused through the capability table, and its UI says why:

- import into an account;
- reorganization;
- Move to Trash;
- Duplicates' "move copies to Trash" resolution for an account's copy.

Duplicates still finds groups that include an account's photos. In them, an account's copy
is never tagged Trash (`DuplicateCopy.canMoveToTrash`, from the capability table):

- Whatever a click, a folder rule or the keeper rule chooses, the account's copy stays and
  only a library's copies move (`DuplicateResolution.stays`).
- The group's header says why: `Otos never removes copies in “Family”`. When nothing
  moves, that is the whole header.
- An account's asset folders are no folders of the user's, so its copies are one folder
  to a rule. A rule row never offers to keep a library's side over an account's, since
  that would move the account's copies; the row's detail says why. A folder set whose
  copies none can move has no row.
- The copy's Move to Trash Now is disabled, and its tooltip reads `Removed only in Immich`.

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
- A first sync of a large account downloads Immich's preview of each asset, from which
  Otos draws its grid thumbnail, about 6 GB for 14,000 stills, under the free-space floor.
  Originals are downloaded only for work that needs their bytes.
- Until Otos renders them, an account's RAWs show Immich's development and its stills a
  smaller loupe preview.
- Otos gains its first networking code (URLSession) and Keychain code (Security
  framework). Both are Apple frameworks, so no third-party dependency is needed.

## Retirement Proof

- Every bare `kind == .library` and `kind != .library` comparison in `Otos/` is replaced
  by a capability. Afterwards no comparison of a root kind with `==` or `!=` is left
  outside `LibraryRootKind`.
- `MaterializationCoordinator.makeLocal` is replaced by `ensureLocal`.
- Byte readers no longer call `FileMaterialization.status` directly to decide whether to
  fetch; they ask `locality(of:)`, and read the status themselves only to re-check it
  immediately before the read.
- The camera-specific Store enumeration names become kind-neutral source-enumeration
  names.

## Living Documentation Impact

- `AGENTS.md` (also `CLAUDE.md`): the source-of-truth, identity, deletion-proof, and
  byte-read principles are restated for sources that are not folders, each in the
  increment that implemented it.
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
