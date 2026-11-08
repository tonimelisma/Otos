# Immich API for a read-only Otos source (2026-11-07)

Research for ADR 0046 and plan 0112. Facts marked **live** were measured against a
disposable Immich 3.3.6 server (official `docker-compose.yml` from the v3.3.6 release,
machine learning not started) on 2026-11-07. Facts marked **source** were read from the
OpenAPI spec and server/mobile source on `main` (spec reports `3.4.0-rc.0`). Anything
else is marked unverified.

## Versions

- Latest stable is **v3.3.6** (2026-11-04); v3.4.0-rc.3 is in release candidate.
- `GET /api/server/version` needs no auth and returns
  `{"major":3,"minor":3,"patch":6,"prerelease":null}` (**live**).
- `GET /api/server/features` and `/server/config` are deprecated since v3.2.0; the
  replacement is `GET /api/public/config` (oauth, passwordLogin, passkey, …) (**source**).
- Policy (`docs/install/upgrading.md`): semver; breaking API changes only in a major. The
  official mobile app gates features by semver only (`server_capability.model.dart`): sync
  v2 needs ≥ 3.0.0 (**source**). Otos therefore requires major 3 and refuses another major
  with a named reason rather than guessing.

## Authentication

- `POST /api/auth/login {email, password}` → 201 with `accessToken`, `userId`,
  `userEmail`, `name`, … (**live**: token length 42).
- The token is sent as `Authorization: Bearer` (**live**), or `x-immich-user-token`.
- Login sessions carry no `expiresAt`; the server refuses a session only when it has one
  and it passed, so a login lasts until logout or revocation (**source**, inferred from
  `session.repository.ts`; not documented).
- **The sync endpoints refuse API keys**: `POST /api/sync/stream` with `x-api-key` → 403
  `"Sync endpoints cannot be used with API keys"` (**live**), because sync checkpoints
  belong to a session. A sync client must log in.
- OIDC: `POST /api/oauth/authorize {redirectUri, state, codeChallenge}` → `{url}`; open it in
  a web authentication session; `POST /api/oauth/callback {url, state, codeVerifier}`
  returns the login response. The mobile redirect is `app.immich:///oauth-callback`, which
  a server admin may override (**source**). Whether a third-party macOS app can use that
  scheme without the admin whitelisting a custom redirect at their identity provider is
  unverified, so OIDC is a separate increment.
- Logout: `POST /api/auth/logout`.

## Sync stream

- `POST /api/sync/stream {types: [...], reset?: bool}` with
  `Accept: application/jsonlines+json` returns JSON Lines (**live**):
  `{"type":"AssetV2","data":{…},"ack":"AssetV2|<updateId>"}`, ending with
  `{"type":"SyncCompleteV1","data":{},"ack":"SyncCompleteV1|<id>"}`.
- `POST /api/sync/ack {acks: [...]}` (≤ 1000) stores the last ack per type for the
  session; `DELETE /api/sync/ack` clears them (**source**).
- A full resync is signalled by a single `SyncResetV1` line: on `reset: true`, a session
  flagged pending reset, or when the last `SyncCompleteV1` ack is older than 30 days
  (audit tables are pruned after 31). The client discards its remote state, acks the
  reset, and syncs again (**source**).
- Owned assets: `AssetsV2` → `AssetV2` and `AssetDeleteV1`. `AssetsV1` answers 400.
- `AssetV2` fields (**live**): `checksum`, `createdAt`, `deletedAt`, `duration`,
  `fileCreatedAt`, `fileModifiedAt`, `height`, `id`, `isEdited`, `isFavorite`,
  `libraryId`, `livePhotoVideoId`, `localDateTime`, `originalFileName`, `ownerId`,
  `stackId`, `thumbhash`, `type` (IMAGE/VIDEO/AUDIO/OTHER), `visibility`
  (archive/timeline/hidden/locked), `width`.
  - `deletedAt` non-null means the asset is in Immich's trash; `AssetDeleteV1` means it
    was deleted permanently.
  - A Live Photo's motion part is its own asset with `visibility: hidden`, linked from the
    still by `livePhotoVideoId`.
  - External-library assets arrive in the same stream with a non-null `libraryId`.
- `AssetExifsV1` → `AssetExifV1` with `fileSizeInByte` (**live**: present even before
  the metadata job ran), plus make/model/lens, GPS, `dateTimeOriginal`, `timeZone`,
  `orientation`, `rating` (**source**). Right after upload the exif fields other than
  `fileSizeInByte` are null until the server's metadata job runs (**live**).
- Partner and shared-album assets arrive only through `PartnerAssetsV2` and
  `AlbumAssetsV2` (**source**). Plan 0112 syncs owned assets only.

## Media endpoints

- `GET /api/assets/{id}/original` serves the original bytes and honours byte ranges
  (**live**: `Range: bytes=0-99` → `206 Partial Content`, `Accept-Ranges: bytes`,
  `Content-Range: bytes 0-99/2414759`). Ranged reads let MediaMetadata read metadata
  without a whole-file download, as cameras that pass the range probe already do.
- `GET /api/assets/{id}/thumbnail?size=thumbnail` → `image/webp`, about 18 KB;
  `size=preview` → `image/jpeg`, about 390 KB (**live**). Defaults are 250 px WebP and
  1440 px JPEG, admin-configurable (**source**). Either is a provisional thumbnail only:
  ADR 0035 requires Otos's own rendering in the grid and loupe.
- `GET /api/assets/{id}/video/playback` serves the transcode, falling back to the
  original, with byte ranges (**source**).
- `checksum` is the SHA-1 of the original, base64-encoded. It is not Otos's xxh3 digest
  (ADR 0018).

## Conclusions

1. An account must be added by logging in, not by pasting an API key: sync refuses keys.
2. The sync stream is a durable server-side cursor per session: Otos needs no listing
   pagination, no snapshot-stability heuristics, and no polling of a full listing. Deletion
   is reported, never inferred.
3. Ranged originals make the metadata pass cheap; renderings still need the whole file.
4. Offline, Immich can serve nothing, so Otos's own stored thumbnail and preview are the
   whole offline experience.

## Sources

- OpenAPI spec: https://github.com/immich-app/immich/blob/main/open-api/immich-openapi-specs.json
- Sync: https://github.com/immich-app/immich/blob/main/server/src/services/sync.service.ts
- Auth: https://github.com/immich-app/immich/blob/main/server/src/services/auth.service.ts
- Media: https://github.com/immich-app/immich/blob/main/server/src/services/asset-media.service.ts
- Mobile capabilities: https://github.com/immich-app/immich/blob/main/mobile/lib/domain/models/server_capability.model.dart
- Upgrade policy: https://github.com/immich-app/immich/blob/main/docs/docs/install/upgrading.md
- Release: https://github.com/immich-app/immich/releases/tag/v3.3.6
