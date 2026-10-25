# Browsers: pasting and dropping several photos

Date: 2026-10-25. Follow-up to `2026-10-24-edited-photo-handoff-and-export.md`, whose
browser rows came from source code only. This pass ran the paste and the drop. No code
or behavior changed.

Labels: **[M]** measured here; **[V]** checked against the cited source.

## Set-up

- **Browsers installed:** Chrome 156.0.8078.47 and Safari 27.0.1. Firefox is not
  installed.
- **Test page:** served from `127.0.0.1`. It logs what a page receives:
  - `clipboardData` on paste, `dataTransfer` on drop;
  - `types`, each `File`'s name, type and size, each item's kind;
  - whether each file decodes in an `<img>`.

  It has an editable field, as a mail or chat composer does.
- **Pasteboard:** one item per file, each carrying its `public.file-url`. That is the
  representation Otos's ⌘C writes (`MediaGridClipboard.write`, `writeObjects` of file
  `NSURL`s) and its grid drag writes (`NSDraggingItem(pasteboardWriter: NSURL)`) [V].
- **Files:** three 4000×2667 JPEG renders, one HEIC render, one original ARW.
- **Chrome:** a throwaway profile driven through the DevTools protocol, which fires
  Chrome's own Paste command. That command reads the system pasteboard as ⌘V does.
- **Safari:** WebKit, Safari's engine, in a `WKWebView` test app.
  - Paste: `paste(_:)` sent to the web view, which is what Edit ▸ Paste does.
  - Drop: WebKit's own `NSDraggingDestination` methods given a named drag pasteboard
    with the same items.
  - Safari.app itself was not driven: screen control was declined, and Safari cannot be
    scripted to paste.
- **Pasteboard ownership:** items after the first are served by the writing process on
  demand. A writer that exits early leaves only the first item [M], so the test writer
  stayed alive during each paste. In Otos the app is the writer and stays alive.

## Results

| | Chrome 156: paste | WebKit (Safari 27): paste | WebKit (Safari 27): drop |
| --- | --- | --- | --- |
| Files received | All 5, in order [M] | All 5, in order [M] | All 5, in order [M] |
| `types` | `["Files"]` only; no path or URL text is exposed [M] | `["Files"]` [M] | `["Files"]` [M] |
| File types | `image/jpeg`, `image/heic`, `image/x-sony-arw` [M] | same [M] | same [M] |
| JPEG displays | Yes [M] | Yes [M] | Yes [M] |
| HEIC displays | **No** [M] | Yes [M] | Yes [M] |
| ARW displays | No [M] | No [M] | No [M] |

- **Chrome drop** was not run, because it needs a real pointer drag and screen control
  was declined. Chrome's drop handler builds its file list with
  `clipboard_util::FilesFromPasteboard` [V,
  [web_drag_dest_mac.mm](https://chromium.googlesource.com/chromium/src/+/main/content/browser/web_contents/web_drag_dest_mac.mm)].
  Its paste path calls the same function [V,
  [clipboard_mac.mm](https://chromium.googlesource.com/chromium/src/+/main/ui/base/clipboard/clipboard_mac.mm)].
  That function loops over every pasteboard item's file URL [V,
  [clipboard_util_mac.mm](https://chromium.googlesource.com/chromium/src/+/main/ui/base/clipboard/clipboard_util_mac.mm)].
  The paste above exercised that function with five items.
- **What a website does with the files is up to the site.** A page receives all of them;
  whether it uploads one or all depends on whether its code loops over `files`. This
  pass tested what browsers deliver, not any particular site.

## Finding

- **Several photos copy, paste and drop into both browser engines as several files.**
  One file URL per photo, as Otos writes today, is enough. No other mechanism is needed.
- **Chrome cannot display HEIC.** A web page in Chrome receives a hand-off HEIC as a
  file it cannot show. A hand-off JPEG displays in both browsers. That is evidence for
  JPEG as the hand-off format of a rendered photo; HEIC remains possible for export,
  where the user chooses.
- **Today's hand-off of an original RAW is useless to a web page.** Neither engine can
  display an ARW. A rendered JPEG fixes this for unedited RAWs too, if the hand-off
  renders them.
