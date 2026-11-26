# ADR 0037: A hand-off is the photo as Otos shows it

- Status: Accepted
- Last updated: 2026-11-26

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
  - an unedited still that is not a RAW, or an untrimmed video: the original itself, on this
    Mac (ADR 0012). A cloud-only original is downloaded first as the user's work. An
    original a source stages — an Immich account's or a camera's (ADR 0046 §4) — has no file
    until Otos copies it, and no app can fetch it, so one not yet staged is fetched first
    too. An original missing from its folder, which no source can send, fails the hand-off;
    its path is never handed over;
  - an edited still or any RAW: a full-size JPEG rendered from the original with its
    recipe, which carries the original's Exif, GPS, TIFF and IPTC metadata with
    orientation and pixel size reset;
  - a trimmed video: its range, exported by passthrough.

  The files are written by `MediaFileWriter`, which export (ADR 0038) also uses, so a
  photo handed off and a photo exported as full-size JPEG are the same file.
- **Where prepared files live.** One folder in Application Support (`HandOff`), never a
  media folder, holding a folder of the launch's own. A file's path in it is fixed by the
  photo and its recipe, so a photo handed off twice in one launch reuses its file, and an
  earlier launch's file is never taken for one. The earlier launches' folders are cleared
  once, before this launch's first preparation writes. Nothing full-size is kept beyond
  that launch.
- **One preparation per file.** An actor runs other work at every `await`, so two asks for
  one photo's file (a drag's promise and a Copy) join one preparation: each waits on its own
  continuation and can stop waiting at once; the preparation is cancelled when its last
  waiter leaves (`HandOffPreparer.join`).
- **Copy, Share, Open and Open With** are one ordered view-model lane:
  1. read the targets' details;
  2. prepare what needs it — download, render or export — behind a bottom status bar
     (`Preparing 3 photos to copy`, M of N, Cancel);
  3. act: write the pasteboard, show the share picker, or open the files (each with its
     own default app).

  Each request's work is a task of its own (`handOffWork`). A selection that needs nothing
  prepared acts with no bar. Cancel cancels that task, which stops the download or render
  in flight, and hands nothing over; the lane goes on to the next request. A newer Copy
  cancels an older one still being prepared and skips one still queued, since the
  pasteboard keeps only the newest. A hand-off is all or nothing, because handing over the
  rest would silently drop a photo the person chose, so the first photo that cannot be
  prepared ends it with an alert naming that photo's cause (`HandOffFailure`), each
  classified by type, never by text:
  - the disk is full: a write the hand-off folder's volume refused for space
    (`PrepareError.outOfSpace`, through `FreeSpaceFloor.refusedForSpace`);
  - a source that cannot send an original, by its sidebar name (`“Family” isn’t answering`,
    `“EOS R5” isn’t connected`; `sourceUnavailable`, from the executor's
    `serverUnreachable` or `deviceUnavailable`);
  - a folder's provider that did not deliver a cloud-only original, by the folder's sidebar
    name (`downloadFailed`);
  - an original missing from its folder (`originalMissing`);
  - macOS's missing support for a RAW's camera (`rawSupportUnavailable`, from
    `ImageRenderer.RAWResourcesUnavailable`), which is no verdict on the photo;
  - a render or export that failed (`renderFailed`);
  - the targets' details the catalog could not read.

  `MediaFileWriter` encodes in memory and then writes the file, so the write's own error
  reaches the caller instead of Image I/O's bare failure.
- **Drag cannot wait,** so its writer is chosen synchronously from the details the grid
  holds (`dragWriters(for:)`):
  - the original's `public.file-url`, a cloud placeholder included: the receiver downloads
    it, because a promise for it would never be fulfilled by Chrome;
  - a file this launch already prepared;
  - or a file promise, which prepares the photo when the receiver asks, downloading a
    cloud-only original through the shared coordinator first and copying the file into the
    receiver's folder on the promise's own queue. Finder, Mail, Messages and Safari wait for
    it.

  A photo dragged into Chrome arrives only if its file is ready. ⌘C then paste works in
  every case. A staged original not yet copied is promised, never offered as a path with
  nothing there. A tile whose details the grid does not hold is promised as pending: its
  details are read at once, off the main actor, and the promise waits for them before it
  names the file (AppKit asks on the main thread at the drop), so the name and the file
  written are always the photo's hand-off file; until then it declares only that it is an
  image or a movie. A promise that cannot be kept fails with the reason (`PrepareError`'s
  description), which is what the receiver shows, since a drag has no alert of Otos's own.
- **Open and Open With list apps by file type** for an original not on disk yet, because
  LaunchServices answers nothing for a path with no file (`LaunchServicesWorkspace`).
- **An unedited HEIC is handed over as itself,** as Finder does. Chrome receives a file it
  cannot display, exactly as it would from Finder; converting would make the hand-off
  something Finder's is not.
- **Reveal in Finder still reveals the original:** it shows where the photo lives, not
  what is handed over, so an edited photo or a RAW is revealed as its original and nothing
  is rendered for it. It is a hand-off to Finder and travels the same lane: an original a
  source stages and has not copied yet (an Immich account's, a camera's) is fetched first
  at interactive priority (`HandOffPreparer.prepare(_:as: .original)`), because Finder can show
  only a file that is there, and then revealed in its staging folder. A source that
  cannot send it, or an original missing from its folder, fails the reveal with the same
  alert, ending "Nothing was revealed."; a partial reveal would silently leave out photos
  the person chose. A cloud placeholder is revealed as it is, as Finder shows it, and never
  materialized. Disabling the item for an unstaged original was rejected: whether it is
  staged is not a reason the person can act on, and every other act on the same targets
  fetches it.

## Consequences

- Copy is no longer instant for an edited photo or a RAW: about 2.2 s per RAW, shown as
  progress. Copying the same photos again in the same launch is instant.
- A copied, shared or opened file of an edited photo or a RAW lives in Application Support
  until the next launch. A receiver that keeps only a reference must copy the file before
  then (Finder, Mail and browsers copy at once).
- Copy of an unedited JPEG, HEIC or video that is on this Mac reads no bytes and is
  instant; one that is cloud-only is downloaded first, behind the status bar (ADR 0012).

## Rejected

- **Hand over originals always** (ADR 0012's rule): hands over a photo Otos does not
  show, and an ARW nothing can display.
- **Pixel data on the pasteboard** (TIFF/PNG): ADR 0012's reasons still hold. It is huge,
  it has no video form, and it pastes one image, not one file per photo.
- **Keep prepared files for the photo's life:** about 4.8 MB per RAW, a library-sized
  cache nothing displays (`2026-10-25-library-storage-and-previews.md`).
- **File promises for Copy:** pasted files must exist when pasted, and browsers do not
  read promises.
