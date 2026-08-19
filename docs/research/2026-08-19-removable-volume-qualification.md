# Removable volume qualification: excluding disk images

Date: 2026-08-19. Plan 0095 increment 9, D10.

## Question

`RemovableVolumeMonitor.currentAttachments` accepts any mounted volume with
`URLResourceValues.volumeIsRemovable == true`. Production evidence
(`docs/plans/0095-honest-import.md` D10) shows this also accepts mounted disk
images — `library_root` held `/Volumes/Raycast` and `/Volumes/BoltAI 2`, both
app-installer DMGs, as permanent removable sources. What does the system
actually report for a mounted disk image versus real removable media, and what
predicate distinguishes them?

## Method

No physical SD card or USB stick is attached in this agent environment (`diskutil
list` shows only the internal disk and disk images — see below), so the
disk-image side of this question is measured directly and the real-hardware
side documents the verified Apple platform behavior instead of guessing.
Physical-hardware measurement is deferred exactly as it was for the camera
download-mtime probe (`docs/research/2026-07-10-camera-import-download-mtime.md`):
recorded as a gap, not silently assumed.

### First pass: `diskutil info` (wrong — see Correction below)

```
$ hdiutil create -size 10m -fs "APFS" -volname "OtosResearchDMG" test-dmg.dmg
$ hdiutil attach test-dmg.dmg
$ diskutil info -plist /Volumes/OtosResearchDMG
```

`diskutil info`'s plist reported `BusProtocol: "Disk Image"`, unchanged whether
the image was converted read-only first (`hdiutil convert -format UDRO`) and
identical at every level of the disk's GUID-partition hierarchy (whole disk,
partition, synthesized APFS container, volume) and for the two iOS Simulator
runtime volumes already mounted on this machine. This looked like a clean,
verified signal and the code was written against it
(`kDADiskDescriptionDeviceProtocolKey != "Disk Image"`, on the assumption that
`diskutil`'s `BusProtocol` field is a direct passthrough of that
`DiskArbitration` key).

### Correction: `diskutil`'s `BusProtocol` is not `kDADiskDescriptionDeviceProtocolKey`

The xctest written against the real code path
(`RemovableVolumeMonitorLiveDiskImageTests`, which mounts a real scratch DMG
and calls the actual `DADiskCreateFromVolumePath` / `DADiskCopyDescription`
production code) failed: `kDADiskDescriptionDeviceProtocolKey` measured
`"Virtual Interface"`, not `"Disk Image"`. `diskutil`'s CLI output is evidently
not a direct passthrough of that one key — it computes `BusProtocol` from
something else internally. Re-measured directly against the API with a small
throwaway probe (`DADiskCreateFromBSDName`/`DADiskCreateFromVolumePath` +
`DADiskCopyDescription`, called for every disk-object level of a mounted DMG:
the whole disk, the GPT partition, the synthesized APFS container, and the
mounted volume itself, plus the real internal boot volume for contrast):

| Path queried | `kDADiskDescriptionDeviceProtocolKey` | `kDADiskDescriptionDeviceModelKey` | `kDADiskDescriptionMediaRemovableKey` |
| --- | --- | --- | --- |
| disk8 (whole disk, DMG) | `"Virtual Interface"` | `"Disk Image"` | `true` |
| disk8s1 (GPT partition, DMG) | `"Virtual Interface"` | `"Disk Image"` | `true` |
| disk9 (synthesized APFS container, DMG) | `"Virtual Interface"` | `"Disk Image"` | `true` |
| disk9s1 / `/Volumes/OtosProbe2` (mounted volume, DMG) | `"Virtual Interface"` | `"Disk Image"` | `true` |
| `/` (real internal boot volume) | `"Apple Fabric"` | `"APPLE SSD AP0512R"` | `false` |

`kDADiskDescriptionDeviceProtocolKey` reports `"Virtual Interface"` uniformly
for every level of a disk image's object hierarchy — a generic "this is a
virtual transport" fact that says nothing about *which* virtual mechanism, so
it cannot distinguish a disk image from, say, some other virtual block device.
`kDADiskDescriptionDeviceModelKey` is where `"Disk Image"` actually lives: a
synthetic model name `DiskImages.framework` stamps on every device it creates,
regardless of disk-object level, contrasted with a real hardware model/vendor
string (`"APPLE SSD AP0512R"`) for physical media.

### Other disk images already present on this machine

`diskutil list` on this machine also shows two iOS Simulator runtime volumes
mounted as `(disk image)` — same classification, confirming this is a general
"how the volume is attached" fact, not something specific to `hdiutil`-created
DMGs.

### Real removable media (SD card, USB stick)

Not measured — none is attached to this machine. `kDADiskDescriptionDeviceModelKey`
is an arbitrary hardware vendor/model string for real devices (confirmed by the
internal-SSD measurement above: `"APPLE SSD AP0512R"`), not a fixed enum the
way the disk-image case turned out to be — there is no equivalent short list of
"the" values real SD-card readers or USB sticks report. The property this
research can state with confidence is the negative one that matters for the
predicate: a real device's model string is never the literal `DiskImages
.framework`-stamped sentinel `"Disk Image"`.

**Follow-up when hardware is available:** attach a real SD card and USB stick,
call `DADiskCopyDescription` on the mounted volume (or run `diskutil info`,
now knowing to read `Media Name`/`Device / Media Name`, which reflects
`kDADiskDescriptionDeviceModelKey`, not `BusProtocol`), and confirm neither
ever reports `"Disk Image"`.

## Predicate

`URLResourceValues` (the `Foundation`/`FileManager` API
`RemovableVolumeMonitor.currentAttachments` already uses) has no key for
device model — `volumeIsRemovableKey`/`volumeIsEjectableKey`/`volumeIsInternalKey`
are filesystem-level facts that disk images share with real removable media.
The distinguishing fact lives one level down, at `DiskArbitration`, which
`RemovableVolumeMonitor.swift` already links and uses elsewhere
(`RemovableDiskDisappearanceContext.handleDiskDisappeared` already calls
`DADiskCopyDescription`).

Qualification: a mounted volume is a real removable source only when
`volumeIsRemovable == true` **and** its `DADiskCopyDescription`'s
`kDADiskDescriptionDeviceModelKey` is present and not equal to `"Disk Image"`.
Absent that key entirely is treated as disqualifying too (fail closed — no
answer is not proof of physical removable media).

## Conclusion

`volumeIsRemovable == true` alone is proven insufficient (measured: a disk
image sets it `true` at every level of its object hierarchy).
`kDADiskDescriptionDeviceModelKey != "Disk Image"` is the verified predicate
that excludes them — verified by calling the actual production API against a
real mounted disk image in an xctest, not by trusting a CLI tool's derived
summary field, which this research's own first pass shows can silently
disagree with the underlying API. Real external-media confirmation remains a
hardware-dependent follow-up, but the exclusion side of the predicate — the
actual bug being fixed — is measured against the real API, not guessed.
