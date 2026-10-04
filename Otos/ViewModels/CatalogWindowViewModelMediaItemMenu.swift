import AppKit
import Foundation
import OSLog

/// Media context menu intents guide
///
/// The context menu on a tile or pane is the menu bar's File and Photo acts for the
/// item under the cursor. This file answers two questions at the moment the menu
/// opens: what the menu contains (`mediaItemMenuModel()`) and what each item does
/// (`performMediaItemCommand(_:)`), which maps every command onto the intent the
/// corresponding menu-bar item already calls.
///
/// The model is built synchronously because the menu is opening now. A right-click
/// on an unselected tile has just changed the selection, so the off-main Open With
/// build may not have landed; in that case the LaunchServices query runs here, on the
/// MainActor, once, under a signpost — a context-menu open is a one-off user action,
/// not layout, and Finder pays the same cost on every right-click.
extension CatalogWindowViewModel {
    func mediaItemMenuModel() -> MediaItemMenuModel {
        let targets = resolveCurrentTargetFileURLs()
        guard !targets.isEmpty else { return .empty }
        let openWith: OpenWithMenuModel
        if currentTargetFileURLs == targets, openWithMenuTask == nil {
            openWith = openWithMenu
        } else {
            let span = OtosSignpost.ui.beginInterval("OpenWithMenuSync")
            openWith = OpenWithMenuModel.make(targets: targets, workspace: workspace)
            OtosSignpost.ui.endInterval("OpenWithMenuSync", span)
            openWithMenuTask?.cancel()
            openWithMenuTask = nil
            currentTargetFileURLs = targets
            applyOpenWithMenu(openWith)
            OtosLog.ui.notice("op=ui.contextMenu.openWithSync count=\(targets.count, privacy: .public)")
        }
        return MediaItemMenuModel(
            openWith: openWith,
            shareItems: targets,
            canReveal: !orderedSelectedAssetIDs.isEmpty,
            canTrash: canMoveTargetedMediaToTrash
        )
    }

    /// The `NSMenu` for the current targets; grid, filmstrip, loupe and compare all
    /// call this and nothing else.
    func makeMediaItemContextMenu() -> NSMenu? {
        let model = mediaItemMenuModel()
        guard !model.shareItems.isEmpty else { return nil }
        let mode = viewMode.rawValue
        OtosLog.ui.notice("op=ui.contextMenu.open count=\(model.shareItems.count, privacy: .public) mode=\(mode, privacy: .public)")
        return MediaItemContextMenu.make(model: model, icons: openWithApplicationIcons) { [weak self] command in
            self?.performMediaItemCommand(command)
        }
    }

    func performMediaItemCommand(_ command: MediaItemCommand) {
        switch command {
        case .open:
            openTargetsInDefaultApplication()
        case let .openWith(application):
            openTargets(with: application)
        case .openWithOther:
            openTargetsWithChosenApplication()
        case .copy:
            copySelection()
        case .share:
            shareCurrentTargets(origin: .contextMenu)
        case .revealInFinder:
            revealSelectionInFinder()
        case let .choice(choice):
            submitMediaChoice(choice, origin: .contextMenu)
        case .moveToTrash:
            moveTargetedMediaToTrash()
        }
    }
}
