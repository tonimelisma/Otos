# Copy, paste, drag and cloud-only originals

Date: 2026-11-26. A review of the hand-off code (Copy, Share, Open, drag, Reveal) after the
owner reported two symptoms: a paste sometimes gives "a text file instead of an image", and
downloading a cloud-only original sometimes stalls and then fails. Research only: it was
done in a cloud session with no Mac, so nothing here was run on macOS. Each finding below
was read in the code, then checked against the cited sources.

Tags: **[V]** read in the cited source (Apple documentation or header, an Apple engineer's
or DTS forum answer, or source code; a third-party report is marked as one). **[I]** inferred,
or not verified.

## What the code did, and what was wrong with it

| # | Defect | Where | Consequence |
| --- | --- | --- | --- |
| 1 | `textHoldsKeyboard` was a list (an edit value being typed, the export sheet) fed by each edit field's `onChange(of: isEntering)`. A field removed while focused (the Edit panel hidden) never reports losing focus, so the flag stuck true. | `CatalogWindowViewModelInspector`, `EditPanelView` | ⌘C sent `copy:` to a responder chain that has no `copy:` for photos: nothing was copied, the menu still looked enabled, and the next paste anywhere was whatever the clipboard held before, often text. ChatGPT turns a long text paste into a text-file attachment (§2). |
| 2 | ⌘C left the pasteboard untouched for the whole download or render. | lane | A paste in that window pasted the previous contents. |
| 3 | `writeObjects([NSURL])`, whose types Apple does not document. | `MediaGridClipboard` | Unverified risk of a string beside the file, which Chromium hands a page as `text/plain` (§1, §2). |
| 4 | Cancel set a flag read between photos and hid the bar; the `await` on the photo in flight went on, and an interactive download had no deadline. | lane, `FileMaterialization.Persistence.interactive` | A stuck download blocked every later Copy, Share, Open and Reveal for good, with nothing on screen. |
| 5 | An interactive download re-asked the provider every 500 ms and ended `requestFailed` on the first re-request that threw. | `FileMaterialization.awaitArrival` | A download still under way could end in an error. |
| 6 | One alert, "its original may be unavailable", for a RAW whose camera support Apple's server did not send in 60 s, a render failure, a catalog read failure, and a cancelled download. | `HandOffFailures` | The error after a stall named the wrong cause. |
| 7 | "An actor so preparations of one photo never overlap" was false: an actor runs other work at every `await`. Two asks for one photo (a drag's promise and a Copy) both rendered it and raced `moveItem`; `clearOnce` marked the folder cleared before the clearing finished. | `HandOffPreparer` | The second ask failed with "couldn't be prepared"; a preparation could write into a folder being emptied. |
| 8 | A drag promise for a tile whose details the grid did not hold was named before they were read. | `HandOffPromise` | A RAW arrived as JPEG bytes named `.ARW`; a trimmed `.MP4` as a QuickTime movie named `.mp4`. |
| 9 | That promise copied an original with `FileManager.copyItem` inside `Task.detached`. | `HandOffPromise` | A cloud-only original downloaded on a cooperative-pool thread, outside the download coordinator. |
| 10 | No check of `changeCount` before the late write. | lane | A slow Copy overwrote what the person copied in another app since. |
| 11 | ⌘V and ⌘X disabled, ⌘C and ⌘A acting on photos, in every text field not on the list: search, People and Places search, a person's name and year, the Immich sign-in. | `OtosApp` | Paste did not work in those fields. |
| 12 | A missing original's path was handed over "as Finder would". | `HandOffPreparer.original(for:)` | Copy reported success; the paste failed in the receiving app. |

Smells: the hand-kept text-field list; three answers to "is this file ready?" (`readyURL`,
`needsPreparation`, a check inside `prepare`); a made-up `MediaAssetID` (`"/"`, `""`) in
`HandOffPromise`; `MediaGridClipboard.write(_ ids:)` called only by a test; Copy requests that
queue instead of the newer one winning; a copy log that cannot say what it handed over. Also
found while fixing: a drag before the launch's first preparation could take a previous
launch's prepared file for ready, and the next preparation's clearing then deleted it under
the receiver.

One suspicion was withdrawn: that a single failed `lstat` ends a download that was going on.
A File Provider fills a dataless file in place without invalidating open descriptors (WWDC21
10182, [V]), and no source shows OneDrive hydration replacing the inode, so a failed `lstat`
means the path is gone, which is a fact.

## 1. What a pasteboard carries

- **[V]** Apple does not document the types `NSURL`'s `NSPasteboardWriting` writes for a file
  URL; only the first type is written at once and the rest are promised, served by the writing
  process (`writableTypes(for:)`,
  <https://developer.apple.com/documentation/appkit/nspasteboardwriting/writabletypes(for:)>).
  The 2026-10-25 browser research found that a writer that exits early leaves only the first
  item.
- **[V]** Chromium's own "copied files" write one `NSPasteboardItem` per file carrying only
  `public.file-url` (`WriteFilesToPasteboard`,
  <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/base/clipboard/clipboard_util_mac.mm>);
  Apple's migration path from `NSFilenamesPboardType` is the same: several items, each with a
  file URL (`NSPasteboard.h`). **[V]** Readers of the old type typically see only the first
  item (Pasteboard Programming Guide,
  <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/PasteboardGuide106/Articles/pbUpdating105.html>).
- **[V]** The pasteboard daemon issues a sandbox extension for each `public.file-url` entry on
  the writer's behalf, and drops one the writer cannot read
  (<https://wadetregaskis.com/mac-app-sandboxing-interferes-with-drag-drop/>, a third-party log
  on macOS 27.2.1), so Mail, Messages and Notes can read what Otos writes this way.
- **[V]** Finder's ⌘C of three files writes `public.file-url` on every item and plain text (the
  paths) on the first; Photos' ⌘C writes `public.jpeg` and `public.file-url` per photo
  (<https://lists.w3.org/Archives/Public/public-webapps-github/2022Feb/0062.html>).

## 2. Which receivers take text

- **[V]** Chromium (Chrome, Edge and every Electron app) reads files only from
  `public.file-url`, with no existence or readability check at paste time; a paste event gets
  `text/plain` as well whenever a string is on the pasteboard, and the page chooses
  (`data_object.cc`, `clipboard_mac.mm`). With files present it hides `image/png`.
- **[V]** The async Clipboard API exposes text, HTML and PNG, never files
  (<https://developer.mozilla.org/en-US/docs/Web/API/Clipboard/read>).
- **[V, community reports]** chatgpt.com turns a long text paste into a file attachment
  (<https://community.openai.com/t/chatgpt-converts-pasted-text-to-file-attachment/1369430>).
  **[I]** Claude.ai has similar behaviour.
- **[V, user reports]** Obsidian pasted Finder's file names as text until 0.13.29.

## 3. What other apps do with a cloud-only file

- **[V]** Photos copies image bytes, so a paste never depends on the cloud. Lightroom has no
  copy-photo command (<https://community.adobe.com/t5/lightroom-ecosystem-cloud-based-ideas/p-copy-photo-to-clipboard/idi-p/12480521>).
- **[V]** A file promise on the general pasteboard does not paste in Finder
  (<https://developer.apple.com/forums/thread/683081>), and browsers read only file URLs: a
  pasted file must exist when it is pasted.
- **[I]** Finder downloads a dataless file it copies, with its own progress; not verified.

## 4. Downloading a File Provider item someone waits for

- **[V]** `startDownloadingUbiquitousItem` only asks fileproviderd to start and reports nothing
  about the end ("All startDownloadingUbiquitousItemAt really does is call out to the
  fileproviderd and say 'download this'", DTS,
  <https://developer.apple.com/forums/thread/795716>). The ubiquitous status keys are
  unreliable for third-party providers (Ferry, OneDrive, macOS 26; an iOS iCloud report,
  <https://developer.apple.com/forums/thread/826061>). `NSFileProviderManager` cannot target
  another vendor's domain (-2001, -2014).
- **[V]** A coordinated read downloads a dataless file before its accessor runs, or fails with
  the provider's error: `coordinate(readingItemAt:options:error:byAccessor:)` "blocks the
  calling thread (potentially for a long time) while the file is downloaded"
  (<https://developer.apple.com/documentation/foundation/nsfilecoordinator>); an Apple engineer:
  "Using NSFileCoordination on the URL to the file will cause it to be downloaded while the
  accessor block is running" (<https://developer.apple.com/forums/thread/763344>, a
  `~/Library/CloudStorage` placeholder); DTS: "use FileCoordination to initiate and manage the
  download" (<https://developer.apple.com/forums/thread/825820>). The intents variant
  (`coordinate(with:queue:byAccessor:)`) has a reported bug where the accessor ran before the
  download; the synchronous call does not.
- **[V]** `cancel()` may be called from any thread; a coordination still waiting returns
  `NSUserCancelledError` at once, and a cancelled coordinator runs no later accessor, so use
  one per operation (`NSFileCoordinator.h`). **[I]** Whether it stops the provider's download is
  undocumented; assume it goes on.
- **[V]** The kernel waits on a dataless read with no timeout; `ETIMEDOUT` means the provider
  could not be reached (xnu `vfs_syscalls.c`; TN3150).

## 5. Keyboard focus and the Edit menu

- **[V]** `NSWindow.firstResponder` is documented as key-value observing compliant
  (<https://developer.apple.com/documentation/appkit/nswindow/firstresponder>);
  `NSApplication.keyWindow` is not, so key-window changes are followed through
  `didBecomeKey`/`didResignKey`.
- **[V]** While a field is edited the window's first responder is the shared field editor, an
  `NSTextView` (Text Editing Programming Guide, field editor). SwiftUI's `TextField` and
  `SecureField` on macOS are `NSTextField`s (SwiftUI-Introspect's view types).
- **[V]** Since 10.5 a disabled menu item's key equivalent passes to the first responder as a
  key down, and `NSTextView` pastes only through a `paste:` menu item, so a disabled Paste
  item means ⌘V does nothing in a focused field (AppKit release notes, Handling Key Events).
- **[V]** `@FocusState` resets when focus leaves; nothing documents an `onChange` when the
  focused view is removed, or the order of two fields' callbacks
  (<https://developer.apple.com/documentation/swiftui/focusstate>).

## 6. File promises

- **[V]** `filePromiseProvider(_:fileNameForType:)` is called on the main thread when the
  destination calls the promise in, at the drop; `writePromiseTo` runs afterwards on the
  delegate's operation queue, wrapped in file coordination; "always use the supplied URL"
  (`NSFilePromiseProvider.h`, AppKit 10.12 notes). The name can be decided at the drop, not
  later, and the written file must be the named one.

## 7. Joining duplicate work in an actor

- **[V]** WWDC21 "Protect mutable state with Swift actors" stores an in-progress `Task` that
  later callers await; Swift Forums threads note that this loses each caller's cancellation,
  and recommend a continuation per waiter inside `withTaskCancellationHandler`, the shared work
  cancelled when the last waiter leaves, a cancel that arrives before registration handled,
  and an identity check when the work completes
  (<https://forums.swift.org/t/structured-caching-in-an-actor/65501>,
  <https://forums.swift.org/t/updating-imagedownloader-actor-sample-to-support-cancellation/85126>).

## Decisions taken from this (owner, 2026-11-26: "yes, download before copying — fix them all")

- Copy, Share, Open and Open With download a cloud-only original before handing it over (ADR
  0012, ADR 0037). A drag still hands a placeholder over as it is: it cannot wait, and Chrome
  never fulfils the promise that would.
- The pasteboard carries one hand-built `public.file-url` item per file (§1), written at once;
  ⌘C claims it at the command and writes only while the claim is still the pasteboard's.
- Interactive downloads are one coordinated read, each on a thread of its own (§4). Its
  coordinator never leaves that thread, because `NSFileCoordinator` is not `Sendable` and the
  codebase allows no unchecked escape (ARC-042); a waiter that leaves stops waiting at once,
  and the thread ends when the provider answers, as the download goes on either way. Background, device and command downloads keep the request-and-watch
  path, which holds no thread per transfer.
- What holds the keyboard is the key window's first responder, observed (§5).
- A promise for an unread tile waits for its details before it names the file (§6).
- A preparation is joined per target with per-waiter continuations (§7).

## Owner steps (need the Mac)

- Dump `NSPasteboard.general.pasteboardItems?.map(\.types)` after an Otos ⌘C, and after a
  Finder ⌘C of the same files, to confirm §1.
- Copy a cloud-only photo from a OneDrive folder and paste it into Chrome: the bar reads
  `Preparing 1 photo to copy`, the file arrives, and `op=materialization.coordinatedRead`
  logs no failure. Open a cloud-only photo in the loupe the same way.
