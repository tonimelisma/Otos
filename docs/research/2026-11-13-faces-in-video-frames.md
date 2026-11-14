# Faces in video frames

Date: 2026-11-13. A measurement on the owner's own videos of how often one frame of a video
holds a face Otos would read, and which frame to take. It opened when the owner asked why
People finds no faces in videos and whether the first frame would do (owner, 2026-11-12:
"measure first"). No decision is recorded here; the owner decides whether videos get faces.

## What was measured

- **Sample:** 24 videos drawn at random (seed 662) from the 1,939 videos in the two fixed
  libraries, all in OneDrive. Every video was cloud-only, so each was downloaded, read and
  put back in the cloud (`FileManager.evictUbiquitousItem`); one video that was already on
  disk was left there. Median video: 201 MB, 19 s long.
- **Frames per video:** the thumbnail QuickLook makes (what Otos shows for a video today,
  ADR 0035), requested at full size, and frames at 0 %, 10 %, 25 %, 50 %, 75 % and 90 % of
  the duration (`AVAssetImageGenerator`, zero tolerance, preferred transform applied).
- **A face that counts** has Vision face landmarks and capture quality, revision 3; quality
  ≥ 0.3; eyes, nose and lips found. This is close to, but not, `FaceAnalyzer`'s admission
  for stills (ADR 0047: quality ≥ 0.28 plus the alignment and person rules). The alignment-scale rule and the embedding model were not run, so this counts faces
  Otos would read, not faces it would recognise.
- The tool was a throwaway Swift program; owner media and results stay outside the repo.

## Results

| Frame | Made | Videos with a face |
| --- | --- | --- |
| QuickLook thumbnail | 15 of 24 | 3 |
| 0 % (first frame) | 24 | 7 |
| 10 % | 24 | 8 |
| 25 % | 24 | 9 |
| 50 % | 24 | 6 |
| 75 % | 24 | 7 |
| 90 % | 24 | 8 |
| Any of the three at 10 %, 50 %, 90 % | — | 9 |
| **Any of the six fixed frames** | — | **12** |

- **Half the videos (12 of 24) hold a face Otos would read in at least one frame.** The six
  fixed frames find every one of them; no single frame finds more than 9.
- **The first frame alone finds 7 of the 12.** The thumbnail frame is the worst choice:
  QuickLook made no thumbnail for 9 of the 24 videos (7 `.mp4`, 2 `.MOV`) when asked for the
  full size, and its frame held a face in 3.
- **Faces per video:** at most 1 in 8 videos, 2 in 2, 3 in 1, 4 in 1.
- **Face size:** admitted faces are 74–921 px tall (median 476 px), in frames of about
  1216 × 1616 (the iPhone videos) and 3840 × 2160. That is in the range the stills admit.
- **Reading cost:** the frame decode is a median 128 ms (worst 6 s, one 4K seek). The
  download dominates: a median 31 s per video here, and the libraries hold 627 GB of video
  (1,939 videos, mean 324 MB). Reading any frame of a cloud-only file downloads the whole
  file, since OneDrive hydrates whole files.

## What this left open (answered below and in ADR 0047)

- **Recognition:** whether a frame's face is matched to the right person was not measured. A
  video frame is compressed and may be motion-blurred; the quality score catches some of it.
  Running the embedding model on these frames against the owner's named people would answer
  it.
- **The same person in several frames:** six frames of one video often show one person
  several times. A video would need one face per person, not one per frame.
- **The download:** faces for every video means downloading all 627 GB once, under the 5 GB
  free-space floor (ADR 0027), with macOS evicting what was uploaded as space runs short.
- **OneDrive's reliability:** on 2026-11-12 OneDrive downloaded nothing for over 15 minutes
  (connection resets, "OneDrive Hydration -40"), and one download on 2026-11-13 timed out
  mid-file. A video reader has to treat a failed download as a retry, not as "no faces".

## Recognition (2026-11-13, second pass)

The six frames of the 12 videos with a face were decoded again, read with `FaceAnalyzer`
(revision 3) and compared with the faces the owner's catalog gives each named person (the
user's, the seeds and Otos's guesses), by best cosine, against assignment's threshold
(0.434) and margin (0.16). Every video was left as found: downloaded only when dataless, and
evicted after.

- **60 faces read in 72 frames; 32 reach a named person, 31 past the margin.** The one close
  call is between two of the children. The other 28 match no one: strangers in four videos.
- **One person per video across frames:** in every video the same person is best in every
  frame where they are found, for example one child in all six frames of one video.
- **Same person across frames of one video:** cosine 0.54–0.98, median 0.78. **Different
  people in one video:** at most 0.17. Merging a video's faces at the threshold joins each
  person's frames and no two people.
- **Unrecognisable faces:** none of the 60 reaches `FaceRecognisability.limit` (the highest
  reads 0.124).
- A contact sheet of one face per person per video, with the name Otos would give, was shown
  to the owner and not committed (family photos).

**Conclusion:** a video's faces are read from these six frames, one face per person per
video, with the frame it was sharpest in (ADR 0047, ENR-031).
