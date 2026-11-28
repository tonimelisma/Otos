# Immich full resync against the test server's version (2026-11-14)

Question: does Otos's full resync (ADR 0046 §5, `ImmichCatalogSync`, `ImmichClient.syncEvents`)
read what the test Immich server actually sends? The resync was written from Immich `main`
(`docs/research/2026-11-13-immich-sync-reset.md`) and has never run against the live server.

## Why not against the live server

The account's session token is a login-Keychain item of the installed app
(`net.melisma.Otos.immich-session`, `ImmichKeychainSessionStore`). A dev build reads its own
service (`net.melisma.Otos.dev.immich-session`), and no build other than the installed app can
read that item without the user's Keychain approval, so the real resync path cannot run in a
`CFFIXED_USER_HOME` sandbox without someone handling the token. It was not run. The installed
app's log of the last 24 hours shows only incremental passes
(`op=catalog.immich.sync phase=pass full=false completed=true`); it never logs the server's
version, which was read from the server's unauthenticated `GET /api/server/version`:
`{"major":3,"minor":3,"patch":0}`.

## What the server sends (source, Immich tag v3.3.0)

Read from `server/src/services/sync.service.ts`, `server/src/utils/sync.ts`,
`server/src/dtos/sync.dto.ts`, `server/src/repositories/sync.repository.ts` and
`server/src/repositories/session.repository.ts` at `v3.3.0`. For these points the tag and
`main` differ only in import order, so the 2026-11-13 reading of `main` holds for 3.3.0.

- **Request:** `{types, reset?}`; `AssetsV2` and `AssetExifsV1` are valid types. The sync
  endpoints refuse an API key (403); they need a login session, as Otos uses.
- **Lines:** `JSON.stringify({type, data, ack}) + "\n"`, `Content-Type:
  application/jsonlines+json`; the ack is `<type>|<updateId>[|<extraId>]`. Dates are UTC ISO
  strings with milliseconds; an int8 such as `fileSizeInByte` is a JSON number or null.
- **Reset:** `reset: true` deletes the session's checkpoints and clears its pending flag,
  then streams everything from the start with no `SyncResetV1`. A pending flag, or a
  `SyncCompleteV1` checkpoint older than 30 days, makes the stream one line,
  `{"type":"SyncResetV1","data":{},"ack":"SyncResetV1|reset"}`, and no `SyncCompleteV1`.
  Acknowledging it resets the session and drops any other ack sent in the same request.
- **Order:** types in the server's fixed order (`AssetsV2` before `AssetExifsV1`); within
  `AssetsV2` every `AssetDeleteV1` comes before the upserts. A trashed asset is still an
  `AssetV2` with `deletedAt`; `AssetDeleteV1` comes only from a hard delete's audit row,
  pruned after 31 days. Every stream that is not a reset ends with `SyncCompleteV1`.
- **Acks:** at most 1,000 per request; for several acks of one type the last in the list is
  kept.
- **Types:** `AssetType` is `IMAGE`, `VIDEO`, `AUDIO`, `OTHER`; visibility is `timeline`,
  `archive`, `hidden`, `locked`.

## Otos against it

- **Request and lines:** `ImmichClient.syncEvents` sends `types` and `reset`, asks for
  `application/jsonlines+json`, and decodes `type`, `data` and `ack`; extra fields are ignored.
- **Reset:** a server reset is recorded as owed (`requestSourceResync`) before its line is
  acknowledged alone (`source.acknowledge([ack])`), so no ack is dropped with it; while a
  resync is owed every pass sends `reset: true`, and the pass that reaches `SyncCompleteV1`
  purges what it did not list (`completeSourceResync`).
- **Acks:** a batch acknowledges only its newest line of each type (`Batch.acks`, one ack
  per type), so the server's last-wins rule and its 1,000 limit are never reached.
- **Audio and other:** read as their types and left out (`ImmichCatalogSync`, `(.audio, _),
  (.other, _)`).

No mismatch was found. `ImmichClientTests.aFullResyncsLinesDecodeAsImmich33WritesThem`
decodes a reset stream and a from-zero stream shaped as 3.3.0 writes them (a deletion before
the upserts, a trashed archived asset with every `AssetV2` field, an audio asset, an EXIF line
with null size, the completion). What stays unproven is the live run itself: a resync's purge
on the test account's 147,024 rows has not been observed.

## Sources

- https://github.com/immich-app/immich/blob/v3.3.0/server/src/services/sync.service.ts
- https://github.com/immich-app/immich/blob/v3.3.0/server/src/utils/sync.ts
- https://github.com/immich-app/immich/blob/v3.3.0/server/src/dtos/sync.dto.ts
- https://github.com/immich-app/immich/blob/v3.3.0/server/src/repositories/sync.repository.ts
- https://github.com/immich-app/immich/blob/v3.3.0/server/src/repositories/session.repository.ts
