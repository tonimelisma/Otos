# A scratch disk image's mount path is shared machine state

Date: 2026-11-10. `DiskEjectorLiveDiskImageTests.aHeldVolumeIsBusyAndAReleasedOneEjects`
failed once in a full `script/check.sh` run (13.0 s, under parallel load, log
`test-20261109T212514Z-p63509-test.log` in a since-removed worktree) at its last line:
after `DiskEjector.eject(volumeAt:)` returned `.ejected`, `held.txt` still existed at
`/Volumes/OtosEject/held.txt`. Three other full runs that morning passed it.

## Question

Two mechanisms could put a file at that path after a successful eject:

1. DiskArbitration completes `DADiskUnmount` before the unmount is visible in the
   filesystem namespace, so the test reads the old mount.
2. The path is not this test's: another image with the same label is mounted at it.

## Measured

macOS 27.0, ExFAT 40 MB images attached `-nobrowse`.

**Ordering (mechanism 1).** A probe mirroring `DiskEjector` (one `DASession` on a
dispatch queue, `DADiskUnmount(whole, kDADiskUnmountOptionWhole)`, then `DADiskEject`)
checked `fileExists` on a file of the volume immediately after each completion
callback. Four probes ran at once, ten iterations each, every image with its own label:

```text
op=probe iterations=10 visibleAfterUnmount=0 visibleAfterEject=0   (×4)
```

40 of 40: once the unmount callback has run, the file is gone from its path.

**Path reuse (mechanism 2).** Three images with one label, attached in sequence:

```text
A=/Volumes/ProbeEj        (A writes held.txt)
B=/Volumes/ProbeEj 1      (B writes held.txt)
detach A
C=/Volumes/ProbeEj        (C writes held.txt)
after A ejected, /Volumes/ProbeEj/held.txt exists? intruder
```

The system names the mount point from the label and hands a freed `/Volumes/<label>`
to the next image with that label at once, from any process. Several worktrees run
`script/check.sh` at the same time, each running this test with the label `OtosEject`
and writing `held.txt`: if another run's image is mounted in the moment between this
run's unmount and its last assertion, the assertion sees that run's file. The
same-label probe run in parallel (4 × 10) did not hit that window, which is a few
milliseconds long when the machine is idle; under the load that stretched the failing
test to 13 s it is the eject itself.

The harness's `detach()` (`hdiutil detach <mountURL> -force`) had the same reach: after
this run's eject, it force-detached whatever image held the path, which could be
another run's.

## Conclusions

- `DiskEjector` reports the right fact: `.ejected` follows DiskArbitration's own
  completions, and nothing at the old mount is visible afterwards. It does not change.
- The defect is the harness naming a path it does not own. `MountedTestDiskImage`
  gives every image a label of its own, so its mount path, its assertions and its
  `detach()` name only that image. Callers no longer choose a label.
