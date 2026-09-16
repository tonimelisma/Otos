import AppKit
import Foundation
import OSLog

/// Share intent guide
///
/// Share hands the current targets' file URLs to the system share picker and reads
/// no bytes in Otos (ADR 0012, the ⌘C rule). The targets are the same resolver Open,
/// curation and Trash use, held in `currentTargetFileURLs`.
///
/// One presenter, one anchor. The toolbar Share button, File ▸ Share… and the context
/// menus' Share… all call `shareCurrentTargets(origin:)`, and the picker always drops
/// from the toolbar Share button — Preview's and Photos' idiom — so the popover never
/// appears from the middle of the grid. When the toolbar button is not on screen (the
/// toolbar hidden or customised), the window's top-trailing corner is the fallback,
/// which is where the button lives.
nonisolated enum ShareOrigin: String, Sendable {
    case toolbar
    case menu
    case contextMenu
}

extension CatalogWindowViewModel {
    /// Called by the toolbar Share button as it enters and leaves a window.
    func setShareAnchor(_ view: NSView?) {
        shareAnchorView = view
    }

    func shareCurrentTargets(origin: ShareOrigin) {
        let items = currentTargetFileURLs
        guard !items.isEmpty else { return }
        if let anchor = shareAnchorView, anchor.window != nil {
            sharePickerPresenter.present(items, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else {
                OtosLog.ui.error("op=ui.share.noWindow count=\(items.count, privacy: .public)")
                return
            }
            let corner = NSRect(x: view.bounds.maxX - 44, y: view.bounds.maxY - 1, width: 1, height: 1)
            sharePickerPresenter.present(items, relativeTo: corner, of: view, preferredEdge: .minY)
        }
        OtosLog.ui.notice(
            "op=ui.share count=\(items.count, privacy: .public) origin=\(origin.rawValue, privacy: .public)"
        )
    }
}
