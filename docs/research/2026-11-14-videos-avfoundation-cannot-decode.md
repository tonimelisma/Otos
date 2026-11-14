# Videos AVFoundation cannot decode (2026-11-14)

Why the installed app logged `op=videoFaces.read phase=failed` for the same videos at every
launch and wake, and which AVFoundation errors are a verdict on the bytes rather than a failed
read. Evidence: the installed app's unified log for three days (`log show --last 3d`,
`subsystem == "net.melisma.Otos"`), read-only probes of the library's local files, and
synthetic files.

## What failed, and how often

Two processes logged them in the window. Each video's faces were read, failed, paced 900 s on the
retry ledger, and read again, for as long as the process ran; a new process started over.

| AVFoundation code | underlying OSStatus | files | where | reads each | ever read cleanly |
|---|---|---|---|---|---|
| -11828 `fileFormatNotRecognized` | -12847 | 38 MKV | Immich | ~30 | never |
| -11832 `noImageAtTime` | -12431 | 28 MP4/MOV | Immich | 4–33 | never |
| -11829 `fileFailedToParse` | -12848 | 1 MP4 | library | 33 | never |
| -11800 `unknown` | -12344 | 3 AVI | library | 33 | never |
| -11821 `decodeFailed` | -12911 | 7 MOV/MP4 | Immich | 1–21 | 3 of 7 did |
| -11800 `unknown` | -17761 | 34 MKV | Immich | 1 | (the same MKVs, in one two-minute window with an unanswered range) |

## The files

- The library MP4 (`fileFailedToParse`) is local (no `SF_DATALESS`), a Sony XAVC header with
  no `moov` atom: `ffprobe` says "moov atom not found". AVFoundation in a script gives the
  same code on every read.
- The three library AVIs are local, MJPEG + PCM, and truncated: the RIFF header declares
  45–168 MB and the files hold 0.5–17 MB. AVFoundation gives `unknown` / -12344 on every
  read. An intact MJPEG AVI made with `ffmpeg` gives `decodeFailed` / -12911 instead, and an
  intact MKV `fileFormatNotRecognized` / -12847: AVFoundation reads neither format.
- The Immich videos were read in ranges with no unanswered range (`remote.failed` false), so
  the server sent every byte asked for. Their originals are not on this Mac, so the
  `noImageAtTime` files could not be probed; whether they hold no frame at a sampled time or
  Otos's zero-tolerance request misses one is not established.

## Conclusions

- A format AVFoundation does not recognise, bytes that do not parse, no decoder, and no image
  at a sampled time are the platform's answer to the bytes it was given: the same files gave
  the same code on every read. These are stored as a verdict naming the decoder
  (`VideoFaceReader.decoderIdentity`: Otos's frame-reading revision and the macOS build), as a
  still's is (ENR-029), so a new macOS or a new reader revision reads them again.
- `decodeFailed` is not: three videos answered it once and read cleanly on the next pass.
- `unknown` is not: it is what the MKVs answered during an outage window, and it names no
  fact. The three truncated AVIs answer it, so they stay paced on the retry ledger.
- A network error reaches the read too (`NSURLErrorDomain` -1001 on one Immich video); it is
  no verdict, and an unanswered range makes the read `unanswered` before any verdict counts.
