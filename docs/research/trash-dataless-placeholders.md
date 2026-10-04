# System Trash and dataless File Provider placeholders

- Date: 2026-10-01 (probe), recorded 2026-10-04
- Question: why does Move to Trash fail for OneDrive media, and what makes it succeed?

## Evidence

Installed Otos logged `op=mediaTrash.path failed role=primary` for a photo in
`OneDrive-Personal/Pictures/Camera Roll`; the error itself was not logged. The
import batch it belonged to had 361 of 484 files flagged `compressed,dataless`
(`ls -lO`).

Probe: a scratch Swift script calling `FileManager.trashItem(at:resultingItemURL:)`
on throwaway files in the OneDrive File Provider root (macOS 27 beta, OneDrive
File Provider build current on 2026-10-01).

| File state | Result |
| --- | --- |
| Materialized (local) | Moved to `~/.Trash` |
| Evicted with `FileManager.evictUbiquitousItem(at:)` → `dataless` | `NSCocoaErrorDomain` 3328 (`NSFeatureUnsupportedError`): "couldn't be moved to the trash because the volume 'Macintosh HD' doesn't have one" |
| Same dataless file after a byte read materialized it | Moved to `~/.Trash` |

`NSWorkspace.recycle` was also probed from a command-line process; it never
called back, so it gave no result either way.

## Conclusion

The refusal is about the placeholder, not the provider: a dataless item cannot
leave its File Provider domain into the local Trash. Materializing first is
sufficient. Otos does this through `MaterializationCoordinator` (ADR 0022).
