# A tour's lines: the log's store, a live stream, and what each loses (2026-11-17)

Supports ADR 0015 (the scorecard) and `script/scorecard.sh`.

## Question

Two of six owner-size sandbox tours (160,002 files) produced scorecards with `clicks=1`. By
the time the script read the session back with `log show`, the unified log's store no longer
held the act lines. The script's live readout of the tour's own `op=tour` lines still had them.
Can the whole session be captured live? Does a live stream lose lines under load? Can the
loss be counted?

## Method

A scratch program logged N `.debug` lines (`op=spew index=<i>`, about 220 bytes each) under a
subsystem of its own, as fast as one thread could. `log stream --level debug` on that
subsystem ran in each style, and the indices that came through were counted.

## Findings

- **`--style ndjson` drops silently.** 500,000 lines logged in 8.7 s (about 57,000 a second)
  reached the stream as 206,777. There were 1,456 gaps, the order was kept, the last line came
  through, and no line said that anything was lost. `--style json` behaved the same: 134,144
  of 200,000, no notice.
- **Text styles report drops.** `--style compact` and `default` write
  `=== Messages dropped during live streaming (use `log show` to see what they were)` once
  per gap (705 notices for 300,000 lines in compact style). A notice does not say how many
  lines were lost.
- **The stream's own cost** at that rate was 7.8 s of CPU for 8.7 s of logging, written to a
  274 MB file. A tour logs at a small fraction of that rate. Each tour's `op=scorecard.capture
  phase=closed` line reports the measured cost: lines, bytes, drop notices and the stream's
  CPU time.
- **A tour at the owner's library size, captured at debug level.** A settled tour of the
  160,002-file sandbox library ran 7.5 minutes. Its capture held 295,935 lines of the session
  (89 MB), with 234 drop notices; the stream itself used 3 min 19 s of CPU.
  `log show` of the same window held 150,086 of the session's lines. The dev build's
  debug lines are not kept in the store, so those are info and above. No line the scorecard
  reads is logged at debug. So the capture is taken at `--level info`, which roughly halves
  what the stream carries.
- **A marker closes the capture.** A line sent with `/usr/bin/logger` after the app has
  exited reaches the same stream through an `OR eventMessage == "<marker>"` clause in its
  predicate. When the marker has come through, every line the app logged before it exited has
  come through too, or was dropped with a notice.

## Conclusion

A tour is captured with one `log stream --style compact --level info`, filtered to the
toured executable and the subsystem. It is opened before the launch and closed on the
marker. The scorecard reads that capture (`read_live_capture`). It also counts the
`log show` read of the same window beside it, and prints
`capture=live lines=<n> dropped=<notices> logShowLines=<n> logShowOnly=<n> end=seen|missing complete=yes|no`.
`logShowLines` counts the session's info-and-above lines `log show` still held, and
`logShowOnly` counts those the capture lacks (matched by message; a stream stamps each
entry a constant 28 ms from the store's stamp for it, measured, so time cannot pair them): a
line lost by the stream without a notice. A capture with a drop notice, with a `logShowOnly`
line, or whose marker never came through, is labelled `PARTIAL`, because it is not the whole
session. `log show` alone is used only when no capture exists, and
then the line says its loss cannot be counted (`complete=unknown`). Compact style does not
print the process image. The script supplies it, since it launched that executable.

At debug level the app's own logging rate at the owner's library size made the stream drop.
Whether it still drops at info level is answered by every tour's `dropped=` count, and a
tour that drops says it is `PARTIAL`.
