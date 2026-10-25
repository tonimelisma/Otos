# Edited photos leaving Otos: copy, drag, Share, Open With and export

Date: 2026-10-24. Research for the editing foundation
(`2026-10-24-editing-foundation.md`). No code or behavior changed. Today every
hand-off — ⌘C, drag-out, Share, Open With — hands over the original's file URL, one per
asset (ADR 0012, ADR 0028, APP-012). Once a photo carries an edit recipe, that original
no longer looks like what Otos shows.

Labels: **[V]** checked against the cited source (Apple documentation, the installed
macOS 27 SDK headers, or Chromium/WebKit source); **[R]** a press or community report;
**[I]** inference.

## Owner direction captured

- Copying, pasting, sharing or dragging an edited photo out of Otos hands over the
  **edited version**. The original file is never modified; the edit stays an overlay.
- Several selected photos (grid, or the loupe filmstrip) copy and paste as several
  items, including into a web page in a browser.
- Exporting is allowed, including exporting several photos at once.

## What other apps do

| Product | Quick hand-off (drag / Share / copy) | Explicit original |
| --- | --- | --- |
| Apple Photos | Plain drag to Finder gives a rendered JPEG at full pixel size, sRGB [R, [Macworld 2016](https://www.macworld.com/article/227190/how-does-photos-resize-images-on-export-or-drag.html)]. Photos drags out file promises, several at once [V, [Apple file-promise sample](https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises)] | Option-drag [R, same article]; File ▸ Export ▸ Export Unmodified Original [V, [Apple guide](https://support.apple.com/guide/photos/export-photos-videos-and-slideshows-pht6e157c5f/mac)] |
| Lightroom Classic | Drag-out hands over the RAW original without edits [R, [Fitzgerald 2016](https://blog.thomasfitzgeraldphotography.com/blog/2016/6/lightroom-quick-tip-drag-and-drop-behaviour)]; no clipboard image copy [R] | Edit In ▸ "Edit a Copy with Lightroom Classic Adjustments" (render) vs "Edit a Copy" / "Edit Original" [V, [Adobe](https://helpx.adobe.com/lightroom-classic/help/open-lightroom-photos-external-applications.html)] |
| Lightroom desktop | Share menu: JPG (Small), JPG (Large), Original, custom [R, [Adobe](https://helpx.adobe.com/lightroom/desktop/save-share-and-export/save-share-photos.html)]; no ⌘C copy, an open request since 2021 [V, [Adobe ideas](https://community.adobe.com/t5/lightroom-ecosystem-cloud-based-ideas/p-copy-photo-to-clipboard/idi-p/12480521)] | Share ▸ Original |
| Capture One | Not documented for drag or copy | "Open With" sends the original; "Edit With" renders a TIFF/PSD/JPEG with adjustments next to the original [V, [Capture One](https://support.capture-one.com/hc/en-us/articles/36474788637725-How-Open-With-and-Edit-With-work-in-Capture-One)] |

The common pattern: the quick paths give a render in Photos and the original in
Lightroom Classic; the original is a separate, explicit command (a modifier or a menu
item) wherever both exist.

## macOS mechanisms and their limits

- **Several pasteboard items.** One `NSPasteboardItem` per file, each carrying
  `public.file-url`, is what Finder, Mail and Messages read as several files (ADR 0012).
  `data(forType:)` returns only the first item that has a type, so a reader asking for
  one image type gets one image [V, SDK `NSPasteboard.h`;
  [docs](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:))].
- **Lazily provided data** (`NSPasteboardItemDataProvider`). The callback must set its
  data synchronously; the reader blocks waiting and gets `nil` if the owner is slow
  enough to time out the inter-process call [V, same docs]. On a normal quit AppKit
  calls in every outstanding promise [V,
  [docs](https://developer.apple.com/documentation/objectivec/nsobject-swift.class/pasteboard:providedatafortype:)];
  a crash fulfils nothing [I].
- **`NSFilePromiseProvider`** is a drag mechanism [V, SDK header]. Finder never calls a
  promise placed on the general pasteboard for paste [R, Apple forums
  [683081](https://developer.apple.com/forums/thread/683081),
  [683382](https://developer.apple.com/forums/thread/683382)].
- **Raw image data** (PNG/JPEG/TIFF/HEIC) on the pasteboard reaches only inline-image
  targets, and usually only the first item.

## What receivers accept

| Receiver | Several file URLs pasted | File-promise drag |
| --- | --- | --- |
| Finder, Mail, Messages | Every file (ADR 0012, APP-012) | Accepted [V, Apple sample] |
| Chrome (web page) | Every item: `FilesFromPasteboard` loops over each item's `public.file-url` and Blink makes one `File` each, named by the file's last path component [V, [clipboard_util_mac.mm](https://chromium.googlesource.com/chromium/src/+/main/ui/base/clipboard/clipboard_util_mac.mm), [data_object.cc](https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/core/clipboard/data_object.cc)]. Older reports of one-file-only [R, [crbug 40417854](https://issues.chromium.org/issues/40417854)] predate current main | Never calls an `NSFilePromiseProvider` promise [V, [web_drag_dest_mac.mm](https://chromium.googlesource.com/chromium/src/+/main/content/browser/web_contents/web_drag_dest_mac.mm)] |
| Safari (WebKit) | Reads the full path array [V, [PlatformPasteboardMac.mm](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/mac/PlatformPasteboardMac.mm)] | Accepted [V, [WebKit 165204](https://bugs.webkit.org/show_bug.cgi?id=165204)] |
| Slack desktop | Chromium, so Chrome's paste path [I] | As Chrome [I] |

Not tested here against running apps: the browser rows come from source, not a paste
into a live Chrome or Safari. A web page reads a pasted `File` from its path whenever
it chooses (for example at upload time), and nothing tells Otos when it is done [I].

## Options for producing the edited file

1. **Render when the user copies, hand over file URLs.** Each edited photo renders to a
   file named after its original (`IMG_1234.jpg`) in an Otos-owned folder; unedited
   photos keep the original's URL. One representation serves ⌘C, Share and Open With,
   and every receiver above works. Cost: ⌘C waits for renders. Measured RAW9 renders are
   2.4–3.2 s cold at full size per photo on this Mac (`2026-10-24-editing-foundation.md`),
   so twenty RAWs take on the order of a minute, plus a download for any dataless
   original.
2. **Provide the file URL lazily, render at paste time.** Copy is instant; the paste
   blocks the receiver, can time out, and fails if Otos crashes.
3. **File promises for drag.** Works for Finder, Mail and Safari; Chrome receives
   nothing, so drag would still need option 1's URLs — two code paths for one action.
4. **Also attach image data.** Inline-image targets work, but Chrome prefers files and
   reads only the first image; ADR 0012 rejected this ambiguity.
5. **A persisted full-size edited render** (see the editing-foundation research) would
   make option 1 instant, at the storage cost recorded there.

**Reasonable approach:** option 1. It keeps ADR 0012's one-URL-per-asset shape, so
copy, paste, Share, Open With and multi-item paste into a web page share one
implementation, and only *what file the URL points at* changes. The rendered files
live in Application Support (CLAUDE.md), named after their originals; their lifetime
cannot be driven by time or by pasteboard change (a page may read the file later), so
the folder belongs to the process that wrote it and is cleared by the next launch,
when no reader of it can remain. Drag-out keeps file URLs too, rendered at drag start
when the photos are edited.

Open questions for the owner:

- **Unedited RAW.** An unedited RAW is shown with RAW9 defaults, but its original is an
  `.arw` that a web page cannot display. Does "hand over the edited version" also mean
  "hand over a rendered JPEG/HEIC for a RAW", as Photos' drag does?
- **The original on purpose.** Photos offers Option-drag and Export Unmodified
  Original; Lightroom and Capture One separate the commands. Does Otos need a way to
  hand over the original of an edited photo?
- **Format.** Photos' drag gives JPEG, the most widely accepted by web pages; HEIC is
  smaller. Which does a hand-off produce?

## Export

What each product's export offers (single and several photos):

| | Apple Photos | Lightroom Classic | Lightroom desktop | Capture One |
| --- | --- | --- | --- | --- |
| Formats | JPEG, HEIC, TIFF (16-bit option), PNG [V, [Apple](https://support.apple.com/guide/photos/export-photos-videos-and-slideshows-pht6e157c5f/mac)] | JPEG, JPEG XL, AVIF, PSD, TIFF, PNG, DNG, Original [R, [Adobe](https://helpx.adobe.com/lightroom-classic/help/export-files-disk-or-cd.html)] | JPG, original, custom [R, Adobe] | Per recipe [V, [Capture One](https://www.captureone.com/blog/how-to-process-multiple-file-formats-at-once)] |
| Size | Small … Full Size, Custom [R, [MacMost](https://macmost.com/exporting-from-mac-photos.html)] | Long/short edge, dimensions, megapixels, %, Don't Enlarge [V, [Dummies](https://www.dummies.com/article/technology/software/adobe-products/lightroom/how-to-export-your-photos-from-adobe-lightroom-classic-264695/)] | Dimensions [R] | Scale per recipe |
| Colour | Color Profile [V] | sRGB, AdobeRGB, ProPhoto, other; 8/16-bit [V, Dummies] | Color space under More Options [R] | ICC per recipe |
| Naming | Title, Filename, Sequential + prefix; subfolder by moment [V] | Template [V] | File naming [R] | Tokens [R] |
| Collisions | Undocumented; " (1)" reported [R, [forum](https://discussions.apple.com/thread/255570147)] | Ask, new name (-N), overwrite without warning, skip [R, Adobe] | — | Suffix, overwrite, skip [R, [Capture One](https://support.captureone.com/hc/en-us/articles/4403556249233)] |
| Metadata | Location toggle [R, MacMost] | Include level; remove person/location [V, Dummies] | Under More Options [R] | Per recipe |
| Several at once | Export N Photos [V] | Any selection; several presets at once (Batch Export) [R, [Adobe](https://helpx.adobe.com/lightroom-classic/help/export-presets-settings-plug-ins.html)] | Any selection [R] | All enabled recipes on the selection [V] |

darktable's export module is a useful clean-slate reference: filename template,
conflict policy (unique name, confirmed overwrite, overwrite-if-changed, skip), format,
quality, max size without upscaling, output profile, metadata toggles, and a background
job with progress and cancel [V,
[darktable](https://docs.darktable.org/usermanual/development/en/module-reference/utility-modules/shared/export/)].

Pitfalls the research surfaced:

- **Exporting into a library root** makes the scanner catalog the exports as new
  assets, and is Otos writing into a media folder; Lightroom Classic's same-folder and
  add-to-catalog paths produce duplicates [R,
  [Adobe forum](https://community.adobe.com/t5/lightroom-classic-bugs/p-export-with-add-to-catalog-option-duplicates-images-in-catalog/m-p/12675252)].
- **Two selected photos with the same base name** from different folders collide inside
  one export [I].
- **Colour.** Core Image converts to the colour space passed to its
  `jpegRepresentation`/`heifRepresentation` call; a wide-gamut file needs its ICC
  profile embedded [I].
- **Location privacy** of exported files is why Photos and Lightroom offer a toggle.
- **HDR.** Apple writes gain-map HDR (an SDR base plus a gain map) through
  `CIContext.writeHEIFRepresentation` options [V,
  [WWDC24 10177](https://developer.apple.com/videos/play/wwdc2024/10177/)]. RAW9's
  `extendedDynamicRangeAmount` defaults to 0 (SDR) on the photos measured.

Export is a new user-initiated file operation: CLAUDE.md's list of the only ways the
user's files change (import, reorganization, Move to Trash, card Erase) does not yet
name it, and ADR 0008 hands "any optional on-disk export of edited renders" to a
separate ADR. Both change in the increment that builds export. Otos's
`ExclusivePublication` (`renamex_np(RENAME_EXCL)` after a volume-capability probe) is
the existing no-overwrite publication mechanism export would use.
