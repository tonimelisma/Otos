# RAW+JPEG pairs, bursts and stacks in other photo apps

Date: 2026-11-13. A desk survey, from vendor help pages, release notes and community threads,
of how photo apps show a RAW+JPEG pair and a burst, how the user reaches a single file, and
how a collapsed group answers an action. It opened on the observation that On This Day
shows every file of a day, each RAW+JPEG shot twice. Plan 0115 relies on it.

## Facts about the reference library

From `docs/research/2026-10-31-duplicate-calibration.md` (two fixed libraries, 14 445 stills
and RAWs):

- 5 338 RAW+JPEG pairs (same folder, same stem, one RAW and one processed file).
- 3 070 frame pairs from one camera in one second, and 16 917 pairs 1–3 s apart.
- No pixel threshold separates a static burst frame from a copy, and a RAW and its camera
  JPEG never pass the copy thresholds (32 × 32 mean difference ≥ 9.8). Pairs and bursts must
  be found from file and capture facts, never from pixels.

Otos already reads Apple's burst identifier: MediaMetadata takes `BurstUUID` from the Apple
maker note (tag `0x000B`) and Otos stores it as `AssetMetadata.burstIdentifier`. Camera
bodies carry no burst identifier MediaMetadata reads today.

## RAW+JPEG pairs

| App | Shown by default | Switching | The other file |
| --- | --- | --- | --- |
| Apple Photos | the JPEG is the original | Image ▸ Use RAW as Original (reads Use JPEG as Original once switched); since macOS 10.15.4 on a grid selection, before that only in Edit | kept with the photo; an opt-in J / R badge (View ▸ Metadata ▸ File Type) says which is the original |
| Lightroom Classic | the RAW; with "Treat JPEG files next to raw files as separate photos" off, the JPEG is a sidecar | none; the preference applies to later imports only | named in the file name (`CR2+JPG`); moves and deletes with the RAW |
| Lightroom desktop, Immich | both, as two photos | — | — |
| digiKam | manual Group by Filename puts the JPEG on top | a show-grouped-images button expands a group | users cannot tell an open group from a closed one (KDE bug 426664) |
| Capture One | both, as two photos | a RAW / JPEG filter | — |

## Bursts and stacks

| App | In the grid | The cover | Reaching the frames | A collapsed group and an action |
| --- | --- | --- | --- | --- |
| Apple Photos | one tile per burst; a Bursts album | Photos suggests one | open the burst, Make a Selection: a filmstrip with a circle per frame, then Keep Everything (or keep only the selection) | Image ▸ Delete 1 Burst deletes every frame |
| Lightroom Classic | the top photo with a count badge at its top left | Photo ▸ Stacking ▸ Move To Top Of Stack (⇧S); ⇧[ / ⇧] reorder | click the badge or press S to expand the stack in place in the grid | a rating, flag or develop change applies to the top photo only |
| Google Photos | one tile, the automatic Top pick | Set as top pick | open the stack; a filmstrip of its photos | Remove from stack takes one photo out; Unstack splits all |
| Immich | the primary asset only | set through the API | a strip of the stack in the viewer | stacking is manual (v1.83) or by tools: immich-go `--manage-raw-jpeg`, `--manage-burst` |

Lightroom Classic stacks bursts only on request (Auto-Stack by Capture Time); Immich stacks
nothing on its own.

## Conclusions

- Every app that pairs a RAW and its JPEG does it in the catalog, everywhere, never in one
  surface. A pair is a file-name fact; a burst is a capture fact.
- No app makes the RAW / JPEG switch prominent. Apple's is a menu item; Lightroom has none.
- The apps split on a collapsed group: Apple treats it as one item (delete removes the
  burst), Lightroom as its top photo (curation and edits land on it alone).
- Lightroom's expand-in-place keeps every existing action working on single members with no
  second browser; Apple's and Google's open a separate view.
- Apple's word "Original" names the file a pair shows. Otos already uses "Original" for a
  photo without its edit (View ▸ Show Original, Revert to Original, DES-098), so Otos cannot
  borrow it.

## Sources

- Apple: [RAW as original](https://support.apple.com/guide/photos/phtbb0eb4eb1/mac),
  [bursts](https://support.apple.com/guide/photos/pht8745d2677/mac),
  [Catalina pair changes](https://discussions.apple.com/docs/DOC-250002461),
  [importing pairs](https://discussions.apple.com/docs/DOC-250002577),
  [J / R badge](https://discussions.apple.com/thread/6995640),
  [duplicate detection in Photos 5](https://discussions.apple.com/docs/DOC-250001956),
  [Photos tech brief](https://apple.com/ph/ios/photos/pdf/Photos_Tech_Brief_Sept_2019.pdf).
- Adobe: [stacks](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/grouping-photos-stacks.html),
  [the separate-photos preference](https://community.adobe.com/questions-675/treat-jpeg-files-next-to-raw-files-as-separate-photos-not-working-937146),
  [Lightroom desktop pair request](https://community.adobe.com/t5/lightroom-ecosystem-cloud-based-ideas/p-please-stack-raw-jpeg-files/idi-p/12240051/page/2),
  [stacking guide](https://expertphotography.com/lightroom-stacking),
  [Assisted Culling](https://adobe.design/ideas/behind-the-design-assisted-culling-in-adobe-lightroom).
- Google: [Photo stacks](https://support.google.com/photos/answer/14169846),
  [Android Central guide](https://www.androidcentral.com/apps-software/how-use-photo-stacks-google-photos).
- Immich: [v1.83.0 stacks](https://github.com/immich-app/immich/releases/tag/v1.83.0),
  [stacked photos discussion](https://www.Github.com/immich-app/immich/discussions/2479),
  [immich-go stacking](https://sweepies.github.io/immich-go/guide/stacking.html),
  [Immich Stack](https://majorfi.github.io/immich-stack),
  [RAW+JPEG guide](https://www.ssdnodes.com/learn/lang/ja/immich-raw-photos-and-raw-jpeg-pairs).
- digiKam: [quick group](https://cameracode.coffee/digikam-quick-group),
  [KDE bug 426664](https://bugs.kde.org/show_bug.cgi?id=426664).
- Capture One: [RAW/JPG as one thumbnail](https://support.captureone.com/hc/de/community/posts/360012088557-RAW-JPG-as-one-thumbnail).
- LibrePhotos: [stacks and file variants](https://docs.librephotos.com/docs/user-guide/stacks-and-file-variants),
  [memories](https://docs.librephotos.com/docs/user-guide/memories).
