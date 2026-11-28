# ADR 0038: Export writes new files into a folder the person chooses

- Status: Accepted
- Last updated: 2026-10-25

## Context

A hand-off (ADR 0037) gives another app one full-size file per photo, kept only until the
next launch. People also need files to keep: a set of photos at a chosen size and format
in a folder of their own, to upload, mail or archive.

Product decisions (2026-10-25):
- Export is allowed, for several photos at once and into a library folder.
- Formats JPEG, HEIC or Original; full size or a long edge, never enlarged; a quality
  setting; metadata kept, with a switch to remove location.
- A folder chosen in the sheet and remembered.
- Names are the original's with the new extension; a collision gets `_001`, `_002`… as
  import names them, and nothing is ever overwritten.
- One background job with progress and Cancel, under the 5 GB free-space floor.

Export writes into a folder that may be a library or a cloud-synced folder, so it is one
of the user-initiated file operations CLAUDE.md lists, beside import and reorganization.

## Decision

- **File ▸ Export… (⇧⌘E)** opens a sheet for the current targets: Format, Size (Full Size
  or Long Edge, in pixels), Quality, Remove location, and Folder with Choose…. Size,
  Quality and Remove location shape a rendered file, so Original disables them. The
  choices are remembered in preferences (`ExportSettingsStore`).
- **What each item writes** (`MediaExporter`, one owner):
  - a photo as JPEG or HEIC: rendered from the original with its edit (RAW9 defaults for
    an unedited RAW), scaled down to the long edge when one is set, written by
    `MediaFileWriter`, which a hand-off also uses. It keeps the original's Exif, TIFF,
    IPTC and, unless removed, GPS metadata, with orientation and pixel size reset;
  - a photo as Original: the original's bytes;
  - a video: the original's bytes, or, when it is trimmed or its location is removed,
    its range copied without re-encoding as a QuickTime movie (`AVAssetExportSession`
    passthrough, with AVFoundation's sharing filter to remove location). Original copies
    the file as it is.
- **Writing never touches the destination until it is complete.** Each file is written
  into the scratch folder the system keeps on the destination's volume
  (`FileManager.url(for: .itemReplacementDirectory, …)`), then moved into the folder by
  `ExclusivePublication`, which never replaces an existing file. A taken name is retried
  with `ImportNaming.suffixToken` (`_001` to `_999`). A crash leaves nothing in the
  person's folder; the system clears its scratch folders.
- **The free-space floor** (`FreeSpaceFloor`, ADR 0027) is checked before each write: the
  download of a cloud-only original on its volume, and the file on the destination's
  volume (a rendered photo's uncompressed size bounds its file from above; a copy or a
  passthrough range is at most the original's size). A write the floor refuses stops the
  job.
- **One job lane.** Export submits one request to an ordered, lossless view-model lane
  with one consumer. It checks the folder exists, reads the targets' details, and exports
  them in display order behind a bottom status bar (`Exporting 3 photos`, M of N, Cancel;
  the hand-off's bar, DES-094). Rendering runs on `ImageRenderer.background`, so a long
  export does not hold the interactive lane that loupe zoom and hand-offs use.
- **Outcomes.** A photo that cannot be exported does not stop the others. The floor, a
  write its volume refused for space (`MediaFileWriter.WriteError.outOfSpace`, classified
  by `FreeSpaceFloor.refusedForSpace`, never by wording), and a folder that went away stop
  the job, because every later photo would meet the same wall; the alert names the full
  disk rather than the originals. Cancel stops before the next photo. When an export did not do everything it was
  asked, an alert says so (`Exported 4 of 10 Photos`, with why) and offers Show in Finder
  for the files it wrote. A complete or cancelled export shows nothing more.
- **Into a library.** A library folder is allowed. The scanner catalogs the exported
  files like any new file; nothing about them is special.

## Consequences

- Exported files are the person's: Otos never deletes, replaces or tracks them.
- The export of a cloud-only photo downloads its original, as any deliberate byte read
  does (ADR 0008); macOS may evict it again later.
- Edit ▸ Cut, Copy, Paste and Select All act on text while the sheet is up, not on the
  photos behind it.

## Rejected

- **Write into the destination under a hidden name, then rename.** A crash would leave a
  hidden, unjournaled file in the person's folder, which ARC-031 forbids.
- **Overwrite or ask on a collision.** Export uses import's naming: never overwrite,
  never ask.
- **Stop the whole job on the first failed photo.** Unlike a hand-off, an export is a set
  of independent files; the person keeps what was written and is told what was not.
- **Strip location from Original.** Original is the file as it is on disk; changing its
  metadata would make it something else.
