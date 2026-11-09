# ADR 0037: A hand-off is the photo as Otos shows it

- Status: Accepted
- Last updated: 2026-10-25

## Context

ADR 0012 (Copy) and ADR 0028 (drag) hand another app one original file URL per photo.
Opening another app and Share hand over the same URLs. That was right while Otos showed
originals as they are. Since ADR 0036, a photo can carry an edit. Since ADR 0035, a RAW is
shown developed with RAW9. Handing over the original would hand over a photo Otos does not
show, or an ARW that browsers and most apps cannot display.

Owner decisions (2026-10-25):
- Hand-off behaves like Finder: one full-size file per photo.
- An unedited RAW hands over a rendered JPEG, not the ARW.
- The acceptance case is a mixed selection of edited and unedited photos, copied and
  pasted into Chrome and Safari, arriving as one file per photo.

Measured (`2026-10-25-browser-multi-file-paste-and-drop.md`):
- Chrome and WebKit accept every pasted or dropped file, including a cloud-only one, which
  the browser downloads when it reads it.
- Chrome never fulfils a drag's file promise.
- Chrome cannot display HEIC.
- A RAW renders at full size in about 2.2 s.

## Decision

- **What is handed over** (`HandOffPreparer`, one owner for every path):
  - an unedited still that is not a RAW, or an untrimmed video: the original, unread, as
    before. An original a source stages — an Immich account's or a camera's (ADR 0046
    §4) — has no file until Otos copies it, and no app can fetch it, so one not yet staged
    is fetched first as the user's work, and is then handed over as itself;
  - an edited still or any RAW: a full-size JPEG rendered from the original with its
    recipe, which carries the original's Exif, GPS, TIFF and IPTC metadata with
    orientation and pixel size reset;
  - a trimmed video: its range, exported by passthrough.

  The files are written by `MediaFileWriter`, which export (ADR 0038) also uses, so a
  photo handed off and a photo exported as full-size JPEG are the same file.
- **Where prepared files live.** One folder in Application Support (`HandOff`), never a
  media folder. A file's path is fixed by the photo and its recipe, so a photo handed off
  twice in one launch reuses its file. The folder is cleared once per launch, before the
  first hand-off. Nothing full-size is kept beyond that launch.
- **Copy, Share, Open and Open With** are one ordered view-model lane:
  1. read the targets' details;
  2. prepare what needs it, behind a bottom status bar (`Preparing 3 photos to copy`,
     M of N, Cancel);
  3. act: write the pasteboard, show the share picker, or open the files (each with its
     own default app).

  A selection that needs nothing prepared acts with no bar. Cancel hands nothing over. A
  photo that cannot be prepared fails the hand-off with an alert, because handing over
  the rest would silently drop a photo the person chose.
  The alert names the cause it knows: a write the hand-off folder's volume refused for
  space says the disk is full (`HandOffPreparer.PrepareError.outOfSpace`, classified by the
  error's typed chain through `FreeSpaceFloor.refusedForSpace`); a source that cannot send
  an original is named by its sidebar name in its own terms (`“Family” isn’t answering`,
  `“EOS R5” isn’t connected`; `PrepareError.sourceUnavailable`, from the executor's
  `serverUnreachable` or `deviceUnavailable`); any other failure says the original may be
  unavailable. `MediaFileWriter` encodes in memory and then writes the
  file, so the write's own error reaches the caller instead of Image I/O's bare failure.
- **Drag cannot wait,** so its writer is chosen synchronously from the details the grid
  holds:
  - the original's URL;
  - a file this launch already prepared;
  - or a file promise, which prepares the photo when the receiver asks. Finder, Mail,
    Messages and Safari wait for it.
  A photo dragged into Chrome arrives only if its file is already prepared. ⌘C then paste
  works in every case. A staged original not yet copied is promised, never offered as a
  path with nothing there. A promise that cannot be kept fails with the reason
  (`PrepareError`'s description), which is what the receiver shows, since a drag has no
  alert of Otos's own.
- **Open and Open With list apps by file type** for an original not on disk yet, because
  LaunchServices answers nothing for a path with no file (`LaunchServicesWorkspace`).
- **An unedited HEIC is handed over as itself,** as Finder does. Chrome receives a file it
  cannot display, exactly as it would from Finder; converting would make the hand-off
  something Finder's is not.
- **Reveal in Finder still reveals the original:** it shows where the photo lives, not
  what is handed over.

## Consequences

- Copy is no longer instant for an edited photo or a RAW: about 2.2 s per RAW, shown as
  progress. Copying the same photos again in the same launch is instant.
- A copied, shared or opened file of an edited photo or a RAW lives in Application Support
  until the next launch. A receiver that keeps only a reference must copy the file before
  then (Finder, Mail and browsers copy at once).
- Copy of an unedited JPEG, HEIC or video still reads no bytes and never materializes a
  cloud-only original.

## Rejected

- **Hand over originals always** (ADR 0012's rule): hands over a photo Otos does not
  show, and an ARW nothing can display.
- **Pixel data on the pasteboard** (TIFF/PNG): ADR 0012's reasons still hold. It is huge,
  it has no video form, and it pastes one image, not one file per photo.
- **Keep prepared files for the photo's life:** about 4.8 MB per RAW, a library-sized
  cache nothing displays (`2026-10-25-library-storage-and-previews.md`).
- **File promises for Copy:** pasted files must exist when pasted, and browsers do not
  read promises.
