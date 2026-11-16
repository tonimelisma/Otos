# A released card refused by another DiskArbitration client

2026-11-15. Follows `2026-11-15-a-card-left-waiting-for-metadata.md`, where
`DiskEjectorLiveDiskImageTests/aHeldVolumeIsBusyAndAReleasedOneEjects` failed in 3 of 17 full
passes under load and in none of 30 isolated runs. The cause was unknown.

## What failed

The test holds a file open on a scratch ExFAT image and expects `.busy`. It then closes the
file and expects one `DiskEjector.eject` to return `.ejected`. In the failing passes the second
eject returned something else, and the volume was gone when the run finished.

## Mechanism (proven from diskarbitrationd's log)

`diskarbitrationd` keeps its log for hours. Between 15:00 and 18:20 local time on 2026-11-15,
which covers #785's runs, it logged exactly three unmount-approval dissents. They are
`dispatched response, … kind = disk unmount approval, … dissented, status = 0xF8DA0002`
(`kDAReturnBusy`), at 16:40:16, 16:48:29 and 16:54:15. That is three, the same as the failures.
Each one follows the same sequence:

| Unmount asked (`options = 0x00000001`, whole disk) | Dissent | Then |
| --- | --- | --- |
| 16:40:05.921 | 16:40:16.494 (+10.6 s) | 16:40:16.657 unmount `0x00080001`: forced, whole disk |
| 16:48:19.653 | 16:48:29.942 (+10.3 s) | 16:48:29.977 forced unmount |
| 16:54:05.302 | 16:54:15.570 (+10.3 s) | 16:54:15.612 forced unmount |

- **The whole-disk unmount** is `DiskEjector`'s.
- **The forced one** is the test's teardown, `hdiutil detach -force`, which is why the volume was
  gone.
- **The refusal is a real reply.** It is not diskarbitrationd's response timeout. That timeout is
  10 s plus 1 s of grace (`__kDAResponseTimerLimit`, `DAQueue.c`). When it fires, the client that
  did not answer is skipped, logged as `not responding`, and counted as approving. No
  `not responding` or `timed out` line was logged in any of the three windows. The
  `dissented` line is written only when a client answers with a dissenter (`_DAResponseDispatch`).
  Source: apple-oss-distributions/DiskArbitration, `diskarbitrationd/DAQueue.c`.
- **The outcome is classified correctly.** `DiskEjector.outcome(refusal:)` reads
  `kDAReturnBusy` as `.busy`, so the test saw `.busy` once its own file was closed.

**Who dissented: a client outside Otos.**

- **Otos's own approval client always approves.** `RemovableVolumeMonitor`'s
  `diskUnmountApproval` is the only DiskArbitration approval callback in Otos, and it returns
  `nil`. It registers the callbacks appeared, description changed, unmount approval and
  disappeared.
- **The dissenting session's callbacks do not match Otos's.** They were appeared, description
  changed, disappeared, unmount approval and idle.
- **ImageCaptureCore cannot be the client.** `ICDeviceBrowser`, which test windows start, uses
  ImageCaptureCore and ImageCaptureDevices, and neither links DiskArbitration
  (`dyld_info -dependents`).
- **A late `ICDeviceBrowser` never dissented.** A probe started one 200 ms after asking for an
  unmount, so the browser was running while the unmount waited for its approvals. The unmount
  was approved in all three tries.
- **The client's process is unknown.** diskarbitrationd logs session identities as `<private>`.

**Why load matters.** An unmount solicits every client registered for approval, machine-wide.
Under parallel checks, dozens of short-lived sessions are registered, and an unmount waited about
10 s for approvals even in a quiet probe. Over those seconds, one dissenting client is enough.
An isolated run has fewer clients and a shorter wait.

## Not the cause (ruled out)

- **An open file in Otos.** The only handle on the volume was the test's, closed before the
  second eject. An open file is refused by the unmount call itself
  (`unmount call … returned (status code 0x00000010)`). These refusals are approval dissents.
- **`hdiutil attach` returning before the volume is mounted.** The first eject's `.busy` comes
  from the unmount call finding the held file, so the volume was mounted.
- **Another test's disk image.** Every image has its own label and mount path
  (`MountedTestDiskImage`). Starting `hdiutil create`, `info` or `attach` of a second image while
  an unmount waited did not cause a dissent (`concurrent.sh`, not committed).

## Change

- **The product already handles this case.** `performEjectRemovableSource` asks again after a
  busy refusal, with `time: backoff` (`ejectBusyRetryDelays`, 0.5 s to 4 s), because a holder
  outside Otos reports nothing when it lets go.
- **The test now ejects the released volume the same way**, so it no longer assumes that no
  other client on the Mac refuses. The first eject still has to be `.busy` from the held file.
- **`DiskEjector` now logs `op=disk.eject phase=unavailable step=`** when there is no session,
  volume disk or whole disk. That outcome used to return without a log line.

## Reproduction attempts

- **Full suites.** Eleven full-suite passes ran beside other agents' checks, at a load average
  of 107–150 on 8 cores. Nine were on a tree with extra logging, six of them running the test as
  eight parallel cases, and two were this branch's own checks. Together that was 53 runs of the
  test, and none failed.
- **Probes.** None reproduced the dissent.
- The mechanism above comes from the three dissents logged during #785's runs.
