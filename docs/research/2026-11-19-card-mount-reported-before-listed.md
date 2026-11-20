# A card's mount reported before it is listed (2026-11-19)

## Question

The owner inserted an SD card into the MacBook's built-in reader at 17:46:59 with Otos
running. The card mounted (`/Volumes/4152150790`, exFAT, through FSKit) but never appeared
in Otos. Why?

## Evidence

Otos's unified log at the insert, against the system's own reports:

| Time | Report |
| --- | --- |
| 17:46:59.086 | Otos `op=removableVolume.refresh phase=finish count=0` |
| 17:46:59.101 | Otos `op=removableVolume.refresh phase=finish count=0` |
| 17:46:59.158 | UVFSService starts creating the volume for `disk10s1` |
| 17:46:59.208 | fskitd `ReallyMountVolume`, mount task created at .212 |
| 17:46:59.228 | Otos `op=removableVolume.refresh phase=finish count=0` (the last read) |
| 17:46:59.232 | Finder's volume observer sees `/Volumes/4152150790` |
| 17:47:00.524 | storagekitd: `disk10s1 Mounted: Yes` |

Every read Otos made ran before the mount was usable, and no DiskArbitration report
followed it. Read afterwards, the same volume passed every check
`RemovableVolumeMonitor.currentAttachments()` applies: `volumeIsRemovable == true`,
`kDADiskDescriptionDeviceModelKey == "Built In SDXC Reader"`, listed by
`mountedVolumeURLs(… .skipHiddenVolumes)`.

A probe registered the same DiskArbitration callbacks Otos uses, a kqueue `EVFILT_FS`
filter and NSWorkspace's mount notifications, and on each one read `mountedVolumeURLs`
the way `RemovableVolumeMonitor.currentAttachments()` does. The card was unmounted and
mounted with `diskutil` 18 times (no file on it read or written):

- `EVFILT_FS` with `VQ_MOUNT` arrived first every time, and every time the listing did
  not yet hold the card. The kernel's own mount event is too early to read on.
- DiskArbitration's volume-path change usually found the card listed, but not always: in
  one cycle the listing held nothing at the change and held the card 50 ms later.
- `NSWorkspace.didMountNotification` found the card listed every time (16 of 16).

Otos itself lost the race repeatedly during these cycles: after the first remount
attached the card (`op=removableVolume.refresh count=1`), six of the next seven mounts
ended in `count=0` while the card stayed mounted, and the card stayed out of the sidebar
until a later remount happened to win. The physical insert at 17:46:59 is the same race.

## Conclusion

- A completed mount (`NSWorkspace.didMountNotification`) asks the monitor to read the
  mounted set again. It is the report AppKit posts once a volume is mounted for apps,
  and the listing held the card every time it arrived. It only triggers a read,
  which returns the set as it is, so its order against DiskArbitration's reports does
  not matter (ADR 0013).
- Every read now logs what asked for it (`report=start|diskArbitration|mountCompleted`)
  and each removable volume it excluded with the excluding fact
  (`op=removableVolume.rejected reason=resourceValuesUnavailable|noDeviceModel|notPhysical`),
  so a card that does not appear names its cause.
- Remaining: a physical insert with the fix installed, which needs the card re-inserted by hand.
