# Immich's derived images against Otos's products (2026-11-07)

Research for ADR 0046 and ADR 0035. The proposal: download
Immich's thumbnails into the Otos catalog instead of spending cycles generating
Otos's own. This note measures what Immich makes and what each Otos product would lose by
using it.

Facts marked **live** were measured against a disposable Immich 3.3.6 server (official
`docker-compose.yml`, system config at its defaults, machine learning not started) with
three assets uploaded from `OtosTests/Fixtures/Media`. Facts marked **source** were read
from the server source on `main` at `87ef8950`: `server/src/dtos/config.dto.ts`,
`services/media.service.ts`, `repositories/media.repository.ts`, `cores/storage.core.ts`.

## What Immich generates

- **thumbnail:** WebP, quality 80, 250 px on the **short** edge (sharp `fit: outside`)
  (**source**).
- **preview:** JPEG, quality 80, 1440 px on the short edge, 4:4:4 chroma at quality ≥ 80
  (**source**).
- **fullsize:** off by default, and made only for formats a browser cannot show (HEIC,
  RAW). `GET /api/assets/{id}/thumbnail?size=fullsize` redirects (302) to `/original` for
  JPEG, PNG and WebP, and falls back to the preview otherwise (**source**, **live**).
- **thumbhash:** from a 100 px image, carried in `AssetV2` (**source**, **live**).
- **Encoded video:** H.264/AAC 720p, CRF 23, HDR tone-mapped (hable), made only when the
  transcode policy needs one. Video thumbnails and previews are ffmpeg frames
  (**source**). `/video/playback` served the original MOV for the fixture (**live**).
- **Colour:** the `colorspace` setting defaults to `p3`. sRGB and untagged sources stay
  sRGB; others are converted to Display P3. Resampling is in linear light. Orientation is
  baked into the pixels and no Orientation tag is written (**source**, **live**).
- **RAW:** `extractEmbedded` defaults to false, so sharp/libvips develops the RAW. With it
  true, exiftool's embedded JPEG is used when its short edge reaches the preview size.
  Neither is RAW9 (**source**).
- **HDR:** no gain map or HDR handling; output is 8-bit SDR (**source**).
- **Immich edits** (crop, rotate, mirror) produce separate `_edited` files. The endpoint
  serves the unedited ones by default (**source**).
- **Disk layout:**
  `thumbs/<owner>/<id[0:2]>/<id[2:4]>/<id>_{thumbnail|preview|fullsize}[_edited].<fmt>`
  (**source**).
- **Every size, format and quality is server-wide admin configuration.** A client cannot
  ask for another; it must read what comes back (**source**).

## Measured at defaults (live)

| Asset | thumbnail | preview | fullsize |
|---|---|---|---|
| JPEG 6192×4128, sRGB | WebP 375×250, sRGB, 18 KB | JPEG 2160×1440, sRGB, 391 KB | 302 → original, 5.1 MB |
| HEIC 4032×3024, rotated 90°, P3 | WebP 250×333, P3, 14 KB | JPEG 1440×1920, P3, 347 KB, upright | 302 → preview |
| MOV 960×1280 | WebP 250×334, untagged, 15 KB | JPEG 960×1280, sRGB, 118 KB | 302 → preview |

## What each Otos product would lose

- **Grid thumbnail** (Otos: 256 px). Immich's 250 px short edge is at least as many
  pixels, with gamut preserved. A RAW shows libvips's development, not RAW9.
- **Loupe preview** (Otos: 2560 px long edge, ADR 0035). Immich's is 2160 px (3:2) or
  1920 px (4:3) on the long edge, about 3.1 MP against 4.4 MP: softer on a 5K display,
  with faithful colour and orientation for JPEG and HEIC.
- **Metadata:** unaffected; it comes from the sync stream and ranged reads of the
  original (`docs/research/2026-11-07-immich-api.md`).
- **xxh3 digest** (ADR 0018): needs the original's bytes. Immich offers only SHA-1.
- **Render signature** (ADR 0042): computable from Immich's thumbnail. Comparing a
  signature from Immich's pipeline with one from Otos's crosses two resamplers and two
  RAW developers; whether such a pair stays under the confirm threshold of 4 is
  **unverified**.
- **Edits:** Immich cannot render an Otos edit recipe, so an edited still needs Otos's
  rendering from the original.

## Bandwidth for about 14,000 stills

| | data | 1 Gbit/s | 100 Mbit/s | 20 Mbit/s |
|---|---|---|---|---|
| every original (about 25 MB per RAW) | about 350 GB | about 47 min | about 7.8 h | about 39 h |
| Immich previews (about 0.4 MB) | about 5.6 GB | about 45 s | about 7.5 min | about 37 min |
| Immich thumbnails (about 16 KB) | about 0.23 GB | seconds | about 20 s | about 1.5 min |

Rendering every RAW with RAW9 adds about 4.3 h of CPU at about 1.1 s each (ADR 0035).

## Matching Otos's products to Immich's

Rejected. Otos does not write to Immich, and a client cannot choose Immich's sizes.
Lowering Otos to 1440 px, quality 80 and libvips would degrade every local library to
follow a server setting any admin can change.

## Conclusions

1. On sync, fetch Immich's thumbnail and preview for every asset (about 6 GB) into the
   derived-image store as source-provisional products. Grid, loupe, compare and offline
   browsing work at once, with no original downloaded.
2. Non-RAW stills keep Immich's products until the original is fetched for another
   reason (full-resolution zoom, edit, export, digest); Otos renders its own from that
   read. The cost is a 1920–2160 px loupe instead of 2560.
3. RAWs show Immich's development until RAW9 renders them, from an original fetched
   either on demand or by a background job. That timing is a product choice.
4. An edited still always shows Otos's rendering from the original.
5. Digests stay pending until the original is read. Render signatures are keyed by the
   pipeline that made their thumbnail.
6. Otos reads the size and colour profile of what Immich returns at runtime and never
   assumes the defaults above.
