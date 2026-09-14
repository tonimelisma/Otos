import AppKit
import Foundation
import OSLog

/// Share intent guide
///
/// Share hands the current targets' file URLs to the system share picker and reads
/// no bytes in Otos (ADR 0012, the ⌘C rule). The targets are the same resolver Open,
/// curation and Trash use, held in `currentTargetFileURLs`.
///
/// Three surfaces present the same picker, each through the platform's own API for
/// that surface: the toolbar's `ShareLink`, File ▸ Share… through
/// `SharePickerPresenter`, and the context menus' standard share item. The Otos-owned
/// path is one: this ViewModel's target list. That is the recorded bend in the
/// one-path rule (plan 0103 C), chosen over bridging an `NSToolbar` to unify them.
extension CatalogWindowViewModel {
    /// File ▸ Share…. Anchors the picker to the window's top-trailing corner, below the
    /// toolbar, since a menu command has no control of its own to point at.
    func shareCurrentTargets() {
        let items = currentTargetFileURLs
        guard !items.isEmpty else { return }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else {
            OtosLog.ui.error("op=ui.share.noWindow count=\(items.count, privacy: .public)")
            return
        }
        let anchor = NSRect(x: view.bounds.maxX - 44, y: view.bounds.maxY - 1, width: 1, height: 1)
        sharePickerPresenter.present(items, relativeTo: anchor, of: view, preferredEdge: .minY)
        OtosLog.ui.notice("op=ui.share count=\(items.count, privacy: .public) origin=menu")
    }
}
