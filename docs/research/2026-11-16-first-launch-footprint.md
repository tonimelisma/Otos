# The 1,179 MB first launch after an install (2026-11-16)

## Question

The installed app's first launch after installing ef4492e6 (one session, launched and left
idle about 200 s, no tour) peaked at 1,179 MB, far above plan 0116's 700 MB. Every later
launch of the same build peaked at 234–423 MB. The sample that first carried the peak was
`event=searchEncoderReleased`. Was the peak Core ML compiling models after the install, two
encoders resident at once, or something else, and what keeps it at 700 MB or under?

## Evidence: the session (installed app, read-only)

`op=process.memory` reports `peakFootprintMB` from the kernel's lifetime maximum
(`ri_lifetime_max_phys_footprint`, `ProcessResources.swift`), so a sample says only that the
peak came at or before it. The samples around it:

| Local time | Sample | Footprint | Peak |
| --- | --- | --- | --- |
| 19:00:01.995 | `peopleBuilt` | 301 MB | 517 MB |
| 19:00:16.030 | `peopleBuilt` | 326 MB | **1,179 MB** |
| 19:01:11.898 | `searchEncoderReleased` | 252 MB | 1,179 MB |

So the peak came between 19:00:02 and 19:00:16. `searchEncoderReleased` is only the next
sample after memory pressure: it released the text tower, whose load had added 7 MB of
footprint (`search.encoder phase=loaded footprintDeltaMB=7`).

The models Core ML mapped (`(MIL) MMapped` lines, matched to the bundled models by file size):

| Time | Model | Weights |
| --- | --- | --- |
| 18:59:20.5 | SigLIP2Text | 86 MB |
| 18:59:47.2 | AdaFaceIR101 | 66 MB |
| 19:00:25.9 | SigLIP2Image | 94 MB |

Core ML's compiled programs for those three were created at those times (the Caches folder's
`e5bundlecache` keys). No model loaded inside the peak's window. In the window: two of the
owner's new iPhone videos (`*_iOS.MOV`, 4K) were being read for faces (`videoInFlight=2`,
`op=face.analyse width=3840 height=2160`), along with a People assignment pass and Apple
Intelligence descriptions. Descriptions run in the system's model process.

Across every Otos session in the day's log, this is the only one that analysed a 4K video
frame (12 such analyses), and the only one above 900 MB.

## Evidence: measured in a test process (`FirstLaunchFootprintTests`, on demand)

The peak above the footprint the step started from, sampled every millisecond (`FootprintPeak`):

| Step | Before | After |
| --- | --- | --- |
| Two 4K videos read for faces at once, H.264 8-bit (real `FaceAnalyzer`) | 71–75 MB | 71 MB |
| Two 4K videos read for faces at once, HEVC Main 10 HLG, as an iPhone records | **890 MB** | **128 MB** |
| The text tower's load with no compiled program (a fresh path), then again | cold +6 to +87 MB, 0.8–1.2 s; warm 0 MB, 0 ms | unchanged |

A 4K HDR frame from `AVAssetImageGenerator` is a 16-bit-float image of about 66 MB.
`VideoFaceReader` decoded all six of a video's frames before analysing any, and enrichment
reads two videos at once (`videoEnrichCap`): 12 frames, 790 MB, plus the analysis. That is
the 1,179 MB: about 300 MB of footprint before plus the 890 MB measured.

## Conclusions

- The peak was the video face reader holding six full-resolution HDR frames per video, two
  videos at once. It was not the install: the first launch after the install happened to be
  the first to meet the owner's new 4K videos. A later launch that meets a new 4K HDR video
  would peak the same way.
- It was not compiling models in the process. A cold compile of the text tower added at most
  87 MB, and the compiled programs' loads came 27 s and 66 s apart from the peak.
- It was not two encoders resident at once: the text tower added 7 MB and was released
  separately. The image tower loaded after the peak.
- So keeping compiled models in Application Support, compiling out of process, or making
  model residency exclusive would not have moved this number. Each is rejected for this
  peak, with the numbers above.

## Change

`VideoFaceReader` decodes one frame, analyses it, and keeps it only when it holds faces,
scaled to the preview's size as staging scales it (`ThumbnailStore.scaled`; staging leaves an
already-scaled frame as it is, so the staged HEIC is the same). One full-resolution frame per
video is held at a time. The decode itself (`samples`, no tolerance, upright, full resolution)
is unchanged, so no video is read again and `decodeRevision` stays. Two 4K HDR videos read at
once now add 128 MB at their peak, against 890 MB; the on-demand test bounds it at 200 MB, and
`VideoFaceTests.oneFullResolutionFrameIsHeldAtATime` guards the order on every run.

On the owner's session that is about 300 + 128 MB, under 700 MB. The scorecard's
`memory.peakFootprintMB` already reports every session's peak. A first launch after an install
gets no line of its own: nothing in the log tells that launch apart (no Core ML line names a
compile), and this peak did not depend on it.

## Not measured here

- The installed app's next first launch that meets a new 4K HDR video (a scorecard tour that
  reads one).
- What the sandbox dev build's first launch (889 MB with 28 photos, during an act tour) held:
  its footprint rose from 100 MB to 855 MB while the text tower and AdaFace loaded, during
  the tour's scope steps, and fell to 239 MB within a second. A cold compile measured at most
  87 MB, so most of that rise is something else, not identified here.
