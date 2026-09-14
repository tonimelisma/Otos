import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Open / Open With intents guide
///
/// File ▸ `Open in <Default>` (⌘E) and File ▸ Open With ▸ hand the current targets'
/// file URLs to LaunchServices and read no bytes in Otos (ADR 0012's rule for ⌘C,
/// extended to opening). Targets are the same current-item resolver curation and
/// Trash use: the grid's ordered selection, the loupe's focused asset, compare's
/// active pane.
///
/// The menu model is recomputed off the MainActor whenever a target writer changes
/// (`gridSelection`, `focusedAssetID`, `viewMode`, `comparePair`, `activeComparePane`
/// each call `refreshOpenWithMenu()` from `didSet`), newest-value coalesced: a newer
/// target set cancels the previous build, and a finished build is applied only if the
/// targets it was built for are still the current ones. The File menu therefore
/// renders a stored value and never queries LaunchServices during layout.
///
/// Opening itself is intentionally concurrent: two rapid opens both happen, neither
/// writes ViewModel state, and a failure is logged rather than shown — LaunchServices
/// refusing an app it just listed is not a user-actionable state.
extension CatalogWindowViewModel {
    /// File URLs of the current targets in display order; empty when nothing is targeted.
    func resolveCurrentTargetFileURLs() -> [URL] {
        mediaChoiceTargetIDs(.current).map(\.fileURL)
    }

    /// Resolves the targets once per writer change into `currentTargetFileURLs` (read
    /// synchronously by Share and the toolbar) and rebuilds the Open With model off main.
    func refreshOpenWithMenu() {
        let targets = resolveCurrentTargetFileURLs()
        if currentTargetFileURLs != targets {
            currentTargetFileURLs = targets
        }
        openWithMenuTask?.cancel()
        guard !targets.isEmpty else {
            openWithMenu = .empty
            openWithApplicationIcons = [:]
            openWithMenuTask = nil
            return
        }
        let workspace = workspace
        openWithMenuTask = Task { [weak self] in
            let model = await Self.buildOpenWithMenu(targets: targets, workspace: workspace)
            guard !Task.isCancelled, let self, currentTargetFileURLs == targets else { return }
            openWithMenu = model
            // Icon Services caches by path; resolving once per model change keeps the
            // menu body free of lookups.
            var icons: [URL: NSImage] = [:]
            for application in model.applications {
                icons[application.url] = NSWorkspace.shared.icon(forFile: application.url.path)
            }
            openWithApplicationIcons = icons
        }
    }

    @concurrent
    nonisolated static func buildOpenWithMenu(
        targets: [URL],
        workspace: any WorkspaceOpening
    ) async -> OpenWithMenuModel {
        OpenWithMenuModel.make(targets: targets, workspace: workspace)
    }

    /// ⌘E. Every target opens in its own default app; one launch-services call per app.
    func openTargetsInDefaultApplication() {
        let targets = currentTargetFileURLs
        let model = openWithMenu
        guard !targets.isEmpty, model.canOpen else { return }
        let groups = model.targetsByDefaultApplication(order: targets)
        if model.targetsWithoutDefault > 0 {
            OtosLog.ui.notice(
                "op=ui.open.noDefaultApplication count=\(model.targetsWithoutDefault, privacy: .public)"
            )
        }
        for group in groups {
            open(group.targets, with: group.application, origin: "default")
        }
    }

    /// Open With ▸ item. The whole target list goes to that app in one call.
    func openTargets(with application: OpenWithApplication) {
        let targets = currentTargetFileURLs
        guard !targets.isEmpty else { return }
        open(targets, with: application.url, origin: "openWith")
    }

    /// Open With ▸ Other…: an application chooser rooted at /Applications.
    func openTargetsWithChosenApplication() {
        let targets = currentTargetFileURLs
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let applicationURL = panel.url, let self else { return }
            open(targets, with: applicationURL, origin: "other")
        }
    }

    private func open(_ targets: [URL], with applicationURL: URL, origin: String) {
        let workspace = workspace
        let appID = Bundle(url: applicationURL)?.bundleIdentifier ?? applicationURL.lastPathComponent
        Task {
            do {
                try await workspace.open(targets, withApplicationAt: applicationURL)
                OtosLog.ui.notice(
                    "op=ui.open count=\(targets.count, privacy: .public) app=\(appID, privacy: .public) origin=\(origin, privacy: .public)"
                )
            } catch {
                let description = String(describing: error)
                OtosLog.ui.error(
                    "op=ui.open.failed app=\(appID, privacy: .public) count=\(targets.count, privacy: .public) error=\(description, privacy: .public)"
                )
            }
        }
    }
}
