import AppKit
import Foundation

/// Media clipboard guide
///
/// Writes copied assets to a pasteboard as original file URLs (ADR 0012): one `NSURL`
/// per asset, in the given order, references only — no image or video bytes are read,
/// so copy is instant and never materializes a dataless cloud original. Finder pastes
/// the files; Messages and Mail attach them. The pasteboard is a parameter so the
/// write can be exercised against an isolated `NSPasteboard(name:)` in tests.
nonisolated enum MediaGridClipboard {
    @discardableResult
    static func write(_ ids: [MediaAssetID], to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        guard !ids.isEmpty else {
            return 0
        }
        pasteboard.writeObjects(ids.map { $0.fileURL as NSURL })
        return ids.count
    }
}
