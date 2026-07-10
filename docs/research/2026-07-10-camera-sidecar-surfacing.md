# Camera sidecar surfacing (ImageCapture)

Date: 2026-07-10
Status: research note for plan 0055 Stage B. Hardware probe incomplete in this
agent environment — no MTP/PTP camera was attached.

## API facts (verified from Apple docs + code)

- `ICCameraFile.sidecarFiles` is a **read-only property** populated during device
  enumeration. It is not an enumeration switch.
- The download option `.sidecarFiles` (boolean) controls whether a download
  request also pulls associated sidecars. Current Otos download options pass
  `false`; Stage F will decide bundling when camera import executes.
- Stage B maps each recognized sidecar (`ICCameraItem` cast to `ICCameraFile`
  with `.xmp` / `.srt` extension) onto `DeviceCameraCompanionItem` with the owning
  primary's relative path from the `mediaFiles` walk.

## Open hardware questions (probe when a camera is available)

1. Do specific cameras surface XMP/SRT only in `sidecarFiles`, only in
   `mediaFiles`, or both?
2. When both, are paths/names identical or duplicated?
3. Are `fileSize` / modification dates populated for sidecar items, or NULL
   (schema already allows nullable companion facts)?
4. Does any device produce useful `.lrc` companions that should later expand
   recognition?

Until hardware evidence exists, do not add `.lrc`, and treat `sidecarFiles` as
the authoritative camera pairing source when present.

## Sources

- [ICCameraFile.sidecarFiles](https://developer.apple.com/documentation/imagecapturecore/iccamerafile/sidecarfiles)
- Plan 0055 section 5; review findings `docs/research/2026-07-10-plan-0055-review-findings.md`
