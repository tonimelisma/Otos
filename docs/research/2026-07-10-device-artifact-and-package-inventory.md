# Device-artifact exclusions and package skip inventory

Date: 2026-07-10
Status: research note for plan 0055 Stage B. Real Sony/GoPro/AVCHD card fixtures
were not mounted in this agent environment; exclusions follow the confirmed
gomediaimport ignore set plus existing Otos structural rules.

## Implemented inventory exclusions

| Rule | Behavior |
| --- | --- |
| AppleDouble `._*` | Skip relative path (pre-existing) |
| `.Spotlight-V100`, `.Trashes`, `AVF_INFO` | Skip directory (pre-existing) |
| `.Trash-*`, `$RECYCLE.BIN` | Skip directory / path components |
| Sony `M4ROOT/SUB` | Skip (pre-existing) |
| Sony `M4ROOT/THMBNL` | Skip directory tree |
| Sony `M4ROOT/CLIP/*.xml` | Skip XML clip metadata files only |
| macOS packages | Skip descendants; count per completed scan on `RootRuntimeState.skippedPackageCount` |

These are inventory-only rules for all roots. They never delete files.

## Open fixture questions

1. On a real Sony card, which of THMBNL / CLIP XML / SUB actually classify as
   catalog media under `NSURLContentTypeKey` today?
2. On FAT/exFAT AVCHD camcorder cards, does macOS report the AVCHD structure as
   a package (`isPackage == true`) so the current skip+count path fires?
3. GoPro cards: any additional junk trees that classify as image/movie?

Record answers here when fixtures are available; do not expand destructive
cleanup (THM/CTG/AAE/…) without a confirmed product requirement.
