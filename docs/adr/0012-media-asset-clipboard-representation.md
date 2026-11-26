# ADR 0012: Media Asset Clipboard Representation

## Status

Accepted; rewritten 2026-11-26 by the owner's decision to download a cloud-only original
before it is copied ("yes, download before copying"). Which file is copied for a photo is ADR
0037's (the original, or a full-size file prepared for an edited photo or a RAW); this ADR owns
what the pasteboard carries for it, when it is written, and that the file is on this Mac.
Open / Open With (APP-035) and Share (APP-036) hand the same files to another process under
the same rule.

## Context

The media grid has a ⌘C / Edit ▸ Copy command. We must decide what a copied image or video
places on `NSPasteboard.general`, so it can be pasted or attached in other apps, and what
happens when its original is a dataless cloud placeholder, which most of the owner's library
is.

Verified facts (`docs/research/2026-11-26-copy-paste-and-cloud-originals.md`,
`docs/research/2026-10-25-browser-multi-file-paste-and-drop.md`):

- macOS's default representation for a copied image is uncompressed `public.tiff`; a
  full-resolution TIFF of one large photo can be tens to hundreds of MB. Photos copies a JPEG
  and a file URL; Finder copies file URLs; Lightroom has no copy-photo command.
- A file URL pastes and attaches the file in Finder, Messages, Mail, AirDrop and web pages at
  full fidelity, for a few bytes, and is the only representation that works for video.
  Chrome and WebKit accept several pasted files, one per pasteboard item.
- Chromium hands a page `text/plain` beside the files whenever a string is on the pasteboard,
  and the page chooses; some web apps take the text, and chatgpt.com turns a long pasted text
  into a file attachment. `NSURL`'s `NSPasteboardWriting` types are undocumented, and every
  type after the first is promised, served by the writing process for as long as it runs.
- A file promise does not paste: Finder and browsers read file URLs only, so a pasted file
  must exist when it is pasted.
- A receiver that reads a dataless original downloads it in its own process, on its own
  terms: its own progress or none, its own error or a hang, and nothing Otos can report.
  Otos can download it first, deliberately, as the user's work, through the shared
  `MaterializationCoordinator`, and report a failure in its own terms.
- Otos is unsandboxed, so a plain file URL on the pasteboard is directly readable by the
  receiving app, and the pasteboard grants a sandboxed receiver access to each
  `public.file-url` entry.

## MECE Decision Scope

Owned here: the pasteboard representation a Copy writes, when it claims and when it writes
the pasteboard, and the rule that every file handed to another app is on this Mac.

Referenced, not owned: which file a photo hands over and the hand-off lane that prepares it
(ADR 0037); the selection model and the copy command wiring (APP-011, APP-012); the
download mechanism (`FileMaterialization`, ADR 0008/0009); drag-and-drop (ADR 0028), which
writes the same item but cannot wait for a download.

## Decision

- **A Copy hands over files that are on this Mac.** A cloud-only original is downloaded first,
  at interactive priority, behind the hand-off's status bar, before the pasteboard is written;
  Share, Open and Open With do the same. The download is the user's act on the photos they
  chose, so it is deliberate, never accidental, materialization. An original missing from its
  folder fails the Copy with an alert; its path is never handed over.
- **One pasteboard item per file, carrying exactly `public.file-url`,** in display order,
  built by hand (`NSPasteboardItem.setString(_:forType: .fileURL)`), written at once, so no
  string rides beside the file and every item outlives Otos's process. No pixel, promise or
  transcoded representation.
- **⌘C claims the pasteboard at the command** (`clearContents`), before any file is ready,
  and the Copy writes only while that claim is still the pasteboard's (`changeCount`): a
  paste while photos are prepared pastes nothing rather than what was there before, and a
  Copy that finishes after anything else wrote the pasteboard — another app, or a newer Copy
  — leaves it alone.

## Alternatives Considered

### Original file URLs, handed over as they are (the decision until 2026-11-26)

Instant, and reads no bytes. A cloud-only original was downloaded by whichever app read it,
with that app's progress and errors or none, and a missing original was handed over as a path
with nothing there. Rejected by the owner after pastes that failed or stalled.

### Image pixel data (TIFF/PNG), Preview-style; or file URL plus image data, Photos-style

Pastes inline into a rich-text field. Huge and uncompressed, no video form, and Chromium hides
image data when files are present, so the file URL would win in browsers anyway. Not built;
an additive representation if a receiver ever needs it.

### A file promise, or a lazy data provider

A promise does not paste. A lazy `public.file-url` provider would answer on Otos's main thread
while the file downloads, a hang of as long as the download takes.

### `NSURL` objects (`writeObjects([NSURL])`)

What Otos wrote before: undocumented types, and every item after the first served by Otos's
process on demand, so a quit or an update's relaunch left only the first.

## Consequences

- Copying a cloud-only photo takes as long as its download, shown as `Preparing N photos to
  copy` with Cancel; copying photos that are on this Mac stays instant.
- Every receiver gets a file it can read at once, and a provider that cannot deliver one is
  reported by Otos (`Couldn’t Prepare Photos`), named by its source.
- A paste never delivers what the clipboard held before the ⌘C, and a slow Copy never
  overwrites a newer copy.
- Pasting into a browser text field inserts the files, never an inline image; the accepted
  gap is unchanged.

## Living Documentation Impact

- `docs/requirements.md`: APP-012, APP-035, APP-036, APP-051.
- ADR 0037: what a hand-off downloads and how it fails.
- `docs/research/2026-11-26-copy-paste-and-cloud-originals.md`.

## Reversal Plan

Handing originals over unread again would drop the download step from the hand-off lane and
restore its failure modes; it needs the owner's decision. Adding a pixel representation is
additive.
