# Cloud drives on macOS: renames, moves, placeholders and identifiers

Date: 2026-10-25. Follow-up to `2026-10-24-asset-identity-and-out-of-app-moves.md`,
whose option C re-attaches overlay after a move outside Otos by matching inode, size,
mtime and birth time. It needs to know how cloud clients apply a rename or move made on
another device. No code or behavior changed. Nothing was renamed, moved, downloaded or
evicted; the local inspection is read-only.

Labels: **[D]** documented by Apple or the vendor; **[E]** reported empirically by
others; **[L]** observed on this Mac; **[U]** unconfirmed or inferred.

## What is installed here

- OneDrive (`~/Library/CloudStorage/OneDrive`, File Provider domain
  `com.microsoft.OneDrive.FileProvider/OneDrive`) [L]. The library's photos are here.
- An iCloud Drive File Provider exists, but no iCloud Drive folder is in use; a stale
  2024 `iCloudDrive-iCloudDrive (…)` directory holds only two app containers [L].
- No Dropbox, Google Drive or Box [L].
- **The OneDrive domain is not running.** `fileproviderctl dump -l` reports
  "unable to startup", `SqliteErrorDomain 5 "database is locked"`, and "temporarily
  disconnected: OneDrive is not running", while the OneDrive processes are running [L,
  checked twice on 2026-10-25, once outside the agent sandbox]. Files that are already
  local still read normally [L].

## Every major client is on Apple's File Provider

