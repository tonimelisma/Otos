# What DiskArbitration, NSWorkspace and ImageCaptureCore report

Date: 2026-10-23. Plan 0106, increment 3: before replacing a timed guess about a
removable volume or a camera with a wait on a report, establish which reports exist.

## Question

Three places waited on time for a state the OS might report:

- `RemovableVolumeMonitor` quiesces a source on `willUnmount` and resumes it 2 s later
  if the volume is still mounted.
- `DeviceCameraSession.waitForCatalogStability` takes two samples of the camera's item
  list 500 ms apart, up to 30 s, and proves deletions only when they agree.
- `SmokeLibrarySelection` polled the ViewModel every 100 ms for 30 s for the requested
  root.

## Unmount refused by another process: measured

A probe registered, in one process, NSWorkspace's `willUnmount`, `didUnmount` and
`didMount` observers and DiskArbitration's description-changed, disappeared and
unmount-approval callbacks. It held a file open on a 40 MB ExFAT scratch image
(`diskutil image create blank --fs ExFAT`, attached `nobrowse`), called
`NSWorkspace.unmountAndEjectDevice` from another thread, waited 5 s, closed the file,
and called it again.

```text
  1.066 DA unmountApproval path=file:///Volumes/OTOSPROBE/
  1.070 NSWorkspace willUnmount
  1.292 unmount#1 threw NSOSStatusErrorDomain -47
        (5 s: nothing)
  6.301 DA unmountApproval
  6.302 NSWorkspace willUnmount
  6.484 DA descriptionChanged keys=(DAVolumePath) path=nil
  6.485 NSWorkspace didUnmount
  6.526 DA disappeared disk10 / disk10s1
  6.540 unmount#2 returned OK
```

- A refused unmount is announced (approval request, `willUnmount`) and then reported to
  its caller alone, as `fBsyErr` (-47), 226 ms after `willUnmount`. No notification,
  description change or callback reaches any other process.
- A successful one is reported three ways: the volume path leaves the description,
  `didUnmount`, and the disks disappear.

So when Finder or `diskutil` asks and is refused, nothing tells Otos. When Otos asks,
the call itself returns the outcome.

## Camera catalog completeness: headers and earlier hardware evidence

`ICCameraDevice.h` and `ICCameraItem.h` (Xcode 27 SDK) offer
`deviceDidBecomeReadyWithCompleteContentCatalog`, `contentCatalogPercentCompleted`,
`cameraDevice:didAddItems:` / `didRemoveItems:`, and
`ICCameraItem.wasAddedAfterContentCatalogCompleted`. The last marks an item captured
after enumeration finished; it says nothing about whether the enumerated list is whole.
Hardware runs recorded in `removable-volume-and-camera-sources.md` saw the
complete-catalog callback with one item of a full card listed (a second session) and
`deviceDidBecomeReady` with none. No camera was attached for this pass, so nothing new
was measured.

## Conclusions

- **Otos's own Eject** resumes the source as soon as the unmount call fails; the
  outcome is a fact it holds.
- **An unmount asked for elsewhere** keeps a limit, renamed
  `unreportedUnmountRefusalLimit` (2 s). Nothing reports the refusal, so the limit is a
  product decision about when background work on a still-mounted card resumes. Success
  needs no limit: it detaches at once.
- **Camera completeness** keeps its two-sample check, now `catalogSettleLimit` and
  `catalogSettleSampleInterval`. No report states the list is whole, and the check
  gates only whether a pass may delete rows; a list still changing at the limit
  deletes nothing. The open and catalog limits (10 s, 240 s) are deadlines on a PTP
  link that may never answer.
- **Smoke selection** follows the window states the ViewModel publishes (`Observations`)
  and resolves once the catalog's first load has finished: the publication is the
  report.
