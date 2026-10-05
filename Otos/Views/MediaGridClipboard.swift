import AppKit
import Foundation
import OSLog

/// Media clipboard guide
///
/// Writes copied assets to a pasteboard as original file URLs (ADR 0012): one `NSURL`
/// per asset, in the given order, references only — no image or video bytes are read,
/// so copy is instant and never materializes a dataless cloud original. Finder pastes
/// the files; Messages and Mail attach them. The pasteboard is a parameter so the
/// write can be exercised against an isolated `NSPasteboard(name:)` in tests.
///
/// The pasteboard can refuse the write after `clearContents()` has already emptied it,
/// so the returned count is what the pasteboard accepted, and every write is logged
/// here — the one place both copy paths share.
nonisolated enum MediaGridClipboard {
    @discardableResult
    static func write(_ ids: [MediaAssetID], to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        guard let first = ids.first else {
            return 0
        }
        let accepted = pasteboard.writeObjects(ids.map { $0.fileURL as NSURL })
        let written = accepted ? ids.count : 0
        let fields = [
            "requested": "\(ids.count)", "written": "\(written)",
            "changeCount": "\(pasteboard.changeCount)", "first": first.relativePath.rawValue,
        ]
        if accepted {
            OtosLog.ui.noticeOperation("ui.copy", phase: "written", fields: fields)
        } else {
            OtosLog.ui.errorOperation("ui.copy", phase: "refused", fields: fields)
        }
        return written
    }
}