| Provider | Status |
| --- | --- |
| iCloud Drive | File Provider since macOS 14 [E, [Eclectic Light](https://eclecticlight.co/2026/05/09/explainer-file-provider-and-cloud-services/)] |
| OneDrive | File Provider on macOS 12.1+; Files On Demand "cannot be turned off" [D, [Microsoft](https://support.microsoft.com/en-us/onedrive/fix-onedrive-files-on-demand-issues-on-macos-12-1-or-later)] |
| Dropbox | File Provider on 12.5+, but users can still stay on the legacy mode [D, [Dropbox](https://help.dropbox.com/en-us/installs/dropbox-for-macos-support)] |
| Google Drive | File Provider streaming; a "legacy streaming" mode at `/Volumes/GoogleDrive` and a plain-folder mirror mode still exist [D, [Google](https://support.google.com/drive/answer/12178485)] |
| Box | Box Drive 2.24+ on File Provider at `~/Library/CloudStorage/Box-Box` [D, [Box](https://support.box.com/hc/en-us/articles/4407786216211-Box-Drive-v2-24-Release-Notes)] |

So one mechanism governs the common case, with legacy modes as exceptions Otos cannot
rule out.

## A rename or move made on another device

- The provider reports it as an update to an existing item, keyed by its
  `itemIdentifier`, with a new `filename` or `parentItemIdentifier`. macOS then updates
  the user-visible file itself [D, FileProvider SDK headers `NSFileProviderEnumerating.h`,
  `NSFileProviderItem.h`; [WWDC21 10182](https://developer.apple.com/videos/play/wwdc2021/10182/)].
- That makes an in-place rename (same inode, an FSEvents rename) the likely result, but
  no Apple document or empirical report states it [U].
- A file that first syncs down to a Mac gets a new local inode there [E,
  [Eclectic Light](https://eclecticlight.co/2024/03/07/icloud-drive-in-sonoma-clones-sparse-files-versions-and-more/)].
  A domain rebuild, account re-link or reinstall recreates every local file [D,
  `NSFileProviderDomain.h`; [U] for the effect on inodes and birth times].
- Otos's July OneDrive research never saw a rename event
  (`2026-07-11-onedrive-materialization-fsevents.md`).

## A content change made on another device

The system fetches the new contents and replaces the file on disk, or evicts it when the
provider's policy says so [D, headers]. Whether the inode and birth time survive is not
documented and no report was found [U].

## Placeholders

- A dataless file keeps its name and size [D, [Apple](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension)];
  creation and modification dates are synced item fields [D, headers].
- Downloading fills the existing file "without invalidating the open file descriptor"
  [D, WWDC21 10182], which implies the same inode; one reader reports the inode is
  unchanged across evict and re-download [E, Eclectic Light 2024-03-18].
- Birth time is the local creation time, not the cloud's. The top-level OneDrive
  folders here were all born within four seconds on 2026-08-04, when the domain was set
  up [L].

## Identifiers Otos could read

- `NSFileProviderManager.getIdentifierForUserVisibleFile(at:)` returns the provider's
  item and domain identifiers [D]. Its header frames it as the provider's own API
  ("a file which doesn't reside in your provider/domain … NSFileNoSuchFileError"). From
  an unsandboxed third-party process it reached the daemon here but failed with the same
  `database is locked` error, so third-party use is unsettled [L]. Whether an item
  identifier stays stable across devices is up to each provider [D; Apple's forum
  question is unanswered: [thread 714344](https://developer.apple.com/forums/thread/714344)].
- On these files `fileIdentifier` equals the inode and `documentIdentifier` is nil,
  because files are not tracked (`UF_TRACKED`) by default [L; [Apple forums
  831339](https://developer.apple.com/forums/thread/831339)].
- Otos invents no durable IDs (ADR 0008). A provider's own identifier is not invented by
  Otos, but it exists only inside a provider domain and is unproven for third-party
  callers.

## Pinning ("keep downloaded")

Providers set `NSFileProviderContentPolicyDownloadEagerlyAndKeepDownloaded` on their
own items (macOS 13+) [D]. No public pin API exists for other apps. iCloud's "Keep
Downloaded" uses an undocumented, protected `com.apple.fileprovider.pinned#PX` extended
attribute [E, [Eclectic Light](https://eclecticlight.co/2026/10/13/pin-files-in-icloud-drive/)].
`fileproviderctl` and `brctl` here have no pin, download or evict commands [L].

## Photo apps on cloud drives

Lightroom Classic experts report that a Finder rename leaves catalog links missing, with
a manual "Find Missing Folder" fix, and that optimized-storage originals break workflows
[E, [Lightroom Queen](https://www.lightroomqueen.com/lightroom-photos-missing-fix/)].
Capture One users report OneDrive downloading every image [E,
[Capture One community](https://support.captureone.com/hc/es/community/posts/360009637598-C1-and-the-cloud-dropbox-etc)].

## Finding

- On this Mac, option C (a byte-free move witness) covers Finder renames and moves on
  the same disk. For a rename on another device it most likely works, because File
  Provider applies remote renames itself, but that is unproven [U].
- What breaks C for certain: a domain rebuild, re-link or reinstall (every file is new);
  a file first synced down after the move; Dropbox or Google Drive legacy modes [D/U].
  In those cases the row is purged, as today.
- Settling it needs one experiment per provider, on a test file:
  1. `stat -f '%i %z %m %B %Sf'` with the file dataless, then downloaded.
  2. On the web or another device: rename it, move it, move it into a folder never
     opened on this Mac, then edit it.
  3. Watch FSEvents for a rename or a remove plus create, and re-run `stat`.
  4. Evict and re-download, then re-run `stat`.
- The OneDrive domain must start first. While it reports "unable to startup" and
  "disconnected", remote changes are most likely not arriving on this Mac [U].

## Measured: remote changes on OneDrive (experiment R2, 2026-10-25)

FSEvents on this Mac while the user changed a test file on OneDrive's side. Round 1
started with the file downloaded; round 2 with it cloud-only:

| Remote change | Local event | Inode | Size | Birth time | mtime |
| --- | --- | --- | --- | --- | --- |
| Rename file | `renamed` pair | kept | kept | kept | **changed, +480 s**, 5 s after the rename (to the rename time) |
| Move file to another folder | `renamed` pair | kept | kept | kept | kept |
| Rename folder | `renamed` pair (dir) | kept | — | kept | changed (directory) |
| Evict (agent, `evictUbiquitousItem`) | — | kept | kept | kept | kept |
| Round 2: rename the cloud-only file | OneDrive **downloaded it**, then a `renamed` pair | kept | kept | kept | kept |
| Round 2: move it | `renamed` pair | kept | kept | kept | **changed, +183 s** |

- **For the move witness (ADR 0034):** it must be inode + size + birth time,
  not mtime, because remote renames and moves rewrite mtime unpredictably.
- A remote rename of a cloud-only file downloaded it (n=1).
- **For enrichment:** a remotely renamed file's `(size, mtime)` signature changes, so
  it re-queues for enrichment. When the file is cloud-only, that means downloading it
  again. ADR 0034 says how a re-keyed row keeps its enrichment stamp.
