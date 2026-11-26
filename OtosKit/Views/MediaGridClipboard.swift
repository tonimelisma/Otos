import AppKit
import Foundation
import OSLog

/// Media clipboard guide
///
/// Writes copied files to a pasteboard (ADR 0012): one pasteboard item per file, in the
/// given order, each carrying exactly one type, `public.file-url`. The files are what the
/// hand-off chose (ADR 0037) and are on this Mac: an original, downloaded first when it was
/// cloud-only, or a full-size file prepared in Application Support. Finder pastes the files;
/// Messages, Mail and web pages attach them.
///
/// The item is built by hand rather than by writing `NSURL`, whose `NSPasteboardWriting`
/// types are undocumented: a string beside the file would reach a web page as `text/plain`
/// next to its files, and a page that takes the text pastes a path instead of a photo
/// (`docs/research/2026-11-26-copy-paste-and-cloud-originals.md`). Its data is written at
/// once, so every item stays readable after Otos quits or relaunches to update.
///
/// A Copy claims the pasteboard when it is commanded (`claim`), before its files are ready,
/// and writes only if the pasteboard is still its claim's (`write(files:to:claimed:)`): a
/// paste in between pastes nothing rather than what was there before, and a Copy that
/// finishes after another app wrote the pasteboard leaves that newer content alone.
///
/// The pasteboard is a parameter so the write can be exercised against an isolated
/// `NSPasteboard(name:)` in tests. Every claim and write is logged here, the one place
/// every Copy passes.
nonisolated enum MediaGridClipboard {
    /// Empties `pasteboard` for a Copy and returns its change count, which the Copy's write
    /// must still find.
    static func claim(_ pasteboard: NSPasteboard) -> Int {
        let changeCount = pasteboard.clearContents()
        OtosLog.ui.noticeOperation("ui.copy", phase: "claimed", fields: ["changeCount": "\(changeCount)"])
        return changeCount
    }

    /// Writes one item per file, in order, if the pasteboard is still the claim's. Returns
    /// how many files the pasteboard accepted: none when the claim was superseded or the
    /// pasteboard refused the write.
    @discardableResult
    static func write(files urls: [URL], to pasteboard: NSPasteboard, claimed claim: Int) -> Int {
        guard pasteboard.changeCount == claim else {
            OtosLog.ui.noticeOperation("ui.copy", phase: "superseded", fields: [
                "requested": "\(urls.count)", "claim": "\(claim)", "changeCount": "\(pasteboard.changeCount)",
            ])
            return 0
        }
        guard let first = urls.first else {
            return 0
        }
        let accepted = pasteboard.writeObjects(urls.map(pasteboardItem(for:)))
        let written = accepted ? urls.count : 0
        let fields = [
            "requested": "\(urls.count)", "written": "\(written)",
            "changeCount": "\(pasteboard.changeCount)", "first": first.lastPathComponent,
        ]
        if accepted {
            OtosLog.ui.noticeOperation("ui.copy", phase: "written", fields: fields)
        } else {
            OtosLog.ui.errorOperation("ui.copy", phase: "refused", fields: fields)
        }
        return written
    }

    /// One file's pasteboard item: its `public.file-url` and nothing else. A drag writes the
    /// same item.
    static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }
}
