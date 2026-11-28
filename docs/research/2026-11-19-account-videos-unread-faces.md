# Account videos whose faces were never read (2026-11-19)

Why 14 of the reference library's Immich videos logged `op=videoFaces.remote phase=unread unread=video`
every 15–20 minutes, each read fetching 1–22 MB from the server and never succeeding, and
what each failure was. Evidence: the installed app's unified log (`log show --info --last 12h`,
`eventMessage CONTAINS "videoFaces.remote"`), read-only GETs of the 14 originals from the
test Immich server with the session token Otos stored (into a scratch folder, deleted after), and
probes opening them with `AVURLAsset` from local files.

## What the log showed

From 15:16 to 21:52, 358 outcome lines, all `phase=unread`, none `finish`; about 3.4 GB read
from the server in all. Two errors:

| AVFoundation code | underlying OSStatus | videos | lines | bytes per read |
|---|---|---|---|---|
| -11869 `noSourceTrack` ("Cannot Open") | -12430 | 4 `.mov` (`20241231_230000*.mov`) | 104 | 1 MB (two reads) |
| -11821 `decodeFailed` ("Cannot Decode") | -12911 | 10 `_iOS.mp4` / `_iOS.MOV` | 254 | 4–25 MB |

## The originals are what the server stores

Each `/original` answered 200 with `Content-Type` matching `originalMimeType` and
`Content-Length` equal to the EXIF `fileSizeInByte` and to the catalog's size (`fileBytes=`
in the log). The server sends the original, not a transcode, so (c) is ruled out.

## The four `.mov` files: VP9, which this Mac has no decoder for

The video track's codec is `vp09` (1740 × 1080), audio AAC. Opened from a local file,
`AVAssetTrack.isDecodable` and `isPlayable` are `false`, and every frame answers
`noSourceTrack` over -12430, exactly what the log shows through the resource loader. The
loader is not the cause. Registering the supplemental VP9 decoder
(`VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)`) makes the track
report decodable, but every frame then fails `-11855` over -12910, "could not be decoded on
this computer". These videos are genuinely undecodable here. Renaming an H.264 fixture's
`avc1` sample entry to `vp09` reproduces the same track flags and the same error.

`VideoFaceReader.isUndecodable` did not count `noSourceTrack` as a verdict, so each read was
`facesUnread`, paced 900 s, and fetched again. The platform states the fact before any frame
is asked for: the track says it is not decodable. The reader now asks `isDecodable` first and
throws `trackNotDecodable`, which is a verdict (stamped with no faces by the frame reader's
decoder, read again when that decoder or macOS changes), and no frame's bytes are fetched.

## The ten HEVC files: AVFoundation cannot seek to a few frames before each sync frame

All are HEVC (`hvc1`, 1552 × 2064, 30 fps) with AAC audio, a sync frame about every 8.4 s,
and open groups of pictures (frames decoded after a sync frame but shown before it). From a
local file, `isDecodable` is `true`; an `AVAssetReader` decodes every frame in order without
error (646 of 646, and 275 of 275); `AVAssetImageGenerator` at zero tolerance decodes every
sample but one or more, deterministically on every run. Scanning one video every 1/60 s
around its second sync frame (8.40 s), the frames at 8.233, 8.267 and 8.300 s fail
`decodeFailed` over -12911 and every other frame decodes. Each failing sample lies just before
a sync frame: 8.22–8.33 s before 8.40, 11.24 before 11.40, 16.58 before 16.73, 33.33 before
33.40. A synthetic open-GOP HEVC from `AVAssetWriter` (sync frames every 28 and every 245
frames) did not reproduce it, so the trigger is in these encoders' bitstreams; the failure is
AVFoundation's seek, the same through the resource loader and from a local file, so (b) is
ruled out too.

The same sample read at the sync frame after it (`AVSampleCursor`, stepping in presentation
order to the next full sync sample) decodes in every case, 0.07–0.19 s later. Applying the
reader's rule to all ten files, every sample reads: one sample in most files, three in one
(`cb541965…`), none failing.

## What changed

- `VideoFaceReader.read` asks the video track's `isDecodable` before any frame and throws
  `VideoFaceReaderError.trackNotDecodable`, a verdict in `isUndecodable`.
- A sampled frame that fails `decodeFailed` is read at the next sync frame, else the last
  before it (`frame(at:)`, `syncFrameTime`); a sampled frame that is itself a sync frame has
  no fallback, so a decoder's own failure is still a failed read, and neither has a frame of
  an account video once a range went unanswered (`RemoteVideoAsset.failed`): AVFoundation
  reports a frame whose bytes never came as `decodeFailed` too, and without that rule a
  server that stopped answering cost a fallback read per sample instead of ending the read at
  the first. The samples read so are
  logged (`syncFrames=` on `op=videoFaces.remote`, `videoFacesSyncFrames=` in
  `op=enrichment.item`).
- The 900 s pacing for a failed read stays: once the platform's facts are read as facts, an
  unread video is a read that can succeed next time (an outage, a failed analysis), and ADR
  0032 keeps such a request outstanding.
