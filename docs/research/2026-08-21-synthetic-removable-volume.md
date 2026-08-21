# Synthetic removable-volume probe

This probe records the removable-volume fixtures used by plan 0097 increment 1.
It is intentionally outside the product's disk-image cleanup rule: the harness
attaches volumes through the same `CatalogStore.attachRemovableVolume` owner intent
used by tests and does not persist the product's `Disk Image` device model.

## Procedure

```text
script/synthetic-card.sh create
script/synthetic-card.sh attach
diskutil info /Volumes/OTOSPROBE
diskutil info /Volumes/OTOSPROBECS
script/synthetic-card.sh detach
script/synthetic-card.sh attach
script/synthetic-card.sh destroy
```

The actual run used a temporary override,
`OTOS_SYNTHETIC_CARD_STATE_DIR=/private/tmp/otos-synthetic-card-run`, and completed
the detach, re-attach, capability inspection, and cleanup successfully.

## Measurements on 2026-08-20

The ExFAT image mounted at `/Volumes/OTOSPROBE` and reported:

- `File System Personality: ExFAT`
- `Media Type: Generic`
- `Device Location: External`
- `Removable Media: Removable`
- `Media Read-Only: No`

The case-sensitive APFS image mounted at `/Volumes/OTOSPROBECS` and reported:

- `File System Personality: Case-sensitive APFS`
- `Name (User Visible): APFS (Case-sensitive)`
- `Device Location: External`
- `Removable Media: Removable`
- `Media Read-Only: No`

The case-sensitive volume retained both `IMG_1.JPG` and `img_1.jpg` as distinct
files. On ExFAT, creating NFC `café.jpg` followed by its NFD spelling produced one
file, stored with the decomposed spelling (`café.jpg`). This confirms that the
harness supplies distinct case capabilities and that the Unicode normalization
measurement is reproducible without physical card hardware.

Both volumes detached and re-attached at their expected mount points. The disk
utility reports `Protocol: Disk Image` because these are local image-backed test
volumes; the harness deliberately leaves `deviceModel` unset so that this fact is
not persisted as the product's removable-root cleanup marker.
