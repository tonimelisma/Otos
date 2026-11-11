# Sony ARW bytes read as a TIFF, so no ARW was read for faces (2026-11-11)

## Finding

The installed app logged 604 `op=render.still phase=failed error=unreadable` lines in a
day, every one a Sony ARW (ILCE-6700) in a OneDrive library, every file local (no
`SF_DATALESS`). Each was a faces-only read (`upright`), and 1,492 other stills finished.

`ImageRenderer.uprightOriginal` opened the original's bytes with
`CGImageSourceCreateWithData` and no type hint. A probe on one of those files (macOS 27
beta, Darwin 27.0.0):

| How the source was made | `CGImageSourceGetType` | Pixel width |
|---|---|---|
| bytes, no hint | `public.tiff` | none |
| bytes, `kCGImageSourceTypeIdentifierHint = com.sony.arw-raw-image` | `com.sony.arw-raw-image` | 6192 |
| URL | `com.sony.arw-raw-image` | 6192 |

An ARW begins with a TIFF header, so Image I/O sniffing the bytes alone takes it for a
TIFF and finds no image in it. `CIRAWFilter(imageData:identifierHint:)` was already given
the hint and opened the same file, which is why the previews rendered.

A hint does not override bytes that sniff clearly: plain TIFF bytes given the ARW hint
still read as `public.tiff`. So a generated file cannot reproduce the failure, and Image
I/O writes no RAW format (`CGImageDestinationCopyTypeIdentifiers` lists none).

## Consequence

`MediaEnricher.readStill` treats a `RenderError` as a still no decoder can read and stamps
it with no faces (ENR-022), so each ARW was stored as read with none and never retried.

## Change

`ImageRenderer.StillSource` carries the type its extension names and makes every Image I/O
source over its bytes with that hint; `openRAW` passes the same type to `CIRAWFilter`. The
`v24_raw_faces_reread` migration clears the faces stamp of each RAW with no face row.
