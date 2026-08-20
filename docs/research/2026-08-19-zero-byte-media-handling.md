# Zero-byte media files: what the system and other tools do

Date: 2026-08-19. Plan 0096 owner decision Q4, defect D19.

## Question

`MediaEligibility.isCatalogMedia` classifies a file as catalog media from its
`UTType` alone and never reads its size
(`Otos/Services/MediaEligibility.swift:25`; its doc comment states the split
deliberately: "Decodability and enrichment unsupported outcomes are separate").
A zero-byte `.heif` therefore becomes a permanent grid item that can never show
a thumbnail or a preview.

Should Otos catalog a zero-byte file at all, and if it does, what should it say
about it?

## The files this came from

Three zero-byte files in the user's library, found because the user selected
them and asked why they showed nothing:

```
2026/08/20260814_164104-<host>-safeBackup-0001.heif   0 bytes
2026/08/20260814_164106-<host>-safeBackup-0001.arw    0 bytes
2026/08/20260814_164106_001-<host>-safeBackup-0001.arw 0 bytes
```

All created 2026-08-16 23:13, all carrying a `com.apple.FinderInfo` xattr, all
sitting beside intact originals (`20260814_164104.heif`, 5,410,816 bytes;
`20260814_164106.arw`, 36,823,040 bytes). Two more exist in the other library
root (`2026/05/20260514_195133.jpg`, `2026/05/20260515_191748.avi`), so five
rows catalog-wide.

`-safeBackup-NNNN` is the Microsoft OneDrive client's protective-copy naming;
`<host>` is this Mac's host name. The `abraunegg/onedrive` maintainer describes
the trigger as the client being "about to replace or remove a local file" when
"there's any chance the current on-disk content might be different to what
OneDrive expects" — it backs the local file up first. Microsoft's own guidance
attributes 0 KB outcomes to "an incomplete upload/download, Files On-Demand
placeholder not hydrating, or a local cache/state problem" rather than to
server-side corruption. So these are sync artifacts, not damaged originals, and
the user's actual photos are intact.

## Measured: what the system says about a zero-byte `.heif`

Run against `20260814_164104-<host>-safeBackup-0001.heif` on macOS 27.0.

| Tool | Result |
| --- | --- |
| `mdls` (Spotlight) | `kMDItemContentType = "public.heif"`, `kMDItemKind = "HEIF Image"`, `kMDItemPixelHeight = (null)` |
| `file(1)` | `empty` |
| `exiftool 13.55` | Lists the file. `File Size: 0 bytes`. No image metadata, no error. |
| `sips -g pixelWidth` | `Warning: … not a valid file - skipping` |
| `CGImageSourceCreateWithURL` | Returns a **non-nil** source. `CGImageSourceGetCount` = `0`. `CGImageSourceGetStatus` = `-4` (`kCGImageStatusUnexpectedEOF`). `CGImageSourceGetType` = `nil`. |
| `qlmanage -t -s 64` | Did not return within 120 s. Single observation; not characterized further. |

One pattern runs through all of it: **type classification succeeds and content
extraction returns nothing.** Spotlight indexes it as a HEIF image and then has
no pixel dimensions to report. Image I/O hands back a source object and then
reports zero images with an explicit EOF status. `exiftool` lists it. Nothing
deletes it, nothing hides it, and the two tools whose job is to produce pixels
(`sips`, Image I/O) fail loudly rather than silently.

That is exactly the split Otos already implements: `MediaEligibility` classifies
by type, and `MediaTileDetail.thumbnailUnavailable`
(`Otos/Models/CatalogModels.swift:551`) distinguishes "enrichment ran and could
not produce a thumbnail" from "not yet enriched", which drives the `photo.slash`
/ `video.slash` placeholder glyph
(`Otos/Views/MediaAssetTilePresentation.swift:186`). Verified for all five rows:
`enriched_source_mtime` is set, `thumbnail_path` is null, so every one of them is
already drawing the "unavailable" glyph and not a stuck loading state.

## Measured: what comparable applications do

**Lightroom Classic.** Shows unreadable files in the Import dialog and then
refuses them, reporting: "The following files were not imported because they
could not be read or the destination folder is not writable." For files already
in the catalog whose originals later become unreadable or missing, it keeps the
catalog row and marks it with a badge rather than removing it — a grey dotted
rectangle with an exclamation mark when a Smart Preview exists, a different
dotted-rectangle badge otherwise. Two different policies for two different
moments: **refuse at import, retain and flag once catalogued.**

**macOS Photos.** No documented policy. Community reports describe imports
stalling on unreadable items and recommend removing such files before importing;
there is also a documented Image Capture bug that itself creates empty data
files during iPhone/iPad import. Nothing here is a design to copy.

**digiKam, darktable, Capture One.** No published rule found for zero-byte
handling in documentation or source-search results. Recorded as a gap rather
than guessed at.

## Conclusion

The convergent behavior is **not** "silently skip". It is:

1. Classify by type. Otos already matches Spotlight, `exiftool`, and Lightroom
   here.
2. Fail content extraction explicitly, and show that failure. Otos already does
   this correctly.
3. **Refuse to import a file with no content, and say why.** This is
   Lightroom's import-time rule and it is the piece Otos is missing: a zero-byte
   file on a card is planned as an ordinary copy today, because
   `hasAnyDate` is true from its mtime, so the artifact propagates into the
   library.
4. Never delete the catalog row for a file that still exists. Otos already
   guarantees this (ADR 0008, ARC-033).

**This reverses the recommendation plan 0096 first recorded for Q4.** The
initial reading — exclude zero-byte files at scan time — contradicts the
filesystem-is-truth principle and contradicts every tool measured above, all of
which list the file. It also mistakes the complaint: the user could see the
tiles and could see they were broken; what they could not see was *why*, or that
the files were harmless sync debris rather than lost photos.

Recommended answer to Q4: **keep cataloguing them, block them from import with a
stated reason, and give the tile a reason the user can read.** The scan-time
exclusion is rejected.

## Sources

- [What does safeBackup do - or what triggers it? · abraunegg/onedrive Discussion #3027](https://github.com/abraunegg/onedrive/discussions/3027)
- [Why are some OneDrive files showing as 0KB or appearing corrupted — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5824104/why-are-some-onedrive-files-showing-as-0kb-or-appe)
- [The following files were not imported because they could not be read — Adobe Community](https://community.adobe.com/questions-675/the-following-files-were-not-imported-because-they-could-not-be-read-977030)
- [Identify and re-connect missing original photos in Lightroom Classic catalogs](https://support.imagen-ai.com/hc/en-us/articles/12143265630621-Identify-and-re-connect-missing-original-photos-in-Lightroom-Classic-catalogs)
- [Photos refuses to import JPEGs — Apple Community](https://discussions.apple.com/thread/255950168)
- [New macOS bug can devour hard drive space when importing iPad and iPhone photos — TechRadar](https://www.techradar.com/news/new-macos-bug-can-devour-hard-drive-space-when-importing-ipad-and-iphone-photos)
