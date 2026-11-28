# RAW camera support is an on-demand asset

2026-11-22. macOS 27.0, Xcode 27. Evidence tags as elsewhere: [M] measured here,
[V] verified in Apple's headers or files.

## Question

Otos chooses RAW9 for every RAW whose camera supports it (ADR 0035) but never asked
Core Image to fetch what that decoder needs. Is there anything to fetch, what does a
fetch cost when it is already there, and how should a failed fetch be handled?

## Findings

- **The API.** `CIRAWFilter.downloadResources(timeout:completionHandler:)` (new in 27)
  "downloads any on-demand resources required to decode this filter's image using its
  current decoderVersion, if they aren't already present". It reports once, with nil on
  success "whether or not a download was actually needed", or an error when the download
  failed or the timeout elapsed, on a queue of Core Image's choosing [V,
  `CoreImage.framework/Headers/CIRAWFilter.h`]. The MacOSX27.2 SDK adds
  `downloadAllResources(timeout:completionHandler:)`, which "downloads every on-demand
  demosaic/denoise model that may be used", not scoped to one file [V]: what a filter
  fetches is RAW9's demosaic and denoise model for its camera.
- **The resources are per camera and not part of the OS.** They are MobileAsset assets
  of type `com_apple_MobileAsset_RawCamera_Camera` under `/System/Library/AssetsV2/`. On the
  test Mac two are installed, both for the Sony ILCE-6700 (`arw.sony.394`,
  `dng.adobe.sonyilce-6700`), 3.2 MB together. Each asset's `Info.plist` says
  `__InstallWithOS = false`, `__RequiredByOS = false`,
  `__AssetDefaultGarbageCollectionBehavior = NeverCollected`, and names a
  `minRawCameraVersion` of 9.20.0. The asset catalog beside them lists 757 assets [V].
  A Mac that has never developed a given camera's RAW, such as a new Mac or a photo
  from a camera the Mac has not seen, may not have that camera's asset.
- **Cost when present.** A probe opened two local ILCE-6700 ARWs, set RAW9 and then
  RAW8, and called `downloadResources` three times each. The first call took 0.41 ms,
  every later one 0.008–0.23 ms, and each reported nil. The completion ran off the main
  thread. The returned progress read 0/1 at return and 1/1 after the report [M]. A
  Pentax PEF supported decoders 6 and 7 only, so this probe could not exercise it.
- **Not measured.** The behavior of a RAW9 development whose camera asset is absent,
  when nothing fetched it first. No local RAW from a RAW9 camera without an installed
  asset was available, and removing a system asset is out of bounds. Otos does not rely
  on that behavior; it follows the API's contract.

## Conclusions for Otos

- Ask for the resources every time a RAW is opened, after its decoder is chosen. A
  present camera answers in well under a millisecond, which is noise beside a
  development of about a second, so no per-process record of what was fetched is kept.
- Wait for the report. The timeout is a deadline on an external server that may never
  answer (ADR 0033), and one minute is generous for an asset of about 1.6 MB.
- A failed fetch is not a fact about the file. Enrichment paces the row for
  `rawSupportUnavailable` and develops it again later. It never stamps the RAW
  undecodable, which would hold until the next OS update, and never marks its source
  unreadable.
- Rejected: falling back to RAW8 when RAW9's support cannot be fetched. The rendering
  would be honest about its decoder, but a library would show two decoders' looks and
  two control sets, and nothing re-renders a RAW8 thumbnail until the OS changes
  (ADR 0035, no re-render on OS updates).
