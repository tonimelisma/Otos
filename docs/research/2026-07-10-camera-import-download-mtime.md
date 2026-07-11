# Camera import download mtime probe (plan 0055 Stage F)

Date: 2026-07-10

## Question

Does ImageCapture `requestDownload` preserve, invent, or clear destination
mtime for MTP/PTP camera files?

## Method available in this increment

No camera hardware is attached in the agent environment, so a live probe could
not run. Stage F therefore stamps import staging with the planned
`destination_modified_at` (capture-wall or source camera date) after bytes land,
matching the filesystem-volume contract, instead of trusting download mtime.

## Follow-up when hardware is available

1. Download one known JPEG via `DeviceCameraSession.download`.
2. Compare `NSURLContentModificationDateKey` before stamp vs after stamp.
3. Record whether the download left epoch, "now", or a camera date.
4. Update this note with the measured outcome; keep stamping unless evidence
   shows download already writes the capture-derived value.

## Conclusion for Stage F

Stamping remains mandatory. Hardware probe is deferred, not skipped as a product
decision.
