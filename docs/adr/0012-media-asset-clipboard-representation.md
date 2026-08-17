# ADR 0012: Media Asset Clipboard Representation

## Status

Accepted. Implemented as APP-012: Copy writes one `public.fileURL` per selected
asset in display order and reads no media bytes.

## Context

The media grid is gaining selection and a ⌘C / Edit ▸ Copy command
. We must decide what a copied
image or video actually places on `NSPasteboard.general`, so it can be pasted or
attached in other apps.

Verified facts:

- macOS's default representation for a copied image is uncompressed `public.tiff`;
  a full-resolution TIFF of one large photo can be tens to hundreds of MB.
  Apple's own apps show the trade-off: Preview copies full-res TIFF (heavy),
  Photos copies downscaled pixels (lossy). Neither copies a file URL for images.
- Pasting a **file URL** attaches/copies the original file in Finder, Messages,
  Mail, and AirDrop, at full fidelity, for a few bytes, and is the only
  representation that works for **video**. A file URL does **not** paste as an
  image into a browser `contenteditable`.
- Otos is unsandboxed, so a plain file URL on the pasteboard is directly readable
  by the receiving app with no security-scoped bookmark.
- Otos principles: the filesystem is the source of truth, originals are read-only,
  and byte reads must never *accidentally* materialize a dataless cloud
  placeholder. Writing a file **reference** reads no bytes and materializes
  nothing; decoding pixels to the pasteboard would read bytes and could
  materialize placeholders.
- `MediaAssetID` already carries full filesystem identity, so the file URL is
  derivable from identity with no Store round-trip and no byte read.

## MECE Decision Scope

What this ADR owns: the pasteboard representation written when the user copies
selected catalog assets from the media grid.

What it references but does not own: the selection model and the copy command
wiring (owned by spec 0031); asset→URL construction (`MediaAssetID.fileURL`, owned
by the catalog model); enrichment-time byte reading and materialization (owned by
ADR 0008/0009).

Adjacent decisions requiring their own ADR/spec when built: drag-and-drop export
out of the grid; a pixel/"Copy as Image" representation; any export pipeline that
transcodes originals.

## Decision

Copy writes one original **file URL** (`public.fileURL`) per selected asset, in
display order, and nothing else. It reads no image or video bytes and adds no
pixel, promise, or transcoded representation. It does not itself materialize a
dataless cloud original; if the receiving app later reads the pasted file, that
byte read (and any materialization) is the receiver's action, consistent with the
filesystem being the source of truth.

## Alternatives Considered

### Alternative A — File URLs only (chosen)

Pros:

- Tiny, lossless, and immune to the TIFF-size problem.
- Works in Finder, Messages, Mail, AirDrop, and is the only option for video.
- Reads no bytes; materializes no dataless placeholder; needs no Store query.

Cons:

- Does not paste an image into a browser `contenteditable`.

Failure modes:

- A user expecting an inline image paste into a web text field gets nothing there.
  Mitigated by documenting the gap and keeping a pixel representation as a clean
  additive follow-up.

### Alternative B — Image pixel data (TIFF/PNG), Preview-style

Pros:

- Pastes as an image into browsers and rich-text targets.

Cons:

- Huge, uncompressed payloads; reads and decodes originals on copy, which
  materializes dataless cloud placeholders — a direct conflict with the
  no-accidental-materialization principle. No representation for video.

Failure modes:

- Copying large photos or any video is impractical or impossible.

### Alternative C — Both file URL and lazy pixel data on one pasteboard item

Pros:

- Receivers pick what they understand: files where files are wanted, pixels in a
  browser.

Cons:

- Still requires decoding originals (lazily) to satisfy the pixel type, so the
  materialization and size concerns return the moment a receiver asks for pixels;
  more surface than the verified requirements need right now.

Failure modes:

- A rich-text target that prefers the file URL inserts a file link instead of an
  inline image, surprising the user — the "two representations, one item"
  ambiguity that warrants its own decision when actually built.

## Consequences

- Copy is instant, tiny, lossless, and works for both photos and videos into the
  common share targets, with no byte I/O and no MainActor decode.
- Pasting an image directly into a browser text field is not supported yet; that
  is an accepted, documented gap.
- The design is additive: a future pixel representation attaches more types to the
  same pasteboard items, or a separate "Copy as Image" command, without changing
  the selection model or the copy command path.

## Retirement Proof

No prior clipboard/copy behavior exists to retire. This ADR introduces the first
pasteboard write. `EnrichmentCoordinator.url(for:)` is consolidated into
`MediaAssetID.fileURL` by spec 0031, but that construction change is owned by the
spec, not this ADR.

## Living Documentation Impact

- `docs/index.md`: add this ADR to the decisions table.
- `docs/requirements.md`: APP-012 references this ADR for the copy representation
  and the no-materialization-on-copy property.
- : links this ADR.
- No existing document currently describes clipboard behavior, so nothing is
  rewritten or deleted.

## Reversal Plan

Adding a pixel representation is additive and needs no reversal of this decision.
Switching to pixels-only (dropping the file URL) would be a behavior change that
reintroduces the size/video/materialization problems above and would require a new
ADR with fresh evidence.
