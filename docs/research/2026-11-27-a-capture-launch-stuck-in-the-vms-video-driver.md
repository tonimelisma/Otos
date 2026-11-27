# A capture launch stuck in the virtual Mac's video driver

Date: 2026-11-27. `main`'s CI run 45911509928 (bd6f431) failed on shard 3. Its tree was
identical to #38's head, which had passed. On attempt 2, `script/app-capture.sh`'s light launch
outlived TERM and KILL, stuck exiting (`ps` state `?<E`). The dark launch, in the same sandbox
home, never reached its first grid, and the sandbox volume stayed mounted.

## How often

In the 17 most recent shard-3 captures before this note, 5 left an Otos that could not end:

- **Which launch:** 4 were the second (dark) launch and 1 was the light launch.
- **Quit timing:** a stuck launch was quit 1 to 3 s after its window appeared, while its
  background work was running. A normal quit returns at once.
- **Outcome:** every stuck launch also failed `sandboxLibrary.destroy` (`stillMounted`) and left
  a `diskimages-helper` orphan at the job's end.
- **Why most runs stayed green:** when the stuck launch was the dark one, both captures were
  already written. When it was the light one, the dark launch opened the same catalog and the
  same library volume, and failed.

## Where it is stuck

`script/app-capture.sh` used to record a stuck process with `sample`, which cannot attach to an
exiting process, so no record was ever written. `spindump` reads the process's stacks from a
kernel stackshot, which works on an exiting process. With `sudo -n spindump <pid>` on CI's runner,
capture run 45921082792 caught a stuck dark launch (pid 3962, 47 s after its fork):

- **What was left of it:** the process was a zombie with one thread left. `lsof -p` listed no
  open file, so its file descriptors were already closed.
- **Where that thread sat:** in the kernel, in `AppleVideoToolboxParavirtualization`, the
  virtual Mac's paravirtualized VideoToolbox driver
  (`/System/Library/Extensions/AppleVideoToolboxParavirtualization.kext`, 15.0.0, on
  `kernel.release.vmapple` 27.0.0, `VirtualMac2,1`, macOS 27.0.1 26A434). The call chain was:

  ```
  AppleVideoToolboxParavirtualizationDriver::deregisterAllGuestUUIDsForUserClient
    → sendForgetUUIDMessageToHost
      → sendMessageToHost
        → IOEventSource::sleepGate → IOWorkLoop::sleepGate → lck_mtx_sleep
  ```
- **Last ran:** 44.4 s before the stackshot.

As the process's VideoToolbox user client is torn down at exit, the driver tells the VM's host
to forget the process's sessions. It then sleeps on the work loop's gate until the host answers.
The host did not answer, so the task never finished terminating.

- **Why it holds the volume:** a task that has not finished terminating keeps its address
  space, so its memory-mapped files keep their vnodes, and the volume they live on cannot be
  unmounted.
- **Why Otos uses VideoToolbox here:** the generated library holds two videos, and their
  thumbnails decode through VideoToolbox.
- **Only one record so far:** a second stuck dark launch in capture run 45921085147 (pid
  17080) was recorded too, but there `spindump` reported "No samples for specified time
  interval". Its stack is unknown, so this note's cause rests on one record.

## Conclusions

- **The hang is the CI VM's.** It is in the host side of the VM's paravirtualized video driver,
  which a real Mac does not have. Nothing Otos does in userspace can make the kernel finish an
  exit it is waiting on.
- **The capture's defect was the shared sandbox.** Two independent launches shared one catalog
  and one library volume, so one stuck launch broke the next. Each appearance now launches in a
  sandbox home of its own, made before and destroyed after its launch (`script/app-capture.sh`).
  A stuck launch keeps only its own home mounted, until the runner is discarded. In three
  capture runs of this change (45921080138, 45921082792, 45921085147), two dark launches were
  stuck. Both runs wrote both captures and passed.
- **A stuck launch is recorded with its stacks and open files** (`unkillable-<pid>.spindump.txt`
  and `.lsof.txt` in `app-captures-<run>`), so a later one that is stuck anywhere else shows
  where.
- **Videos stay in the capture's library.** Leaving them out would avoid the driver, but the
  look a session reads would then show no video tile.
