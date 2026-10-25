import AppKit
import Foundation
import OSLog

/// Media clipboard guide
///
/// Writes copied files to a pasteboard (ADR 0012): one `NSURL` per file, in the given
/// order, references only. The files are what the hand-off chose (plan 0108 increment 13):
/// an original, which is not read, so a dataless cloud original is downloaded by whoever
/// pastes it, or a full-size file prepared in Application Support. Finder pastes the
/// files; Messages, Mail and web pages attach them. The pasteboard is a parameter so the
/// write can be exercised against an isolated `NSPasteboard(name:)` in tests.
///
/// The pasteboard can refuse the write after `clearContents()` has already emptied it,
/// so the returned count is what the pasteboard accepted, and every write is logged
/// here — the one place both copy paths share.
nonisolated enum MediaGridClipboard {
    @discardableResult
    static func write(_ ids: [MediaAssetID], to pasteboard: NSPasteboard) -> Int {
        write(files: ids.map(\.fileURL), to: pasteboard)
    }

    /// One `public.file-url` per file, in order: the originals and prepared files a
    /// hand-off chose (plan 0108 increment 13).
    @discardableResult
    static func write(files urls: [URL], to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        guard let first = urls.first else {
            return 0
        }
        let accepted = pasteboard.writeObjects(urls.map { $0 as NSURL })
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
}
