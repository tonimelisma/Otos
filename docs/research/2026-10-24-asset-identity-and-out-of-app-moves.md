# Asset identity and out-of-app moves: should Otos move to checksums?

Date: 2026-10-24. Research only; no code or behavior changed. Asset identity is the
filesystem path (ADR 0008); an XXH3-128 hash is a subordinate fact about the bytes at a
path (ADR 0018). Overlay — today ratings, soon one edit recipe per photo — is purged when
its path is proven deleted. A rename or move in Finder therefore loses it. That was
acceptable while overlay was cheap to lose; an edit is not.

Labels: **[V]** checked against the cited source, SDK header, repo file or a local run;
**[R]** community report; **[I]** inference.

## Prior art

| App | Identity | After a rename or move outside the app |
| --- | --- | --- |
| Lightroom Classic | Catalog path | Photo shows as missing; the user relinks with Find Missing Folder / Locate. Synchronize Folder imports found files as new, without their edits [R, [Lightroom Queen](https://www.lightroomqueen.com/lightroom-photos-missing-fix/), [Synchronize](https://www.lightroomqueen.com/synchronize-folder/)] |
| Apple Photos, referenced files | Path | "Photos won't be able to locate them" [V, [Apple](https://support.apple.com/kb/PH21367)] |
| Capture One catalog | Path | Files go offline; the user runs Locate [V, [Capture One](https://www.captureone.com/blog/relocating-offline-files-catalogs)] |
| darktable | Path + XMP sidecar | Database link lost; re-import restores edits only if the sidecar moved too [R, [pixls.us](https://discuss.pixls.us/t/getting-darktable-to-find-moved-images/33714)] |
| digiKam | Path + partial "uniqueHash" | Reuses a trashed row only when name, size and uniqueHash all match, so a move is caught and a rename apparently not [V, [itemscanner_database.cpp](https://lxr.kde.org/source/graphics/digikam/core/libs/database/item/scanner/itemscanner_database.cpp), [docs](https://docs.digikam.org/en/maintenance_tools/maintenance_newitems.html)] |
| PhotoPrism | Path, then full SHA1 | A new path whose hash matches a vanished row takes over that row; if the old path still exists, the new file is a duplicate [V, `internal/photoprism/index_mediafile.go`] |
| Immich external libraries | Path | "Considered a new asset after the move" [V, [Immich](https://docs.immich.app/features/libraries)] |

Desktop apps that reference user folders (Lightroom Classic, Photos, Capture One,
Immich) keep path identity and make the user relink by hand. Only tools that own fully
local storage relink by hash. Edits survive moves elsewhere only through sidecars, which
Otos does not write.

## Why a content hash is the wrong identity here

- **Cloud placeholders.** Most media is dataless. Hashing forces a download, and OneDrive
  hydrates whole files (`2026-09-01-onedrive-hydration-shape-and-latency.md`), so even a
  partial hash downloads everything. Renaming a 10,000-photo cloud folder would download
  it all before any overlay could reattach.
- **In-place metadata writers** (EXIF/XMP-in-file editors) change the bytes and so the
  hash, while the path — today's identity — survives them.
- **Duplicates.** Two paths with one digest leave no fact to say which owns the overlay.
- **Removable volumes are never hashed** (ADR 0013, ADR 0018).
- It contradicts ADR 0008's path identity and its explicit rule that a hash never
  preserves overlay across moves.

## A move witness that reads no bytes

Measured locally on APFS [V]: `mv` keeps the inode, mtime and birth time; a save by
writing a temporary file and renaming it over the original gets a new inode with the
same mtime and birth time.

```
a ino=356576434 mtime=1792908410 birth=1792908410
after mv ino=356576434 mtime=1792908410 birth=1792908410
after atomic replace ino=356576435 mtime=1792908410 birth=1792908410
```

- `NSURLFileIdentifierKey` returns the inode, documented as "not stable across all file
  systems or mounts" [V, SDK `NSURL.h`]. ADR 0008 rejected
  `NSURLFileResourceIdentifierKey` because it is "not persistent across system
  restarts" [V, SDK `NSURL.h`]; that is a different key.
- FSEvents can carry each event's inode when the stream is created with
  `kFSEventStreamCreateFlagUseExtendedData` [V, SDK `FSEvents.h`]. Otos creates its
  stream with `FileEvents | UseCFTypes | IgnoreSelf | WatchRoot` only [V,
  `Otos/Services/CatalogFilesystemWatcher.swift:136`], and a renamed directory becomes a
  subtree rescan [V, `Otos/Services/FilesystemEventFlags.swift:44`].
- Moves made while Otos is not running surface only at the next full scan, so a witness
  must be stored on the row to pair them then.
- **Unverified:** whether OneDrive or iCloud apply a rename made on another device as a
  `rename(2)` (inode kept) or as delete-and-recreate, and whether a renamed dataless file
  stays dataless. Otos's earlier provider research never observed a rename event
  (`2026-07-11-onedrive-materialization-fsevents.md`). A probe is needed before relying
  on it; `2026-10-25-cloud-drives.md` gathers what File Provider documents and the
  experiment that settles it.
- A move between volumes is a copy then a delete, and always changes the inode.

## Options

| | Design | Catches | Misses / cost |
| --- | --- | --- | --- |
| A | **Path only** (today) | — | Every Finder rename or folder rename loses edits and ratings; Lightroom and Photos at least keep a "missing" state, Otos purges |
| B | **Hash as identity**, or PhotoPrism-style hash relink | Moves anywhere whose bytes are local | Downloads every moved cloud file; duplicates ambiguous; in-place writers break identity; removable volumes excluded; reverses ADR 0008 |
| C | **Path identity, moves paired at reconcile by a byte-free witness.** The scanner records inode and volume; in the reconcile transaction that would purge a missing row, a *unique* newly seen row on the same volume with equal inode, size, mtime and birth time inherits that row's overlay (re-key, as reorganization already re-keys). No unique match means today's purge | Finder rename, move and folder rename on one volume, while running or across relaunch; nothing materialized | Cross-volume moves; provider delete-and-recreate (unverified); a rename coinciding with an atomic rewrite. One column, one resource key, an ADR 0008 amendment |
| D | **C, plus a hash fallback for bytes already local**: when the witness fails, a non-dataless new file whose size and freshly computed hash uniquely match a missing row's recorded hash inherits it | Also copy-then-delete moves of local files | Requires holding back the purge of rows with authored overlay until candidates are hashed — an orphan state against ADR 0008's one lifecycle |

**Finding:** moving to checksums (B) is the wrong fix; it trades a rename problem for a
download problem. C keeps path identity — the inode is a witness for one transaction,
never an identity — and covers the common cases with zero byte reads. D waits for a
measured need after C. The cloud-provider rename behavior must be probed before C's
coverage for cloud folders can be stated.
