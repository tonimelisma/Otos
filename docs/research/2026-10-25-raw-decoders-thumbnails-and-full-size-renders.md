# RAW decoders, today's thumbnails, and full-size renders

Date: 2026-10-25. Follow-up to `2026-10-24-editing-foundation.md`. No code or behavior
changed. Three questions: do cameras without RAW9 need RAW8; where today's grid
thumbnail comes from; how a full-size (100%) view is rendered and whether it is kept.

Labels: **[M]** measured here (macOS 27.0, Xcode 27, scratch probes reading local,
non-dataless files only); **[V]** checked against code or the cited source; **[R]** a
community or press report; **[U]** unconfirmed.

## Cameras without RAW9

- RAW9 covers 69 of the 939 camera models `CIRAWFilter` decodes [M]: Panasonic 21,
  Canon 19, Sony 18, Nikon 5, Sigma 3, Fujifilm 2, Leica 1
  (`CIRAWFilter.supportedCameraModels(with: .version9)`). Every RAW in the installed
  catalog is from the Sony ILCE-6700, which is on the list [M].
- Every other supported camera decodes with RAW8 (the filter's default) or older; the
  file's own `supportedDecoderVersions` says which [M: `[7, 8, 9]` for the ILCE-6700].
  So yes: Otos needs RAW8 for those cameras. It is the same `CIRAWFilter` with a
  different `decoderVersion`, not a second pipeline.
- The control set differs by decoder. On the same file, RAW8 also supports colour noise
  reduction, detail and moiré reduction; RAW9 does not [M, foundation research table].
  The sidebar shows a control only when the photo's filter reports it supported
  (`is…Supported`), so a RAW8 photo shows those three and a RAW9 photo does not.
- A photo's recipe records the decoder version it was edited with: rendering the same
  values through another decoder gives a different image, and macOS may add RAW9 support
  for a camera later. Unedited RAW defaults to the newest version the file supports.

## Where today's grid thumbnail comes from

- Otos's grid thumbnail is a 256 px image from `QLThumbnailGenerator`
  (`Otos/Services/MediaEnricher.swift:381`) [V]. Otos makes it, but Quick Look builds it
  from the camera's embedded JPEG, not from the RAW data.
- Measured on one ILCE-6700 ARW at the same 256×171 size, mean absolute difference per
  channel on a 0–255 scale [M]:

  | Quick Look thumbnail compared with | Difference |
  | --- | --- |
  | Embedded camera JPEG (1616×1080) | 2.25 |
  | RAW9 render | 17.90 |
  | RAW8 render | 17.75 |

- The camera JPEG has visibly more contrast and saturation than the RAW9 default render,
  which is flatter [M, images compared side by side]. Showing RAW9 defaults
  (decision 6) therefore changes how every RAW looks in the grid and the loupe, not only
  edited ones.
- Side observation: Quick Look failed on the same file in place inside the OneDrive
  folder when called from a command-line probe (`GSLibraryErrorDomain` 3, "Generation
  not found") and succeeded on a local copy [M]. Not investigated in the app.

## How a full-size view is rendered

Nothing Otos would show needs a stored full-size image: the screen is smaller than the
photo. The 100% view (zoomed in) renders only the visible part of the full-resolution
image from the original:

- `CIRAWFilter` at `scaleFactor = 1`, rendering only the window's rectangle with
  `CIContext.render(_:toBitmap:rowBytes:bounds:format:colorSpace:)` [M]:

  | Visible area at 100% | First view | Pan to a new area | Slider change |
  | --- | --- | --- | --- |
  | 1280×800 | 222–244 ms | 7–255 ms | 11–76 ms |
  | 2560×1600 | 428–779 ms | 11–768 ms | 10–81 ms |

  Measured on two ARWs, two runs each, with one `CIContext` with `cacheIntermediates`
  per run.
- A full-size render of the whole photo (6192×4128) takes 2.6–3.2 s and peaks at
  270–290 MB [M]. Rendering only the visible area is 3–14× faster on first view.
- The original must be local. A dataless original downloads first, through the
  `MaterializationCoordinator`, as every byte read does.

## How others keep full-size renders

| Product | 100% view rendered from | Full-size kept? | When built / discarded | Disk per photo |
| --- | --- | --- | --- | --- |
| Lightroom Classic | Develop: the RAW. Library: a stored 1:1 preview [R, [LR Queen](https://www.lightroomqueen.com/lightroom-performance-previews-caches/); [Adobe Community](https://community.adobe.com/questions-675/do-previews-do-anything-whatsoever-946115)] | 1:1 previews, optional: full-resolution Adobe RGB JPEGs in `Previews.lrdata` [R, LR Queen] | On zoom, at import, or Library ▸ Previews ▸ Build 1:1. Auto-discard after 1 day, 1 week, 30 days, or never; the default of 30 days is from a community expert, not Adobe [R] | 3.9 MB for a 1:1 of a 42 MB Sony RAW; 289 kB at 2048 px [R, [Adobe Community](https://community.adobe.com/t5/lightroom-classic-discussions/why-are-preview-files-so-large/td-p/10093293)]; catalogs average about 2.7–2.8 MB per photo [R] |
| Lightroom (cloud) | The original, downloaded on demand; offline, the 2,560 px Smart Preview [R, [LR Queen forum](https://www.lightroomqueen.com/community/threads/help-with-syncing-lightroom-classic-cc-with-lightroom-cc.36538/)] | No full-size render; a capped cache of originals and Smart Previews [R, Adobe help excerpt] | Cache limit set by the user | Smart Preview about 2% of the RAW, about 1 MB [R, [creative-photographer](https://www.creative-photographer.com/smart-previews-lightroom/)] |
| Capture One | The RAW [R, [Capture One blog](https://www.captureone.com/blog/preview-sizes-and-offline-editing-in-capture-one-pro-7)] | No; a display-sized preview (default 2,560 px in Pro 7; current guidance: match the display) | At import or first view; regenerated when the size changes | [U] |
| Apple Photos | [U] | Yes, for edited photos only: a full-size render in `resources/renders`, plus smaller derivatives with the edit [R, [photos forensics](https://github.com/muxcmux/apple-photos-forensics)] | Rebuilt with each edit | [U] |
| darktable | The RAW; optional full-preview disk cache, default off [V, [darktable manual](https://docs.darktable.org/usermanual/development/en/preferences-settings/lighttable/)] | Optional, never deleted | When previewed | "several gigabytes" in total [V] |

Adobe's and Capture One's own help pages refused automated fetches; their rows come from
search excerpts and community experts, as labelled.

Photos keeps a full-size render because PhotoKit hands an edit to other apps as a baked
file. Lightroom's 1:1 previews exist because Library cannot render RAW; it discards
them on a timer. Otos keeps every overlay for as long as the asset exists and never
evicts (ADR 0008, ADR 0009), so a full-size render would be permanent.

## Disk cost of a kept full-size render

RAW9 at 6192×4128, HEIC, Display P3, two ARWs: 1.03 MB and 5.23 MB [M]. That suggests
roughly 6–31 GB for the 5,937 ARWs [I, scaled from two files], on top of the display
render.

## Finding

- **RAW8 is needed** for every camera without RAW9. It is the same filter with a per-photo
  decoder version that is recorded in the recipe, and it shows only the controls that
  decoder supports.
- **The grid thumbnail is Otos's, but its pixels are the camera's JPEG.** Moving to RAW9
  defaults means re-rendering every RAW's thumbnail from RAW data.
- **No full-size render is kept.** The 100% view renders the visible rectangle from the
  original (0.2–0.8 s on first view, tens of ms per slider change). Export, copy and
  drag render the full image when they run. A kept full-size render would cost about
  6–31 GB for this library under a lifecycle with no eviction, and nothing would display
  it at full size.
- What is kept is unchanged from the foundation research: the 256 px thumbnail and one
  display-size render.
