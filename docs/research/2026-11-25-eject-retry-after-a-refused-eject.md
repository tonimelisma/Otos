# An eject retry that found no volume (2026-11-25)

## What failed

On GitHub's 3-core `xcode-27` runner, CI run for tonimelisma/Otos#4 (303e2143),
`DiskEjectorLiveDiskImageTests/aHeldVolumeIsBusyAndAReleasedOneEjects` failed at
`RemovableEjectOutcomeTests.swift:241`: `outcome == .ejected`, `outcome → .diskUnavailable`.
It had passed on the same runner in the two runs before.

The test holds a file open on a scratch ExFAT image (`.busy` from the unmount), closes it,
and ejects again as Otos ejects a card: `.busy` is asked again after
`ejectBusyRetryDelays` (`2026-11-15-a-released-card-refused-by-another-client.md`).

## Reading

- `.diskUnavailable` comes only from the steps before any request: no session, no disk at
  the volume's path (`DADiskCreateFromVolumePath`), or no whole disk. The first two
  attempts in the test had found the disk at that path, so at the failing attempt the path
  no longer named a mounted volume.
- So an attempt after the file was closed had unmounted the volume and was then refused
  with a busy status by the eject: `DiskEjector` reports any busy refusal as `.busy`,
  whichever request it answered. DiskArbitration solicits its clients' approval for an
  eject as it does for an unmount, and a dissent there reads the same way. The step is in
  the `op=disk.eject phase=refused step=` line, which the CI log does not hold
  (unified log), so which client dissented is not known.
- Each attempt resolved the disk again from the volume's path. The retry after a refused
  eject therefore found nothing to eject: the card was unmounted but not ejected, and the
  product (`performEjectRemovableSource`, which retries the same way) would have reported
  "could not be ejected".

## Change

`DiskEjector.Ejection`: one Eject, which resolves its whole disk on its first attempt and
keeps it, and asks only for the eject once its unmount has succeeded.
`DiskEjector.attempts(ofVolumeAt:)` hands the caller its attempts;
`performEjectRemovableSource` and the live test ask one Ejection again after a busy
refusal.

## Sources

- The CI job log of run 303e2143's `Build And Test (Xcode 27)` (`op=test.failure`).
- `OtosKit/Services/DiskEjector.swift`; ADR 0014.
