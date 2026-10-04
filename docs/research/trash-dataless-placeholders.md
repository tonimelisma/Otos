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

## Follow-up, 2026-10-04: Finder, other media apps, and the HIG

### Finder

Scripted (`tell application "Finder" to delete`, i.e. Move to Trash) on files made
dataless with `evictUbiquitousItem(at:)`:

| File | Result |
| --- | --- |
| 6 B, dataless | In `~/.Trash`, fully local afterwards |
| 40 MB, dataless (evicted 5 s after upload; may have been served from the provider's local cache) | In `~/.Trash` after 1.0 s, all 41,943,040 bytes local |

`NSFileCoordinator.coordinate(writingItemAt:options: .forMoving)` around `trashItem`
still fails with 3328, so file coordination is not what lets Finder succeed.

Gold standard (the owner, by hand in Finder): a local `test.txt` moved to the Trash
landed in `~/.Trash`; a 1 GiB file that OneDrive had made dataless, moved to the Trash
the same way, did not appear in `~/.Trash` and was gone from the domain. Whether
Finder decides by size, or never downloads on a user's Move to Trash, is not yet
established. Scripted Finder runs are weaker evidence than a manual action.

OneDrive's recycle bin on the web listed every probe deletion (scripted and manual)
except the 1 GiB file at the time of the check.

### Other media apps

| App | Delete goes to | Undo |
| --- | --- | --- |
| Lightroom Classic | System Trash ("Delete from Disk") | None; reported to bypass the Trash in cloud-synced folders since 2023 |
| Lightroom desktop | "Deleted" album, 30 days | Restore |
| Apple Photos | "Recently Deleted", 30 days | Recover |
| Capture One | Catalog/session Trash | Edit ▸ Undo Move to Trash |
| digiKam | `.dtrash` inside each collection | Undo since 6.0 |
| Adobe Bridge | System Trash | ⌘Z moves back; buggy, not on external volumes |
| Finder | System Trash | ⌘Z, Put Back |

Every app with undo keeps the item reachable by the app. Otos rules out an app vault
and writing into media folders, so its route is the system Trash plus the
`resultingItemURL` that `trashItem` reports.

### HIG

- Alerts: avoid alerts for common, undoable actions, even destructive ones; titles
  describe the situation; buttons are verbs naming the result; `Cancel` is always
  `Cancel`; a deliberately chosen destructive act is not destructive-styled.
- macOS alerts may carry a suppression checkbox; for a multi-button alert AppKit's
  default title is `Do not ask again` (`NSAlert.showsSuppressionButton`).
- Settings: minimize settings, prefer good defaults, put general, infrequently
  changed options in Settings.

These shape Plan 0104.

### Sources

- Apple Developer Forums: [761438](https://developer.apple.com/forums/thread/761438),
  [686536](https://developer.apple.com/forums/thread/686536)
- Microsoft: [Files On-Demand for Mac](https://support.microsoft.com/office/save-disk-space-with-onedrive-files-on-demand-for-mac-529f6d53-e572-4922-a585-e7a318c135f0),
  [Delete files or folders in OneDrive](https://support.microsoft.com/office/delete-files-or-folders-in-onedrive-21fe345a-e488-4fa7-932b-f053c1bebe8a)
- Adobe: [Kost on Remove vs Delete](https://jkost.com/blog/2019/05/removing-vs-deleting-images-in-lightroom-classic.html),
  [Delete from Disk bypasses Trash](https://community.adobe.com/t5/lightroom-classic-discussions/quot-delete-from-disk-quot-bypasses-trash-now/m-p/14189793/highlight/true),
  [Lightroom deleted photos](https://helpx.adobe.com/lightroom-cc/using/restore-deleted-photos.html),
  [Bridge undo bug](https://community.adobe.com/bug-reports-557/bug-deleting-files-in-bridge-and-then-pressing-undo-creates-a-huge-mess-1501595)
- [Capture One](https://support.captureone.com/hc/en-us/articles/360002547417),
  [digiKam bug 246727](https://bugs.kde.org/show_bug.cgi?id=246727),
  [Apple Photos](https://support.apple.com/guide/photos/pht3bfab2f96/mac),
  [Intego on Put Back](https://www.intego.com/mac-security-blog/?p=69448)
- HIG: [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts),
  [Settings](https://developer.apple.com/design/human-interface-guidelines/settings);
  [`NSAlert.showsSuppressionButton`](https://developer.apple.com/documentation/appkit/nsalert/showssuppressionbutton)
