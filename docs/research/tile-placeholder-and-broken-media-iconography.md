# Tile Placeholder And Broken-Media Iconography

Status: non-authoritative research note.

Date: 2026-07-09

Input for the broken-media placeholder work requested by the owner (wonky toy
camera producing zero-byte and truncated AVI/JPEG files that render as QuickLook
document icons instead of thumbnails or placeholders).

## Root cause of the "document icon" tiles (evidence)

- Toy-camera library (`…/Family/Summer Photos`, library_root 4) contains
  zero-byte and truncated files alongside real `_001` siblings:
  `2026/05/20260515_191748.avi` = 0 bytes, `2026/05/20260514_195133.jpg` =
  0 bytes, `2026/05/20260514_195430.avi` = 96 KB (truncated); the `_001`
  variants are tens of MB and thumbnail fine.
- `MediaEnricher` requests QuickLook representations with
  `representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]`
  (MediaEnricher.swift:87) and never inspects
  `QLThumbnailRepresentation.type`. For unreadable media QuickLook returns the
  **icon** representation (the AVI/JPEG document icon), which is then staged,
  promoted, and stored as the asset's real thumbnail (ENR-004's "icon fallback
  accepted"). Verified by opening stored thumbnail JPEGs: the 0-byte AVI's
  stored thumbnail is the AVI document icon bitmap.
- Because the icon is a "successful" enrichment, no failure is logged and no
  stored fact distinguishes it — the tile treats it as a painted thumbnail
  (which is why the corner video badge appears on those tiles).
- API capability: `QLThumbnailRepresentation.type` distinguishes
  `.icon` / `.lowQualityThumbnail` / `.thumbnail`, so "QuickLook could not
  produce a real thumbnail" is detectable at generation time with the API
  already in use.

## HIG / SF Symbols grammar

Apple's SF Symbols guidance: the **slash** variant conveys an item that is
inactive or **unavailable**; **badges** add status to a base symbol. Sources:
[SF Symbols HIG](https://developer.apple.com/design/human-interface-guidelines/sf-symbols),
[WWDC21 What's new in SF Symbols](https://developer.apple.com/videos/play/wwdc2021/10097/).
"Media that cannot be loaded" maps naturally onto the slash grammar.

Symbol availability verified programmatically on this machine (macOS 27 beta,
`NSImage(systemSymbolName:)`):

| Symbol | Exists | Use |
| --- | --- | --- |
| `photo` | yes | loading placeholder, image (current) |
| `film` | yes | loading placeholder, video (current) |
| `r.square` / `r.square.fill` | yes | loading placeholder, RAW (proposed — differentiates RAW from image) |
| `photo.slash` | yes | broken image (proposed) |
| `video.slash` | yes | broken video (proposed) |
| `photo.badge.exclamationmark` | yes | alternative error grammar — but no video counterpart |
| `video.badge.exclamationmark` | **no** | — |
| `raw`, `r.square.slash`, `camera.badge.exclamationmark` | **no** | — |
| `exclamationmark.triangle` | yes | generic error badge (composition option) |

Consequences:

- A consistent single-symbol *slash* pair exists for image and video
  (`photo.slash` / `video.slash`); the badge-exclamation grammar cannot be
  used consistently (no video variant on this OS).
- RAW has a loading-glyph candidate (`r.square`) but **no broken variant**;
  differentiating broken-RAW from broken-image requires either sharing
  `photo.slash` or compositing (e.g. `r.square` plus a small
  `exclamationmark.triangle` companion view). Owner decision.
- Broken placeholders should reuse the loading placeholder's visual family
  (neutral square, dim centered glyph, same sizing policy) so the states read
  as siblings, and broken tiles must show **no lower-right kind badge**
  (owner rule, 2026-07-09).

## Repair consideration for already-stored icon thumbnails

The catalog has no stored fact separating icon-fallback thumbnails from real
ones, so existing wrong rows cannot be found directly. Practical proxies:

- videos with a thumbnail and `duration_seconds IS NULL` (the broken AVIs) —
  this same population needs re-enrichment anyway once AVI duration extraction
  lands (separate MediaMetadata work stream);
- images with `byte_size = 0`.

Zero-byte files can also be short-circuited before any cloud download: a
0-byte source can never produce media bytes, so enrichment can mark it
unavailable without materialization.

## Sources

- [Apple HIG: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [WWDC21: What's new in SF Symbols](https://developer.apple.com/videos/play/wwdc2021/10097/)
- [QLThumbnailRepresentation.type](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailrepresentation)
- Local verification: symbol-availability script (session scratchpad), catalog
  DB queries, stored thumbnail JPEG inspection, `MediaEnricher.swift:83-90`.
